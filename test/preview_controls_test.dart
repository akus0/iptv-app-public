import 'package:nox_iptv/widgets/player_stream_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/screens/player_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/iptv_bottom_bar.dart';
import 'package:nox_iptv/widgets/player_controls.dart';
import 'package:nox_iptv/widgets/preview_player_controls.dart';
import 'package:nox_iptv/widgets/preview_pip_launcher.dart';

class _Controller extends VideoPlayerHdrController {
  _Controller({bool initialized = true})
      : super.networkUrl(Uri.parse('https://example.test/live')) {
    value = VideoPlayerHdrValue(
        duration: Duration.zero,
        isInitialized: initialized,
        isPlaying: true,
        size: const Size(1920, 1080),
        volume: .6);
  }
  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    value = value.copyWith(volume: volume);
  }

  @override
  bool isVideoTrackSupportAvailable() => false;
  @override
  bool isAudioTrackSupportAvailable() => false;
}

class _Playback extends PlaybackService {
  _Playback(super.storage, super.playlist);
  int reloads = 0;
  @override
  Future<void> play(Channel channel) async {
    currentChannel = channel;
  }

  @override
  Future<void> reloadCurrentChannel() async {
    reloads++;
  }
}

class _Epg extends EpgService {
  _Epg(super.storage);
  @override
  List<EpgProgram> getPrograms(String id) => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
  });
  late StorageService storage;
  late PlaylistManager playlist;
  late _Playback playback;
  late AppPreferences prefs;
  late _Epg epg;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    playlist = PlaylistManager(storage, CatalogDatabase());
    playback = _Playback(storage, playlist);
    prefs = AppPreferences(storage);
    await prefs.init();
    epg = _Epg(storage);
  });
  void playerTestWidgets(String description, WidgetTesterCallback callback) {
    testWidgets(description, (tester) async {
      try {
        await callback(tester);
      } finally {
        await playback.stop();
      }
    });
  }

  tearDown(() {
    playback.dispose();
    playlist.dispose();
    prefs.dispose();
    epg.dispose();
  });
  Widget app(Widget child) => MultiProvider(providers: [
        Provider.value(value: storage),
        ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        ChangeNotifierProvider<PlaybackService>.value(value: playback),
        ChangeNotifierProvider<AppPreferences>.value(value: prefs),
        ChangeNotifierProvider<EpgService>.value(value: epg),
      ], child: MaterialApp(home: child));

  playerTestWidgets(
      'TV Info is one Up press away and holding OK opens details once',
      (tester) async {
    prefs.isTelevision = true;
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final channel = Channel(
        id: 'p::1',
        rawId: '1',
        playlistId: 'p',
        name: 'Tennis',
        group: 'Sport',
        url: 'https://example.invalid/never-play');
    final controller = _Controller(initialized: false);
    playback.currentChannel = channel;
    playback.controller = controller;
    await tester.pumpWidget(app(PlayerScreen(channel: channel)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'player-stream-info');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(PlayerStreamInfo), findsOneWidget);
    Navigator.of(tester.element(find.byType(PlayerStreamInfo))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    FocusManager.instance.rootScope.descendants
        .singleWhere((n) => n.debugLabel == 'player-root')
        .requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(PlayerStreamInfo), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.byType(PlayerStreamInfo), findsOneWidget,
        reason: 'Release must not activate a dialog control');
    expect(playback.controller, same(controller));
    expect(playback.reloads, 0);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'automatic preview PiP presents one player route with the same controller',
      (tester) async {
    final key = GlobalKey<NavigatorState>();
    final controller = _Controller();
    final channel = Channel(
        id: 'p::1',
        rawId: '1',
        playlistId: 'p',
        name: 'Tennis',
        group: 'Sport',
        url: 'https://example.invalid/never-play');
    playback.currentChannel = channel;
    playback.controller = controller;
    await tester.pumpWidget(app(MaterialApp(
        navigatorKey: key,
        builder: (_, child) => Stack(children: [
              child!,
              PreviewPipLauncher(
                  navigatorKey: key,
                  playerBuilder: (c) => Scaffold(body: Text('PiP: ${c.name}'))),
            ]),
        home: const Scaffold(body: Text('Preview')))));
    Future<void> mode(bool active) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              'com.nox.nox_iptv/picture_in_picture',
              const StandardMethodCodec()
                  .encodeMethodCall(MethodCall('modeChanged', active)),
              (_) {});
      await tester.pumpAndSettle();
    }

    await mode(true);
    expect(find.text('PiP: Tennis'), findsOneWidget);
    await mode(true);
    await mode(false);
    expect(playback.controller, same(controller));
    expect(playback.reloads, 0);
    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Preview'), findsOneWidget);
    expect(key.currentState!.canPop(), false);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'auto PiP is enabled only while the phone preview route is visible',
      (tester) async {
    const method = MethodChannel('com.nox.nox_iptv/picture_in_picture');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null));
    playback.pictureInPicture.supported = true;
    playback.currentChannel = Channel(
        id: 'p::1',
        rawId: '1',
        playlistId: 'p',
        name: 'Tennis',
        group: 'Sport',
        url: 'https://example.invalid/never-play');
    playback.controller = _Controller();
    await tester.pumpWidget(app(Scaffold(
        body: PreviewPlayerControls(
            onFullscreen: () {},
            child: const SizedBox(width: 320, height: 180)))));
    await tester.pumpAndSettle();
    bool enabled() =>
        (calls.lastWhere((c) => c.method == 'update').arguments
            as Map)['enabled'] ==
        true;
    expect(enabled(), true);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Settings'))));
    await tester.pumpAndSettle();
    expect(enabled(), false);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(enabled(), true);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'tap preview controls transport without replacing its video',
      (tester) async {
    final controller = _Controller();
    playback.controller = controller;
    var fullscreens = 0;
    await tester.pumpWidget(app(Scaffold(
        body: SizedBox(
      width: 320,
      height: 180,
      child: PreviewPlayerControls(
          onFullscreen: () => fullscreens++,
          child: const SizedBox(
              key: ValueKey('native-surface'), width: 320, height: 180)),
    ))));
    final surface =
        tester.element(find.byKey(const ValueKey('native-surface')));
    await tester.tap(find.byKey(const ValueKey('preview-controls-toggle')));
    await tester.pump();
    expect(fullscreens, 0);
    await tester.tap(find.byKey(const ValueKey('player-play-pause')));
    await tester.pump();
    expect(controller.value.isPlaying, false);
    await tester.tap(find.byKey(const ValueKey('player-play-pause')));
    await tester.pump();
    expect(controller.value.isPlaying, true);
    await tester.tap(find.byKey(const ValueKey('player-mute')));
    await tester.pump();
    expect(controller.value.volume, 0);
    await tester.tap(find.byKey(const ValueKey('player-mute')));
    await tester.pump();
    expect(controller.value.volume, .6);
    final slider = find.byKey(const ValueKey('player-volume-slider'));
    await tester.drag(slider, const Offset(-10, 0));
    await tester.pump();
    final held = await tester.startGesture(tester.getCenter(slider));
    await tester.pump(const Duration(seconds: 5));
    expect(slider.hitTestable(), findsOneWidget);
    await held.up();
    await tester.pump();
    final adjustedVolume = controller.value.volume;
    expect(adjustedVolume, lessThan(.6));
    expect(adjustedVolume, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('player-mute')));
    await tester.pump();
    expect(controller.value.volume, 0);
    await tester.tap(find.byKey(const ValueKey('player-mute')));
    await tester.pump();
    expect(controller.value.volume, adjustedVolume);
    playback.currentChannel = Channel(
        id: 'p::live',
        rawId: 'live',
        playlistId: 'p',
        name: 'Live',
        group: 'TV',
        url: 'https://example.invalid/live');
    await tester.tap(find.byKey(const ValueKey('player-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconnect').hitTestable());
    await tester.pumpAndSettle();
    expect(playback.reloads, 1);
    await tester.tap(find.byKey(const ValueKey('player-fullscreen')));
    expect(fullscreens, 1);
    expect(tester.element(find.byKey(const ValueKey('native-surface'))),
        same(surface));
    await tester.pumpWidget(const SizedBox());
  });
  playerTestWidgets(
      'preview PiP opens the video route and enters without replacing its controller',
      (tester) async {
    const channel = MethodChannel('com.nox.nox_iptv/picture_in_picture');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'enter' || call.method == 'isSupported') return true;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final controller = _Controller();
    playback.controller = controller;
    playback.currentChannel = Channel(
        id: 'p::live',
        rawId: 'live',
        playlistId: 'p',
        name: 'Live channel',
        group: 'TV',
        url: 'https://example.test/live');
    playback.pictureInPicture.supported = true;
    await tester.pumpWidget(app(Scaffold(
        body: SizedBox(
            width: 256,
            height: 144,
            child: PreviewPlayerControls(
                onFullscreen: () {}, child: const SizedBox.expand())))));
    await tester.tap(find.byKey(const ValueKey('preview-controls-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('player-volume-slider')), findsOneWidget);
    expect(tester.takeException(),
        isNull); // Five buttons and slider fit the TV preview.
    await tester.tap(find.byKey(const ValueKey('player-pip')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(calls.where((c) => c.method == 'enter'), hasLength(1));
    expect(playback.controller, same(controller));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  playerTestWidgets(
      'preview exposes info and reconnect even when the stream fails',
      (tester) async {
    final controller = _Controller(initialized: false);
    playback.controller = controller;
    playback.currentChannel = Channel(
        id: 'p::live',
        rawId: 'live',
        playlistId: 'p',
        name: 'Test channel',
        group: 'TV',
        url: 'https://example.invalid/live');
    playback.error = '[HTTP 503] unavailable';
    playback.notifyListeners();
    await tester.pumpWidget(app(Scaffold(
        body: SizedBox(
            width: 256,
            height: 144,
            child: PreviewPlayerControls(
                onFullscreen: () {},
                child: const VideoPlayerPane(showControls: false))))));
    expect(find.byKey(const ValueKey('connection-info')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('connection-info')));
    await tester.pumpAndSettle();
    expect(find.text('Connection problem'), findsOneWidget);
    expect(find.textContaining('Server error 503'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connection-retry')));
    expect(playback.reloads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'portrait fullscreen controls clear both gesture and button navigation',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    playback.controller = _Controller(initialized: false);
    final channel = Channel(
        id: 'p::live',
        rawId: 'live',
        playlistId: 'p',
        name: 'Test channel',
        group: 'TV',
        url: 'https://example.test/live');
    for (final inset in [24.0, 48.0]) {
      tester.view.padding = FakeViewPadding(bottom: inset);
      tester.view.viewPadding = FakeViewPadding(bottom: inset);
      await tester.pumpWidget(app(PlayerScreen(channel: channel)));
      await tester.pump();
      final rect = tester.getRect(find.byType(PlayerControls));
      expect(rect.bottom, lessThanOrEqualTo(844 - inset));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  playerTestWidgets(
      'fullscreen exits at bottom right and cropping is only an explicit setting',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    prefs.setVideoFill(true); // Old zoom setting must not affect entry.
    final controller = _Controller(initialized: false);
    playback.controller = controller;
    final channel = Channel(
        id: 'p::live',
        rawId: 'live',
        playlistId: 'p',
        name: 'Test channel',
        group: 'TV',
        url: 'https://example.invalid/live');
    await tester.pumpWidget(app(Builder(
        builder: (context) => Scaffold(
            body: TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => PlayerScreen(channel: channel))),
                child: const Text('Open player'))))));
    Future<void> settleTransition() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      // Guarded dialogs complete after their closing frame. Render the
      // settings callback scheduled by that completion before asserting.
      await tester.pump();
    }

    Future<void> reveal() async {
      if (!tester.widget<PlayerControls>(find.byType(PlayerControls)).active) {
        await tester.tapAt(const Offset(190, 300));
        await settleTransition();
      }
    }

    await tester.tap(find.text('Open player'));
    await settleTransition();
    expect(
        tester.widget<VideoPlayerPane>(find.byType(VideoPlayerPane)).fillScreen,
        false);
    await reveal();
    final exit = find.byKey(const ValueKey('player-fullscreen'));
    expect(tester.getRect(exit).bottom, greaterThan(790));
    expect(tester.getRect(exit).right, greaterThan(370));
    expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('player-settings'))).top,
        lessThan(60));
    await tester.tap(find.byKey(const ValueKey('player-rotate')));
    await settleTransition();
    expect(
        tester.widget<VideoPlayerPane>(find.byType(VideoPlayerPane)).fillScreen,
        false);
    final volume = find.byKey(const ValueKey('player-volume-slider'));
    final held = await tester.startGesture(tester.getCenter(volume));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<PlayerControls>(find.byType(PlayerControls)).active,
        true);
    await held.up();
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<PlayerControls>(find.byType(PlayerControls)).active,
        false);
    await reveal();

    await tester.tap(find.byKey(const ValueKey('player-settings')));
    await settleTransition();
    await tester.tap(find.byKey(const ValueKey('player-picture-size')));
    await settleTransition();
    await tester.tap(find.text('Zoom to fill'));
    await settleTransition();
    expect(
        tester.widget<VideoPlayerPane>(find.byType(VideoPlayerPane)).fillScreen,
        true);
    await tester.tap(find.byTooltip('Close'));
    await settleTransition();
    await tester.tap(exit);
    await settleTransition();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(playback.controller, same(controller));
    expect(playback.reloads, 0);
    await tester.tap(find.text('Open player'));
    await settleTransition();
    expect(
        tester.widget<VideoPlayerPane>(find.byType(VideoPlayerPane)).fillScreen,
        false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  playerTestWidgets('compact navigation keeps its style and usable tap targets',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            bottomNavigationBar:
                IptvBottomBar(selected: 'sports', onSelect: _ignore))));
    final bar = tester.getSize(find.byType(IptvBottomBar));
    final target = tester.getSize(find.byKey(const ValueKey('bottom-sports')));
    expect(bar.height, lessThan(70));
    expect(target.height, greaterThanOrEqualTo(48));
  });
}

void _ignore(String value) {}
