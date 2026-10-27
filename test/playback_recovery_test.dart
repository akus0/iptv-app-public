import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playback_health.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/player_connection_status.dart';

class TestStorage extends StorageService {
  @override
  Future<void> writeCacheFile(String filename, String content) async {}
}

class TestPlaylist extends PlaylistManager {
  TestPlaylist(StorageService storage) : super(storage, CatalogDatabase());
  @override
  bool isPlaylistEnabled(String id) => true;
}

class FakePlayer extends VideoPlayerHdrController {
  FakePlayer(this.name, this.log)
      : super.networkUrl(Uri.parse('https://example.invalid/$name'));
  final String name;
  final List<String> log;
  final ready = Completer<void>();
  Completer<void>? release;
  int plays = 0;
  bool failRelease = false;
  @override
  Future<void> initialize(
      {VideoViewType viewType = VideoViewType.textureView}) async {
    log.add('$name.initialize');
    await ready.future;
    value = value.copyWith(isInitialized: true, size: const Size(1920, 1080));
  }

  @override
  Future<void> setVolume(double volume) async {
    value = value.copyWith(volume: volume);
  }

  @override
  Future<void> play() async {
    plays++;
    log.add('$name.play');
    value = value.copyWith(isPlaying: true);
  }

  // Controlled fake: no platform handle is created or released.
  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    log.add('$name.dispose');
    if (failRelease) throw StateError('release failed');
    await release?.future;
  }
}

class TestPlayback extends PlaybackService {
  TestPlayback(super.storage, super.playlistManager, this.log);
  final List<String> log;
  final created = <FakePlayer>[];
  @override
  FakePlayer createController(Channel channel, {String? url}) {
    final c = FakePlayer(channel.rawId, log);
    created.add(c);
    return c;
  }
}

Channel channel(String id) => Channel(
    id: 'p::$id',
    rawId: id,
    playlistId: 'p',
    name: id,
    group: 'TV',
    url: 'https://example.invalid/$id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestStorage storage;
  late TestPlaylist playlist;
  late TestPlayback playback;
  late List<String> log;
  setUpAll(() async {
    const dir = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (dir.isNotEmpty) {
      for (final entry in {
        'Roboto': 'Roboto-Regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf'
      }.entries) {
        await (FontLoader(entry.key)
              ..addFont(File('$dir/${entry.value}')
                  .readAsBytes()
                  .then((b) => ByteData.sublistView(b))))
            .load();
      }
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = TestStorage();
    await storage.init();
    playlist = TestPlaylist(storage);
    log = [];
    playback = TestPlayback(storage, playlist, log);
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
  });
  Future<void> ready(WidgetTester tester, FakePlayer c) async {
    c.ready.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  playerTestWidgets(
      'manual reconnect releases first, delays, and preserves volume',
      (tester) async {
    final old = FakePlayer('old', log);
    old.value = old.value.copyWith(isInitialized: true, volume: .3);
    playback.currentChannel = channel('new');
    playback.controller = old;
    final reconnect = playback.reloadCurrentChannel();
    await tester.pump();
    expect(log, ['old.dispose']);
    expect(playback.created, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    expect(playback.created, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(playback.created, hasLength(1));
    final next = playback.created.single;
    expect(next.value.volume, .3);
    await ready(tester, next);
    await tester.pump(const Duration(seconds: 1));
    await reconnect;
    expect(next.plays, 1);
    expect(playback.error, isNull);
    expect(playback.reconnectStatus, isNull);
  });
  playerTestWidgets('failed release cannot open an overlapping connection',
      (tester) async {
    playback.currentChannel = channel('old');
    playback.controller = FakePlayer('old', log)..failRelease = true;
    await playback.play(channel('new'));
    expect(playback.created, isEmpty);
    expect(playback.error, contains('previous player could not close'));
    expect(playback.health.value.phase, StreamPhase.failed);
  });
  playerTestWidgets('late old-channel errors cannot overwrite the new channel',
      (tester) async {
    await playback.play(channel('a'));
    final a = playback.created.last;
    await playback.play(channel('b'));
    final b = playback.created.last;
    a.ready.completeError(StateError('old channel failure'));
    await tester.pump();
    await ready(tester, b);
    expect(playback.currentChannel!.rawId, 'b');
    expect(playback.controller, same(b));
    expect(playback.error, isNull);
    expect(a.plays, 0);
    expect(b.plays, 1);
  });
  playerTestWidgets(
      'rapid selections all wait for the original connection release',
      (tester) async {
    final old = FakePlayer('old', log)..release = Completer<void>();
    playback.currentChannel = channel('old');
    playback.controller = old;
    final first = playback.play(channel('a'));
    await tester.pump();
    final second = playback.play(channel('b'));
    await tester.pump();
    expect(playback.created, isEmpty);
    old.release!.complete();
    await first;
    await second;
    expect(playback.created, hasLength(1));
    expect(playback.created.single.name, 'b');
    await ready(tester, playback.created.single);
  });
  playerTestWidgets(
      'switching during reconnect backoff cancels the old attempt',
      (tester) async {
    playback.currentChannel = channel('old');
    playback.controller = FakePlayer('old', log);
    final reconnect = playback.reloadCurrentChannel();
    await tester.pump();
    await playback.play(channel('new'));
    final next = playback.created.single;
    await ready(tester, next);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    await reconnect;
    expect(playback.created, hasLength(1));
    expect(playback.currentChannel!.rawId, 'new');
    expect(playback.error, isNull);
  });
  playerTestWidgets(
      'opening timeout releases the stream and surfaces a real timeout',
      (tester) async {
    await playback.play(channel('slow'));
    final slow = playback.created.single;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(playback.error, contains('[STREAM_OPEN_TIMEOUT]'));
    expect(log, contains('slow.dispose'));
    expect(playback.health.value.phase, StreamPhase.failed);
    expect(playback.controller, isNull);
    slow.ready.complete();
    await tester.pump();
    expect(slow.plays, 0);
  });
  playerTestWidgets('stop cancels pending opens without a late error',
      (tester) async {
    await playback.play(channel('old'));
    final old = playback.created.single;
    await playback.stop();
    old.ready.completeError(StateError('closed'));
    await tester.pump();
    expect(playback.currentChannel, isNull);
    expect(playback.error, isNull);
    expect(playback.health.value.phase, StreamPhase.idle);
  });
  playerTestWidgets(
      'buffer status updates do not rebuild whole-app subscribers',
      (tester) async {
    final c = FakePlayer('a', log);
    c.value = c.value.copyWith(isInitialized: true, isPlaying: true);
    playback.currentChannel = channel('a');
    playback.controller = c;
    var appChanges = 0;
    playback.addListener(() => appChanges++);
    c.value = c.value.copyWith(isBuffering: true, isPlaying: false);
    await tester.pump(const Duration(seconds: 3));
    expect(playback.health.value.phase, StreamPhase.buffering);
    // Elapsed time uses a monotonic clock; the synthetic timer still samples status.
    expect(appChanges, 0);
    c.value = c.value.copyWith(isBuffering: false, isPlaying: true);
    expect(playback.health.value.phase, StreamPhase.playing);
  });

  playerTestWidgets('remote recovery actions override fullscreen shortcuts',
      (tester) async {
    final focus = FocusNode();
    var retries = 0, infos = 0, hijacked = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CallbackShortcuts(
                bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): () => hijacked++
        },
                child: PlayerStatusCard(
                    health: const StreamHealth(StreamPhase.failed,
                        error: '[HTTP 503]'),
                    switchFocusNode: focus,
                    onRetry: () => retries++,
                    onInfo: () => infos++)))));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(retries, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(infos, 1);
    expect(hijacked, 0);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });

  for (final size in [
    const Size(256, 144),
    const Size(257, 144),
    const Size(390, 219),
    const Size(844, 390),
    const Size(1280, 720)
  ]) {
    playerTestWidgets('connection feedback fits ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final states = [
        const StreamHealth(StreamPhase.connecting, seconds: 12),
        const StreamHealth(StreamPhase.buffering, seconds: 4),
        const StreamHealth(StreamPhase.recovering, attempt: 2, retrySeconds: 6),
        const StreamHealth(StreamPhase.failed, error: '[HTTP 403 Forbidden]')
      ];
      for (var i = 0; i < states.length; i++) {
        final key = GlobalKey();
        var retries = 0;
        await tester.pumpWidget(MaterialApp(
            theme: buildAppTheme(AppConstants.cyberpunkPalettes.first),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(size.width == 257 ? 1.5 : 1)),
                child: child!),
            home: Scaffold(
                body: RepaintBoundary(
                    key: key,
                    child: ColoredBox(
                        color: const Color(0xFF1D2832),
                        child: PlayerStatusCard(
                            health: states[i],
                            onRetry: () => retries++,
                            onInfo: () {}))))));
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        if (i == 3) {
          await tester.tap(find.text('Retry'));
          expect(retries, 1);
          await tester.pump(const Duration(milliseconds: 300));
        }
        if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
          await tester.runAsync(() async {
            final image = await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await File('/tmp/iptv-player-status-$i-${size.width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
