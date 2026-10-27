import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  @override
  EpgProgram? getCurrentProgram(String id) => id == 'sky'
      ? EpgProgram(
          channelId: id,
          title: 'Live F1: Grand Prix Sunday',
          description:
              'Build-up to the Mexico City Grand Prix, followed by live race coverage.',
          start: DateTime.now().subtract(const Duration(minutes: 20)),
          stop: DateTime.now().add(const Duration(hours: 3)))
      : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const dir = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (dir.isEmpty) return;
    for (final e in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(e.key)
        ..addFont(File('$dir/${e.value}')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 720)
  ]) {
    testWidgets('F1 feeds fit $size, filter and keep a chosen camera',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width >= 960;
      final guide = _Guide(storage);
      final matcher = SportsChannelMatcher(guide);
      final channels = [
        for (final e in [
          ('sky', 'UK: Sky Sports F1 UHD'),
          ('tv', 'F1: F1-TV'),
          ('oscar', 'F1: OSCAR PIASTRI | MCLAREN | PIA'),
          ('lando', 'F1: LANDO NORRIS | MCLAREN | NOR'),
          ('track', 'F1: F1-TRACKER'),
          ('data', 'F1: F1-DATA')
        ])
          Channel(
              id: e.$1,
              rawId: e.$1,
              playlistId: 'test',
              name: e.$2,
              group: 'UK| FORMULA 1 PPV',
              url: 'https://example.invalid/never-play')
      ];
      await tester.runAsync(() => matcher.prepare(channels));
      final game = SportsGame(
          id: 'race',
          league: sportsLeagueById('racing.f1')!,
          start: DateTime.now().add(const Duration(hours: 1)),
          state: GameState.pre,
          statusText: 'Scheduled',
          home: const SportsTeam(
              id: '', name: '', shortName: '', abbreviation: ''),
          away: const SportsTeam(
              id: '', name: '', shortName: '', abbreviation: ''),
          event: const SportsEventInfo(
              title: 'Mexico City Grand Prix', session: 'Race'));
      final matches = [
        for (final c in channels)
          ChannelMatch(
              c,
              ['sky', 'tv'].contains(c.id)
                  ? MatchReason.network
                  : MatchReason.sport,
              ['sky', 'tv'].contains(c.id) ? 365 : 65,
              detail: ['sky', 'tv'].contains(c.id)
                  ? 'Dedicated F1 coverage · scheduled session'
                  : null)
      ];
      SportsChannelChoice? chosen;
      await tester.pumpWidget(RepaintBoundary(
          key: const ValueKey('capture'),
          child: MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: prefs),
                ChangeNotifierProvider<EpgService>.value(value: guide)
              ],
              child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: buildAppTheme(prefs.palette),
                  home: Builder(
                      builder: (context) => Scaffold(
                          body: Center(
                              child: TextButton(
                                  child: const Text('Open'),
                                  onPressed: () async {
                                    chosen =
                                        await showDialog<SportsChannelChoice>(
                                            context: context,
                                            builder: (_) =>
                                                SportsChannelPickerDialog(
                                                    game: game,
                                                    matcher: matcher,
                                                    matches: matches,
                                                    tileMatch: matches.first));
                                  }))))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<SportsChannelList>(find.byType(SportsChannelList))
              .rows
              .first
              .channel
              .id,
          'sky');
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')));
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/iptv-f1-picker-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final onboard = find.byKey(const ValueKey('f1-feed-onboard'));
      await tester.ensureVisible(onboard);
      await tester.pumpAndSettle();
      await tester.tap(onboard);
      await tester.pumpAndSettle();
      final rows =
          tester.widget<SportsChannelList>(find.byType(SportsChannelList)).rows;
      expect(
          rows.map((r) => r.channel.id), unorderedEquals(['oscar', 'lando']));
      expect(tester.takeException(), isNull);
      if (prefs.isTelevision) {
        final ink = tester
            .widget<InkWell>(find.byKey(const ValueKey('game-channel:oscar')));
        ink.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        // In short landscape view a detailed row can exceed the viewport.
        // Tap its visible channel heading rather than an offscreen centre.
        final row = find.byKey(const ValueKey('game-channel:oscar'));
        await tester.tapAt(tester.getTopLeft(row) + const Offset(24, 24));
      }
      await tester.pumpAndSettle();
      expect(chosen?.channel?.id, 'oscar');
      await tester.pumpWidget(const SizedBox());
      guide.dispose();
      prefs.dispose();
    });
  }
}
