import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/b_league.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

String schedule(
        {String status = 'FINAL',
        String score = '80',
        String club = 'lh',
        String time = '19:05'}) =>
    '''B.LEAGUE
<script>var year = '2026'; var mon = '11'; var day = '06';</script>
<ul id="schedule-b1"><li class="list-item" id="123">
<span class="home"><img src="https://bleague.bl.kuroco-img.app/files/logo/2026/s/$club.png"></span>
<span class="away"><img src="https://bleague.bl.kuroco-img.app/files/logo/2026/s/an.png"></span>
<div class="info-arena">Arena $time</div><div class="info-scorestate">$status</div>
<span class="home-score">$score</span><span class="away-score">$score</span>
<ul><li>Nested broadcast link</li></ul></li></ul>
<ul id="schedule-b2"><li class="list-item" id="999">Other division</li></ul>''';

String broadcastPanel(String contents,
        {String id = '123',
        bool live = true,
        String title = 'LIVE Broadcast'}) =>
    '<main class="modal-content" id="modal-filter-detail-content-$id">'
    '<div class="${live ? 'modal-live-contents' : 'modal-recorded-contents'}">'
    '<span class="modal-title">$title</span><ul>$contents</ul></div></main>';
String broadcaster(String name, String icon) =>
    '<li><img src="https://bleague.bl.kuroco-img.app/files/$icon.svg">'
    '<div class="broadcast-list-item"><span class="link-line">$name</span></div></li>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final league = sportsLeagueById('basketball.bleague')!;
  final now = DateTime.utc(2026, 11, 2);
  test(
      'B.League nested links preserve game identity, JST time and explicit states',
      () {
    final game = parseBLeagueScoreboard(schedule(), league, now: now).single;
    expect(game.id, 'bleague:123');
    expect(game.home.id, 'bleague:702');
    expect(game.away.id, 'bleague:693');
    expect(game.start, DateTime.utc(2026, 11, 6, 10, 5));
    expect(game.state, GameState.post);
    expect(
        parseBLeagueScoreboard(schedule(status: '見どころ', score: ''), league,
                now: now)
            .single
            .state,
        GameState.pre);
    expect(
        parseBLeagueScoreboard(schedule(status: 'Q2'), league, now: now)
            .single
            .state,
        GameState.live);
    for (final data in [
      schedule(status: 'POSTPONED'),
      schedule(status: 'Unverified'),
      schedule(score: '-1'),
      schedule(time: '24:60')
    ]) {
      expect(parseBLeagueScoreboard(data, league, now: now), isEmpty);
    }
    expect(
        parseBLeagueScoreboard(schedule(status: '見どころ', score: ''), league,
            now: DateTime.utc(2026, 12)),
        isEmpty);
    expect(() => parseBLeagueScoreboard(schedule(club: 'unknown'), league),
        throwsFormatException);
    expect(
        () =>
            parseBLeagueScoreboard(schedule().replaceAll('</ul>', ''), league),
        throwsFormatException);
  });
  test('per-game live linear broadcasts retain country and medium', () {
    final data = schedule() +
        broadcastPanel(broadcaster('とちぎテレビ', 'icon_chijouha') +
            broadcaster('NHK(BS)', 'icon_bs') +
            broadcaster('J SPORTS 3', 'icon_cs') +
            broadcaster('J SPORTS 3', 'icon_cs') +
            broadcaster('Basketball Live', 'icon_all') +
            broadcaster('Amazon Prime Video', 'icon_net') +
            broadcaster('DAZN', 'icon_net'));
    final game = parseBLeagueScoreboard(data, league, now: now).single;
    expect(game.broadcasts, ['とちぎテレビ', 'NHK(BS)', 'J SPORTS 3']);
    expect(game.scoreboardBroadcasts.map((b) => b.name), game.broadcasts);
    for (final b in game.scoreboardBroadcasts) {
      expect(b.country, 'Japan');
      expect(b.source, 'B.League');
      expect(b.medium, 'TV');
      expect(b.isStreaming, false);
    }
  });
  test('optional broadcast gaps never remove otherwise valid fixtures', () {
    final tv = broadcaster('J SPORTS 3', 'icon_cs');
    for (final suffix in [
      broadcastPanel(tv, id: '999'),
      broadcastPanel(tv, live: false),
      broadcastPanel(tv, title: 'Replay'),
      broadcastPanel(tv, title: 'LIVE and Replay'),
      broadcastPanel(broadcaster('Network', 'unknown')),
      broadcastPanel(
          tv.replaceAll('bleague.bl.kuroco-img.app', 'example.invalid')),
      broadcastPanel(tv.replaceAll('</span>', '</broken>')),
      broadcastPanel(tv) + broadcastPanel(tv),
      broadcastPanel(tv) + broadcastPanel(tv) + broadcastPanel(tv),
      broadcastPanel('x' * 33000 + tv),
    ]) {
      final game =
          parseBLeagueScoreboard(schedule() + suffix, league, now: now).single;
      expect(game.broadcasts, isEmpty);
      expect(game.scoreboardBroadcasts, isEmpty);
    }
    final game = parseBLeagueScoreboard(
            schedule() +
                broadcastPanel(tv, title: 'LIVE放送') +
                broadcastPanel(broadcaster('J SPORTS 4', 'icon_cs'),
                    live: false, id: '999'),
            league,
            now: now)
        .single;
    expect(game.broadcasts, ['J SPORTS 3']);
  });
  test('B.League changed or incomplete standings fail closed', () {
    for (final data in [
      'B.LEAGUE',
      'B.LEAGUE 2026年11月01日 全試合終了時点<table class="table table-ranking"><tr><td>1</td></tr></table>'
    ]) {
      expect(() => parseBLeagueStandings(Uint8List.fromList(utf8.encode(data))),
          throwsFormatException);
    }
  });
  test(
      'legacy all preference stays light while explicit optional selections survive',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAllLeagues(true);
    expect(
        savedSportsLeagues(storage).any((l) => !l.enabledByDefault), isFalse);
    await storage.setSportsLeagues(
        ['baseball.npb', 'baseball.kbo', 'baseball.abl', league.id]);
    await storage.setSportsAllLeagues(true);
    expect(
        savedSportsLeagues(storage).map((l) => l.id),
        containsAll(
            ['baseball.npb', 'baseball.kbo', 'baseball.abl', league.id]));
    await storage.setSportsLeagues(['baseball.npb']);
    expect(
        savedSportsLeagues(storage).map((l) => l.id), contains('baseball.npb'));
    expect(savedSportsLeagues(storage).map((l) => l.id),
        isNot(contains(league.id)));
  });
}
