// Local-only device harness. No subscription URLs or provider requests.
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nox_iptv/services/playback_timeline.dart';
import 'package:nox_iptv/services/subtitle_tracks.dart';
import 'package:provider/provider.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/screens/multiview_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/device_memory_service.dart';
import 'package:nox_iptv/services/playback_health.dart';
import 'package:nox_iptv/services/multiview_session.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Playlist extends PlaylistManager {
  _Playlist(StorageService storage, this.rows)
      : super(storage, CatalogDatabase());
  final List<Channel> rows;
  @override
  List<Channel> get visibleLiveChannels => rows;
  @override
  List<PlaylistProfile> get profiles => [
        PlaylistProfile(
            id: 'fixture',
            name: 'Local test',
            mode: 'm3u',
            sortOrder: 0,
            createdAt: DateTime(2026),
            maxConnections: 4)
      ];
  @override
  Future<void> ensureLiveChannelsLoaded() async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final uri = Uri.parse(const String.fromEnvironment('IPTV_TEST_VIDEO'));
  if (uri.scheme != 'http' ||
      !uri.host.startsWith('192.168.') ||
      uri.port != 8911) {
    throw StateError('Local fixture only');
  }
  final storage = StorageService();
  await storage.init();
  final prefs = AppPreferences(storage);
  await prefs.init();
  prefs.isTelevision = await DeviceTypeService.isTelevision();
  final rows = [
    for (var i = 0; i < 80000; i++)
      Channel(
          id: 'fixture::$i',
          rawId: '$i',
          playlistId: 'fixture',
          name: i < 4
              ? 'Local test ${i + 1}'
              : i < 8
                  ? 'Adaptive test ${i - 3}'
                  : 'Test channel $i',
          group: 'Test group ${i ~/ 800}',
          url: uri
              .replace(
                  path: i >= 4 && i < 8 ? '/adaptive.m3u8' : uri.path,
                  query: 'view=$i')
              .toString())
  ];
  final playlist = _Playlist(storage, rows);
  final session = MultiviewSession();
  const four = bool.fromEnvironment('IPTV_TEST_FOUR');
  final originalLayout = storage.getMultiviewLayout();
  if (four) await storage.setMultiviewLayout('grid');
  if (four) {
    FocusManager.instance.addEarlyKeyEventHandler((event) {
      if (event is! KeyDownEvent ||
          (event.logicalKey != LogicalKeyboardKey.keyQ &&
              event.logicalKey != LogicalKeyboardKey.keyW)) {
        return KeyEventResult.ignored;
      }
      final count = event.logicalKey == LogicalKeyboardKey.keyQ ? 2 : 4;
      for (final cell in session.cells) {
        final controller = cell.controller;
        if (controller != null) {
          unawaited(PlaybackTimelineBridge.channel
              .invokeMethod<bool>('multiviewBudget', {
            'playerId': SubtitleTracks.playerIdOf(controller),
            'screens': count,
          }));
        }
      }
      // ignore: avoid_print
      print('IPTV_BUDGET $count');
      return KeyEventResult.handled;
    });
  }
  final playback = PlaybackService(storage, playlist);
  var sampling = false;
  Timer.periodic(const Duration(seconds: 2), (_) async {
    if (sampling) return;
    sampling = true;
    try {
      for (final c in session.cells) {
        if (c.controller != null) {
          await PlaybackHealthBridge.read(c.controller!);
        }
      }
    } finally {
      sampling = false;
    }
  });
  final frames = <FrameTiming>[];
  WidgetsBinding.instance.addTimingsCallback(frames.addAll);
  Timer.periodic(const Duration(seconds: 2), (_) {
    if (frames.isEmpty) return;
    final build = frames.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final raster = frames.map((f) => f.rasterDuration.inMicroseconds).toList()
      ..sort();
    double percentile(List<int> data, double p) =>
        data[((data.length - 1) * p).round()] / 1000;
    // ignore: avoid_print
    print('IPTV_FRAME ${jsonEncode({
          'frames': frames.length,
          'build_p50_ms': percentile(build, .5),
          'build_p95_ms': percentile(build, .95),
          'raster_p95_ms': percentile(raster, .95),
          'build_over_16ms': build.where((n) => n > 16667).length,
          'raster_over_16ms': raster.where((n) => n > 16667).length
        })}');
    frames.clear();
  });
  runApp(MultiProvider(
      providers: [
        Provider.value(value: storage),
        ChangeNotifierProvider.value(value: prefs),
        ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        ChangeNotifierProvider.value(value: playback),
        ChangeNotifierProvider.value(value: EpgService(storage)),
      ],
      child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true).copyWith(
              colorScheme: const ColorScheme.dark(primary: Color(0xFF9BCEF4))),
          home: MultiviewScreen(session: session))));
  await Future<void>.delayed(const Duration(seconds: 3));
  if (four) await storage.setMultiviewLayout(originalLayout);
  await session.assign(0, rows[0]);
  await session.assign(1, rows[1]);
  if (four) {
    await session.assign(2, rows[2]);
    await session.assign(3, rows[3]);
  }
}
