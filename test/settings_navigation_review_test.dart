import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:nox_iptv/services/additional_licenses.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/screens/settings/settings_workspace.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'player_polish_test.dart' as fixture;

class _Playlists extends fixture.Playlist {
  _Playlists(super.storage);
  final extraProfiles = <PlaylistProfile>[];
  @override
  List<PlaylistProfile> get profiles => [
        PlaylistProfile(
            id: 'p',
            name: 'Example sports',
            mode: 'xtream',
            sortOrder: 0,
            createdAt: DateTime(2026),
            xtreamServer: 'https://example.invalid',
            xtreamUsername: 'demo',
            categoryLayout: 'organised'),
        PlaylistProfile(
            id: 'q',
            name: 'Example channels',
            mode: 'm3u',
            sortOrder: 1,
            createdAt: DateTime(2026),
            m3uUrl: 'https://example.invalid/list.m3u',
            categoryLayout: 'provider'),
        ...extraProfiles,
      ];
  @override
  List<M3uGroup> groupsForPlaylist(String id, String type) => [
        for (var i = 0; i < 90; i++)
          M3uGroup(
              title:
                  '${type == 'tv' ? 'Sports' : 'Entertainment'} category ${i + 1}',
              playlistId: id,
              channels: channels.take(3).toList()),
      ];
  @override
  Future<void> ensureLibraryCategoriesFor(String id) async {}
  @override
  List<Channel> hiddenChannelsFor(String playlistId) =>
      channels.take(20).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<LicenseEntry> licenceEntries;
  setUpAll(() async {
    registerAdditionalLicenses();
    licenceEntries = await LicenseRegistry.licenses.toList();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (fonts.isNotEmpty) {
      for (final entry in {
        'Roboto': 'Roboto-Regular.ttf',
        'monospace': 'Roboto-Regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf'
      }.entries) {
        await (FontLoader(entry.key)
              ..addFont(File('$fonts/${entry.value}')
                  .readAsBytes()
                  .then(ByteData.sublistView)))
            .load();
      }
    }
  });
  for (final size in [
    const Size(960, 540),
    const Size(844, 390),
    const Size(390, 844)
  ]) {
    testWidgets('settings routes, dialogs and remote traversal fit $size',
        (tester) async {
      // Reuse decoded notices without futures bound to an earlier test zone.
      LicenseRegistry.reset();
      LicenseRegistry.addLicense(() => Stream.fromIterable(licenceEntries));
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width == 960;
      final playlist = _Playlists(storage);
      final guide = fixture.Guide(storage);
      final playback = fixture.Playback(storage, playlist);
      playback.currentChannel = fixture.channel(0);
      playback.controller = fixture.Controller();
      final capture = GlobalKey();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<EpgService>.value(value: guide),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              builder: (_, child) =>
                  RepaintBoundary(key: capture, child: child),
              home: const SettingsWorkspace())));
      await tester.pumpAndSettle();
      Future<void> snapshot(String name) async {
        expect(tester.takeException(), isNull, reason: name);
        const output = String.fromEnvironment('SETTINGS_CAPTURE_DIR');
        if (output.isEmpty) return;
        await tester.runAsync(() async {
          final image = await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$output/${size.width.toInt()}-$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> tap(String label) async {
        final matches = find.text(label);
        var target = matches;
        if (matches.evaluate().isNotEmpty) target = matches.last;
        if (target.evaluate().isEmpty) {
          final scroll = find.byType(Scrollable).last;
          tester.state<ScrollableState>(scroll).position.jumpTo(0);
          await tester.pumpAndSettle();
          if (target.evaluate().isEmpty) {
            await tester.scrollUntilVisible(target, 180,
                scrollable: scroll, maxScrolls: 30);
          }
        }
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        if (label == 'Open-source licences') {
          for (var i = 0; i < 30; i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 50)));
            await tester.pump(const Duration(milliseconds: 100));
            if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
              break;
            }
          }
          expect(find.byType(CircularProgressIndicator), findsNothing);
          await tester.pumpAndSettle();
        } else if (label == 'From phone') {
          await tester.pump(const Duration(milliseconds: 200));
        } else {
          await tester.pumpAndSettle();
        }
      }

      Future<void> back() async {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }

      final layoutMetrics = <String, Object>{};
      Future<void> scan(String name, {int count = 15}) async {
        await snapshot(name);
        final scrolls = find
            .byType(Scrollable)
            .evaluate()
            .where((e) => ModalRoute.of(e)?.isCurrent != false)
            .map((e) => (e as StatefulElement).state as ScrollableState)
            .toList();
        layoutMetrics[name] = [
          for (final state in scrolls)
            {
              'viewport': state.position.viewportDimension,
              'overflow': state.position.maxScrollExtent
            }
        ];
        if (const String.fromEnvironment('SETTINGS_CAPTURE_DIR').isNotEmpty) {
          final positions = [
            for (final state in scrolls) state.position.pixels
          ];
          for (final state in scrolls) {
            if (state.position.maxScrollExtent > 0) {
              state.position.jumpTo(state.position.maxScrollExtent);
            }
          }
          await tester.pump();
          await snapshot('$name-bottom');
          for (var i = 0; i < scrolls.length; i++) {
            scrolls[i].position.jumpTo(positions[i]);
          }
          await tester.pump();
        }
        if (!prefs.isTelevision) return;
        const expected = {
          'settings': [
            'Playlists & guide',
            'Movies & series',
            'Playback & preferences',
            'Appearance',
            'About iptv-app'
          ],
          'general': [
            'Language',
            '24-hour clock',
            'Playback at startup',
            'Watch multiple channels',
            'Show resume reminder',
            'Clear search & channel history'
          ],
          'appearance': ['Dark grey', 'OLED black', 'Light'],
          'library': [
            'Show Movies tab',
            'Show Series tab',
            'Choose content in your playlists',
            'Refresh categories'
          ],
          'playlists': [
            'TV guide',
            'Refresh playlists',
            'Add playlist',
            'Playlist order',
            'Example sports',
            'Example channels'
          ],
          'guide': ['Refresh guide', 'Add XMLTV guide', 'Clear guide listings'],
          'custom-guide': ['Name (optional)', 'XMLTV URL', 'Cancel', 'Save'],
          'content': ['Live TV', 'Movies', 'Series', 'Cancel', 'Save'],
          'user-agent': ['Default (recommended)', 'Custom…', 'Cancel'],
          'user-agent-custom': ['User-agent value', 'Cancel', 'Save'],
          'backup': ['Server address', 'Cancel', 'Add'],
          'categories': ['Search', 'Done'],
          'hidden': ['Unhide'],
        };
        final seen = <String>{};
        void collect() {
          final node = FocusManager.instance.primaryFocus;
          if (node == null || node is FocusScopeNode) return;
          final context = node.context;
          if (context is! Element) return;
          void visit(Element e) {
            if (e.widget case Text(:final data?)) seen.add(data);
            if (e.widget case TextField(:final decoration?)) {
              if (decoration.labelText != null) seen.add(decoration.labelText!);
            }
            e.visitChildren(visit);
          }

          visit(context);
          context.visitAncestorElements((e) {
            if (e.widget case TextField(:final decoration?)) {
              if (decoration.labelText != null) seen.add(decoration.labelText!);
              return false;
            }
            return e.widget is! Scaffold;
          });
        }

        collect();
        if (name == 'guide') {
          final intervalFocus = tester
              .widgetList<Focus>(find.descendant(
                  of: find.byType(DropdownButton<int>),
                  matching: find.byType(Focus)))
              .firstWhere((w) => w.focusNode != null);
          intervalFocus.focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          collect();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pumpAndSettle();
        }
        // Traverse both axes: dialog actions and toolbar controls share rows.
        for (final key in [
          ...List.filled(count, LogicalKeyboardKey.arrowDown),
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowLeft,
          ...List.filled(count, LogicalKeyboardKey.arrowUp),
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
          collect();
          expect(tester.takeException(), isNull,
              reason: '$name ${key.keyLabel}');
        }
        for (final label in expected[name] ?? <String>[]) {
          expect(seen, contains(label),
              reason: '$name must reach $label by D-pad');
        }
      }

      await scan('settings');
      await tap('Playback & preferences');
      await scan('general');
      await tap('Language');
      await scan('language', count: 5);
      await back();
      await tap('Playback at startup');
      await scan('startup', count: 5);
      await tap('Cancel');
      await tap('Clear search & channel history');
      await snapshot('history');
      await tap('Cancel');
      await back();
      await tap('Appearance');
      await scan('appearance', count: 5);
      await back();
      await tap('Movies & series');
      await scan('library');
      await back();
      await tap('About iptv-app');
      await scan('about');
      await tap('Open-source licences');
      await tester.pumpAndSettle();
      await scan('licences', count: 4);
      await back();
      await back();
      await tap('Playlists & guide');
      await scan('playlists');
      await tap('Refresh playlists');
      await scan('refresh-confirmation', count: 3);
      if (size.width > size.height) {
        expect(tester.getRect(find.byType(AlertDialog)).left,
            greaterThan(size.width * .35),
            reason: 'Settings confirmations must leave the preview clear');
      }
      await tap('Cancel');
      await tap('Playlist order');
      await scan('priority');
      if (prefs.isTelevision) {
        Focus.of(tester.element(find.text('Live TV'))).requestFocus();
        await tester.pump();
        for (final label in ['Movies order', 'Series order']) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pumpAndSettle();
          expect(find.text(label), findsOneWidget);
        }
      }
      await back();
      await tap('TV guide');
      await scan('guide', count: 30);
      await tap('Every 12 hours');
      await snapshot('guide-interval');
      await back();
      await tap('Add XMLTV guide');
      await scan('custom-guide', count: 5);
      await tap('Save');
      await snapshot('custom-guide-validation');
      await tap('Cancel');
      await tap('Clear guide listings');
      await snapshot('clear-guide');
      await tap('Cancel');
      await back();
      await tap('Add playlist');
      for (final mode in [
        'M3U URL',
        'Xtream Codes',
        'Stalker / MAC',
        'Smart Add',
        'From phone'
      ]) {
        await tap(mode);
        if (mode == 'From phone') {
          await snapshot('add-phone');
        } else {
          await scan('add-${mode.split(' ').first}', count: 18);
          if (mode == 'Xtream Codes') {
            await tap('Content from this playlist');
            await scan('new-playlist-content', count: 6);
            await tap('Cancel');
          }
          if (mode == 'Stalker / MAC') {
            await tap('Additional provider details');
            await scan('add-stalker-advanced', count: 24);
          }
        }
      }
      await back();
      await tap('Example sports');
      await scan('playlist-detail', count: 22);
      await tap('Keep provider categories');
      await snapshot('organisation');
      await back();
      await tap('Connection details');
      await scan('connection-details', count: 3);
      await tap('Close');
      await tap('3 days');
      await snapshot('playlist-update-interval');
      await back();
      final edit = find.byTooltip('Edit login');
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await scan('edit-playlist', count: 22);
      await back();
      await tester.tap(find.byTooltip('Delete playlist'));
      await tester.pumpAndSettle();
      await snapshot('delete-playlist');
      await tap('Cancel');
      await tap('Content from this playlist');
      await scan('content', count: 6);
      await tap('Cancel');
      await tap('User agent');
      await scan('user-agent', count: 9);
      await tap('Custom…');
      await scan('user-agent-custom', count: 4);
      await tap('Cancel');
      await tap('Add backup server');
      await scan('backup', count: 5);
      await tap('Cancel');
      await tap('Manage categories');
      await scan('categories', count: 30);
      await tap('Example sports');
      await snapshot('category-playlists');
      await back();
      for (final type in ['Movies', 'Series', 'Live TV']) {
        await tap(type);
        await snapshot('categories-${type.split(' ').first}');
      }
      await tap('Done');
      await tap('Hidden channels');
      await scan('hidden', count: 25);
      await back();
      await back();
      await tap('Example channels');
      await scan('m3u-detail');
      await tap('Connection details');
      await scan('m3u-connection', count: 3);
      await tap('Close');
      await back();
      playlist.extraProfiles.add(PlaylistProfile(
          id: 'portal',
          name: 'Example portal',
          mode: 'stalker',
          createdAt: DateTime(2026),
          sortOrder: 2,
          portalUrl: 'https://example.invalid/stalker_portal/c/',
          portalMac: '00:1A:79:00:00:01'));
      playlist.notifyListeners();
      await tester.pumpAndSettle();
      await tap('Example portal');
      await scan('portal-detail', count: 22);
      await tap('Connection details');
      await scan('portal-connection', count: 3);
      await tap('Close');
      await back();
      const captureDir = String.fromEnvironment('SETTINGS_CAPTURE_DIR');
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() =>
            File('$captureDir/${size.width.toInt()}-metrics.json')
                .writeAsString(jsonEncode(layoutMetrics)));
      }
      expect(playlist.loads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      playback.dispose();
      playlist.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }
}
