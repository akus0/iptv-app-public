import 'package:nox_iptv/widgets/sports_activity_status.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/replay_schedule_service.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/sports_replays_panel.dart';

final channel = Channel(
    id: 'test::sports',
    rawId: 'sports',
    playlistId: 'test',
    name: 'Sports',
    group: 'Sports',
    url: 'https://example.invalid/never-play');

ReplaySnapshot snapshot(String title) {
  final now = DateTime.now();
  final event = SportsReplay(sport: 'racing', title: title, broadcasts: [
    ReplayBroadcast(
        channel,
        EpgProgram(
            channelId: channel.epgId,
            title: title,
            start: now.subtract(const Duration(minutes: 10)),
            stop: now.add(const Duration(hours: 1))))
  ]);
  return ReplaySnapshot([event], 1, highlights: [event]);
}

class _Playlist extends PlaylistManager {
  _Playlist(StorageService storage) : super(storage, CatalogDatabase());
  List<Channel> rows = [channel];
  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      rows;
}

class _HeldReplays extends SportsReplayService {
  _HeldReplays(super.epg);
  final pending = <Completer<ReplaySnapshot>>[];
  final forces = <bool>[];
  final inputs = <List<Channel>>[];
  int running = 0, peak = 0;
  @override
  Future<ReplaySnapshot> load(List<Channel> channels,
      {required Object revision, DateTime? at, bool force = false}) {
    final task = Completer<ReplaySnapshot>();
    pending.add(task);
    forces.add(force);
    inputs.add(channels);
    running++;
    if (running > peak) peak = running;
    return task.future.whenComplete(() => running--);
  }
}

class _FailingDates extends ReplayScheduleService {
  _FailingDates() : super(fetch: (_, __) async => [], cached: () => []);
  @override
  Future<void> enrich(List<SportsReplay> events,
      {required bool Function() cancelled,
      required void Function() onUpdate}) async {
    throw StateError('Optional date source failed');
  }
}

void main() {
  for (final highlights in [false, true]) {
    testWidgets(
        'sport headings pin within their section and focus clears them: highlights=$highlights',
        (tester) async {
      tester.view.physicalSize = const Size(650, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final guide = EpgService(storage);
      final playlist = _Playlist(storage);
      final service = _HeldReplays(guide);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<EpgService>.value(value: guide),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ],
          child: MaterialApp(
              home: Scaffold(
                  body: SportsReplaysPanel(
                      active: true,
                      highlights: highlights,
                      service: service,
                      dateService: _FailingDates(),
                      onPlay: (_) async {})))));
      await tester.pump();
      final now = DateTime.now();
      final events = [
        for (final sport in ['darts', 'poker', 'tennis'])
          for (var i = 0; i < 8; i++)
            SportsReplay(
                sport: sport,
                title: '$sport programme $i',
                broadcasts: [
                  ReplayBroadcast(
                      Channel(
                          id: '$sport-$i',
                          rawId: '$sport-$i',
                          playlistId: 'test',
                          name: 'Channel $i',
                          group: 'Sport',
                          url: 'https://example.invalid/never-play'),
                      EpgProgram(
                          channelId: '$sport-$i',
                          title: '$sport programme $i',
                          description:
                              'Extended coverage of $sport, with the key moments, competitors and venue details from this programme. (Sports)',
                          start: now.subtract(const Duration(minutes: 15)),
                          stop: now.add(const Duration(hours: 1))))
                ])
      ];
      service.pending.single
          .complete(ReplaySnapshot(events, events.length, highlights: events));
      await tester.pumpAndSettle();
      final synopsis = find.text(
          'Extended coverage of darts, with the key moments, competitors and venue details from this programme.');
      expect(synopsis, findsWidgets,
          reason: 'Both replay and highlight cards include the guide synopsis');
      expect(tester.widget<Text>(synopsis.first).maxLines, greaterThan(1));
      final scrollFinder = find.byKey(const ValueKey('replays-scroll'));
      final scroll = tester.widget<CustomScrollView>(scrollFinder).controller!;
      final top = tester.getTopLeft(scrollFinder).dy;
      final darts = find.byKey(const ValueKey('replay-heading-darts'));
      final poker = find.byKey(const ValueKey('replay-heading-poker'));
      scroll.jumpTo(180);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(darts).dy, closeTo(top, .1));
      final visible = find
          .byWidgetPredicate((w) =>
              w is InkWell &&
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('replay-darts'))
          .evaluate()
          .where((element) {
            final rect = tester.getRect(find.byWidget(element.widget));
            return rect.top >= top + 30 &&
                rect.bottom < tester.getBottomRight(scrollFinder).dy;
          })
          .first
          .widget as InkWell;
      final beforeFocus = scroll.offset;
      visible.focusNode!.requestFocus();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(beforeFocus, .1),
          reason: 'Fully visible focus must not scroll');

      expect(find.text('darts programme 7'), findsNothing,
          reason: 'Cards remain lazily built');
      for (var i = 0;
          i < 30 &&
              (poker.evaluate().isEmpty ||
                  tester.getTopLeft(poker).dy > top + .1);
          i++) {
        scroll.jumpTo(
            (scroll.offset + 90).clamp(0, scroll.position.maxScrollExtent));
        await tester.pumpAndSettle();
      }
      expect(tester.getTopLeft(poker).dy, closeTo(top, .1));
      if (darts.evaluate().isNotEmpty) {
        expect(tester.getBottomRight(darts).dy, lessThanOrEqualTo(top + .1));
      }
      final visibleCard = find.byWidgetPredicate((w) =>
          w is InkWell &&
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('replay-poker'));
      expect(visibleCard, findsWidgets);
      tester.widget<InkWell>(visibleCard.first).focusNode!.requestFocus();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(visibleCard.first).dy,
          greaterThanOrEqualTo(tester.getBottomRight(poker).dy - .1));
      expect(tester.takeException(), isNull);
      // Refresh is directly reachable and returns to the same replay/highlight.
      final current = tester.widget<InkWell>(visibleCard.first).focusNode!;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'replays-refresh');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(current.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
          tester
              .widget<SportsFilterButton>(
                  find.byKey(const ValueKey('replay-sport-picker')))
              .focusNode!
              .hasFocus,
          isTrue);
      await tester.pumpWidget(const SizedBox());
      playlist.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }
  for (final highlights in [false, true]) {
    testWidgets(
        'guide updates coalesce and survive pause/retry, highlights=$highlights',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final guide = EpgService(storage);
      final playlist = _Playlist(storage);
      final service = _HeldReplays(guide);
      final key = GlobalKey<SportsReplaysPanelState>();
      Widget app({bool active = true}) => MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: prefs),
                ChangeNotifierProvider<EpgService>.value(value: guide),
                ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ],
              child: MaterialApp(
                  home: Scaffold(
                      body: SportsReplaysPanel(
                          key: key,
                          active: active,
                          highlights: highlights,
                          service: service,
                          dateService: _FailingDates(),
                          onPlay: (_) async {}))));
      await tester.pumpWidget(app());
      await tester.pump();
      expect(service.pending, hasLength(1));
      for (var i = 0; i < 50; i++) {
        guide.guideRowsLoaded.value++;
      }
      final forced = key.currentState!.refresh(force: true);
      expect(key.currentState!.refresh(), same(forced));
      expect(service.pending, hasLength(1));
      service.pending.first.complete(snapshot('First replay'));
      await tester.pump();
      expect(service.pending, hasLength(2));
      expect(service.forces, [false, true]);
      service.pending.last.complete(snapshot('Updated replay'));
      await tester.pumpAndSettle();
      expect(await forced, true);
      expect(service.pending, hasLength(2));
      expect(find.text('Updated replay'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'optional date failure cannot break guide browsing');

      // Rows arriving while idle also refresh without a general guide notification.
      guide.guideRowsLoaded.value++;
      await tester.pump(const Duration(milliseconds: 210));
      expect(service.pending, hasLength(3));
      playlist.rows = [];
      playlist.notifyListeners();
      service.pending.last.complete(snapshot('Removed channel result'));
      await tester.pump();
      expect(find.text('Removed channel result'), findsNothing);
      expect(service.pending, hasLength(4));
      expect(service.inputs.last, isEmpty);
      service.pending.last.complete(snapshot('Current catalogue'));
      await tester.pumpAndSettle();

      // A background panel must not start its queued scan or periodic scans.
      final background = key.currentState!.refresh();
      key.currentState!.refresh(force: true);
      await tester.pump();
      final count = service.pending.length;
      await tester.pumpWidget(app(active: false));
      service.pending.last.complete(snapshot('Before pause'));
      await tester.pumpAndSettle();
      await background;
      await tester.pump(const Duration(seconds: 31));
      expect(service.pending, hasLength(count));
      await tester.pumpWidget(app());
      await tester.pump();
      expect(service.pending, hasLength(count + 1));
      expect(service.forces.last, true);
      service.pending.last.completeError(StateError('Guide unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Before pause'), findsOneWidget);
      expect(
          tester
              .widget<SportsActivityLine>(find.byType(SportsActivityLine))
              .details,
          'Couldn’t read the guide. Tap refresh to retry.');
      final retry = key.currentState!.refresh(force: true);
      await tester.pump();
      service.pending.last.complete(snapshot('Recovered replay'));
      await tester.pumpAndSettle();
      expect(await retry, true);
      expect(find.text('Recovered replay'), findsOneWidget);
      expect(
          tester
              .widget<SportsActivityLine>(find.byType(SportsActivityLine))
              .hasError,
          isFalse);
      expect(service.peak, 1);
      expect(tester.takeException(), isNull);

      // A late completion after closing cannot restart work or touch disposed UI.
      final closing = key.currentState!.refresh();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      service.pending.last.complete(snapshot('Too late'));
      await tester.pump();
      expect(await closing, false);
      guide.guideRowsLoaded.value++;
      expect(tester.takeException(), isNull);
      playlist.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }
}
