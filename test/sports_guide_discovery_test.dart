import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/testing.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_match_inputs.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/extended_sports.dart';
import 'package:nox_iptv/utils/motorsport_coverage.dart';
import 'package:nox_iptv/utils/sports_guide_coverage.dart';
import 'package:nox_iptv/utils/sports_coverage_models.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final rows = <String, EpgProgram>{};
  int reads = 0;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    return rows[normalizeEpgId(id)];
  }

  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) =>
      throw StateError('Guide discovery must not query SQL or a provider');
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) =>
      throw StateError('Exact guide bindings must not run fuzzy queries');
}

class _ChangingGuide extends _Guide {
  _ChangingGuide(super.storage);
  int revision = 0;
  bool changeOnRead = true;
  @override
  int get changeRevision => revision;
  @override
  EpgProgram? getCurrentProgram(String id) {
    if (changeOnRead) {
      changeOnRead = false;
      revision++;
    }
    return super.getCurrentProgram(id);
  }
}

class _Picks implements SportsMatchPicks {
  _Picks([this.id]);
  final String? id;
  @override
  String? channelIdFor(SportsGame game) => id;
}

class _RacingGuide extends _Guide {
  _RacingGuide(super.storage);
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      const [];
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      const [];
}

class _FixtureGuide extends _RacingGuide {
  _FixtureGuide(super.storage);
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      rows.values
          .where((p) => p.start.isBefore(to) && p.stop.isAfter(from))
          .toList();
}

Channel _channel(String id, {String? epg, String? name}) => Channel(
    id: 'p::$id',
    rawId: id,
    playlistId: 'p',
    name: name ?? 'TV $id',
    group: 'TV',
    url: 'https://example.test/$id',
    epgIdOverride: epg ?? id);
final _now = DateTime.utc(2026, 10, 24, 12);
EpgProgram _programme(String id, String title,
        {String? description, bool live = false, DateTime? stop}) =>
    EpgProgram(
        channelId: id,
        title: title,
        description: description,
        isLive: live,
        start: _now.subtract(const Duration(minutes: 30)),
        stop: stop ?? _now.add(const Duration(minutes: 30)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Guide guide;
  late StorageService storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
  });
  tearDown(() => guide.dispose());

  for (final background in [false, true]) {
    test(
        'additional local competitions bind only live fixture coverage: worker=$background',
        () async {
      final entries = <String, (String, String, bool, String)>{
        'aus': (
          'Australian Championship',
          'Marconi Stallions FC v Bayswater City SC: Round 4\nCoverage from Marconi Stadium.',
          true,
          'SBS'
        ),
        'aus-copy': (
          'Australian Championship : Marconi Stallions FC v Bayswater City SC: Round 4',
          'Coverage from Marconi Stadium.',
          true,
          'SBS HD'
        ),
        'school': (
          'High School Football - CIF Southern Section: Apple Valley at Villa Park',
          'First round.',
          true,
          'Local Sports'
        ),
        'school-final': (
          'High School Football - OIA Division I Tournament: Waipahu vs. Aiea',
          'Championship.',
          true,
          'Local Sports'
        ),
        'horse': (
          'Horse Racing - Melbourne Cup Carnival - Champions Day',
          'Live racing from Flemington.',
          true,
          'FS1'
        ),
        'horse-channel': (
          'Race Day Saturday',
          'Coverage from Australian racecourses.',
          true,
          'Sky Racing 1'
        ),
        'rodeo': (
          'Columbia River Circuit Finals - Performance 2',
          'ProRodeo coverage from Yakima, Washington.',
          true,
          'Cowboy Channel'
        ),
        'bulls': (
          'PBR World Finals - Bull Riding',
          'Championship competition.',
          true,
          'Sports'
        ),
        'unmarked': (
          'High School Football - Waipahu vs. Aiea',
          'Full game.',
          false,
          'Sports'
        ),
        'replay': (
          'High School Football - Waipahu vs. Aiea Replay',
          'Full game.',
          true,
          'Sports'
        ),
        'recap': (
          'High School Football',
          'Recap of the week’s games.',
          true,
          'Sports'
        ),
        'preview': (
          'High School Football Preview: Waipahu vs. Aiea',
          'Preview of the game.',
          true,
          'Sports'
        ),
        'generic': (
          'Australian Championship',
          'A sports programme.',
          true,
          'Sports'
        ),
        'other-sport': (
          'Australian Championship Swimming: Alpha v Beta',
          'Swimming from the aquatic stadium.',
          true,
          'Sports'
        ),
        'horse-film': (
          'Horse Racing',
          'A documentary about the history of racing.',
          true,
          'Sports'
        ),
        'horse-replay': (
          'Horse Racing Replay',
          'Melbourne Cup Carnival.',
          true,
          'Sports'
        ),
        'horse-tips': (
          'Horse Racing Tips',
          'Betting analysis.',
          true,
          'Sky Racing'
        ),
        'motor': (
          'Race Day Saturday',
          'Coverage of the race.',
          true,
          'Fox Sports Racing'
        ),
        'rodeo-shop': (
          'Rodeo Drive',
          'Shopping in Los Angeles.',
          true,
          'Lifestyle'
        ),
        'rodeo-replay': (
          'ProRodeo Replay',
          'Circuit finals coverage.',
          true,
          'Cowboy Channel'
        ),
        'old': (
          'Horse Racing - Melbourne Cup Carnival 2024',
          'Full coverage.',
          true,
          'Sports'
        ),
      };
      for (final e in entries.entries) {
        guide.rows[e.key] = _programme(e.key, e.value.$1,
            description: e.value.$2, live: e.value.$3);
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare(
          [for (final e in entries.entries) _channel(e.key, name: e.value.$4)]);
      final games = await matcher.discoverGuideEvents();
      expect(
          games
              .expand((g) => g.guideProgrammes)
              .map((p) => p.channelId)
              .toSet(),
          {
            'aus',
            'aus-copy',
            'school',
            'school-final',
            'horse',
            'horse-channel',
            'rodeo',
            'bulls'
          });
      expect(games.where((g) => g.league.id == 'guide.australian-championship'),
          hasLength(1));
      final matches = await matcher.matchDay(games, _Picks());
      expect(
          matches.values
              .expand((m) => m)
              .every((m) => m.reason == MatchReason.guide),
          true);
      expect(matches.values.expand((m) => m).map((m) => m.channel.id).toSet(), {
        for (final g in games)
          for (final p in g.guideProgrammes) 'p::${p.channelId}'
      });
      final reads = guide.reads;
      final repeated = await matcher.discoverGuideEvents();
      expect(repeated.map((g) => g.id), games.map((g) => g.id));
      if (!background) expect(repeated, same(games));
      expect(guide.reads, reads);
      for (final g in games) {
        expect(g.league.source, 'Channel guide');
        expect(g.league.hasStandings, false);
        expect(sportsLeagueById(g.league.id), isNotNull);
        expect(sportLabel(g.league.espnPath.split('/').first), isNotEmpty);
      }
    });
  }

  for (final background in [false, true]) {
    test(
        'merged cards retain all channel alternatives beyond the card limit: worker=$background',
        () async {
      final titles = [
        'LIVE ONE Fight Night 49',
        'Live MMA One Fight Night',
        'Live: MMA One Fight Night - MMA One Fight Night'
      ];
      for (var i = 0; i < 18; i++) {
        guide.rows['$i'] = _programme('$i', titles[i % titles.length],
            live: true, stop: _now.add(const Duration(hours: 4)));
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (var i = 0; i < 18; i++) _channel('$i')]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(1));
      expect(games.single.guideProgrammes, hasLength(18));
      final selected = (await matcher.matchDay(games, _Picks())).values.single;
      expect(selected, hasLength(8));
      final alternatives =
          await matcher.alternativesFor(games.single, matches: selected);
      expect(alternatives.map((m) => m.channel.id).toSet(),
          {for (var i = 0; i < 18; i++) 'p::$i'});
      expect(alternatives.every((m) => m.reason == MatchReason.guide), true);
      final pinned =
          (await matcher.matchDay(games, _Picks('p::17'))).values.single;
      expect(pinned.first.channel.id, 'p::17');
      expect((await matcher.alternativesFor(games.single, matches: pinned)),
          hasLength(18));
    });
  }

  for (final background in [false, true]) {
    test(
        'Sambo competition coverage requires live evidence and exact channels: worker=$background',
        () async {
      final entries = <String, (String, String, bool)>{
        'english': (
          'Sambo World Championships',
          'Day one of the championship, combining wrestling and grappling techniques.',
          true
        ),
        'german': (
          'Sambo-Weltmeisterschaften: Tag 1',
          'FIAS Sambo World Championships coverage.',
          true
        ),
        'replay': ('Sambo World Championships Replay', 'Full coverage.', true),
        'unmarked': ('Sambo World Championships', 'Full coverage.', false),
        'news': ('Sambo World Championships News', 'Latest results.', true),
        'training': (
          'Sambo World Championships Training',
          'Training session.',
          true
        ),
        'film': (
          'Sambo World Championships',
          'A documentary about a former champion.',
          true
        ),
        'conflict': (
          'Sambo World Championships',
          'Live tennis coverage.',
          true
        ),
        'incidental': (
          'Sports Tonight',
          'Sambo World Championships coverage.',
          true
        ),
        'boxing-conflict': (
          'Sambo World Championships',
          'Live boxing coverage.',
          true
        ),
        'unspecified': ('Sambo', 'General sports coverage.', true),
        'placeholder': ('Sambo World Championships PPV 123', '', true),
        'expired': ('Sambo World Championships', 'Full coverage.', true),
      };
      for (final entry in entries.entries) {
        guide.rows[entry.key] = _programme(entry.key, entry.value.$1,
            description: entry.value.$2,
            live: entry.value.$3,
            stop: entry.key == 'expired' ? _now : null);
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in entries.keys) _channel(id)]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(2));
      expect(games.every((g) => g.league.id == 'guide.sambo'), true);
      final result = await matcher.matchDay(games, _Picks());
      expect(result.values.expand((m) => m).map((m) => m.channel.rawId),
          unorderedEquals(['english', 'german']));
      expect(
          result.values
              .expand((m) => m)
              .every((m) => m.reason == MatchReason.guide),
          true);
      final reads = guide.reads;
      expect((await matcher.discoverGuideEvents()).map((g) => g.id),
          games.map((g) => g.id));
      expect(guide.reads, reads);
      expect(supportsSportsScoreboard(games.first.league), false);
      expect(supportsSportsSchedule(games.first.league), false);
      expect(sportLabel('sambo'), 'Sambo');
      expect(sportIcon('sambo'), sportIcon('taekwondo'));
      expect(savedSportsLeagues(storage).map((l) => l.id),
          contains('guide.sambo'));
      await storage.setHiddenGuideLeagues(['guide.sambo']);
      expect(savedSportsLeagues(storage).map((l) => l.id),
          isNot(contains('guide.sambo')));
    });
  }

  test('Test cricket requires named, consistent opponents and format evidence',
      () {
    for (final entry in <(String, String)>[
      ('Test Cricket - Afghanistan vs. Zimbabwe', '1st Test, Day 2.'),
      (
        'Test : Afghanistan v Zimbabwe 1st Test Day 2',
        'Coverage of Test Cricket.'
      ),
      ('Test Cricket', 'Afghanistan vs. Zimbabwe\n1st Test, Day 2.'),
      ('Cricket: India versus Australia', 'Second Test match.'),
      ('Test cricket: England v New Zealand', 'New Zealand vs England, Day 3.'),
      ('Test cricket: South Africa v Sri Lanka', ''),
      ('Test cricket: West Indies v Pakistan', ''),
      ('Test cricket: Bangladesh v Ireland', ''),
    ]) {
      expect(hasNamedTestCricketFixture(entry.$1, entry.$2), true,
          reason: entry.toString());
    }
    for (final entry in <(String, String)>[
      ('Cricket: Australia vs India', ''),
      ('Test cricket', 'Live coverage.'),
      ('Test cricket: Australia vs Australia', ''),
      ('Test cricket: Australia vs TBD', ''),
      ('Test cricket: Australia vs Nepal', ''),
      ('Test cricket: Australia vs India', 'England vs New Zealand'),
      ('Test cricket: Australia vs India', 'Australia vs Nepal'),
      ('Test cricket: Australia vs Nepal', 'Australia vs India'),
      ('Test cricket: Australia vs India / Pakistan vs Sri Lanka', ''),
      ('Test cricket', 'Earlier: Australia vs India. Live coverage follows.'),
      ('Test cricket', '${'x' * 640}Australia vs India'),
      ('Test cricket: Australia vs India', 'Live rugby coverage.'),
      ('Cricket Review: Afghanistan vs Zimbabwe', '1st Test, Day 2.'),
      ('Test cricket: Australia vs India', 'Highlights of the last Test.'),
      ('Test cricket: Australia vs India', '3rd ODI.'),
      ('Test cricket: Australia vs India', 'Under-19 coverage.'),
    ]) {
      expect(hasNamedTestCricketFixture(entry.$1, entry.$2), false,
          reason: entry.toString());
    }
  });

  for (final background in [false, true]) {
    test('Test cricket uses exact live guide slots and cache ($background)',
        () async {
      final entries = <String, (String, String, bool)>{
        'title': (
          'Test Cricket: Afghanistan vs. Zimbabwe',
          '1st Test, Day 2.',
          true
        ),
        'synopsis': (
          'Test Cricket',
          'Afghanistan vs. Zimbabwe\n1st Test, Day 2.',
          true
        ),
        'review': (
          'Cricket Review: Afghanistan vs Zimbabwe',
          '1st Test, Day 2.',
          true
        ),
        'replay': ('Test cricket: Australia vs India Replay', '', true),
        'unmarked': ('Test cricket: Australia vs India', '', false),
        'conflict': (
          'Test cricket: Australia vs India',
          'England v New Zealand',
          true
        ),
        'placeholder': ('Test cricket: Australia vs India FLSP 123', '', true),
        'expired': ('Test cricket: Australia vs India', '', true),
      };
      for (final entry in entries.entries) {
        guide.rows[entry.key] = _programme(entry.key, entry.value.$1,
            description: entry.value.$2,
            live: entry.value.$3,
            stop: entry.key == 'expired' ? _now : null);
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in entries.keys) _channel(id)]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(1));
      expect(games.single.guideProgrammes, hasLength(2));
      expect(games.every((g) => g.league.id == 'guide.test-cricket'), true);
      expect(games.every((g) => g.statusText == 'Live · guide'), true);
      final matches = await matcher.matchDay(games, _Picks());
      expect(matches.values.expand((m) => m).map((m) => m.channel.rawId),
          unorderedEquals(['title', 'synopsis']));
      expect(
          matches.values
              .expand((m) => m)
              .every((m) => m.reason == MatchReason.guide),
          true);
      expect(
          (await matcher.alternativesFor(games.single))
              .map((m) => m.channel.rawId),
          unorderedEquals(['title', 'synopsis']));
      final reads = guide.reads;
      final repeated = await matcher.discoverGuideEvents();
      expect(repeated.map((g) => g.id), games.map((g) => g.id));
      expect(guide.reads, reads);
      expect(supportsSportsScoreboard(games.first.league), false);
      expect(supportsSportsSchedule(games.first.league), false);
      expect(savedSportsLeagues(storage).map((l) => l.id),
          contains('guide.test-cricket'));
      await storage.setHiddenGuideLeagues(['guide.test-cricket']);
      expect(savedSportsLeagues(storage).map((l) => l.id),
          isNot(contains('guide.test-cricket')));
    });
  }

  test('Tauihi live coverage keeps exact channels and rejects non-events',
      () async {
    final entries = <String, (String, String, bool)>{
      'live': (
        'Tauihi: Kahu v Pouakai',
        'LIVE coverage from Round 7 of Tauihi Basketball Aotearoa between the Northern Kahu and Mainland Pouakai.',
        false
      ),
      'replay': ('Tauihi: Kahu v Pouakai Replay', 'Basketball coverage.', true),
      'recap': ('Tauihi highlights', 'Basketball coverage.', true),
      'news': ('Tauihi news', 'Live basketball news and interviews.', true),
      'unmarked': ('Tauihi: Kahu v Pouakai', 'Basketball coverage.', false),
      'fiction': ('Tauihi', 'A documentary about basketball.', true),
      'wrong-sport': ('Tauihi football', 'Live soccer coverage.', true),
      'synopsis-conflict': (
        'Live football: Red v Blue',
        'Live coverage of a Tauihi basketball match.',
        true
      ),
      'slot': ('LIVE Tauihi: Kahu v Pouakai ESPN+ 123', '', true),
    };
    for (final entry in entries.entries) {
      guide.rows[entry.key] = _programme(entry.key, entry.value.$1,
          description: entry.value.$2, live: entry.value.$3);
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([for (final id in entries.keys) _channel(id)]);
    final games = await matcher.discoverGuideEvents();
    expect(games.single.league.id, 'guide.tauihi');
    expect(games.single.league.shortName, 'Tauihi');
    expect(games.single.statusText, 'Live · guide');
    final result = await matcher.matchDay(games, _Picks());
    expect(result.values.single.single.channel.rawId, 'live');
    expect(result.values.single.single.reason, MatchReason.guide);
    final reads = guide.reads;
    expect(identical(await matcher.discoverGuideEvents(), games), true);
    expect(guide.reads, reads);
    expect(supportsSportsScoreboard(games.single.league), false);
    expect(supportsSportsSchedule(games.single.league), false);
    expect(kAutomaticSportsLeagues.map((l) => l.id), contains('guide.tauihi'));
    expect(
        savedSportsLeagues(storage).map((l) => l.id), contains('guide.tauihi'));
    await storage.setHiddenGuideLeagues(['guide.tauihi']);
    expect(savedSportsLeagues(storage).map((l) => l.id),
        isNot(contains('guide.tauihi')));
  });

  test('explicit women league variants keep the title ahead of the synopsis',
      () {
    for (final label in [
      'EuroLeague Women',
      "Women's EuroLeague",
      'EuroLeague Womens'
    ]) {
      expect(
          additionalGuideCompetition(
              'basketball', label, 'EuroCup Women coverage follows.'),
          'euroleague-women');
    }
    for (final label in [
      'EuroCup Women',
      'Women’s EuroCup',
      'EuroCup Womens'
    ]) {
      expect(
          additionalGuideCompetition(
              'basketball', label, 'EuroLeague Women coverage follows.'),
          'eurocup-women');
    }
    expect(
        additionalGuideCompetition(
            'basketball', 'EuroLeague', 'EuroCup Women coverage follows.'),
        'euroleague');
    expect(
        additionalGuideCompetition('basketball', 'FIBA 3x3 basketball',
            'EuroLeague Women coverage follows.'),
        'basketball');
  });

  test('women European basketball coverage retains its competition', () async {
    final titles = {
      'league': 'Live EuroLeague Women: Basket Landes vs Fenerbahce',
      'cup': 'Live EuroCup Women: Villeneuve vs Estudiantes',
      'league-original': 'Live EuroLeague: Real Madrid vs Barcelona',
      'cup-original': 'Live EuroCup: Trento vs Ulm',
    };
    for (final entry in titles.entries) {
      guide.rows[entry.key] = _programme(entry.key, entry.value,
          description:
              'Live basketball coverage. EuroLeague Women and EuroCup Women results follow.');
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([for (final id in titles.keys) _channel(id)]);
    final games = await matcher.discoverGuideEvents();
    expect({
      for (final game in games)
        game.guideProgrammes.single.channelId: game.league.id
    }, {
      'league': 'guide.euroleague-women',
      'cup': 'guide.eurocup-women',
      'league-original': 'guide.euroleague',
      'cup-original': 'guide.eurocup',
    });
    for (final game in games) {
      expect(supportsSportsScoreboard(game.league), false);
    }
  });

  test('live tennis and golf sessions use exact guide channels without SQL',
      () async {
    final cases = <String, (String, String, bool)>{
      'golf': (
        'Live DP World Tour Golf',
        'The second round of the Abu Dhabi Aldar Championship.',
        false
      ),
      'tennis': (
        'WTA Tennis Quarter Finals',
        'Enjoy live action from the ATP and WTA Tours.',
        true
      ),
      'multi-court': (
        'Center Court Live',
        'Paris-ATP, Hong Kong-WTA & Chennai-WTA Quarterfinals. Tennis action from around the world.',
        false
      ),
      'skating': (
        'Eiskunstlauf - Grand Prix: Frauen: Kurzprogramm',
        'Übertragung aktueller Eiskunstlauf-Wettbewerbe. (Figure skating)',
        true
      ),
      'replay': ('Live DP World Tour Golf Highlights', 'Second round.', true),
      'studio': (
        'Tennis Channel Live',
        'Discussing the ATP quarterfinals.',
        true
      ),
      'news': (
        'Golf Central Live',
        'News from the PGA Tour final round.',
        true
      ),
      'unmarked': (
        'DP World Tour Golf',
        'Second round of the championship.',
        false
      ),
      'generic': ('Live Tennis', 'Tennis channel programming.', true),
      'fiction': (
        'Grand Prix',
        'A documentary about figure skating competitions.',
        true
      ),
      'mixed': ('Live Tennis and Golf Finals', 'Sports coverage.', true),
      'rolling': ('Live WTA Tennis Quarterfinals ESPN+ 123', '', true),
      'expired': (
        'Live ATP Tennis Quarterfinals',
        'Quarterfinal coverage.',
        true
      ),
    };
    for (final e in cases.entries) {
      guide.rows[e.key] = _programme(e.key, e.value.$1,
          description: e.value.$2,
          live: e.value.$3,
          stop: e.key == 'expired' ? _now : null);
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([for (final id in cases.keys) _channel(id)]);
    final updates = <SportsGuideDiscovery>[];
    final games = await matcher.discoverGuideEvents(onProgress: updates.add);
    expect(games.map((g) => g.guideProgrammes.single.channelId).toSet(),
        {'golf', 'tennis', 'multi-court', 'skating'});
    expect(games.every((g) => g.isGuideEvent && g.statusText == 'Live · guide'),
        true);
    expect(updates.last.complete, true);
    expect(updates.first.complete, false);
    final result = await matcher.matchDay(games, _Picks());
    for (final game in games) {
      final matches = result[SportsChannelPicks.eventKey(game)]!;
      expect(matches.single.reason, MatchReason.guide);
      expect(
          matches.single.channel.epgId, game.guideProgrammes.single.channelId);
    }
    final reads = guide.reads;
    expect(identical(await matcher.discoverGuideEvents(), games), true);
    expect(guide.reads, reads);
  });

  test('an excluded numbered slot can become real coverage after correction',
      () async {
    final corrected = _ChangingGuide(storage)..changeOnRead = false;
    addTearDown(corrected.dispose);
    final matcher = SportsChannelMatcher(corrected, clock: () => _now);
    addTearDown(matcher.dispose);
    corrected.rows['slot'] = _programme(
        'slot', 'Live WTA Tennis Quarterfinals ESPN+ 123',
        live: true);
    await matcher.prepare([_channel('slot')]);
    expect(await matcher.discoverGuideEvents(), isEmpty);
    corrected.rows['slot'] = _programme(
        'slot', 'Live WTA Tennis Quarterfinals ESPN+ 123',
        live: true,
        description: 'Live quarterfinal coverage from the Hong Kong Open.');
    corrected.revision++;
    final games = await matcher.discoverGuideEvents();
    expect(games.single.league.id, 'guide.tennis');
    expect(games.single.guideProgrammes.single, same(corrected.rows['slot']));
    corrected.rows['slot'] = _programme(
        'slot', 'Live WTA Tennis Quarterfinals ESPN+ 123',
        live: true);
    corrected.revision++;
    expect(await matcher.discoverGuideEvents(), isEmpty);
  });

  test('session discovery is opt-in for the shared classification vocabulary',
      () {
    expect(extendedGuideSport('WTA Tennis Quarterfinals', ''), isNull);
    expect(extendedGuideSport('DP World Tour Golf', 'Second round'), isNull);
  });

  test(
      'early worker discovery agrees with the full index and preserves channels',
      () async {
    final channels =
        List.generate(8000, (i) => _channel('$i', name: 'Sports TV $i'));
    guide.rows['12'] =
        _programme('12', 'Live Badminton World Tour', live: true);
    guide.rows['13'] =
        _programme('13', 'Live Badminton World Tour', live: true);
    guide.rows['24'] = _programme('24', 'Live Darts Championship', live: true);
    var now = _now;
    final direct = SportsChannelMatcher(guide, clock: () => _now);
    final worker = SportsChannelMatcher.background(guide, clock: () => now);
    addTearDown(direct.dispose);
    addTearDown(worker.dispose);
    await direct.prepare(channels);
    SportsGuideDiscovery? expected;
    await direct.discoverGuideEvents(onProgress: (update) => expected = update);
    final updates = <SportsGuideDiscovery>[];
    var prepared = false;
    await worker.prepare(channels, onGuideProgress: (update) {
      expect(prepared, isFalse);
      updates.add(update);
      if (updates.length == 1) now = now.add(const Duration(minutes: 1));
    });
    prepared = true;
    expect(updates.first.complete, isFalse);
    expect(updates.last.complete, isTrue);
    expect(updates.last.validUntil, expected!.validUntil);
    expect(updates.last.validUntil!.isAfter(now), isTrue);
    expect(
        updates.last.games.map((g) => g.id), expected!.games.map((g) => g.id));
    for (final entry in expected!.matches.entries) {
      expect(
          updates.last.matches[entry.key]!
              .map((m) => (m.channel.id, m.score, m.reason)),
          entry.value.map((m) => (m.channel.id, m.score, m.reason)));
      for (final match in updates.last.matches[entry.key]!) {
        expect(match.channel,
            same(channels.firstWhere((c) => c.id == match.channel.id)));
      }
    }
    (worker as WidgetsBindingObserver).didHaveMemoryPressure();
    final fallback = await worker.discoverGuideEvents();
    expect(fallback.map((g) => g.id), expected!.games.map((g) => g.id));
  });

  test(
      'guide changes during early catalogue selection fall back to fresh evidence',
      () async {
    final changing = _ChangingGuide(storage);
    addTearDown(changing.dispose);
    changing.rows['one'] =
        _programme('one', 'Live Badminton World Tour', live: true);
    final worker = SportsChannelMatcher.background(changing, clock: () => _now);
    addTearDown(worker.dispose);
    final early = <SportsGuideDiscovery>[];
    await worker.prepare(List.generate(4096, (i) => _channel('$i', epg: 'one')),
        onGuideProgress: early.add);
    expect(early, isEmpty,
        reason: 'Do not publish a catalogue selected across guide versions');
    final updates = <SportsGuideDiscovery>[];
    expect(await worker.discoverGuideEvents(onProgress: updates.add),
        hasLength(1));
    expect(updates.last.evidenceVersion, (
      changing.changeRevision,
      changing.currentGuideRevision,
      changing.lastUpdated
    ));
  });

  test('oversized guide catalogue falls back without losing exact coverage',
      () async {
    guide.rows['one'] =
        _programme('one', 'Live Badminton World Tour', live: true);
    final channels = List.generate(24001, (i) => _channel('$i', epg: 'one'));
    final worker = SportsChannelMatcher.background(guide, clock: () => _now);
    addTearDown(worker.dispose);
    final early = <SportsGuideDiscovery>[];
    await worker.prepare(channels, onGuideProgress: early.add);
    expect(early, isEmpty);
    final updates = <SportsGuideDiscovery>[];
    final games = await worker.discoverGuideEvents(onProgress: updates.add);
    expect(games, hasLength(1));
    expect(updates.last.complete, isTrue);
    expect(updates.last.matches.values.single, hasLength(8));
    expect(
        updates.last.matches.values.single.every((m) => m.isConfident), isTrue);
  });

  test('discovery publishes exact channels before the scan finishes', () async {
    final channels = <Channel>[];
    for (var i = 0; i < 1600; i++) {
      final id = '$i';
      channels.add(_channel(id));
      guide.rows[id] = _programme(
          id,
          i == 0 || i == 1599
              ? 'Live Badminton World Tour'
              : 'Evening movie $i',
          live: i == 0 || i == 1599);
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare(channels);
    final updates = <SportsGuideDiscovery>[];
    final reads = <int>[];
    final result = await matcher.discoverGuideEvents(onProgress: (update) {
      updates.add(update);
      reads.add(guide.reads);
    });
    expect(updates.first.complete, isFalse);
    expect(reads.first, greaterThan(0));
    expect(updates.first.games, hasLength(1));
    expect(updates.first.games.single.guideProgrammes, hasLength(1),
        reason: 'Previously published snapshots must not mutate');
    expect(updates.first.matches.values.single.single.channel.id, 'p::0');
    expect(updates.first.matches.values.single.single.isConfident, isTrue);
    expect(updates.last.complete, isTrue);
    expect(result.single.guideProgrammes, hasLength(2));
    expect(result.single.id, updates.first.games.single.id);
    expect(updates.last.matches.values.single.map((m) => m.channel.id),
        unorderedEquals(['p::0', 'p::1599']));
    expect(updates.last.games, same(result));
    final noProgress = await matcher.discoverGuideEvents();
    expect(noProgress, same(result));
  });

  test('out-of-order provider slots cannot renumber a published guide card',
      () async {
    final earlier = _now.subtract(const Duration(minutes: 80));
    guide.rows['late'] = EpgProgram(
        channelId: 'late',
        title: 'Live Badminton World Tour',
        start: _now.subtract(const Duration(minutes: 10)),
        stop: _now.add(const Duration(hours: 2)),
        isLive: true);
    guide.rows['early'] = EpgProgram(
        channelId: 'early',
        title: 'Live Badminton World Tour',
        start: earlier,
        stop: _now.add(const Duration(hours: 2)),
        isLive: true);
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([_channel('late'), _channel('early')]);
    final snapshots = <SportsGuideDiscovery>[];
    final result = await matcher.discoverGuideEvents(onProgress: snapshots.add);
    expect(result, hasLength(2));
    final first = snapshots.first.games.single;
    expect(first.start, earlier);
    final retained = result.singleWhere((g) => g.id == first.id);
    expect(retained.start, earlier);
    expect(retained.guideProgrammes.single.channelId, 'early');
  });

  test('guide coverage publishes the start boundary despite stable event IDs',
      () async {
    var now = _now;
    guide.rows['racing'] = EpgProgram(
        channelId: 'racing',
        title: 'Supercars Gold Coast Race 1 LIVE',
        isLive: true,
        start: now.add(const Duration(minutes: 5)),
        stop: now.add(const Duration(hours: 2)));
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    await matcher.prepare([_channel('racing', name: 'Sports TV')]);
    final before = await matcher.discoverGuideEvents();
    expect(before, hasLength(1));
    expect(before.single.state, GameState.pre);
    now = now.add(const Duration(minutes: 6));
    final after = await matcher.discoverGuideEvents();
    expect(after.single.id, before.single.id);
    expect(after.single.state, GameState.live);
    expect(sameGuideCoverage(before, after), isFalse);
    expect(
        sameGuideCoverage(after,
            [copyGuideCoverage(after.single, after.single.guideProgrammes)]),
        isTrue);

    final original = after.single.guideProgrammes.single;
    final corrected = EpgProgram(
        channelId: original.channelId,
        start: original.start,
        stop: original.stop,
        title: original.title,
        isLive: original.isLive,
        description: 'Final table, live coverage.');
    expect(
        sameGuideCoverage(after, [
          copyGuideCoverage(after.single, [corrected])
        ]),
        isFalse);
  });

  test(
      'new scored cup matches both teams in EPG, not another game on the network',
      () async {
    final feed = _FixtureGuide(storage);
    addTearDown(feed.dispose);
    feed.rows['correct'] = _programme('correct',
        'Concacaf Central American Cup Soccer: Alajuelense vs. Motagua LIVE',
        description: 'Semifinal, second leg.');
    feed.rows['wrong'] = _programme('wrong',
        'Concacaf Central American Cup Soccer: Saprissa vs. LA Firpo LIVE');
    final matcher = SportsChannelMatcher(feed, clock: () => _now);
    addTearDown(matcher.dispose);
    await matcher.prepare([
      _channel('wrong', name: 'Sports Network 1'),
      _channel('correct', name: 'Sports Network 2'),
    ]);
    final game = SportsGame(
      id: 'cup-fixture',
      league: sportsLeagueById('concacaf.central.american.cup')!,
      start: _now.subtract(const Duration(minutes: 20)),
      state: GameState.live,
      statusText: 'Live',
      home: const SportsTeam(
          id: 'h',
          name: 'Alajuelense',
          shortName: 'Alajuelense',
          abbreviation: 'ALA'),
      away: const SportsTeam(
          id: 'a',
          name: 'FC Motagua',
          shortName: 'Motagua',
          abbreviation: 'MOT'),
    );
    final matches = (await matcher.matchDay([game], _Picks())).values.single;
    expect(matches.first.channel.rawId, 'correct');
    expect(matches.first.isConfident, isTrue);
    expect(matches.where((m) => m.isConfident).map((m) => m.channel.rawId),
        ['correct']);
  });

  for (final background in [false, true]) {
    test(
        'named competitions retain their league and exact guide bindings ($background)',
        () async {
      final rows = <String, (String, String, String)>{
        'euroleague': ('LIVE EuroLeague: Red vs Blue', '', 'guide.euroleague'),
        'eurocup': (
          'Košarka - Eurocup: Aris - Cedevita Olimpija LIVE',
          'Euroleague Basketball competition.',
          'guide.eurocup'
        ),
        'ahl': (
          'Hershey Bears @ Rochester Americans LIVE',
          'AHL action live from the arena.',
          'guide.ahl'
        ),
        'ohl': (
          'OHL Hockey - Brantford Bulldogs at Sarnia Sting LIVE',
          'From Progressive Auto Sales Arena. AHL alumni in the crowd.',
          'guide.ohl'
        ),
        'ohl-synopsis': (
          'Windsor Spitfires at Ottawa 67s LIVE',
          'Ontario Hockey League action.',
          'guide.ohl'
        ),
        'aflw': (
          'LIVE AFLW: St Kilda v Port Adelaide',
          'Australian rules football.',
          'guide.aflw'
        ),
        'poland': (
          'LIVE Ekstraklasa Soccer: Legia vs Lech',
          '',
          'guide.ekstraklasa'
        ),
        'cyclocross': (
          'Live Cyclocross: Overijse',
          'Superprestige elite women.',
          'guide.cyclocross'
        ),
        'climbing': (
          'Climbing World Series LIVE',
          'Speed final.',
          'guide.climbing'
        ),
        'gymnastics': (
          'World Championship Artistic Gymnastics LIVE',
          'Apparatus finals.',
          'guide.gymnastics'
        ),
        'wwe': ('WWE NXT Halloween Havoc LIVE', '', 'guide.wwe'),
        'aew': ('All Elite Wrestling: Dynamite LIVE', '', 'guide.aew'),
        'tna': ('TNA iMPACT! LIVE', '', 'guide.tna'),
      };
      for (final entry in rows.entries) {
        guide.rows[entry.key] =
            _programme(entry.key, entry.value.$1, description: entry.value.$2);
        guide.rows['old-${entry.key}'] = _programme('old-${entry.key}',
            entry.value.$1.replaceAll('LIVE', '').replaceAll('Live', ''),
            description: entry.value.$2);
        guide.rows['replay-${entry.key}'] = _programme(
            'replay-${entry.key}', '${entry.value.$1} Replay',
            description: entry.value.$2);
      }
      // Remove live wording from the repeated hockey synopsis as well.
      guide.rows['old-ahl'] = _programme(
          'old-ahl', 'Hershey Bears @ Rochester Americans',
          description: 'AHL action from the arena.');
      guide.rows['wrong'] = _programme('wrong', 'Live AFLW: Brisbane v Sydney',
          description:
              'Action from the A-League Women, the top football division in Australia.');
      guide.rows['studio'] = _programme('studio', 'WWE Kickoff LIVE');
      guide.rows['other-eurocup'] = _programme(
          'other-eurocup', 'Live Skiing Eurocup',
          description: 'Winter sports.');
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in guide.rows.keys) _channel(id)]);
      final events = await matcher.discoverGuideEvents();
      expect(events, hasLength(rows.length));
      for (final event in events) {
        final id = rows.keys.singleWhere((id) => rows[id]!.$1 == event.title);
        expect(event.league.id, rows[id]!.$3);
        final matches =
            (await matcher.matchDay([event], _Picks())).values.single;
        expect(matches.where((m) => m.isConfident), hasLength(1));
        expect(matches.first.channel.rawId, id);
      }
      final reads = guide.reads;
      expect((await matcher.discoverGuideEvents()).map((e) => e.id),
          events.map((e) => e.id));
      expect(guide.reads, reads);
    });
  }

  for (final background in [false, true]) {
    test(
        'additional guide competitions keep exact channels and live evidence ($background)',
        () async {
      final broadcasts = <String, (String, String, String)>{
        'padel': (
          'Premier Padel Tennis: Kuwait Quarterfinals LIVE',
          '',
          'guide.padel'
        ),
        'pickleball': (
          'LIVE PPA Tour: Texas Open Final',
          '',
          'guide.pickleball'
        ),
        'taekwondo': (
          'LIVE World Taekwondo Grand Prix: Paris Final',
          '',
          'guide.taekwondo'
        ),
        'sailing': ('LIVE SailGP: Sydney Day 2', '', 'guide.sailing'),
        'triathlon': ('LIVE IRONMAN World Championship', '', 'guide.triathlon'),
        'local': ('ศึกจิตรเมืองนนท์', 'ถ่ายทอดสดมวยไทย', 'guide.muay-thai'),
        'local-two': (
          'ศึกจ้าวมวยไทย',
          'ถ่ายทอดสดการแข่งขันชกมวยศึกจ้าวมวยไทย.',
          'guide.muay-thai'
        ),
        'one': ('ถ่ายทอดสด ONE ลุมพินี 200', '', 'guide.one'),
        'rws': ('LIVE RWS: Rajadamnern World Series', '', 'guide.muay-thai'),
        'kiatpetch': (
          'LIVE Suek Kiatpetch Tor Nam Thai TKO',
          '',
          'guide.muay-thai'
        ),
        'thai-fight': ('ไทยไฟท์ [สด]', '', 'guide.muay-thai'),
      };
      for (final entry in broadcasts.entries) {
        guide.rows[entry.key] =
            _programme(entry.key, entry.value.$1, description: entry.value.$2);
      }
      final excluded = [
        'Premier Padel Tennis: Kuwait Quarterfinals',
        'World Taekwondo Grand Prix: Paris Final',
        'SailGP Racing On The Edge LIVE',
        'Kp Sunday Fight 2026',
        'One Lumpinee Heroes LIVE',
        'มวยไทย ถ่ายทอดสด ย้อนหลัง',
        'ไฮไลท์มวยไทย ถ่ายทอดสด',
        'มวยมันส์ช่อง 8',
      ];
      for (final (i, title) in excluded.indexed) {
        guide.rows['excluded-$i'] = _programme('excluded-$i', title);
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in guide.rows.keys) _channel(id)]);
      final events = await matcher.discoverGuideEvents();
      expect(events, hasLength(broadcasts.length));
      for (final event in events) {
        final id = broadcasts.keys
            .singleWhere((id) => broadcasts[id]!.$1 == event.title);
        expect(event.league.id, broadcasts[id]!.$3);
        expect(event.league, same(sportsLeagueById(event.league.id)));
        final matches =
            (await matcher.matchDay([event], _Picks())).values.single;
        expect(matches.first.channel.rawId, id);
        expect(matches.first.isConfident, isTrue);
        expect(matches.where((m) => m.isConfident), hasLength(1));
      }
      final reads = guide.reads;
      expect((await matcher.discoverGuideEvents()).map((e) => e.id),
          events.map((e) => e.id));
      expect(guide.reads, reads);
    });
  }

  for (final background in [false, true]) {
    test(
        'additional broadcasts require live evidence and exact slots ($background)',
        () async {
      final titles = {
        'sumo': 'Grand Sumo Tournament: Day 4',
        'skating':
            'ISU Grand Prix of Figure Skating: Skate Canada International',
        'skiing': 'Alpine Skiing World Cup: Women’s Slalom',
        'basketball': 'FIBA Mens 3X3 Basketball World Tour: Macau',
      };
      for (final entry in titles.entries) {
        guide.rows[entry.key] = _programme(entry.key, entry.value, live: true);
        guide.rows['old-${entry.key}'] =
            _programme('old-${entry.key}', entry.value);
        guide.rows['recap-${entry.key}'] = _programme(
            'recap-${entry.key}', '${entry.value} Highlights',
            live: true);
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in guide.rows.keys) _channel(id)]);
      final events = await matcher.discoverGuideEvents();
      expect(events.map((g) => g.league.id),
          unorderedEquals(titles.keys.map((s) => 'guide.$s')));
      for (final event in events) {
        expect(event.league, same(sportsLeagueById(event.league.id)));
        final matches =
            (await matcher.matchDay([event], _Picks())).values.single;
        expect(matches.where((m) => m.isConfident), hasLength(1));
        expect(matches.first.channel.rawId,
            event.league.espnPath.split('/').first);
      }
      final reads = guide.reads;
      final cached = await matcher.discoverGuideEvents();
      expect(cached.map((g) => g.id), events.map((g) => g.id));
      if (!background) expect(cached, same(events));
      expect(guide.reads, reads, reason: 'Warm discovery reuses its snapshot');
      expect(
          classifySportsReplay(_programme(
                  'sumo-repeat', 'Grand Sumo Tournament: Day 4 Replay'))
              ?.sport,
          'sumo');
      expect(classifySportsHighlights(guide.rows['recap-skating']!)?.sport,
          'skating');
      expect(extendedGuideSport('Impractical Jokers: Pseudo-Sumo', ''), isNull);
      expect(
          extendedGuideSport('A skating adventure',
              'A documentary about figure skating competitions.'),
          isNull);
      expect(extendedGuideSport('PBA Bowling', ''), 'bowling');
      expect(extendedGuideSport('FIBA World Basketball', ''), isNull,
          reason: 'Magazine shows must not become 3×3 fixtures');
    });
  }

  for (final background in [false, true]) {
    test('studio and recap programmes are not live events ($background)',
        () async {
      final rejected = [
        'F1 Paddock Live Pre Gara',
        'F1 Paddock Live',
        'Live Supercars Recap',
        'Live F1: Post-race',
        'Live F1: Ted’s Notebook',
        'Live WEC: Race Review',
        'X Games Highlights',
        'Billiards Roundup',
      ];
      final kept = [
        'Live F1: Mexico Grand Prix Race',
        'Live Supercars: Race 2',
        'Live WEC: Free Practice',
        'X Games - Shanghai',
        'World Poker Tour',
        'World Snooker Tour',
      ];
      for (final (i, title) in [...rejected, ...kept].indexed) {
        guide.rows['coverage$i'] =
            _programme('coverage$i', title, live: i < rejected.length + 3);
      }
      // A stale LIVE flag must not override an explicit highlights synopsis.
      guide.rows['summary'] = _programme('summary', 'X Games',
          live: true, description: 'Highlights from the X Games in Shanghai.');
      guide.rows['story'] = _programme('story', 'Surfing: A champion',
          description: 'The story of a surfing champion and his career.');
      guide.rows['documentary'] = _programme('documentary', 'X Games',
          description: 'A documentary about the BMX competition.');
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in guide.rows.keys) _channel(id)]);
      expect((await matcher.discoverGuideEvents()).map((g) => g.title),
          unorderedEquals(kept));
      final recap = _programme('recap', 'Supercars Recap', live: true);
      expect(classifySportsHighlights(recap)?.sport, 'racing');
      expect(classifySportsHighlights(guide.rows['summary']!)?.sport,
          'action-sports');
      expect(
          classifySportsHighlights(_programme(
              'race', 'Live F1: Mexico Grand Prix Race',
              live: true,
              description:
                  'Live coverage of the race, with highlights from qualifying.')),
          isNull);
    });
  }

  for (final worker in [false, true]) {
    test(
        '${worker ? 'worker' : 'direct'}: combat simulcasts attach to scored card and keep all picker channels',
        () async {
      final rows = _RacingGuide(storage);
      addTearDown(rows.dispose);
      var now = _now;
      for (var i = 0; i < 12; i++) {
        rows.rows['$i'] = _programme('$i',
            i.isEven ? 'Live UFC 333 Prelims HD' : 'UFC 333 Preliminary Fights',
            description: 'Live event coverage on broadcaster $i.',
            live: true,
            stop: _now.add(Duration(minutes: i == 0 ? 30 : 60)));
      }
      rows.rows['other'] = _programme('other', 'UFC 334 Prelims', live: true);
      final matcher = worker
          ? SportsChannelMatcher.background(rows, clock: () => now)
          : SportsChannelMatcher(rows, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in rows.rows.keys) _channel(id)]);
      final discovered = await matcher.discoverGuideEvents();
      expect(discovered, hasLength(2));
      final broadcast =
          discovered.singleWhere((g) => g.guideProgrammes.length == 12);
      final score = SportsGame(
          id: 'score',
          league: sportsLeagueById('mma.ufc')!,
          start: _now,
          state: GameState.live,
          statusText: 'Round 2',
          home: broadcast.home,
          away: broadcast.away,
          event: const SportsEventInfo(title: 'UFC 333'));
      final merged = mergeSportsGuideCoverage([score], discovered);
      expect(merged, hasLength(2));
      final card = merged.singleWhere((g) => g.id == 'score');
      expect(card.guideProgrammes, hasLength(12));
      final short = (await matcher.matchDay([card], _Picks())).values.single;
      expect(short, hasLength(8));
      final all = await matcher.alternativesFor(card, matches: short);
      expect(all.where((m) => m.isConfident), hasLength(12));
      expect(
          all
              .where((m) => m.isConfident)
              .any((m) => m.channel.rawId == 'other'),
          isFalse);
      now = _now.add(const Duration(minutes: 31));
      final current =
          (await matcher.matchDay([card], _Picks(), limit: 30)).values.single;
      expect(current.where((m) => m.isConfident), hasLength(11));
      expect(
          current
              .where((m) => m.isConfident)
              .any((m) => m.channel.rawId == '0'),
          isFalse);
      matcher.dispose();
    });
  }

  for (final worker in [false, true]) {
    test(
        '${worker ? 'worker' : 'direct'}: F1 and ONE duplicates retain every exact alternative and cache',
        () async {
      final titles = [
        'Live F1 São Paulo GP First Practice',
        'Formula One: Sao Paulo Grand Prix - Free Practice 1',
        'F1 Brazilian GP FP1',
        'ONE Friday Fights 177 ᴸᶦᵛᵉ',
        'ONE Friday Fights 2026: OFF 177',
        'LIVE EVENT 02 - 8:30am ONE Friday Fights 177',
      ];
      for (final (i, title) in titles.indexed) {
        guide.rows['$i'] = _programme('$i', title,
            description: i == 3 ? 'Live coverage. - 2026-10-24' : null,
            live: true);
      }
      final matcher = worker
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher
          .prepare([for (var i = 0; i < titles.length; i++) _channel('$i')]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(2));
      expect(games.every((g) => g.guideProgrammes.length == 3), isTrue);
      final cached = await matcher.discoverGuideEvents();
      expect(sameGuideCoverage(cached, games), isTrue);
      if (!worker) expect(identical(cached, games), isTrue);
      final matched = await matcher.matchDay(games, _Picks());
      final channels = <String>{};
      for (final game in games) {
        final matches = matched[SportsChannelPicks.eventKey(game)]!;
        expect(matches, hasLength(3));
        expect(
            matches.every((m) => m.isConfident && m.programme != null), isTrue);
        final alternatives =
            await matcher.alternativesFor(game, matches: matches);
        expect(alternatives, hasLength(3));
        channels.addAll(alternatives.map((m) => m.channel.rawId));
        expect(alternatives.map((m) => m.programme!.title).toSet(),
            game.guideProgrammes.map((p) => p.title).toSet());
      }
      expect(channels, {'0', '1', '2', '3', '4', '5'});
    });

    test(
        '${worker ? 'worker' : 'direct'}: combined motorsport keeps all channels and expires individual slots',
        () async {
      final racing = _RacingGuide(storage);
      addTearDown(racing.dispose);
      var now = _now;
      for (var i = 0; i < 12; i++) {
        racing.rows['$i'] = _programme(
            '$i',
            i.isEven
                ? 'Live F1 Mexico Grand Prix Race'
                : 'Formula One Mexican GP',
            description: 'Broadcast $i',
            live: true,
            stop: _now.add(Duration(minutes: i == 0 ? 10 : 60)));
      }
      final matcher = worker
          ? SportsChannelMatcher.background(racing, clock: () => now)
          : SportsChannelMatcher(racing, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        for (var i = 0; i < 12; i++)
          _channel('$i', name: i == 11 ? 'F1 Driver Tracker' : 'Race TV $i')
      ]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(1));
      final all = await matcher.alternativesFor(games.single);
      expect(all, hasLength(12));
      expect(all.first.isConfident, isTrue);
      expect(all.last.channel.rawId, '11');
      expect(all.last.isConfident, isFalse);
      final main = SportsGame(
          id: 'score',
          league: sportsLeagueById('racing.f1')!,
          start: _now,
          end: _now.add(const Duration(hours: 2)),
          state: GameState.live,
          statusText: 'Lap 10',
          home: games.single.home,
          away: games.single.away,
          event: const SportsEventInfo(
              title: 'Mexico City Grand Prix', session: 'Race'));
      final merged = mergeMotorsportCoverage([main], games);
      expect(merged, hasLength(1));
      final matches = (await matcher.matchDay(merged, _Picks())).values.single;
      expect(matches, hasLength(8));
      expect(
          matches.every((m) => m.isConfident && m.programme != null), isTrue);
      final alternatives =
          await matcher.alternativesFor(merged.single, matches: matches);
      expect(alternatives, hasLength(12));
      expect(alternatives.where((m) => m.isConfident), hasLength(11));
      now = _now.add(const Duration(minutes: 11));
      final expired =
          (await matcher.matchDay(merged, _Picks(), limit: 30)).values.single;
      expect(
          expired.any((m) => m.channel.rawId == '0' && m.isConfident), isFalse);
      expect(expired.where((m) => m.isConfident), hasLength(10));
      matcher.dispose();
    });
  }

  test(
      'guide leagues survive upgrades, respect hiding, and make no score requests',
      () async {
    await storage.setSportsLeagues(['mlb']);
    expect(savedSportsLeagues(storage).map((l) => l.id),
        containsAll(['guide.npb', 'guide.kbo', 'guide.cpbl', 'rugby.live']));
    await storage.setHiddenGuideLeagues(['guide.kbo']);
    expect(savedSportsLeagues(storage).map((l) => l.id),
        isNot(contains('guide.kbo')));
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      throw StateError('Guide-only leagues must never query ESPN');
    });
    addTearDown(client.close);
    final service = SportsService.withClient(client);
    expect(await service.gamesForDay(kGuideSportsLeagues, _now), isEmpty);
    expect(service.lastError, isNull);
    expect(await service.replayGames(kGuideSportsLeagues.first, _now), isEmpty);
    expect(requests, 0);
    final all = [...kSportsLeagues, ...kSportsLeagueBank];
    expect(all.map((l) => l.id).toSet().length, all.length);
    expect(kSportsLeagueBank.where((l) => l.region == 'Rugby').length, 15);
  });

  for (final background in [false, true]) {
    test(
        'motorsport supports: exact channel evidence, no replay guesses ($background)',
        () async {
      final titles = [
        'Supercars : Gold Coast Supports (KAYO) ᴸᶦᵛᵉ',
        'Live Porsche Carrera Cup Australia: Race 2',
        'Live Aussie Racing Cars: Race 4',
        'Live Formula 2: Feature Race',
        'Live Formula 3: Sprint Race',
        'Live GT World Challenge: Race 2',
        'Live WEC: 8 Hours of Bahrain',
        'Live V8 SuperUtes: Race 3',
        'Supercars Gold Coast Supports replay',
        'Live Porsche road test',
        'Live Horse Racing',
        'GT3 Highlights',
        'Formula 2: Feature Race', // no live evidence: may be a replay
        'Live Supercars: Gold Coast 500', // explicit replay synopsis
      ];
      for (var i = 0; i < titles.length; i++) {
        guide.rows['motor$i'] = _programme('motor$i', titles[i],
            description: i == 0
                ? 'Porsche Carrera Cup Race 2; Aussie Racing Cars Race 4.'
                : i == 13
                    ? 'A replay of yesterday’s race.'
                    : '');
      }
      final channels = [
        for (var i = 0; i < titles.length; i++) _channel('motor$i'),
        _channel('variant', epg: 'motor0'),
        _channel('wrong', name: 'Supercars supports'),
      ];
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare(channels);
      final games = await matcher.discoverGuideEvents();
      expect(games.map((g) => g.title),
          unorderedEquals([...titles.take(8), titles[10]]));
      expect(games.singleWhere((g) => g.title == titles[10]).league.id,
          'guide.horse-racing');
      expect(
          games.where((g) => g.title != titles[10]).every((g) =>
              g.league.espnPath.startsWith('racing/') &&
              g.statusText == 'Live · guide'),
          isTrue);
      final support = games.singleWhere((g) => g.title == titles.first);
      final matches =
          await matcher.matchDay([support], _Picks(), includePossible: true);
      expect(matches.values.single.map((m) => m.channel.rawId),
          unorderedEquals(['motor0', 'variant']));
      expect(matches.values.single.every((m) => m.isConfident), isTrue);
      final reads = guide.reads;
      await matcher.discoverGuideEvents();
      expect(guide.reads, reads, reason: 'No rescanning an unchanged guide');
    });
  }

  test('motorsport may be in a competitive synopsis, never a bare car brand',
      () {
    expect(
        extendedGuideSport('Gold Coast Supports',
            'Live coverage of Porsche Carrera Cup and Aussie Racing Cars.'),
        'racing');
    expect(
        extendedGuideSport('Road test', 'Driving a new Porsche on the road.'),
        isNull);
    expect(extendedGuideSport('Live horse racing', 'Race coverage from Ascot.'),
        'horse-racing');
  });

  test('rugby competition detection keeps unrelated leagues and shows out', () {
    final cases = {
      'NRL: Panthers vs Storm': 'nrl',
      'NRLW: Broncos vs Roosters': 'nrlw',
      "NRL Women: Broncos vs Roosters": 'nrlw',
      'Betfred Super League: Wigan vs Leeds': 'super-league',
      'Super Rugby Pacific: Blues vs Chiefs': 'super-rugby',
      'Bunnings NPC: Canterbury vs Waikato': 'npc',
      'Gallagher Prem: Bath vs Bristol': 'premiership',
      'Top 14: Toulouse vs Toulon': 'top14',
      'URC: Leinster vs Munster': 'urc',
      'Japan Rugby League One': 'league-one',
      'Currie Cup: Sharks vs Bulls': 'currie-cup',
      'Autumn Nations: England vs Australia': 'internationals',
    };
    expect(
        rugbyGuideCompetition('United Rugby Championship: Bulls v Lions', ''),
        'urc');
    expect(
        extendedGuideSport('This is TNT Sports Ultimate',
            'Home of Champions League and Gallagher Premiership coverage'),
        isNull);
    expect(
        extendedGuideSport('UEFA Europa League: Plzen v Levski', '',
            channelName: 'AU STAN | Bath v Bristol PREM Rugby'),
        isNull);
    for (final e in cases.entries) {
      expect(extendedGuideSport(e.key, ''), 'rugby', reason: e.key);
      expect(rugbyGuideCompetition(e.key, ''), e.value, reason: e.key);
    }
    for (final title in [
      'Super League: Basel vs Young Boys',
      'Premiership: Celtic vs Rangers',
      'Champions Cup: Soccer',
      'NRL News',
      'Rugby documentary'
    ]) {
      expect(extendedGuideSport(title, ''), isNull, reason: title);
    }
    expect(
        extendedGuideSport('Sharks vs Bulls', '',
            channelName: 'Sky Sport Rugby'),
        'rugby');
    expect(
        extendedGuideSport('Sharks vs Bulls', '', channelName: 'Sky Sport 1'),
        isNull);
  });

  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: rugby and unspecified cricket formats stay excluded',
        () async {
      guide.rows['nrl'] =
          _programme('nrl', 'NRL: Panthers vs Storm', live: true);
      guide.rows['urc'] =
          _programme('urc', 'URC: Leinster vs Munster', live: true);
      guide.rows['cricket'] =
          _programme('cricket', 'Cricket: Australia vs India', live: true);
      guide.rows['future'] = _programme(
          'future', 'STAN | Bath v Bristol PREM Rugby (2026-11-01 05:40:15)');
      guide.rows['old'] = _programme('old', 'Replay: NRL Panthers vs Storm');
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([for (final id in guide.rows.keys) _channel(id)]);
      final games = await matcher.discoverGuideEvents();
      expect(games, isEmpty);
    });
  }

  test(
      'extended sport vocabulary needs programme evidence, not incidental fiction',
      () {
    for (final entry in {
      'World Poker Tour': 'poker',
      'High Stakes Poker': 'poker',
      'PDC European Championship Darts': 'darts',
      'Counter-Strike: BLAST Premier': 'esports',
      'X Games': 'action-sports',
      'Street League Skateboarding': 'action-sports',
      'Northern Ireland Open Snooker': 'billiards',
      'PBA Tour Bowling': 'bowling',
      'BWF Badminton': 'badminton',
      'World Table Tennis': 'table-tennis',
    }.entries) {
      expect(extendedGuideSport(entry.key, ''), entry.value, reason: entry.key);
    }
    expect(extendedGuideSport('Poker Night', '(Sports, Cards)'), 'poker');
    expect(
        extendedGuideSport(
            'Cash Cab',
            'Unsuspecting members of the public climb into a taxicab for a chance to win. '
                '(Game show, Motorsports, Action sports, Esports) - 2012-04-21'),
        isNull);
    expect(
        extendedGuideSport('Sports quiz show',
            'Players compete with questions about darts and esports.'),
        isNull);
    for (final title in [
      'Poker Face',
      'Kill the Poker Player',
      'Poker Night',
      'Poker documentary',
      'Valorant review',
      'BMX tutorial',
      'Esports news'
    ]) {
      expect(extendedGuideSport(title, ''), isNull, reason: title);
    }
    expect(
        extendedGuideSport('Kill the Poker Player',
            'Two robbers search for stolen money. (Classic tv) - 1972'),
        isNull);
    expect(
        extendedGuideSport('The Upper Hand',
            'Caroline offers to host Charlie’s monthly poker game.'),
        isNull);
    expect(extendedGuideSport('Crime scene', 'The detective plays darts.'),
        isNull);
    expect(
        extendedGuideSport(
            'The Masters', 'Live coverage of the snooker tournament.'),
        'billiards');
  });

  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: exact mappings, variants, cache, manual picks and expiry',
        () async {
      var now = _now;
      guide.rows['poker'] =
          _programme('POKER', 'World Poker Tour', description: 'Final table.');
      guide.rows['darts'] =
          _programme('darts', 'European Championship Darts', live: true);
      final channels = [
        for (var i = 0; i < 12; i++) _channel('poker$i', epg: 'Poker'),
        _channel('darts'),
        _channel('other', name: 'World Poker Tour guesses'),
        _channel('header', epg: 'Poker', name: '### Poker'),
        _channel('xt_vod_1', epg: 'Poker'),
      ];
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => now)
          : SportsChannelMatcher(guide, clock: () => now);
      addTearDown(matcher.dispose);
      await matcher.prepare(channels);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(2));
      final poker = games.singleWhere((g) => g.league.id == 'guide.poker');
      expect(poker.title, 'World Poker Tour');
      expect(poker.isOnAirOnly, isTrue);
      expect(games.singleWhere((g) => g.league.id == 'guide.darts').statusText,
          'Live · guide');
      expect(poker.withOnlineBroadcasts([]).guideProgrammes,
          poker.guideProgrammes);
      final reads = guide.reads;
      for (var i = 0; i < 5; i++) {
        expect((await matcher.discoverGuideEvents()).map((g) => g.id),
            games.map((g) => g.id));
      }
      expect(guide.reads, reads,
          reason: 'Repeated polls reuse the snapshot/discovery');
      final matches =
          await matcher.matchDay(games, _Picks(), includePossible: true);
      final top = matches[SportsChannelPicks.eventKey(poker)]!;
      expect(top, hasLength(8));
      expect(top.every((m) => m.reason == MatchReason.guide && m.isConfident),
          isTrue);
      expect(
          identical(top.first.channel,
              channels.firstWhere((c) => c.id == top.first.channel.id)),
          isTrue);
      final all = await matcher.alternativesFor(poker, matches: top);
      expect(all, hasLength(12));
      expect(all.any((m) => m.channel.rawId == 'other'), isFalse);
      final manual = await matcher.matchDay([poker], _Picks('p::poker9'));
      expect(manual.values.single.first.channel.id, 'p::poker9');
      expect(
          (await matcher.alternativesFor(poker, matches: manual.values.single)),
          hasLength(12));
      now = _now.add(const Duration(minutes: 31));
      expect(await matcher.discoverGuideEvents(), isEmpty);
      expect(
          (await matcher.matchDay([poker], _Picks())).values.single, isEmpty);
    });
  }

  test('no placeholders, expired slots or explicitly recorded poker events',
      () async {
    final titles = [
      'Poker Face',
      'PDC Darts TV',
      'X Games 2024',
      'Poker replay: WSOP Final Table',
      'X Games highlights',
      'Darts coming soon',
      'PDC Darts: event ended',
      'PDC Board: Dutch Darts Championship stop:2026-10-18 23:00:00',
      'Poker Night',
      'US (ESPN+ 170) | Surfing: WSL Championship Tour (2026-10-25 02:30:00)',
      'Poker Masters \$2000 NL Holdem Final Table',
      'World Poker Tour',
    ];
    final channels = [
      for (var i = 0; i < titles.length; i++)
        _channel('$i', name: i == 1 ? titles[i] : null)
    ];
    for (var i = 0; i < titles.length; i++) {
      guide.rows['$i'] = _programme('$i', titles[i]);
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare(channels);
    expect(
        (await matcher.discoverGuideEvents()).map((g) => g.title),
        unorderedEquals([
          'World Poker Tour',
          'Poker Masters \$2000 NL Holdem Final Table'
        ]));
  });

  test(
      'poker synopsis identifies coverage on general channels without broad plot matches',
      () {
    for (final (title, description, name) in [
      (
        'Bay 101 Shooting Stars',
        'From San Jose, California. (Card games, Poker)',
        'MASN'
      ),
      ('The Main Event', 'Las Vegas pros play poker.', 'CBS Sports Network'),
      (
        'The Final Table',
        "Live no-limit Texas hold'em action from Las Vegas.",
        'NBC Sports Boston'
      ),
      (
        'Choctaw: Part 2',
        'Coverage of the WPT final table, with interviews between hands.',
        'NESN'
      ),
      ('Weekend Tables', '${'x' * 605} (Poker)', 'CBS Sports Network'),
      ('Poker Night', '', 'Altitude Sports 2'),
      ('Poker Night', 'Poker Night', 'US | NBC Sports Philadelphia HD'),
    ]) {
      expect(extendedGuideSport(title, description, channelName: name), 'poker',
          reason: title);
    }
    for (final (title, description) in [
      (
        'The King of Queens',
        "Gambling N'Diction: Doug convinces his mum to enter a high-stakes poker tournament. (S8 Ep13/23)"
      ),
      (
        'Death in Paradise',
        'The team enter the high-stakes world of poker when a finalist is poisoned and the only suspects are the other players.'
      ),
      (
        'The Upper Hand',
        "Caroline offers to host Charlie's monthly poker game."
      ),
      (
        'A family night',
        'Poker players gather at the final table. (Comedy, Sitcom)'
      ),
      ('Poker Night', 'A detective is trapped by a murderer. (Movie, Horror)'),
      ('Poker interviews', 'Interview with poker players at the final table.'),
      ('NBA Basketball', 'A player enjoys poker action between games.'),
    ]) {
      expect(
          extendedGuideSport(title, description,
              channelName: 'CBS Sports Network'),
          isNull,
          reason: title);
    }
    expect(
        extendedGuideSport('Poker Night', '', channelName: 'A Movie Channel'),
        isNull);
  });

  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: general US guide poker keeps exact channels and does not need a supplemental feed',
        () async {
      guide.rows['masn'] = _programme('masn', 'Bay 101 Shooting Stars',
          description: 'From San Jose, California. (Card games, Poker)');
      guide.rows['cbs'] = _programme('cbs', 'The Main Event',
          description: 'Las Vegas pros play poker.', live: true);
      guide.rows['altitude'] = _programme('altitude', 'Poker Night');
      guide.rows['movie'] = _programme('movie', 'Poker Night',
          description: 'A detective is trapped by a murderer. (Movie, Horror)');
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        _channel('masn', name: 'MASN'),
        _channel('cbs', name: 'CBS Sports Network'),
        _channel('altitude', name: 'Altitude Sports 2'),
        _channel('movie', name: 'Movies'),
        _channel('unrelated', name: 'World Poker Tour'),
      ]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(3));
      final matches = await matcher.matchDay(games, _Picks());
      expect(matches.values.map((m) => m.single.channel.rawId).toSet(),
          {'masn', 'cbs', 'altitude'});
      expect(matches.values.every((m) => m.single.isConfident), true);
      expect(
          games
              .singleWhere((g) => g.title == 'Bay 101 Shooting Stars')
              .isOnAirOnly,
          true);
      expect(games.singleWhere((g) => g.title == 'The Main Event').isOnAirOnly,
          false);
      final reads = guide.reads;
      await matcher.discoverGuideEvents();
      expect(guide.reads, reads, reason: 'Same cached guide is reused');
    });
  }

  test('poker aliases, channel context and non-competition exclusions', () {
    expect(extendedGuideSport('WPT Choctaw: Part 2', ''), 'poker');
    expect(extendedGuideSport('Poker Go: Heads Up Showdown 2022', ''), 'poker');
    expect(extendedGuideSport('Poker Night', '(Poker) - 2018-03-07'), 'poker');
    expect(
        extendedGuideSport('Bahamas: \$250K NLH Invitational', '',
            channelName: 'US | Triton Poker HD'),
        'poker');
    expect(extendedGuideSport('Bahamas: \$250K NLH Invitational', ''), isNull);
    expect(
        extendedGuideSport(
            'An Interview With: Peter Jetten', 'One of Triton Poker’s players'),
        isNull);
    expect(
        extendedGuideSport('Poker Face', 'A crime drama.',
            channelName: 'Poker TV'),
        isNull);
    expect(
        extendedGuideSport(
            'Tour de France Route Presentation', 'Cycling coverage'),
        isNull);
    expect(extendedGuideSport('Roasted squash', 'Cooking a winter vegetable.'),
        isNull);
  });
  test(
      'a real poker episode may share the channel name; advertisements may not',
      () async {
    guide.rows['episode'] = _programme('episode', 'World Poker Tour',
        description: 'Six players contest the final table at WPT Choctaw.');
    guide.rows['advert'] = _programme('advert', 'PokerGO',
        description:
            'The home of poker tournaments, your non-stop poker channel.');
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare([
      _channel('episode', name: 'World Poker Tour'),
      _channel('advert', name: 'PokerGO')
    ]);
    final games = await matcher.discoverGuideEvents();
    expect(games, hasLength(1));
    expect(games.single.title, 'World Poker Tour');
    matcher.dispose();
  });
  test('existing cricket and cycling replay vocabulary remains available', () {
    for (final title in [
      'Replay: IPL Final',
      'Replay: T20 Final',
      'Replay: Vuelta Stage 5',
      'Replay: MLB Baseball',
      'Replay: FIH Pro League Field Hockey Final'
    ]) {
      expect(classifySportsReplay(_programme('a', title)), isNotNull,
          reason: title);
    }
  });
  for (final background in [false, true]) {
    test(
        '${background ? "worker" : "direct"}: poker and Asian baseball use exact airing channels, excluding known recordings',
        () async {
      final titles = {
        'old': 'Poker Go: 2021 Poker Masters',
        'classic': 'World Poker Tour - Aruba Poker Classic',
        'replay': 'Replay: WSOP Final Table',
        'alias': 'WPT Choctaw: Part 2',
        'npb': 'Nippon Professional Baseball',
        'kbo': 'KBO: LG Twins vs KIA Tigers',
        'cpbl': '中華職棒：統一獅 vs 中信兄弟',
        'local': '韓国プロ野球：KIA vs Samsung',
        'cricket': 'Cricket: Australia vs India',
        'netball': 'Suncorp Super Netball',
        'cycling': 'Cycling: Tour de France',
        'squash': 'PSA World Tour: Squash',
        'handball': 'Handball: Championship Final',
        'field': 'FIH Pro League: Field Hockey',
        'bad': 'No event: Poker Masters',
        'highlights': 'WPT Highlights',
        'stale': 'Poker PPV stop:2026-10-18 23:00:00',
      };
      for (final e in titles.entries) {
        guide.rows[e.key] =
            _programme(e.key, e.value, live: e.key == 'old' || e.key == 'kbo');
      }
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => _now)
          : SportsChannelMatcher(guide, clock: () => _now);
      addTearDown(matcher.dispose);
      await matcher.prepare([
        for (final id in titles.keys) _channel(id),
        _channel('guess', name: 'KBO Baseball Poker')
      ]);
      final games = await matcher.discoverGuideEvents();
      expect(games, hasLength(11));
      expect(games.where((g) => g.title == titles['cricket']), isEmpty);
      expect(games.where((g) => g.title == titles['old']), isEmpty);
      expect(games.where((g) => g.title == titles['replay']), isEmpty);
      expect(games.singleWhere((g) => g.title == titles['classic']).statusText,
          'On air');
      expect(games.where((g) => g.league.id == 'guide.kbo'), hasLength(2));
      expect(
          games.singleWhere((g) => g.league.id == 'guide.npb').league.espnPath,
          'baseball/guide');
      final matches = await matcher.matchDay(games, _Picks());
      for (final g in games) {
        final matched = matches[SportsChannelPicks.eventKey(g)]!;
        expect(matched, hasLength(1));
        expect(matched.single.isConfident, isTrue);
        expect(matched.single.programme!.title, g.title);
        expect(matched.single.channel.rawId, isNot('guess'));
      }
    });
  }

  test(
      'identical simultaneous broadcasts combine; different tables stay separate',
      () async {
    guide.rows['a'] =
        _programme('a', 'World Poker Tour', description: 'Table one');
    guide.rows['b'] =
        _programme('b', 'World Poker Tour', description: 'Table two');
    guide.rows['c'] =
        _programme('c', 'World Poker Tour', description: 'Table one');
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare([_channel('a'), _channel('b'), _channel('c')]);
    final games = await matcher.discoverGuideEvents();
    expect(games, hasLength(2));
    expect(games.map((g) => g.guideProgrammes.length).toList()..sort(), [1, 2]);
    final old = games.first;
    guide.rows.clear();
    guide.notifyListeners();
    expect(await matcher.discoverGuideEvents(), isEmpty);
    // Replacing the catalogue also invalidates discovery and exact matches.
    await matcher.prepare([_channel('new')]);
    expect(await matcher.discoverGuideEvents(), isEmpty);
    expect((await matcher.matchDay([old], _Picks())).values.single, isEmpty);
  });

  test('new sports also classify explicit replays and highlights', () {
    for (final title in [
      'World Poker Tour',
      'PDC Darts Championship',
      'Counter-Strike Final',
      'X Games BMX Final'
    ]) {
      expect(classifySportsReplay(_programme('a', 'Replay: $title')), isNotNull,
          reason: title);
      expect(classifySportsHighlights(_programme('a', '$title Highlights')),
          isNotNull,
          reason: title);
    }
    expect(classifySportsReplay(_programme('a', 'Poker Face Replay')), isNull);
  });

  test(
      '80k catalogue shares one guide index and warm discovery does zero reads',
      () async {
    final channels = [
      for (var i = 0; i < 80000; i++) _channel('$i', epg: '${i % 8000}')
    ];
    for (var i = 0; i < 8000; i++) {
      guide.rows['$i'] = _programme(
          '$i', i < 8 ? 'World Poker Tour' : 'Daily programme',
          description: i < 8 ? 'Table $i' : 'General entertainment');
    }
    final matcher = SportsChannelMatcher(guide, clock: () => _now);
    await matcher.prepare(channels);
    guide.reads = 0;
    final watch = Stopwatch()..start();
    expect(await matcher.discoverGuideEvents(), hasLength(8));
    final cold = watch.elapsedMicroseconds;
    expect(guide.reads, 8000);
    watch.reset();
    for (var i = 0; i < 100; i++) {
      await matcher.discoverGuideEvents();
    }
    expect(guide.reads, 8000);
    // ignore: avoid_print
    print(
        '80k catalogue: discovery ${cold / 1000}ms; 100 cached calls ${watch.elapsedMicroseconds / 1000}ms; zero SQL/network');
  });
}
