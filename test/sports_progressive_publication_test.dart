import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final current = <String, EpgProgram>{};
  Completer<List<EpgProgram>>? query;
  @override
  EpgProgram? getCurrentProgram(String id) => current[id];
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      query == null ? current.values.toList() : await query!.future;
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      current.values.where((p) => ids.contains(p.channelId)).toList();
}

class _Picks implements SportsMatchPicks {
  @override
  String? channelIdFor(SportsGame game) => null;
}

final _now = DateTime.utc(2026, 11, 4, 12);
SportsGame _game(String id, String home, String away,
        {List<String> broadcasts = const []}) =>
    SportsGame(
        id: id,
        league: sportsLeagueById('nhl')!,
        start: _now.subtract(const Duration(minutes: 20)),
        state: GameState.live,
        statusText: 'Live',
        broadcasts: broadcasts,
        home:
            SportsTeam(id: home, name: home, shortName: home, abbreviation: ''),
        away: SportsTeam(
            id: away, name: away, shortName: away, abbreviation: ''));
final _games = [
  _game('a', 'Boston Bruins', 'Toronto Maple Leafs'),
  _game('b', 'New York Rangers', 'New Jersey Devils'),
  _game('c', 'Montreal Canadiens', 'Ottawa Senators'),
];
Channel _channel(int i, String name, {String? feed}) => Channel(
    id: 'p::$i',
    rawId: '$i',
    playlistId: 'p',
    name: name,
    group: 'Sports',
    url: 'https://example.invalid/$i',
    epgIdOverride: feed ?? '$i');
EpgProgram _programme(Channel channel, SportsGame game) => EpgProgram(
    channelId: channel.epgId,
    title: 'NHL: ${game.home.name} vs ${game.away.name}',
    start: _now.subtract(const Duration(minutes: 30)),
    stop: _now.add(const Duration(hours: 2)));
Object _signature(Map<String, List<ChannelMatch>> matches) => {
      for (final e in matches.entries)
        e.key: [
          for (final m in e.value)
            (
              m.channel.id,
              m.reason,
              m.score,
              m.detail,
              m.programme?.title,
              m.programme?.start,
              m.programme?.stop,
              m.supportingBroadcasts
            )
        ]
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Guide guide;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
  });
  tearDown(() => guide.dispose());

  for (final background in [false, true]) {
    for (final shared in [false, true]) {
      test(
          'exact feeds publish independently and shared feeds stay pending: worker=$background shared=$shared',
          () async {
        final channels = [
          for (var i = 0; i < _games.length; i++)
            _channel(i, '${_games[i].home.name} vs ${_games[i].away.name}',
                feed: shared && i < 2 ? 'shared' : '$i'),
        ];
        final matcher = background
            ? SportsChannelMatcher.background(guide, clock: () => _now)
            : SportsChannelMatcher(guide, clock: () => _now);
        final reference = SportsChannelMatcher(guide, clock: () => _now);
        addTearDown(matcher.dispose);
        addTearDown(reference.dispose);
        await matcher.prepare(channels);
        await reference.prepare(channels);
        final expected =
            await reference.matchDay(_games, _Picks(), includePossible: true);
        final updates = <Map<String, List<ChannelMatch>>>[];
        final result = await matcher.matchDay(_games, _Picks(),
            includePossible: true, onProgress: updates.add);
        expect(_signature(result), _signature(expected));
        final first = updates.firstWhere((u) => u['nhl:a']?.isNotEmpty == true);
        expect(first.containsKey('nhl:b'), isFalse);
        expect(first['nhl:a']!.first.isConfident, !shared);
        // Every confidence claim made before completion must survive the full
        // cohort, including quality variants with different IDs but one EPG.
        for (final update in updates) {
          for (final e in update.entries) {
            for (final match in e.value.where((m) => m.isConfident)) {
              expect(
                  result[e.key]!.any(
                      (m) => m.channel.id == match.channel.id && m.isConfident),
                  isTrue);
            }
          }
        }
      });
    }
  }

  test(
      'current-guide preview publishes its first event while SQL and peers are pending',
      () async {
    final channels = [
      for (var i = 0; i < 3; i++) _channel(i, 'Sports Feed $i')
    ];
    for (var i = 0; i < channels.length; i++) {
      guide.current[channels[i].epgId] = _programme(channels[i], _games[i]);
    }
    guide.query = Completer<List<EpgProgram>>();
    final matcher = SportsChannelMatcher.background(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare(channels);
    final first = Completer<Map<String, List<ChannelMatch>>>();
    final completion = matcher.matchDay(_games, _Picks(), includePossible: true,
        onProgress: (rows) {
      if (!first.isCompleted && rows['nhl:a']?.isNotEmpty == true) {
        first.complete(rows);
      }
    });
    final preview = await first.future.timeout(const Duration(seconds: 5));
    expect(guide.query!.isCompleted, isFalse);
    expect(preview.keys, ['nhl:a']);
    expect(preview['nhl:a']!.single.channel, same(channels.first));
    expect(preview['nhl:a']!.single.isConfident, isFalse,
        reason:
            'Early publication must not turn a partial guide into final evidence');
    guide.query!.complete(guide.current.values.toList());
    final result = await completion;
    expect(result.values.every((m) => m.first.isConfident), isTrue);
  });

  test('an exact owner can publish ahead of weaker shared broadcaster evidence',
      () async {
    final channels = [_channel(0, 'ESPN')];
    guide.current['0'] = _programme(channels.single, _games.first);
    final games = [
      _games.first,
      _game('b', 'New York Rangers', 'New Jersey Devils', broadcasts: ['ESPN'])
    ];
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare(channels);
    final updates = <Map<String, List<ChannelMatch>>>[];
    final result = await matcher.matchDay(games, _Picks(),
        includePossible: true, onProgress: updates.add);
    expect(updates.first['nhl:a']!.first.isConfident, isTrue);
    expect(updates.first.containsKey('nhl:b'), isFalse);
    expect(result['nhl:a']!.first.isConfident, isTrue);
    expect(result['nhl:b']!.any((m) => m.isConfident), isFalse);
  });
}
