import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/utils/sports_presentation.dart';

void main() {
  test('English divisions use the existing scoreboard parser and tier order',
      () {
    final fixtures = jsonDecode(
        File('test/fixtures/english_divisions.json').readAsStringSync()) as Map;
    final ids = ['eng.1', 'eng.2', 'eng.3', 'eng.4', 'eng.5'];
    final leagues = ids.map((id) => sportsLeagueById(id)!).toList();
    expect(leagues.map(leagueDisplayPriority),
        orderedEquals(leagues.map(leagueDisplayPriority).toList()..sort()));
    for (final entry in fixtures.entries) {
      final league = sportsLeagueById(entry.key as String)!;
      final games = parseEspnScoreboard((jsonEncode(entry.value), league));
      expect(games, hasLength(1));
      expect(games.single.league, same(league));
      expect(games.single.home.name, isNotEmpty);
      expect(games.single.away.name, isNotEmpty);
      expect(games.single.start.isUtc, true);
      expect(leagueDescription(league), contains('tier'));
      expect(league.hasStandings, true);
      expect(kSportsLeagueBank.where((l) => l.id == league.id), hasLength(1));
      expect(kDefaultSportsLeagueIds, contains(league.id),
          reason: 'All available leagues are now enabled by default');
    }
  });

  test('upstream accent coverage keeps names intact without changing ASCII',
      () {
    for (final entry in {
      'Beşiktaş': 'besiktas',
      'Śląsk Wrocław': 'slask wroclaw',
      'Győr': 'gyor',
      'Csíkszereda': 'csikszereda',
      'Botoșani': 'botosani',
      'Constanța': 'constanta',
      'Bistrița-Năsăud': 'bistrita nasaud',
      'Węgier': 'wegier',
      'Szűcs': 'szucs',
      'Tennis ATP 2': 'tennis atp 2',
    }.entries) {
      expect(sportsNormalize(entry.key), ' ${entry.value} ');
    }
    expect(sportsNormalize('S\u0301wia\u0328tek'), sportsNormalize('Świątek'));
  });

  test('small supplemental logos use tiny without resizing larger artwork', () {
    const image = 'https://r2.thesportsdb.com/images/media/team/badge/test.png';
    expect(sportsLogoUrl(image), '$image/tiny');
    expect(sportsLogoUrl('$image/tiny'), '$image/tiny');
    expect(sportsLogoUrl(image, size: 300), image);
    expect(sportsLogoUrl('https://example.invalid/logo.png'),
        'https://example.invalid/logo.png');
  });

  test('unsupported video does not waste connections on backup servers', () {
    expect(
        isDecoderPlaybackError(
            'No decoder on this device can play this video [UNSUPPORTED_VIDEO: video/dolby-vision]'),
        true);
    expect(isDecoderPlaybackError('MediaCodecVideoRenderer error'), true);
    expect(
        isDecoderPlaybackError('Network failure [HTTP 404 Not Found]'), false);
  });
}
