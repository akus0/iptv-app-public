import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';

/// Optional offline diagnostic. Input contains ONLY names/groups, never stream
/// URLs, credentials, logos or EPG addresses. No network clients are allowed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const path = String.fromEnvironment('PLAYLIST_LABELS_FILE');
  test('offline playlist matching diagnostic', () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final epg = EpgService(storage);
      addTearDown(epg.dispose);
      final matcher = SportsChannelMatcher(epg);
      final rows = jsonDecode(await File(path).readAsString()) as List;
      final channels = [
        for (final (i, row) in rows.indexed)
          Channel(
              id: 'offline::$i',
              rawId: '$i',
              playlistId: 'offline',
              name: row['name'] as String,
              group: row['group'] as String,
              url: 'https://example.invalid/not-a-stream')
      ];
      final games = [
        for (final (i, names) in [
          ('Juan Manuel Cerundolo', 'Carlos Alcaraz'),
          ('Yunchaokete Bu', 'Casper Ruud'),
          ('Daniil Medvedev', 'Jan-Lennard Struff'),
          ('Corentin Moutet', 'Alexander Zverev'),
        ].indexed)
          SportsGame(
              id: '$i',
              league: sportsLeagueById('tennis.atp')!,
              start: DateTime.utc(2026, 10, 10, 12),
              state: GameState.live,
              statusText: 'Live',
              home: SportsTeam(
                  id: 'h$i',
                  name: names.$1,
                  shortName: names.$1,
                  abbreviation: ''),
              away: SportsTeam(
                  id: 'a$i',
                  name: names.$2,
                  shortName: names.$2,
                  abbreviation: ''),
              event: const SportsEventInfo(title: 'Rolex Shanghai Masters')),
      ];
      final clock = Stopwatch()..start();
      await matcher.prepare(channels);
      final indexMs = clock.elapsedMilliseconds;
      clock.reset();
      final picks = SportsChannelPicks.load(storage);
      final matches = await matcher.matchDay(games, picks, includeGuide: false);
      final matchMs = clock.elapsedMilliseconds;
      clock.reset();
      final warm = await matcher.matchDay(games, picks, includeGuide: false);
      expect(identical(warm, matches), isTrue);
      debugPrint('Offline ${channels.length} channels: index ${indexMs}ms, '
          '4 games ${matchMs}ms, warm ${clock.elapsedMicroseconds}us');
      for (final game in games) {
        debugPrint(game.title);
        for (final match in matches[SportsChannelPicks.eventKey(game)]!) {
          debugPrint(
              '  ${match.score} ${match.reason.name}: ${match.channel.name}');
        }
      }
    },
        createHttpClient: (_) =>
            throw StateError('Offline test: network forbidden'));
  },
      skip: path.isEmpty
          ? 'Provide a local, sanitized playlist label file.'
          : false);
}
