import 'dart:async';
import 'package:nox_iptv/widgets/detail_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/xtream_series.dart';
import 'package:nox_iptv/screens/series_detail_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Playback extends PlaybackService {
  _Playback(super.storage, super.playlist);
  int historyReads = 0;
  @override
  List<Channel> get recentlyPlayed {
    historyReads++;
    return [];
  }
}

class _SlowPositionStorage extends StorageService {
  Completer<void>? positionGate;
  int positionWrites = 0;
  @override
  Future<void> setLastPosition(String id, int value) async {
    positionWrites++;
    await positionGate?.future;
    await super.setLastPosition(id, value);
  }
}

void main() {
  testWidgets('episode restart bursts cancel cleanly when leaving details',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = _SlowPositionStorage();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final manager = PlaylistManager(storage, CatalogDatabase());
    final playback = _Playback(storage, manager);
    final episode = Channel(
        id: 'one::ep1',
        rawId: 'ep1',
        playlistId: 'one',
        name: 'Episode 1',
        group: 'Drama',
        url: 'https://example.invalid/1');
    await storage.setLastPosition(episode.id, 60000);
    storage.positionWrites = 0;
    storage.positionGate = Completer<void>();
    var plays = 0;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<AppPreferences>.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: manager),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
            navigatorKey: navigator,
            home: SeriesDetailScreen(
              series: XtreamSeries(
                  seriesId: 1,
                  playlistId: 'one',
                  name: 'Test show',
                  categoryId: 'Drama'),
              loadEpisodes: () async => (
                episodes: {
                  1: [episode]
                },
                plot: null,
                details: null
              ),
              playEpisode: (_, __) async {
                plays++;
              },
              showFavorite: false,
            ))));
    await tester.pumpAndSettle();
    final restart = tester
        .widget<DetailPillButton>(
            find.widgetWithText(DetailPillButton, 'Restart'))
        .onPressed;
    for (var i = 0; i < 30; i++) {
      restart();
    }
    await tester.pump();
    expect(storage.positionWrites, 1);
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Elsewhere')))));
    await tester.pumpAndSettle();
    storage.positionGate!.complete();
    await tester.pumpAndSettle();
    expect(plays, 0,
        reason: 'A late restart must not open over the new screen');
    expect(find.text('Elsewhere'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    playback.dispose();
    manager.dispose();
    prefs.dispose();
  });

  testWidgets(
      'episode navigation reuses resume calculation and watched edits invalidate it',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final manager = PlaylistManager(storage, CatalogDatabase());
    final playback = _Playback(storage, manager);
    final episodes = [
      for (var i = 1; i <= 120; i++)
        Channel(
            id: 'one::xt_ep_$i',
            rawId: 'xt_ep_$i',
            playlistId: 'one',
            name: 'Episode $i',
            group: 'Drama',
            url: 'https://example.invalid/$i')
    ];
    var loads = 0;
    var plays = 0;
    String? playedId;
    int? queueSize;
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<AppPreferences>.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: manager),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
            home: SeriesDetailScreen(
          series: XtreamSeries(
              seriesId: 1,
              playlistId: 'one',
              name: 'Test show',
              categoryId: 'Drama'),
          loadEpisodes: () async {
            loads++;
            return (episodes: {1: episodes}, plot: null, details: null);
          },
          playEpisode: (episode, queue) async {
            plays++;
            playedId = episode.id;
            queueSize = queue.length;
          },
          showFavorite: false,
        ))));
    await tester.pumpAndSettle();
    expect(find.text('Play S1E1'), findsOneWidget);
    final reads = playback.historyReads;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(playback.historyReads, reads);
    expect(loads, 1);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-8');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(storage.isFullyWatched(episodes[8].id), isTrue);
    expect(find.text('Play S1E10'), findsOneWidget);
    expect(playback.historyReads, reads + 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(storage.isFullyWatched(episodes[8].id), isFalse);
    expect(find.text('Play S1E1'), findsOneWidget);
    expect(plays, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(plays, 1);
    expect(playedId, episodes[8].id);
    expect(queueSize, 120);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    manager.dispose();
    prefs.dispose();
  });
}
