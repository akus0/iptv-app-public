import 'dart:async';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/screens/settings/group_management_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/screens/settings/settings_workspace.dart';
import 'package:nox_iptv/screens/settings/settings_menu_screen.dart';
import 'package:nox_iptv/screens/settings/add_playlist_screen.dart';
import 'package:nox_iptv/screens/settings/general_settings_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/player_controls.dart';
import 'package:nox_iptv/widgets/settings_navigation.dart';
import 'package:nox_iptv/widgets/settings_scaffold.dart';
import 'package:nox_iptv/widgets/tv_menu_tile.dart';
import 'player_polish_test.dart' as fixture;

class _Playlist extends fixture.Playlist {
  _Playlist(super.storage);
  Completer<void>? save;
  @override
  List<M3uGroup> groupsForPlaylist(String id, String type) => [
        M3uGroup(title: 'Sports category', playlistId: id, channels: const []),
      ];
  @override
  Future<void> setGroupHidden(String playlistId, String groupTitle, bool hidden,
      {bool loadImmediately = true, String type = 'tv'}) async {
    await save?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });
  late StorageService storage;
  late AppPreferences prefs;
  late _Playlist playlist;
  late fixture.Guide guide;
  late fixture.Playback playback;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    prefs = AppPreferences(storage);
    await prefs.init();
    playlist = _Playlist(storage);
    guide = fixture.Guide(storage);
    playback = fixture.Playback(storage, playlist);
    playback.currentChannel = fixture.channel(0);
    playback.controller = fixture.Controller();
  });
  tearDown(() {
    playback.dispose();
    playlist.dispose();
    guide.dispose();
    prefs.dispose();
  });
  Future<void> open(WidgetTester tester, Size size, {double scale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    prefs.isTelevision = size.width >= 960;
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
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.of(context).push(SettingsRoute(
                          builder: (_) => const SettingsWorkspace())),
                      child: const Text('Open settings')))),
        )));
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    if (target.evaluate().isEmpty) {
      final scroll = find.byType(Scrollable).last;
      tester.state<ScrollableState>(scroll).position.jumpTo(0);
      await tester.pumpAndSettle();
      if (target.evaluate().isEmpty) {
        await tester.scrollUntilVisible(target, 180, scrollable: scroll);
      }
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540),
    const Size(1280, 720)
  ]) {
    testWidgets('settings workspace preserves player and nested Back at $size',
        (tester) async {
      await open(tester, size, scale: size.width == 320 ? 1.4 : 1);
      final controller = playback.controller;
      final preview = tester.element(find.byType(VideoPlayerPane));
      final pane = tester.getRect(find.byType(SettingsMenuScreen));
      final video =
          tester.getRect(find.byKey(const ValueKey('settings-preview-column')));
      if (size.width >= 700) {
        expect(pane.left, greaterThan(video.right));
      } else {
        expect(pane.width, size.width);
      }
      await tap(tester, 'Playback & preferences');
      expect(tester.element(find.byType(VideoPlayerPane)), same(preview));
      await tap(tester, 'Playback at startup');
      final dialog = tester.getRect(find.byType(AlertDialog));
      expect(dialog.left, greaterThanOrEqualTo(pane.left));
      expect(dialog.right, lessThanOrEqualTo(pane.right));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(GeneralSettingsScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsMenuScreen), findsOneWidget);
      expect(tester.element(find.byType(VideoPlayerPane)), same(preview));
      await tap(tester, 'Playlists & guide');
      await tap(tester, 'Add playlist');
      expect(find.byKey(const ValueKey('playlist-save')).hitTestable(),
          findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AddPlaylistScreen), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsMenuScreen), findsOneWidget);
      expect(playback.controller, same(controller));
      expect(playlist.loads, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsWorkspace), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await playback.stop();
    });
  }
  testWidgets('rotation retains the nested page, input and preview element',
      (tester) async {
    await open(tester, const Size(390, 844));
    await tap(tester, 'Playlists & guide');
    await tap(tester, 'Add playlist');
    final page = tester.state(find.byType(AddPlaylistScreen));
    final preview = tester.element(find.byType(VideoPlayerPane));
    final name = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Name');
    await tester.enterText(name, 'My playlist');
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(AddPlaylistScreen)), same(page));
    expect(tester.element(find.byType(VideoPlayerPane)), same(preview));
    expect(tester.widget<TextField>(name).controller!.text, 'My playlist');
    expect(find.byKey(const ValueKey('playlist-save')).hitTestable(),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await playback.stop();
  });
  testWidgets('remote enters settings and restores the selected row after Back',
      (tester) async {
    await open(tester, const Size(1280, 720));
    final entry = find.widgetWithText(TvMenuTile, 'Playlists & guide');
    expect(Focus.of(tester.element(find.text('Playlists & guide'))).hasFocus,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('TV guide'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(entry, findsOneWidget);
    expect(Focus.of(tester.element(find.text('Playlists & guide'))).hasFocus,
        isTrue);
    SettingsNavigation.returnToApp(tester.element(entry));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsWorkspace), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await playback.stop();
  });
  testWidgets(
      'nested Back and toolbar Back respect an unfinished category save',
      (tester) async {
    await open(tester, const Size(1280, 720));
    Navigator.of(tester.element(find.byType(SettingsMenuScreen))).push(
        SettingsRoute<bool>(
            builder: (_) => const GroupManagementScreen(playlistId: 'test')));
    await tester.pumpAndSettle();
    playlist.save = Completer<void>();
    await tap(tester, 'Sports category');
    expect(find.text('Saving...'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(GroupManagementScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupManagementScreen), findsOneWidget);
    playlist.save!.complete();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(GroupManagementScreen), findsNothing);
    expect(find.byType(SettingsMenuScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await playback.stop();
  });
  testWidgets('TV editor consumes Back before leaving a nested playlist form',
      (tester) async {
    await open(tester, const Size(1280, 720));
    await tap(tester, 'Playlists & guide');
    await tap(tester, 'Add playlist');
    final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Name');
    tester.widget<TextField>(field).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tester.widget<TextField>(field).readOnly, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AddPlaylistScreen), findsOneWidget);
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AddPlaylistScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await playback.stop();
  });
  testWidgets('portrait keyboard keeps the save action reachable with preview',
      (tester) async {
    await open(tester, const Size(390, 844));
    await tap(tester, 'Playlists & guide');
    await tap(tester, 'Add playlist');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlist-save')).hitTestable(),
        findsOneWidget);
    expect(
        tester
            .getRect(find.byKey(const ValueKey('settings-preview-column')))
            .height,
        64);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await playback.stop();
  });
}
