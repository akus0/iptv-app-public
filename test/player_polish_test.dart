import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/screens/player_screen.dart';
import 'package:nox_iptv/utils/player_route.dart';
import 'package:nox_iptv/screens/multiview_screen.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playback_timeline.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/player_chrome.dart';
import 'package:nox_iptv/widgets/player_controls.dart';
import 'package:nox_iptv/widgets/player_side_panel.dart';
import 'package:nox_iptv/widgets/player_stream_info.dart';
import 'package:nox_iptv/widgets/player_dialog.dart';
import 'package:nox_iptv/widgets/preview_player_controls.dart';

class Controller extends VideoPlayerHdrController {
  Controller()
      : super.networkUrl(Uri.parse('https://example.invalid/never-play')) {
    value = const VideoPlayerHdrValue(
        duration: Duration(minutes: 90),
        position: Duration(minutes: 24),
        isInitialized: true,
        isPlaying: true,
        size: Size(1920, 1080),
        volume: .6);
  }
  final seeks = <Duration>[];
  bool tracksAvailable = false;
  bool videoTracksAvailable = false;
  int videoReads = 0;
  Completer<List<VideoTrack>>? pendingVideo;
  @override
  Future<List<VideoTrack>> getVideoTracks() async {
    videoReads++;
    if (pendingVideo != null) return pendingVideo!.future;
    return [
      const VideoTrack(
          id: 'v',
          isSelected: true,
          width: 1920,
          height: 1080,
          frameRate: 50,
          codec: 'avc1',
          bitrate: 4500000)
    ];
  }

  String selectedAudio = 'en';
  @override
  Future<List<VideoAudioTrack>> getAudioTracks() async => tracksAvailable
      ? [
          VideoAudioTrack(
              id: 'en',
              label: 'English commentary',
              language: 'en',
              isSelected: selectedAudio == 'en',
              channelCount: 2),
          VideoAudioTrack(
              id: 'ambient',
              label: 'Stadium sound',
              language: 'und',
              isSelected: selectedAudio == 'ambient',
              channelCount: 6),
        ]
      : [];
  @override
  Future<void> selectAudioTrack(String id) async {
    selectedAudio = id;
  }

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    value = value.copyWith(position: position);
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
  bool isVideoTrackSupportAvailable() => videoTracksAvailable;
  @override
  bool isAudioTrackSupportAvailable() => tracksAvailable;
}

Channel channel(int i, {bool favourite = false}) => Channel(
    id: 'p::$i',
    rawId: '$i',
    playlistId: 'p',
    name: i == 0
        ? 'Sky Sports F1 HD'
        : i == 1
            ? 'Tennis Channel HD'
            : 'Sports channel $i',
    group: i < 5 ? 'UK Sports' : 'Other sports',
    url: 'https://example.invalid/never-play',
    isFavorite: favourite);

class Playlist extends PlaylistManager {
  Playlist(StorageService storage) : super(storage, CatalogDatabase());
  @override
  final channels = [
    for (var i = 0; i < 80; i++) channel(i, favourite: i == 1 || i == 6)
  ];
  int loads = 0;
  @override
  Future<void> ensureLiveChannelsLoaded() async {
    loads++;
  }

  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      channels;
  @override
  Set<String> favoritedGroupsFor(String playlistId) => {};
}

class Guide extends EpgService {
  Guide(super.storage);
  @override
  EpgProgram? getCurrentProgram(String id) => EpgProgram(
      channelId: id,
      title: id == '0'
          ? 'Formula 1: United States Grand Prix — Qualifying'
          : id == '1'
              ? 'ATP Vienna: Sinner v Alcaraz'
              : 'Live sport coverage',
      start: DateTime.now().subtract(const Duration(minutes: 24)),
      stop: DateTime.now().add(const Duration(minutes: 36)));
  @override
  EpgProgram? getNextProgram(String id) => EpgProgram(
      channelId: id,
      title: id == '0' ? 'Ted’s qualifying notebook' : 'Sports highlights',
      start: DateTime.now().add(const Duration(minutes: 36)),
      stop: DateTime.now().add(const Duration(hours: 2)));
}

class Playback extends PlaybackService {
  Playback(super.storage, super.playlist);
  Completer<void>? stopGate;
  int pendingStops = 0;
  @override
  Future<void> stop() async {
    final gate = stopGate;
    if (gate != null) {
      pendingStops++;
      await gate.future;
    }
    await super.stop();
  }

  @override
  Future<void> play(Channel channel) async {
    currentChannel = channel;
  }

  @override
  List<Channel> get recentlyPlayed => [for (var i = 0; i < 12; i++) channel(i)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (fonts.isEmpty) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(File('$fonts/${entry.value}')
            .readAsBytes()
            .then((v) => ByteData.sublistView(v)));
      await loader.load();
    }
  });
  late StorageService storage;
  late Playlist playlist;
  late Guide guide;
  late Playback playback;
  late AppPreferences prefs;
  late Controller controller;
  late List<MethodCall> calls;
  var native = <String, Object?>{};
  setUp(() async {
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    storage = StorageService();
    await storage.init();
    playlist = Playlist(storage);
    guide = Guide(storage);
    playback = Playback(storage, playlist);
    prefs = AppPreferences(storage);
    await prefs.init();
    controller = Controller();
    playback.controller = controller;
    playback.currentChannel = channel(0);
    calls = [];
    native = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vespertv/subtitles'),
            (call) async => call.method == 'getTextTracks'
                ? [
                    {
                      'group': 2,
                      'track': 0,
                      'language': 'en',
                      'label': 'English captions',
                      'selected': true,
                      'cc': true
                    }
                  ]
                : null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlaybackTimelineBridge.channel, (call) async {
      calls.add(call);
      return call.method == 'snapshot' ? native : true;
    });
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vespertv/subtitles'), null);
    playback.dispose();
    playlist.dispose();
    guide.dispose();
    prefs.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlaybackTimelineBridge.channel, null);
  });
  final rootCapture = GlobalKey();
  Widget app(Widget child) => RepaintBoundary(
      key: rootCapture,
      child: MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: guide),
            ChangeNotifierProvider.value(value: prefs),
          ],
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(prefs.palette),
              home: Scaffold(body: child))));
  Widget transport({required bool live, bool active = true}) => app(
      PlayerTransport(controller: controller, isLive: live, active: active));

  playerTestWidgets(
      'rapid fullscreen handoffs keep one controller and one visible video',
      (tester) async {
    prefs.isTelevision = true;
    NavigatorState? navigator;
    await tester.pumpWidget(app(Builder(builder: (context) {
      navigator = Navigator.of(context);
      return const VideoPlayerPane(showControls: false, showEpgBar: false);
    })));
    await tester.pump();
    final original = playback.controller;
    for (var i = 0; i < 25; i++) {
      final opened = PlayerScreen.open(navigator!, channel(0));
      final duplicate = PlayerScreen.open(navigator!, channel(0));
      expect(duplicate, same(opened));
      await tester.pump();
      await tester.pump();
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byType(VideoPlayerHdr, skipOffstage: false), findsOneWidget);
      expect(playback.controller, same(original));
      expect(playback.isFullscreenActive, isTrue);
      final route = ModalRoute.of(tester.element(find.byType(PlayerScreen)))!;
      expect(route, isA<PlayerRoute>());
      expect(route.transitionDuration, Duration.zero);
      navigator!.pop();
      // A second activation before disposal must not create a second player.
      expect(PlayerScreen.open(navigator!, channel(0)), same(opened));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byType(VideoPlayerHdr), findsOneWidget);
      expect(playback.isFullscreenActive, isFalse);
      expect(playback.controller, same(original));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  playerTestWidgets(
      'multiview spam coalesces stopping and Back cancels a late launch',
      (tester) async {
    prefs.isTelevision = true;
    prefs.hideMultiview = false;
    NavigatorState? navigator;
    await tester.pumpWidget(app(Builder(builder: (context) {
      navigator = Navigator.of(context);
      return const SizedBox();
    })));
    final opened = PlayerScreen.open(navigator!, channel(0));
    await tester.pump();
    await tester.pump();
    final action = tester
        .widget<PlayerControls>(find.byType(PlayerControls))
        .onOpenMultiview!;
    final gate = Completer<void>();
    playback.stopGate = gate;
    for (var i = 0; i < 20; i++) {
      action();
    }
    expect(playback.pendingStops, 1);
    navigator!.pop();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    playback.stopGate = null;
    gate.complete();
    await tester.pump();
    await tester.pump();
    await opened;
    expect(find.byType(MultiviewScreen, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('outgoing fullscreen owner cannot clear a newer session', () {
    final old = Object(), current = Object();
    playback.claimFullscreen(old);
    playback.claimFullscreen(current);
    expect(playback.releaseFullscreen(old), isFalse);
    expect(playback.isFullscreenActive, isTrue);
    expect(playback.ownsFullscreen(current), isTrue);
    expect(playback.releaseFullscreen(current), isTrue);
    expect(playback.isFullscreenActive, isFalse);
  });

  playerTestWidgets(
      'live duration alone never enables rewind; hidden controls stop polling',
      (tester) async {
    native = {'live': true, 'seekable': false, 'duration': 90000};
    await tester.pumpWidget(transport(live: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('player-seek')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(calls.length, 2);
    await tester.pumpWidget(transport(live: true, active: false));
    final count = calls.length;
    await tester.pump(const Duration(seconds: 6));
    expect(calls.length, count);
    expect(controller.seeks, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  playerTestWidgets(
      'DVR dragging commits once with window anchor; go live uses native default',
      (tester) async {
    native = {
      'live': true,
      'seekable': true,
      'duration': 600000,
      'position': 400000,
      'defaultPosition': 590000,
      'buffered': 430000,
      'windowStart': 1000000
    };
    await tester.pumpWidget(transport(live: true));
    await tester.pump();
    expect(find.text('Go live'), findsOneWidget);
    var slider =
        tester.widget<Slider>(find.byKey(const ValueKey('player-seek')));
    slider.onChangeStart!(350000);
    slider.onChanged!(300000);
    slider.onChanged!(250000);
    await tester.pump();
    expect(calls.where((c) => c.method == 'seek'), isEmpty);
    slider = tester.widget<Slider>(find.byKey(const ValueKey('player-seek')));
    slider.onChangeEnd!(250000);
    await tester.pump();
    final seek = calls.singleWhere((c) => c.method == 'seek');
    expect(seek.arguments['position'], 250000);
    expect(seek.arguments['windowStart'], 1000000);
    expect(seek.arguments['liveOnly'], true);
    expect(controller.seeks, isEmpty);
    controller.value = controller.value.copyWith(isPlaying: false);
    await tester.tap(find.byKey(const ValueKey('player-go-live')));
    await tester.pump();
    expect(calls.where((c) => c.method == 'goLive'), hasLength(1));
    expect(controller.value.isPlaying, true);
    await tester.pumpWidget(const SizedBox());
  });
  playerTestWidgets(
      'VOD scrub commits once and preserves pause; skip clamps at start',
      (tester) async {
    controller.value = controller.value
        .copyWith(isPlaying: false, position: const Duration(seconds: 3));
    await tester.pumpWidget(transport(live: false));
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('player-seek')));
    slider.onChangeStart!(10000);
    slider.onChanged!(20000);
    slider.onChanged!(30000);
    expect(controller.seeks, isEmpty);
    slider.onChangeEnd!(30000);
    await tester.pump();
    expect(controller.seeks, [const Duration(seconds: 30)]);
    expect(controller.value.isPlaying, false);
    controller.value =
        controller.value.copyWith(position: const Duration(seconds: 3));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-rewind')));
    await tester.pump();
    expect(controller.seeks.last, Duration.zero);
    final beforeHold = controller.seeks.length;
    await tester.longPress(find.byKey(const ValueKey('player-forward')));
    await tester.pump();
    expect(controller.seeks.length, beforeHold + 1);
    expect(controller.seeks.last, const Duration(minutes: 1));
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'a channel change cancels an in-progress scrub instead of seeking the new player',
      (tester) async {
    await tester.pumpWidget(transport(live: false));
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('player-seek')));
    slider.onChangeStart!(10000);
    slider.onChanged!(20000);
    await tester.pump();
    final previous = controller;
    controller = Controller();
    await tester.pumpWidget(transport(live: false));
    slider.onChangeEnd!(20000);
    await tester.pump();
    expect(previous.seeks, isEmpty);
    expect(controller.seeks, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
    controller = previous;
  });

  playerTestWidgets(
      'channel browser searches now titles, filters favourites/group and never starts sports work',
      (tester) async {
    var requests = 0;
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(440, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          app(PlayerSidePanel(current: channel(0), onClose: () {})));
      await tester.pumpAndSettle();
      expect(find.text('Current'), findsOneWidget);
      expect(playlist.loads, 0);
      await tester.tap(find.text('Favourites'));
      await tester.pumpAndSettle();
      expect(find.text('Tennis Channel HD'), findsOneWidget);
      expect(find.text('Sports channel 6'), findsOneWidget);
      expect(find.text('Sky Sports F1 HD'), findsNothing);
      await tester.tap(find.text('This group'));
      await tester.pumpAndSettle();
      expect(find.text('Sky Sports F1 HD'), findsOneWidget);
      expect(find.text('Sports channel 6'), findsNothing);
      await tester.enterText(
          find.byKey(const ValueKey('player-channel-search')), 'Sinner');
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pumpAndSettle();
      expect(find.text('Tennis Channel HD'), findsOneWidget);
      expect(find.text('Sky Sports F1 HD'), findsNothing);
      expect(playlist.loads, 1);
      expect(requests, 0);
      await tester.enterText(
          find.byKey(const ValueKey('player-channel-search')),
          'does not match');
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pumpAndSettle();
      expect(find.text('Sky Sports F1 HD'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((_) async {
              requests++;
              return http.Response('{"events":[]}', 200);
            }));
  });

  playerTestWidgets(
      'audio and subtitle choices retain selection and volume restores correctly',
      (tester) async {
    controller.tracksAvailable = true;
    final subtitleCalls = <MethodCall>[];
    const subtitles = MethodChannel('vespertv/subtitles');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(subtitles, (call) async {
      subtitleCalls.add(call);
      if (call.method == 'getTextTracks') {
        return [
          {
            'group': 2,
            'track': 0,
            'language': 'en',
            'label': 'English captions',
            'selected': false
          },
          {
            'group': 3,
            'track': 0,
            'language': 'fr',
            'label': 'French captions',
            'selected': false
          },
        ];
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(subtitles, null));
    await tester.pumpWidget(app(Builder(
        builder: (context) => PlayerControls(
                controller: controller,
                title: 'Sports',
                channelId: '0',
                isLive: true,
                channel: channel(0))
            .utilityActions(context))));
    await tester.tap(find.byKey(const ValueKey('player-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Audio track'));
    await tester.pumpAndSettle();
    expect(find.text('English commentary').hitTestable(), findsOneWidget);
    expect(find.text('Stadium sound'), findsOneWidget);
    await tester.tap(find.text('Stadium sound'));
    await tester.pumpAndSettle();
    expect(controller.selectedAudio, 'ambient');
    await tester.tap(find.text('Subtitles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English captions'));
    await tester.pumpAndSettle();
    expect(
        subtitleCalls
            .where((c) => c.method == 'selectTextTrack')
            .last
            .arguments['group'],
        2);
    await tester.tap(find.byKey(const ValueKey('player-mute')).hitTestable());
    await tester.pump();
    expect(controller.value.volume, 0);
    await tester.tap(find.byKey(const ValueKey('player-mute')).hitTestable());
    await tester.pump();
    expect(controller.value.volume, .6);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'switching to a linked channel closes settings before changing playback',
      (tester) async {
    await tester.pumpWidget(app(Builder(
        builder: (context) => PlayerControls(
                controller: controller,
                title: 'Sports',
                channelId: '0',
                isLive: true,
                channel: channel(0),
                linkedChannel: channel(1))
            .utilityActions(context))));
    await tester.tap(find.byKey(const ValueKey('player-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Switch to'));
    await tester.pumpAndSettle();
    expect(find.text('Playback settings'), findsNothing);
    expect(playback.currentChannel!.id, 'p::1');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'mute remembers the chosen level when controls are closed and reopened',
      (tester) async {
    await tester.pumpWidget(app(PlayerVolume(controller: controller)));
    await tester.tap(find.byKey(const ValueKey('player-mute')).hitTestable());
    await tester.pump();
    expect(controller.value.volume, 0);
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pumpWidget(app(PlayerVolume(controller: controller)));
    await tester.tap(find.byKey(const ValueKey('player-mute')).hitTestable());
    await tester.pump();
    expect(controller.value.volume, .6);
    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('player-volume-slider')));
    slider.onChanged!(.25);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-mute')).hitTestable());
    await tester.pump();
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pumpWidget(app(PlayerVolume(controller: controller)));
    await tester.tap(find.byKey(const ValueKey('player-mute')).hitTestable());
    await tester.pump();
    expect(controller.value.volume, .25);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'shared toolbar keeps mute direct and fullscreen last in both modes',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final fullscreen in [false, true]) {
      var exits = 0;
      await tester.pumpWidget(app(Align(
          alignment: Alignment.bottomCenter,
          child: PlayerToolbar(
              controller: controller,
              isLive: true,
              compact: true,
              fullscreen: fullscreen,
              onOpenChannels: fullscreen ? () {} : null,
              onFullscreen: () => exits++))));
      await tester.pump();
      expect(
          find.byKey(const ValueKey('player-volume-slider')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-mute')));
      await tester.pump();
      expect(controller.value.volume, 0);
      expect(find.byTooltip('Unmute'), findsOneWidget);
      tester
          .widget<Slider>(find.byKey(const ValueKey('player-volume-slider')))
          .onChanged!(.3);
      await tester.pump();
      expect(controller.value.volume, .3);
      expect(
          find.byKey(const ValueKey('player-volume-slider')), findsOneWidget);
      expect(
          tester.getRect(find.byKey(const ValueKey('player-fullscreen'))).right,
          320);
      expect(
          tester.getRect(find.byKey(const ValueKey('player-mute'))).center.dy,
          tester
              .getRect(find.byKey(const ValueKey('player-fullscreen')))
              .center
              .dy);
      await tester.tap(find.byKey(const ValueKey('player-fullscreen')));
      expect(exits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  playerTestWidgets('episode actions remain available on narrow full player',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(PlayerToolbar(
        controller: controller,
        isLive: false,
        compact: true,
        fullscreen: true,
        onFullscreen: () {},
        onPrevious: () {},
        onNext: () {})));
    expect(find.byTooltip('Previous episode'), findsOneWidget);
    expect(find.byTooltip('Next episode'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'stream info progresses from connecting and reads only existing metadata while open',
      (tester) async {
    controller.videoTracksAvailable = true;
    controller.tracksAvailable = true;
    controller.value = controller.value.copyWith(isInitialized: false);
    await tester.pumpWidget(app(Builder(
        builder: (context) => TextButton(
            onPressed: () => showPlayerStreamInfo(context),
            child: const Text('Info panel')))));
    await tester.tap(find.text('Info panel'));
    await tester.pumpAndSettle();
    expect(find.text('Connecting'), findsOneWidget);
    expect(controller.videoReads, 0);
    expect(find.text('example.invalid'), findsOneWidget);
    controller.value = controller.value
        .copyWith(isInitialized: true, buffered: [
      DurationRange(const Duration(minutes: 23), const Duration(minutes: 25))
    ]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Playing'), findsOneWidget);
    expect(find.text('avc1'), findsOneWidget);
    expect(find.text('50.00 fps'), findsOneWidget);
    expect(find.text('4.50 Mb/s'), findsOneWidget);
    expect(find.text('16:9'), findsOneWidget);
    expect(find.text('Stereo · 2'), findsOneWidget);
    expect(find.text('English captions'), findsOneWidget);
    expect(find.text('Closed captions'), findsOneWidget);
    expect(find.text('Available languages'), findsOneWidget);
    expect(find.text('1.00×'), findsOneWidget);
    expect(find.text('60 s'), findsOneWidget);
    expect(controller.videoReads, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.videoReads, 1);
    controller.value = controller.value.copyWith(isBuffering: true);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Buffering'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    final reads = controller.videoReads;
    final snapshots = calls.length;
    await tester.pump(const Duration(seconds: 10));
    expect(controller.videoReads, reads);
    expect(calls.length, snapshots);
    expect(controller.seeks, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'slow subtitles do not delay video metadata and late results cannot update a closed panel',
      (tester) async {
    final pending = Completer<List<Map<String, Object>>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('vespertv/subtitles'),
            (call) => pending.future);
    controller.videoTracksAvailable = true;
    await tester.pumpWidget(app(Builder(
        builder: (context) => TextButton(
            onPressed: () => showPlayerStreamInfo(context),
            child: const Text('Info panel')))));
    await tester.tap(find.text('Info panel'));
    await tester.pumpAndSettle();
    expect(find.text('avc1'), findsOneWidget);
    expect(controller.videoReads, 1);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    pending.complete([
      {'group': 1, 'track': 0, 'label': 'Late subtitle', 'selected': true}
    ]);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Late subtitle'), findsNothing);
    expect(controller.videoReads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'stream info discards a previous controllers late metadata and hides URLs in errors',
      (tester) async {
    controller.videoTracksAvailable = true;
    controller.pendingVideo = Completer<List<VideoTrack>>();
    final old = controller;
    await tester.pumpWidget(app(Builder(
        builder: (context) => TextButton(
            onPressed: () => showPlayerStreamInfo(context),
            child: const Text('Info panel')))));
    await tester.tap(find.text('Info panel'));
    await tester.pumpAndSettle();
    final replacement = Controller();
    playback.controller = replacement;
    playback
        .setFullscreenActive(true); // Notify subscribers of the new controller.
    await tester.pump();
    old.pendingVideo!.complete(
        [const VideoTrack(id: 'old', isSelected: true, codec: 'stale-codec')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('stale-codec'), findsNothing);
    playback.error =
        'Network failed https://user:secret@example.invalid/live/password/1.ts?token=private';
    playback.setFullscreenActive(false);
    await tester.pump();
    expect(find.textContaining('secret'), findsNothing);
    expect(find.textContaining('token=private'), findsNothing);
    expect(find.textContaining('[stream address]'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await replacement.dispose();
    playback.controller = old;
  });

  playerTestWidgets(
      'remote can scroll all stream metadata while the close button stays visible',
      (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    prefs.isTelevision = true;
    await tester.pumpWidget(app(Builder(
        builder: (context) => TextButton(
            onPressed: () => showPlayerStreamInfo(context),
            child: const Text('Info panel')))));
    await tester.tap(find.text('Info panel'));
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('player-dialog-scroll')))
        .controller!;
    final closeRect = tester.getRect(find.byTooltip('Close'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(scroll.offset, greaterThan(72));
    expect(tester.getRect(find.byTooltip('Close')), closeRect);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerStreamInfo), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'long track chooser reveals its selected row for the remote',
      (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? chosen;
    await tester.pumpWidget(app(Builder(
        builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showPlayerChoices<int>(
                  context,
                  'Tracks',
                  (sheet) => [
                        for (var i = 0; i < 30; i++)
                          PlayerSettingRow(
                              icon: Icons.subtitles_outlined,
                              title: 'Track $i',
                              selected: i == 25,
                              autofocus: i == 25,
                              onTap: () => Navigator.pop(sheet, i))
                      ]);
            },
            child: const Text('Choose track')))));
    await tester.tap(find.text('Choose track'));
    await tester.pumpAndSettle();
    expect(find.text('Track 25').hitTestable(), findsOneWidget);
    final scroll = tester
        .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('player-dialog-scroll')))
        .controller!;
    expect(scroll.offset, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chosen, 25);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'remote channel browsing moves rows and returns from search without switching early',
      (tester) async {
    prefs.isTelevision = true;
    final played = <String>[];
    var closed = false;
    await tester.pumpWidget(app(PlayerSidePanel(
        current: channel(0),
        onClose: () => closed = true,
        onPlay: (c) async {
          played.add(c.id);
        })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final field = tester
        .widget<TextField>(find.byKey(const ValueKey('player-channel-search')));
    expect(field.focusNode!.hasFocus, true);
    expect(field.readOnly, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(played, isEmpty);
    expect(closed, false);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(played, ['p::1']);
    expect(closed, true);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'large channel search is capped, lazy and cannot play a dummy header',
      (tester) async {
    playlist.channels.clear();
    playlist.channels.addAll(List.generate(80000, (i) => channel(i)));
    playlist.channels.insert(
        0,
        Channel(
            id: 'p::section',
            rawId: 'section',
            playlistId: 'p',
            name: '### Sports section',
            group: 'UK Sports',
            url: 'https://example.invalid/header'));
    await tester
        .pumpWidget(app(PlayerSidePanel(current: channel(0), onClose: () {})));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('player-channel-search')), 'Sports');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('First 200 matches · narrow your search'), findsOneWidget);
    expect(find.text('### Sports section'), findsNothing);
    expect(find.text('Sports channel 199'), findsNothing,
        reason: 'Off-screen rows remain lazy');
    expect(playlist.loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'large text keeps narrow controls and preview volume inside the viewport',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    native = {
      'live': true,
      'seekable': true,
      'duration': 1800000,
      'position': 1200000,
      'buffered': 1230000,
      'defaultPosition': 1790000
    };
    await tester.pumpWidget(app(MediaQuery(
        data: const MediaQueryData(
            size: Size(320, 640), textScaler: TextScaler.linear(1.5)),
        child: Align(
            alignment: Alignment.bottomCenter,
            child: PlayerControls(
                controller: controller,
                title: channel(0).name,
                channelId: '0',
                channel: channel(0),
                isLive: true,
                onOpenChannels: () {},
                onToggleFavorite: () {},
                isFavorite: true)))));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  playerTestWidgets(
      'small DVR preview keeps both edges separate with larger text',
      (tester) async {
    playback.pictureInPicture.supported = true;
    native = {
      'live': true,
      'seekable': true,
      'duration': 1800000,
      'position': 1200000,
      'buffered': 1230000,
      'defaultPosition': 1790000
    };
    await tester.pumpWidget(app(MediaQuery(
        data: const MediaQueryData(
            size: Size(320, 640), textScaler: TextScaler.linear(1.5)),
        child: Center(
            child: SizedBox(
                width: 256,
                height: 144,
                child: PreviewPlayerControls(
                    onFullscreen: () {}, child: const SizedBox.expand()))))));
    await tester.tap(find.byKey(const ValueKey('preview-controls-toggle')));
    await tester.pump();
    await tester.pump();
    final video = tester.getRect(find.byType(PreviewPlayerControls));
    final top = tester.getRect(find.byType(PlayerUtilityActions));
    final bottom = tester.getRect(find.byType(PlayerToolbar));
    expect(top.bottom, lessThanOrEqualTo(bottom.top));
    expect(bottom.bottom, lessThanOrEqualTo(video.bottom));
    expect(bottom.left, greaterThanOrEqualTo(video.left));
    expect(bottom.right, lessThanOrEqualTo(video.right));
    expect(find.byKey(const ValueKey('player-seek')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-pip')), findsOneWidget);
    expect(find.text('Volume'), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('player-mute'))).height,
        greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  SportsGame sportGame({bool field = false}) => SportsGame(
      id: 'fixture',
      league: sportsLeagueById(field ? 'racing.f1' : 'tennis.atp')!,
      start: DateTime.now(),
      state: GameState.live,
      statusText: field ? 'Qualifying' : 'Set 2',
      event: SportsEventInfo(
          title: field
              ? 'United States Grand Prix — Qualifying'
              : 'Vienna Open · Quarter-final'),
      home: const SportsTeam(
          id: 'a',
          name: 'Jannik Sinner',
          shortName: 'Sinner',
          abbreviation: 'SIN',
          score: '6  3'),
      away: const SportsTeam(
          id: 'b',
          name: 'Carlos Alcaraz',
          shortName: 'Alcaraz',
          abbreviation: 'ALC',
          score: '4  2'));

  for (final scale in [1.0, 1.5]) {
    playerTestWidgets(
        'sport rows show full names and honest channel status at text scale $scale',
        (tester) async {
      for (final reason in [
        MatchReason.guide,
        MatchReason.sport,
        MatchReason.pick
      ]) {
        await tester.pumpWidget(app(MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
                child: SizedBox(
                    width: 280,
                    height: 112 + (13 * scale - 13) * 6,
                    child: PlayerSportRow(
                        game: sportGame(),
                        guide: guide,
                        match: ChannelMatch(channel(1), reason, 90),
                        currentChannelId: channel(0).id))))));
        expect(find.text('Jannik Sinner'), findsOneWidget);
        expect(find.text('Carlos Alcaraz'), findsOneWidget);
        expect(find.text('Playing'), findsNothing);
        expect(
            find.text(reason == MatchReason.guide
                ? 'Matched'
                : reason == MatchReason.pick
                    ? 'Your pick'
                    : 'Possible'),
            findsOneWidget);
        expect(find.textContaining('Now · ATP Vienna'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(app(SizedBox(
          width: 280,
          height: 116,
          child: PlayerSportRow(
              game: sportGame(),
              guide: guide,
              hideScores: true,
              searching: true))));
      expect(find.text('6  3'), findsNothing);
      expect(find.text('Finding channels…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 720)
  ]) {
    playerTestWidgets('polished player and browser fit ${size.width}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      prefs.isTelevision = size.width == 1280;
      controller.tracksAvailable = true;
      playback.pictureInPicture.supported = true;
      native = {
        'live': true,
        'seekable': true,
        'duration': 1800000,
        'position': 1200000,
        'buffered': 1230000,
        'defaultPosition': 1790000
      };
      final boundary = GlobalKey();
      Future<void> capture(String name) async {
        if (!const bool.fromEnvironment('CAPTURE_LAYOUT')) return;
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/iptv-$name-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.pumpWidget(app(RepaintBoundary(
          key: boundary,
          child: Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF0C1118))),
            Positioned(
                top: 20,
                left: 16,
                child: Text('SKY SPORTS F1',
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: .3)))),
            Positioned(
                top: 4,
                right: 4,
                child: Builder(
                    builder: (context) => PlayerControls(
                            controller: controller,
                            title: channel(0).name,
                            channelId: '0',
                            channel: channel(0),
                            isLive: true,
                            isFavorite: true,
                            onToggleFavorite: () {},
                            onRotate: prefs.isTelevision ? null : () {},
                            onTogglePictureFit: () {})
                        .utilityActions(context))),
            Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: PlayerControls(
                    controller: controller,
                    title: channel(0).name,
                    channelId: '0',
                    channel: channel(0),
                    isLive: true,
                    isFavorite: true,
                    onToggleFavorite: () {},
                    onOpenChannels: () {},
                    onExitFullscreen: () {},
                    onEnterPip: () {},
                    onRotate: () {},
                    onTogglePictureFit: () {})),
          ]))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await capture('player-controls');
      await tester.tap(find.byKey(const ValueKey('player-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Playback settings'), findsOneWidget);
      if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
        await tester.runAsync(() async {
          final image = await (rootCapture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/iptv-player-settings-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      controller.videoTracksAvailable = true;
      await tester.tap(find.byKey(const ValueKey('player-info')));
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
        await tester.runAsync(() async {
          final image = await (rootCapture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/iptv-player-info-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(RepaintBoundary(
          key: boundary,
          child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                  width: size.width < 600 ? size.width : 440,
                  child:
                      PlayerSidePanel(current: channel(0), onClose: () {}))))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture('player-channels');
      await tester.pumpWidget(app(RepaintBoundary(
          key: boundary,
          child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                  width: size.width < 600 ? size.width : 440,
                  color: playerPanelColor,
                  child: ListView(padding: const EdgeInsets.all(10), children: [
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Text('Live sport',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600))),
                    for (final item in [
                      (sportGame(), MatchReason.guide),
                      (sportGame(field: true), MatchReason.sport),
                      (sportGame(), MatchReason.pick)
                    ])
                      Container(
                          height: 112,
                          margin: const EdgeInsets.only(bottom: 5),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                              color: const Color(0x991A222C),
                              border:
                                  Border.all(color: const Color(0xFF26313D)),
                              borderRadius: BorderRadius.circular(5)),
                          child: PlayerSportRow(
                              game: item.$1,
                              guide: guide,
                              match: ChannelMatch(
                                  channel(item.$1.league.isField ? 0 : 1),
                                  item.$2,
                                  90),
                              currentChannelId: 'none')),
                  ]))))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture('player-sports');

      await tester.pumpWidget(app(Center(
          child: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                  width: 300,
                  height: 169,
                  child: PreviewPlayerControls(
                      onFullscreen: () {}, child: const SizedBox.expand()))))));
      await tester.tap(find.byKey(const ValueKey('preview-controls-toggle')));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await capture('player-preview');
      final video = tester.getRect(find.byType(PreviewPlayerControls));
      final volume = tester.getRect(find.byType(PlayerAudioControl));
      expect(volume.top, greaterThanOrEqualTo(video.top));
      expect(volume.bottom, lessThanOrEqualTo(video.bottom));
      expect(find.byKey(const ValueKey('player-seek')), findsOneWidget);
      expect(tester.getRect(find.byType(PlayerUtilityActions)).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(PlayerToolbar)).top));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
