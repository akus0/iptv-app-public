// Device-only diagnostic entry point. Never packaged in the published APK.
// Build with --release -t tools/tv_profile.dart
// --dart-define=IPTV_DISABLE_AUTOPLAY=true to browse without opening a stream.
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:nox_iptv/screens/sports_screen.dart';
import 'package:nox_iptv/screens/player_screen.dart';
import 'package:nox_iptv/main.dart' as app;
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:provider/provider.dart';
import 'tv_fixture_setup.dart';
import 'tv_database_profile.dart';
import 'package:nox_iptv/services/storage_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('IPTV_PROFILE_DATABASE_WORKERS')) {
    await profileDatabaseWorkers();
  }
  if (const bool.fromEnvironment('IPTV_AUDIT_LIBRARY_CATEGORIES')) {
    final storage = StorageService();
    await storage.init();
    for (final profile in storage.getPlaylists()) {
      for (final type in ['vod', 'series']) {
        final raw = await storage
            .readCacheFile('xtream_${type}_categories_${profile.id}');
        if (raw == null) continue;
        final rows = jsonDecode(raw) as List;
        for (final row in rows) {
          // Titles only: never log account credentials, URLs or stream data.
          // ignore: avoid_print
          print('IPTV_CATEGORY ${jsonEncode({
                'type': type,
                'title': row['name'] ?? row['category_name']
              })}');
        }
      }
    }
  }
  const fixture = String.fromEnvironment('IPTV_FIXTURE_URL');
  if (fixture.isNotEmpty) await installLocalFixture(fixture);
  final frames = <FrameTiming>[];
  final heartbeat = Stopwatch()..start();
  var previousBeat = 0, largestGap = 0;
  Timer.periodic(const Duration(milliseconds: 100), (_) {
    final elapsed = heartbeat.elapsedMilliseconds;
    final gap = elapsed - previousBeat;
    if (gap > largestGap) largestGap = gap;
    previousBeat = elapsed;
  });
  WidgetsBinding.instance.addTimingsCallback(frames.addAll);
  Timer.periodic(const Duration(seconds: 2), (_) {
    if (frames.isEmpty) return;
    final build = frames.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final raster = frames.map((f) => f.rasterDuration.inMicroseconds).toList()
      ..sort();
    double percentile(List<int> times, double p) =>
        times[((times.length - 1) * p).round()] / 1000;
    // Count only rendered frames, not idle time. These are workload timings,
    // not an FPS estimate; platform-view decode is outside these durations.
    // ignore: avoid_print
    print('IPTV_FRAME ${jsonEncode({
          'frames': frames.length,
          'build_p50_ms': percentile(build, .5),
          'build_p95_ms': percentile(build, .95),
          'raster_p95_ms': percentile(raster, .95),
          'build_over_16ms': build.where((t) => t > 16667).length,
          'raster_over_16ms': raster.where((t) => t > 16667).length,
          'ui_heartbeat_max_gap_ms': largestGap,
        })}');
    frames.clear();
    largestGap = 0;
  });
  await app.main();
  if (const bool.fromEnvironment('IPTV_PROFILE_HANDOFF')) {
    Timer.periodic(const Duration(seconds: 2), (timer) {
      Element? sports;
      void visit(Element e) {
        if (e.widget is SportsScreen) sports = e;
        e.visitChildren(visit);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(visit);
      final context = sports;
      if (context == null || !context.mounted) return;
      final playback = context.read<PlaybackService>();
      if (playback.controller?.value.isPlaying != true ||
          playback.isFullscreenActive) {
        return;
      }
      timer.cancel();
      unawaited(_stressHandoffs(context, playback));
    });
  }
  const auditTitle = String.fromEnvironment('IPTV_AUDIT_GUIDE_TITLE');
  if (fixture.isNotEmpty || auditTitle.isNotEmpty) {
    var attempts = 0;
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (++attempts > 60) {
        timer.cancel();
        return;
      }
      void visit(Element element) {
        if (element.widget is TvHomeScreen) {
          if (auditTitle.isNotEmpty) {
            timer.cancel();
            unawaited(_auditProgramme(element, auditTitle));
            return;
          }
          final channel = element
              .read<PlaylistManager>()
              .channels
              .where((c) => c.id == 'tv_performance_fixture::tv-test-live')
              .firstOrNull;
          if (channel == null) return;
          timer.cancel();
          unawaited(element.read<PlaybackService>().play(channel));
          return;
        }
        element.visitChildren(visit);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(visit);
    });
  }
}

Future<void> _auditProgramme(Element element, String title) async {
  final epg = element.read<EpgService>();
  await epg.init();
  for (final p in epg.cachedCurrentProgrammes(DateTime.now())) {
    if (p.title.toLowerCase() != title.toLowerCase()) continue;
    // Guide text only, no provider/stream/account information.
    // ignore: avoid_print
    print('IPTV_GUIDE_TEXT ${jsonEncode({
          'title': p.title,
          'description': p.description
        })}');
  }
}

Future<void> _stressHandoffs(Element context, PlaybackService playback) async {
  await Future<void>.delayed(const Duration(seconds: 8));
  if (!context.mounted) return;
  final navigator = Navigator.of(context);
  final controller = playback.controller;
  final channel = playback.currentChannel;
  if (controller == null || channel == null) return;
  // One already-playing channel only; never open another provider connection.
  for (var i = 0; i < 30; i++) {
    if (!context.mounted || !identical(controller, playback.controller)) break;
    final open = PlayerScreen.open(navigator, channel);
    final duplicate = PlayerScreen.open(navigator, channel);
    await Future<void>.delayed(Duration(milliseconds: i < 15 ? 500 : 120));
    if (!playback.isFullscreenActive) break;
    navigator.pop();
    final exiting = PlayerScreen.open(navigator, channel);
    await open;
    await Future<void>.delayed(Duration(milliseconds: i < 15 ? 500 : 120));
    // No stream/account URLs or programme text in this diagnostic.
    // ignore: avoid_print
    print('IPTV_HANDOFF ${jsonEncode({
          'cycle': i + 1,
          'same_controller': identical(controller, playback.controller),
          'duplicate_guarded':
              identical(open, duplicate) && identical(open, exiting),
          'fullscreen_after': playback.isFullscreenActive,
          'playing': controller.value.isPlaying,
          'position_ms': controller.value.position.inMilliseconds,
          'error': controller.value.hasError,
        })}');
  }
}
