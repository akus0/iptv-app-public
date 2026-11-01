import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:nox_iptv/services/picture_in_picture_service.dart';

class _Controller extends VideoPlayerHdrController {
  _Controller() : super.networkUrl(Uri.parse('https://example.test/live')) {
    value = const VideoPlayerHdrValue(
        duration: Duration.zero,
        isInitialized: true,
        isPlaying: true,
        size: Size(1920, 1080));
  }
  int pauses = 0;
  int plays = 0;
  @override
  Future<void> pause() async {
    pauses++;
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> play() async {
    plays++;
    value = value.copyWith(isPlaying: true);
  }
}

class _Surface extends StatefulWidget {
  const _Surface();
  @override
  State<_Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<_Surface> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.nox.nox_iptv/picture_in_picture');
  final calls = <MethodCall>[];
  late PictureInPictureService pip;
  late _Controller controller;
  bool available = true;
  bool permitted = true;
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  Future<void> native(String method, [Object? arguments]) async {
    final done = Completer<void>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) => done.complete());
    await done.future;
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    available = true;
    permitted = true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      if (call.method == 'isSupported') return available;
      if (call.method == 'enter') return permitted;
      return null;
    });
    pip = PictureInPictureService();
    controller = _Controller();
    pip.attach(controller);
    await settle();
  });
  tearDown(() async {
    pip.dispose();
    await settle();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  Map<Object?, Object?> update() =>
      calls.lastWhere((c) => c.method == 'update').arguments as Map;

  test('player dialog retains media session without enabling automatic PiP',
      () async {
    pip.setFullscreenVisible(true);
    expect(update()['mediaSession'], true);
    pip.setFullscreenVisible(false, playerOpen: true);
    expect(update()['enabled'], false);
    expect(update()['mediaSession'], true);
    expect(controller.pauses, 0);
    pip.setFullscreenVisible(true);
    expect(update()['enabled'], true);
    pip.setFullscreenVisible(false);
    expect(update()['mediaSession'], false);
  });

  testWidgets('large-screen to PiP resize preserves the native surface subtree',
      (tester) async {
    debugDefaultTargetPlatformOverride = null;
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    final width = ValueNotifier<double>(1280);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: prefs,
      child: MaterialApp(
          home: ValueListenableBuilder<double>(
        valueListenable: width,
        builder: (context, value, _) => MediaQuery(
          data: MediaQueryData(size: Size(value, value * 9 / 16)),
          child: Builder(
              builder: (context) => withTvThemeIfNeeded(
                  context, (_) => const _Surface(),
                  preserveSubtree: true)),
        ),
      )),
    ));
    final original = tester.state(find.byType(_Surface));
    width.value = 240;
    await tester.pump();
    expect(tester.state(find.byType(_Surface)), same(original));
    width.value = 1280;
    await tester.pump();
    expect(tester.state(find.byType(_Surface)), same(original));
    await tester.pumpWidget(const SizedBox.shrink());
    width.dispose();
    prefs.dispose();
  });

  test('Home entry enabled only for a visible, playing fullscreen route',
      () async {
    expect(update()['enabled'], false);
    pip.setFullscreenVisible(true);
    expect(update()['enabled'], true);
    expect(update()['aspectRatio'], closeTo(16 / 9, .001));
    expect(await pip.enter(), true);
    await controller.pause();
    expect(update()['enabled'], false);
    expect(await pip.enter(), false);
    await controller.play();
    pip.setFullscreenVisible(false);
    expect(update()['enabled'], false);
  });
  test(
      'live preview supports Home PiP and background audio without a new player',
      () async {
    final owner = Object();
    pip.attach(controller, allowBackgroundAudio: true, title: 'Tennis HD');
    expect(update()['mediaSession'], true);
    pip.setPreviewVisible(owner, true);
    expect(update()['enabled'], true);
    expect(await pip.enter(), true);
    pip.setPreviewVisible(owner, false);
    expect(update()['enabled'], false); // Covered preview cannot enter PiP.
    await native('background', {'resume': true, 'screenOff': false});
    expect(controller.value.isPlaying, true);
    expect(update()['mediaSession'], true);
    await native('background', {'resume': false, 'screenOff': true});
    expect(controller.value.isPlaying, true);
    await native('background', {'resume': false, 'screenOff': false});
    expect(controller.value.isPlaying, true); // Unlock into another app.
    await native('foreground');
    expect(controller.pauses, 0);
    expect(controller.plays, 0);
  });
  test(
      'live preview dismissal and notification Stop remain explicit stop actions',
      () async {
    pip.attach(controller, allowBackgroundAudio: true);
    await native('modeChanged', true);
    await native(
        'background', {'resume': false, 'screenOff': false, 'dismissed': true});
    await native('modeChanged', false);
    expect(controller.value.isPlaying, false);
    expect(update()['mediaSession'], false);
    await native('foreground');
    expect(controller.value.isPlaying, false);
    await controller.play();
    await native('background', {'resume': true, 'screenOff': false});
    await native('mediaAction', 'stop');
    expect(update()['mediaSession'], false);
    await native('foreground');
    expect(controller.value.isPlaying, false);
  });
  test('preview audio works with PiP denied and respects paused playback',
      () async {
    pip.attach(controller, allowBackgroundAudio: true);
    pip.setPreviewVisible(Object(), true);
    permitted = false;
    expect(await pip.enter(), false);
    await native('background', {'resume': true, 'screenOff': false});
    expect(controller.value.isPlaying, true);
    await native('mediaAction', 'pause');
    await native('background', {'screenOff': true});
    await native('foreground');
    expect(controller.value.isPlaying, false);
  });

  test('PiP entry and expansion preserve the same running stream', () async {
    pip.setFullscreenVisible(true);
    await native('modeChanged', true);
    expect(pip.active, true);
    expect(controller.value.isPlaying, true);
    await native('modeChanged', false);
    expect(pip.active, false);
    expect(controller.pauses, 0);
    expect(controller.plays, 0);
  });
  test('fully hidden activity pauses and resumes only its own stream',
      () async {
    await native('background', true);
    expect(controller.value.isPlaying, false);
    await native('foreground');
    expect(controller.value.isPlaying, true);
    await native('background', true);
    final replacement = _Controller();
    await replacement.pause();
    pip.attach(replacement);
    await native('foreground');
    expect(replacement.value.isPlaying, false);
  });
  test('closing PiP pauses without automatically restarting on reopening',
      () async {
    await native('modeChanged', true);
    await native('background', false);
    await native('modeChanged', false);
    await native('foreground');
    expect(controller.value.isPlaying, false);
    expect(controller.plays, 0);
  });
  test('a late initialization cannot start audio behind other apps', () async {
    await controller.pause();
    await native('background', true);
    await controller.play();
    expect(controller.value.isPlaying, false);
    await native('foreground');
    expect(controller.value.isPlaying, true);
  });
  test('fullscreen lock keeps audio, notification controls and the same stream',
      () async {
    pip.setFullscreenVisible(true);
    expect(update()['mediaSession'], true);
    await native('background', {'screenOff': true, 'resume': false});
    expect(controller.value.isPlaying, true);
    expect(controller.pauses, 0);
    expect(update()['mediaSession'], true);
    expect(update()['enabled'], false);
    await native('mediaAction', 'pause');
    expect(controller.value.isPlaying, false);
    expect(update()['playing'], false);
    await native('mediaAction', 'play');
    expect(controller.value.isPlaying, true);
    await native('foreground');
    expect(controller.plays, 1); // only the explicit lock-screen Play
    expect(update()['enabled'], true);
  });
  test('locking PiP survives mode callback ordering, then dismissal stops it',
      () async {
    pip.setFullscreenVisible(true);
    await native('modeChanged', true);
    await native('background', {'screenOff': true, 'resume': false});
    await native('modeChanged', false);
    await native('background', {'screenOff': true, 'resume': false});
    expect(controller.value.isPlaying, true);
    await native('background', {'screenOff': false, 'resume': false});
    expect(controller.value.isPlaying, false);
    expect(update()['mediaSession'], false);
    await native('foreground');
    expect(controller.value.isPlaying, false);
  });
  test(
      'preview screen lock still pauses, and paused fullscreen does not auto-play',
      () async {
    await native('background', {'screenOff': true, 'resume': true});
    expect(controller.value.isPlaying, false);
    await native('foreground');
    pip.setFullscreenVisible(true);
    await controller.pause();
    await native('background', {'screenOff': true, 'resume': false});
    await native('foreground');
    expect(controller.value.isPlaying, false);
  });
  test('lock-screen Stop removes the session and does not resume on unlock',
      () async {
    pip.setFullscreenVisible(true);
    await native('background', {'screenOff': true, 'resume': false});
    await native('mediaAction', 'stop');
    expect(update()['mediaSession'], false);
    await native('foreground');
    expect(controller.value.isPlaying, false);
    expect(update()['mediaSession'], false);
    await controller.play();
    expect(update()['mediaSession'], true);
    pip.setFullscreenVisible(false);
    expect(update()['mediaSession'], false);
  });
  test('screen-off playback also works on Android without PiP support',
      () async {
    pip.dispose();
    available = false;
    pip = PictureInPictureService();
    pip.attach(controller, title: 'ABC HD');
    pip.setFullscreenVisible(true);
    await settle();
    expect(update()['mediaSession'], true);
    expect(update()['title'], 'ABC HD');
    await native('background', {'screenOff': true, 'resume': false});
    expect(controller.value.isPlaying, true);
    expect(await pip.enter(), false);
  });
  test('denied PiP permission fails gracefully without stopping video',
      () async {
    pip.setFullscreenVisible(true);
    permitted = false;
    expect(await pip.enter(), false);
    expect(controller.value.isPlaying, true);
  });
  test('unsupported devices never offer or request PiP', () async {
    pip.dispose();
    available = false;
    pip = PictureInPictureService();
    pip.attach(controller);
    pip.setFullscreenVisible(true);
    await settle();
    expect(pip.supported, false);
    final count = calls.length;
    expect(await pip.enter(), false);
    expect(calls.length, count);
  });
}
