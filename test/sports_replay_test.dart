import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

final now = DateTime.utc(2026, 10, 22, 10);
EpgProgram programme(String title,
        {String id = 'sport',
        String? description,
        DateTime? start,
        DateTime? stop}) =>
    EpgProgram(
        channelId: id,
        title: title,
        description: description,
        start: start ?? now.subtract(const Duration(minutes: 20)),
        stop: stop ?? now.add(const Duration(minutes: 40)));
Channel channel(String id,
        {String? epg,
        bool favorite = false,
        String? name,
        String group = 'Sports'}) =>
    Channel(
        id: 'p::$id',
        rawId: id,
        playlistId: 'p',
        name: name ?? id,
        group: group,
        url: 'https://example.test/no-stream',
        epgIdOverride: epg,
        isFavorite: favorite);

class _Guide extends EpgService {
  _Guide(super.storage);
  List<EpgProgram> programmes = [];
  int scans = 0;
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime at) {
    scans++;
    return programmes.where((p) => p.isNowPlaying(at));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'structured guide subtitles recover recorded events without guessing live state',
      () {
    final cases = [
      (
        programme('NHRA Drag Racing',
            description: '1993: World Finals\nFrom Pomona, Calif.'),
        channel('a', name: 'NHRA Drag Racing'),
        'racing',
        ReplayEvidence.historical
      ),
      (
        programme('Trans Am Racing Series',
            description:
                '2025: Virginia International Raceway\nTrans Am Racing Series'),
        channel('b', name: 'Racing America'),
        'racing',
        ReplayEvidence.historical
      ),
      (
        programme('Poker After Dark',
            description:
                'S05 E49 — Week 9: Top Guns Cash Game #2\nFeatures six poker players.'),
        channel('c', name: 'Pokergo'),
        'poker',
        ReplayEvidence.labelled
      ),
      (
        programme('World Poker Tour: Season 10',
            description:
                'Bay 101 Shooting Star - Part 2\nThe world’s finest poker players compete around the world.'),
        channel('d'),
        'poker',
        ReplayEvidence.labelled
      ),
      (
        programme('Cyprus II',
            description:
                'S2022 E25 — \$100K NLH Main Event\nBig decisions shape the final table.'),
        channel('e', name: 'Triton Poker'),
        'poker',
        ReplayEvidence.labelled
      ),
      (
        programme('MLP Grand Rapids',
            description:
                '2026: Day 2 - Encore Encore Pickleball coverage from MLP Grand Rapids 2026.'),
        channel('f', name: 'Pickleball TV'),
        'pickleball',
        ReplayEvidence.labelled
      ),
      (
        programme('IFSC Climbing World Series',
            description:
                'S2026 E61 — Lead Semi-Final-Santiago-Chile\nCoverage of the lead semi-final.'),
        channel('g'),
        'action-sports',
        ReplayEvidence.likely
      ),
    ];
    for (final (p, c, sport, evidence) in cases) {
      final result = classifySportsReplay(p, channel: c, allowLikely: true);
      expect(result?.sport, sport, reason: p.title);
      expect(result?.evidence, evidence, reason: p.title);
      final live = EpgProgram(
          channelId: p.channelId,
          title: p.title,
          description: p.description,
          start: p.start,
          stop: p.stop,
          isLive: true);
      expect(classifySportsReplay(live, channel: c, allowLikely: true), isNull);
    }
    for (final p in [
      programme('A Golf Club Somewhere',
          description:
              'S1 E2 Mollymook Andrew Daddo rediscovers the club, showcasing the 18-hole championship layout.'),
      programme('Poker Face',
          description:
              'S01 E4 A detective investigates a murder at a cash game.'),
      programme('NHRA Drag Racing', description: 'NHRA Drag Racing'),
    ]) {
      expect(
          classifySportsReplay(p,
              channel: channel('x', name: p.title), allowLikely: true),
          isNull,
          reason: p.title);
    }
  });

  test('tour reviews and postgame roundups belong in Highlights, not Replays',
      () {
    for (final (p, sport) in [
      (programme('ATP Review', description: 'Beijing\nBeijing.'), 'tennis'),
      (
        programme('Gotta See It',
            description: 'Must-see moments from the world of sports.'),
        'sports'
      ),
      (programme('WTA Tour Review', description: 'Ningbo.'), 'tennis'),
      (
        programme('College Football Final',
            description:
                'After the final whistle, College Football Final breaks down Saturday’s action with postgame highlights and analysis.'),
        'football'
      ),
      (
        programme('The Association: Post Up',
            description:
                'The Association Post Up looks back at the NBA highlights and news of the day.'),
        'basketball'
      ),
    ]) {
      expect(classifySportsHighlights(p)?.sport, sport, reason: p.title);
      expect(classifySportsReplay(p, allowLikely: true), isNull,
          reason: p.title);
    }
    expect(
        classifySportsHighlights(programme('Film Review',
            description: 'A critic looks back at movie highlights.')),
        isNull);
  });
  test('live coverage after a subtitle overrides recorded-episode clues', () {
    final p = programme('World Poker Tour',
        description:
            'S2026 E3 — Main Event\nLive coverage of the final table with poker players.');
    expect(isLiveSportsProgramme(p), true);
    expect(classifySportsReplay(p, allowLikely: true), isNull);
  });
  test(
      'explicit daily roundups and mini highlight shows are distinct from news',
      () {
    expect(
        classifySportsHighlights(programme('NFL Blitz',
                description:
                    'NFL Blitz features action packed highlights and news around the NFL.'))
            ?.sport,
        'football');
    expect(
        classifySportsHighlights(programme('NBA Mini NBA Minis',
                description:
                    "Catch up on today's NBA action with a condensed, highlight driven version of the game."))
            ?.sport,
        'basketball');
    expect(
        classifySportsHighlights(programme('NFL News',
            description:
                'NFL News features highlights and news around the NFL.')),
        isNull);
    expect(
        classifySportsReplay(
            programme('NBA: Boston v New York',
                description: 'Pregame analysis of the upcoming matchup.'),
            allowLikely: true),
        isNull);
  });
  test(
      'channel sport context gives only a likely replay, and corrected guide text wins',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = _Guide(storage)
      ..programmes = [programme('South Africa v Australia')];
    final service = SportsReplayService(guide);
    final channels = [channel('sport', name: 'Sky Sports Cricket')];
    final first = await service.load(channels, revision: 1, at: now);
    expect(first.events.single.sport, 'cricket');
    expect(first.events.single.evidence, ReplayEvidence.likely);
    final second =
        await service.load(channels, revision: 1, at: now, force: true);
    expect(second.events.single.title, first.events.single.title);
    guide.programmes = [
      programme('South Africa v Australia',
          description: 'Highlights of the cricket match.')
    ];
    guide.notifyListeners();
    final corrected = await service.load(channels, revision: 1, at: now);
    expect(corrected.events, isEmpty);
    expect(corrected.highlights.single.sport, 'cricket');
    guide.programmes = [
      EpgProgram(
          channelId: 'sport',
          title: 'South Africa v Australia',
          start: now.subtract(const Duration(minutes: 20)),
          stop: now.add(const Duration(minutes: 40)),
          isLive: true)
    ];
    guide.notifyListeners();
    final live = await service.load(channels, revision: 1, at: now);
    expect(live.events, isEmpty);
    expect(live.highlights, isEmpty);
    guide.dispose();
  });
  test('highlights need explicit coverage, sport context and usable guide', () {
    for (final entry in {
      'NFL Panthers @ Eagles Highlights': 'football',
      'U.S. F1 GP Highlights 2023': 'racing',
      'A-League: Women - Phoenix v Melbourne City Hls': 'soccer',
      'Archery Highlights - World Cup Finals': 'archery',
      'PADEL: Premier Padel Valladolid – Highlights': 'padel',
    }.entries) {
      final p = programme(entry.key);
      expect(classifySportsHighlights(p)?.sport, entry.value);
      expect(classifySportsReplay(p, allowLikely: true), isNull);
    }
    expect(
        classifySportsHighlights(programme('2nd Test Day 4: SA v AUS Hlts'),
                channel: channel('cricket', name: 'Sky Sports Cricket'))
            ?.sport,
        'cricket');
    expect(
        classifySportsHighlights(programme('Full Court',
                description:
                    "Catch up on the night's NBA action with a fast-paced recap featuring game highlights."))
            ?.sport,
        'basketball');
    expect(
        classifySportsHighlights(programme('On the Fly',
                description:
                    "Recapping all the night's exciting action from around the National Hockey League, with highlights, analysis and interviews."))
            ?.sport,
        'hockey');
    for (final p in [
      programme('SportsCenter', description: 'NBA highlights and news.'),
      programme('NFL News Highlights'),
      programme('Upcoming - MLB Highlights'),
      programme('No EPG', description: 'Highlights of NBA basketball.'),
      programme('NBA: Boston v New York (Replay)',
          description: 'Full game replay.'),
      programme('Live: Philippines Open Pool',
          description:
              'Live coverage. This event highlights the country’s love of the game.'),
      programme('This is BBC Scotland',
          description: 'Highlights from BBC Scotland.'),
      programme('The Champions Club',
          description:
              'Live studio programme with extensive UEFA Champions League match highlights and analysis.'),
    ]) {
      expect(classifySportsHighlights(p), isNull, reason: p.title);
    }
  });
  test('highlights share replay cache, group exact listings and expire locally',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final guide = _Guide(storage)
      ..programmes = [
        programme('NBA Highlights', id: 'nba'),
        programme('NFL: Eagles v Panthers (Replay)', id: 'nfl'),
        programme('NBA Highlights',
            id: 'old', stop: now.subtract(const Duration(minutes: 1))),
      ];
    final service = SportsReplayService(guide);
    final channels = [
      channel('a', epg: 'nba'),
      channel('b', epg: 'nba', favorite: true),
      channel('c', epg: 'nfl'),
      channel('d', epg: 'old')
    ];
    final first = await service.load(channels, revision: 1, at: now);
    expect(first.events, hasLength(1));
    expect(first.highlights, hasLength(1));
    expect(first.highlights.single.broadcasts, hasLength(2));
    expect(first.highlights.single.broadcasts.first.channel.isFavorite, true);
    expect(first.highlights.single.eventDate, isNull);
    expect(identical(first, await service.load(channels, revision: 1, at: now)),
        true);
    expect(guide.scans, 1);
    final expired = await service.load(channels,
        revision: 1, at: now.add(const Duration(hours: 1)));
    expect(expired.highlights, isEmpty);
    guide.dispose();
  });
  test(
      'current playlist guide aliases recover events and reject abbreviated highlights',
      () {
    for (final entry in {
      'FIBA 3x3 Women’s World Cup: U23 United States vs Spain': 'basketball',
      'Super Lig 2026/27: Trabzonspor vs Besiktas': 'soccer',
      'Fútbol CONMEBOL Copa Sudamericana: City Torque vs Atlético Mineiro':
          'soccer',
      'EPCR Challenge Cup: Edinburgh v Toulon': 'rugby',
    }.entries) {
      expect(
          classifySportsReplay(programme(entry.key), allowLikely: true)?.sport,
          entry.value);
    }
    for (final p in [
      programme('Cricket: SA v AUS Hlts'),
      programme('A-League: Women - Phoenix v Melbourne City Hls'),
      programme('A-League: Phoenix v Melbourne City',
          description: 'Highlights from Round 1 of the Women’s A-League.'),
    ]) {
      expect(classifySportsReplay(p, allowLikely: true), isNull);
    }
    final condensed = classifySportsReplay(programme(
        'Condensed Game - 2026: Kansas State vs. Cincinnati',
        description:
            'Battle of two unbeaten teams in the Big 12 during Week 4. From Sept. 26, 2026. (Football) - 2026-09-30'));
    expect(condensed?.sport, 'football');
    expect(condensed?.evidence, ReplayEvidence.labelled);
    expect(
        classifySportsReplay(programme('Raptors in 30: Chicago at Toronto'))
            ?.evidence,
        ReplayEvidence.labelled);
  });
  test('generic replay labels need an actual fixture in the synopsis', () {
    expect(
        classifySportsReplay(programme('Replay',
                description:
                    'Boston Celtics v New York Knicks. NBA basketball.'))
            ?.sport,
        'basketball');
    expect(
        classifySportsReplay(
            programme('Replay', description: 'NBA basketball all day.')),
        isNull);
    expect(
        classifySportsReplay(programme('No EPG',
            description: 'Boston Celtics v New York Knicks. NBA basketball.')),
        isNull);
    expect(
        classifySportsReplay(
            programme('Cricket: South Africa v Australia',
                description:
                    '2nd Test Day 4. The latest highlights, reaction and analysis of sport stories.'),
            allowLikely: true),
        isNull);
  });
  test(
      'conditional fixtures and retrospective compilations are not on-air replay events',
      () {
    for (final p in [
      programme('MLB Baseball - Dodgers at Brewers',
          description: 'Game 7. (If necessary)'),
      programme('MotoGP: Casey at the Aussie GP #2',
          description:
              'Explore legendary rider Casey Stoner’s best races from the Australian Grand Prix.'),
    ]) {
      expect(classifySportsReplay(p, allowLikely: true), isNull);
    }
    expect(
        classifySportsReplay(programme('Boxing: A vs B (Replay)',
            description: 'A condensed version of this boxing match.')),
        isNotNull);
  });
  test('positive replay evidence preserves names and divisions without scores',
      () {
    for (final entry in {
      'Replay: ATP Tennis — Alcaraz v Sinner': 'tennis',
      'NCAA Women’s Soccer: FAU v USF (R)': 'soccer',
      'NCAA Women’s Volleyball — Texas v Stanford [RPT]': 'volleyball',
      'NBA: Celtics v Knicks (Repeat)': 'basketball',
      'Formula 1: Australian Grand Prix — Replay': 'racing',
      'NRL: Panthers v Storm (Encore)': 'rugby',
      'NFL: Chiefs v Bills (Replay)': 'football',
    }.entries) {
      final value = classifySportsReplay(programme(entry.key));
      expect(value?.sport, entry.value, reason: entry.key);
      expect(value!.title, isNotEmpty);
    }
    expect(
        classifySportsReplay(programme('Alcaraz v Sinner',
                description: 'Full replay of the ATP tennis final.'))
            ?.sport,
        'tennis');
  });

  test(
      'rejects live, highlight, incidental replay, generic and ambiguous slots',
      () {
    for (final p in [
      programme('LIVE: NBA Celtics v Knicks (Replay)'),
      programme('NBA Highlights (Replay)'),
      programme('Tennis News (Repeat)'),
      programme('NBA: Celtics v Knicks',
          description: 'Live coverage. Replay available tomorrow.'),
      programme('NCIS (Repeat)'),
      programme('Sports Replay'),
      programme('Tennis and Golf Replay'),
      programme('ATP Tennis: Alcaraz v Sinner'),
      programme('NCAA Women’s Volleyball: Stanford v Texas'),
    ]) {
      expect(classifySportsReplay(p), isNull, reason: p.title);
    }
  });

  late _Guide guide;
  late SportsReplayService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    service = SportsReplayService(guide);
  });
  tearDown(() => guide.dispose());

  test('recognises historical guide dates and seasons on ordinary channels',
      () {
    final c = channel('normal', name: 'Sky Sports Tennis');
    for (final p in [
      programme('ATP Final: Cincinnati',
          description: 'Tiafoe meets Fils. (23.08)'),
      programme('SPFL 16/17: Rangers v Celtic'),
      programme('Boxing: 2019: Ruiz vs. Joshua II'),
      programme('College Football - Louisville at Syracuse',
          description: 'Week 7. (Football) - 2026-10-17'),
      programme('High School Football - Vanden vs. Vacaville',
          description: 'From Oct. 16, 2026. (Football)'),
      programme('Cubs Classics - 1997: Phillies at Cubs',
          description: '(Classic sport event, Baseball) - 1997-09-21'),
    ]) {
      final result = classifySportsReplay(p, channel: c);
      expect(result?.evidence, ReplayEvidence.historical, reason: p.title);
    }
  });

  test('classification and displayed dates share conservative evidence', () {
    expect(
        classifySportsReplay(programme('LaLiga 2025-26: A v B'),
                allowLikely: true)
            ?.evidence,
        ReplayEvidence.likely);
    expect(
        classifySportsReplay(
                programme('Tennis: A v B',
                    description:
                        'Their previous meeting was from Oct. 10, 2026.'),
                allowLikely: true)
            ?.evidence,
        ReplayEvidence.likely);
    expect(
        classifySportsReplay(programme('Boxing: Gala, 4 juin 2026'),
                allowLikely: true)
            ?.evidence,
        ReplayEvidence.historical);
    expect(
        classifySportsReplay(
                programme('Tennis: A v B',
                    description: 'Played on 16 October 2026.'),
                allowLikely: true)
            ?.evidence,
        ReplayEvidence.historical);
  });

  test('ended event slots cannot become replays or highlight suggestions',
      () async {
    final names = [
      'ENDED | NHL ON THE FLY | US: VIAPLAY PPV 1',
      'END: NBA Warriors vs Lakers',
      'US: PPV 03: ENDED | Boxing',
      '[ENDED] Tennis Replay 1',
      'Finished - Football PPV',
      'End | Old fixture',
      'NEXT | SAT, 10/10 - ESPN FC | US: ESPN+ PPV 160',
    ];
    final channels = [
      for (var i = 0; i < names.length; i++) channel('$i', name: names[i])
    ];
    guide.programmes = [
      for (var i = 0; i < names.length; i++)
        programme('NBA Replay: Warriors vs Lakers', id: '$i')
    ];
    expect(
        (await service.load(channels, revision: 1, at: now)).events, isEmpty);
    guide.programmes = [
      for (var i = 0; i < names.length; i++)
        programme('NHL Highlights: Bruins vs Rangers', id: '$i')
    ];
    expect((await service.load(channels, revision: 2, at: now)).highlights,
        isEmpty);
    expect(
        classifySportsReplay(
            programme('ENDED | NBA Replay: Warriors vs Lakers')),
        isNull);
    expect(
        classifySportsReplay(
            programme('Soccer Replay: Preston North End vs Blackburn')),
        isNotNull);
  });

  test(
      'event slots require replay evidence; old dates alone cannot activate PPV',
      () async {
    final channels = [
      channel('old', name: 'US: Boxing PPV 1'),
      channel('possible', name: 'Event 04: Tyson vs Lewis'),
      channel('named', name: 'Tyson vs Lewis - Oct 10'),
      channel('real', name: 'Boxing PPV 2'),
      channel('linear', name: 'ESPN'),
    ];
    guide.programmes = [
      for (final id in ['old', 'named', 'linear'])
        programme('Boxing: Tyson vs Lewis - 2002', id: id),
      programme('Boxing: Tyson vs Lewis', id: 'possible'),
      programme('Boxing Replay: Tyson vs Lewis', id: 'real'),
    ];
    final result = await service.load(channels, revision: 1, at: now);
    expect(
        result.events
            .expand((e) => e.broadcasts)
            .map((b) => b.channel.rawId)
            .toSet(),
        {'linear', 'real'});
  });

  test('missing live marker is only likely, live metadata and Unicode win', () {
    final c = channel('normal', name: 'ESPN');
    final match = programme('NBA Basketball - Warriors at Lakers',
        description: '(Basketball) - 2026-10-21');
    expect(classifySportsReplay(match, channel: c)?.evidence,
        ReplayEvidence.likely);
    for (final p in [
      programme('NBA Basketball - Warriors at Lakers ᴸᶦᵛᵉ',
          description: '(Basketball) - 2026-10-10'),
      EpgProgram(
          channelId: 'normal',
          title: 'NBA Warriors at Lakers',
          start: now,
          stop: now.add(const Duration(hours: 2)),
          isLive: true),
      programme('College Gameday Podcast',
          description: '(Football) - 2024-09-12'),
      programme('Upcoming - MLB Network Strike Zone'),
      programme('NFL Football'),
      programme('NBA News (Replay)'),
      programme('NHL Now',
          description:
              'Hosts discuss the news ahead of game action. (Hockey, Sports talk) - 2016-10-12'),
      programme('SUPERCARS GOLD COAST GREATNESS : #4',
          description: 'A countdown of moments ahead of the Supercars Finals.'),
    ]) {
      expect(classifySportsReplay(p, channel: c), isNull, reason: p.title);
    }
    // A reference to an earlier meeting does not date today's match.
    expect(
        classifySportsReplay(
                programme('NBA Warriors at Lakers',
                    description: 'The Lakers won on 2020-10-01.'),
                channel: c)
            ?.evidence,
        ReplayEvidence.likely);
    expect(
        classifySportsReplay(
                programme('Boxing: Ruiz vs Joshua',
                    description: '(Boxing) - 2026-02-31'),
                channel: c)
            ?.evidence,
        ReplayEvidence.likely);
    expect(
        classifySportsReplay(
                programme('LaLiga 2025/26: Real Madrid vs Barcelona'),
                channel: c)
            ?.evidence,
        ReplayEvidence.likely);
  });

  test('unflagged simulcast of a current live fixture is not a likely replay',
      () async {
    guide.programmes = [
      programme(
          'NBA Basketball - Golden State Warriors at Los Angeles Lakers ᴸᶦᵛᵉ',
          id: 'live'),
      programme('NBA Basketball - Golden State Warriors at Los Angeles Lakers',
          id: 'other'),
      programme('College Football - Ohio State at Indiana', id: 'college'),
    ];
    final result = await service.load(
        [channel('live'), channel('other'), channel('college')],
        revision: 1, at: now);
    expect(result.events.single.title, contains('Ohio State'));
    expect(result.events.single.evidence, ReplayEvidence.likely);
  });

  const guidePath = String.fromEnvironment('REPLAY_GUIDE_FILE');
  test('offline current-guide audit across the whole playlist', () async {
    await HttpOverrides.runZoned(() async {
      final rows = jsonDecode(await File(guidePath).readAsString()) as List;
      guide.programmes = [
        for (final r in rows)
          EpgProgram(
              channelId: r['channelId'] as String,
              title: r['title'][0]['text'] as String,
              description:
                  r['desc'] == null ? null : r['desc'][0]['text'] as String,
              start: DateTime.parse(r['start'] as String),
              stop: DateTime.parse(r['stop'] as String),
              isLive: r['live'] != null)
      ];
      final channels = <Channel>[];
      for (final r in rows) {
        for (final c in r['channels'] as List) {
          channels.add(channel('audit${channels.length}',
              epg: r['channelId'] as String,
              name: c['name'] as String,
              group: c['group'] as String));
        }
      }
      final snapshot = await service.load(channels,
          revision: 1, at: DateTime.utc(2026, 10, 22, 2, 10, 30));
      expect(snapshot.events.length, greaterThan(10));
      expect(
          snapshot.events.any((e) => e.title.contains('Louisville')), isTrue);
      expect(
          snapshot.events.any((e) => e.title.contains('Cincinnati')), isTrue);
      expect(snapshot.events.any((e) => e.title.contains('Rangers v Celtic')),
          isTrue);
      expect(snapshot.events.any((e) => e.title == 'NHL Now'), isFalse);
      expect(
          snapshot.events.any((e) => e.title.contains('Canadian Finals Rodeo')),
          isTrue);
      expect(snapshot.events.where((e) => e.title.contains('Texas Tech')),
          hasLength(1));
      expect(snapshot.events.where((e) => e.eventDate != null).length,
          greaterThan(10));
      expect(
          snapshot.events
              .firstWhere((e) => e.title.contains('Cincinnati'))
              .eventDate
              ?.label,
          '23 Aug · year not listed');
      expect(
          snapshot.events
              .firstWhere((e) => e.title.contains('Texas Tech'))
              .eventDate
              ?.label,
          '14 Feb 2026');
      expect(
          snapshot.events
              .expand((e) => e.broadcasts)
              .any((b) => isLiveSportsProgramme(b.programme)),
          isFalse);
      // ignore: avoid_print
      print('Guide audit: ${snapshot.events.length} events; '
          '${snapshot.events.where((e) => e.evidence == ReplayEvidence.likely).length} likely.');
      for (final e in snapshot.events) {
        // ignore: avoid_print
        print(
            '${e.evidence.name}: ${e.title} | ${e.broadcasts.first.channel.name} | ${e.reason} | date: ${e.eventDate?.label}');
      }
    }, createHttpClient: (_) => throw StateError('Network forbidden'));
  }, skip: guidePath.isEmpty ? 'Optional sanitized offline guide' : false);

  test('dedicated replay services supply omitted labels without guessing teams',
      () async {
    final nba = channel('nba', name: 'Replay 1', group: '🏀 NBA League Pass');
    final nfl = channel('nfl', name: 'NFL Replay 4');
    final soccer =
        channel('pl', name: 'PL REPLAY 1 HD', group: 'UK| SOCCER REPLAY ᴿᴬᵂ');
    guide.programmes = [
      programme('Boston Celtics at New York Knicks', id: 'nba'),
      programme('Chiefs vs Bills', id: 'nfl'),
      programme('Arsenal v Chelsea', id: 'pl'),
    ];
    final result = await service.load(
        [nba, nfl, soccer, channel('ordinary', epg: 'nba', name: 'ESPN')],
        revision: 1, at: now);
    expect(result.events, hasLength(3));
    expect(result.events.map((e) => e.sport),
        unorderedEquals(['basketball', 'football', 'soccer']));
    expect(result.events.expand((e) => e.broadcasts).map((b) => b.channel.id),
        unorderedEquals([nba.id, nfl.id, soccer.id]));
    expect(result.unscheduled, isEmpty);
    expect(
        classifySportsReplay(programme('Alcaraz v Sinner (Replay)'),
                channel: channel('tennis', name: 'Tennis Channel'))
            ?.sport,
        'tennis');
    expect(
        classifySportsReplay(programme('LIVE: Chiefs vs Bills'), channel: nfl),
        isNull);
    expect(
        classifySportsReplay(programme('Tennis: Alcaraz vs Sinner'),
            channel: nfl),
        isNull);
  });

  test(
      'missing and generic guides form a directory, never invented on-air events',
      () async {
    final missing = channel('missing', name: 'NFL Replay 1');
    final generic =
        channel('generic', name: 'Replay 2', group: 'NBA League Pass');
    final unavailable = channel('unavailable', name: 'NHL Replay 3');
    final live = channel('live', name: 'NFL Replay 4');
    final highlights = channel('highlights', name: 'NFL Replay 5');
    guide.programmes = [
      programme('Replay 2', id: 'generic'),
      programme('Off air — NHL Replay', id: 'unavailable'),
      programme('LIVE: NFL Chiefs v Bills', id: 'live'),
      programme('NFL Highlights', id: 'highlights'),
    ];
    final result = await service.load(
        [missing, generic, unavailable, live, highlights],
        revision: 1, at: now);
    expect(result.events, isEmpty);
    expect(result.unscheduled.map((e) => e.channel.id),
        unorderedEquals([missing.id, generic.id]));
    expect(isUnscheduledReplayChannel(missing, null), isTrue);
    expect(isUnscheduledReplayChannel(missing, programme('Off air')), isFalse);
    expect(isUnscheduledReplayChannel(missing, programme('LIVE: NFL Football')),
        isFalse);
    guide.programmes.add(programme('Chiefs at Bills', id: 'missing'));
    guide.notifyListeners();
    final updated = await service.load(
        [missing, generic, unavailable, live, highlights],
        revision: 1, at: now);
    expect(updated.events.single.title, 'Chiefs at Bills');
    expect(updated.unscheduled.single.channel.id, generic.id);
  });

  test(
      'rejects info, highlights, entertainment, stale PPV and mixed sport labels',
      () {
    for (final c in [
      channel('info', name: 'NFL Replay Channel Guide'),
      channel('info2', name: 'PL REPLAY INFO HD', group: 'SOCCER REPLAY'),
      channel('highlights', name: 'NHL Replay Highlights'),
      channel('dummy', name: '### NBA REPLAY ###'),
      channel('movie', name: 'Starz Encore'),
      channel('sky', name: 'Sky Replay', group: 'UK Entertainment'),
      channel('vod',
          name:
              'End | Jones vs. Sanchez: Full Event Replay | Matchroom Boxing | 2026-10-03'),
      channel('old',
          name: 'WHL TV 07: SPO @ VIC | GAME REPLAYS | Wed Apr 16th 10:05PM'),
      channel('mixed', name: 'Replay 1', group: 'Tennis and Golf'),
      channel('xt_vod_1', name: 'NFL Replay 1'),
    ]) {
      expect(replayChannelSport(c), isNull, reason: c.name);
    }
  });

  const labelPath = String.fromEnvironment('PLAYLIST_LABELS_FILE');
  test('offline playlist audit recognises dedicated replay categories',
      () async {
    await HttpOverrides.runZoned(() async {
      final rows = jsonDecode(await File(labelPath).readAsString()) as List;
      final channels = [
        for (final (i, row) in rows.indexed)
          channel('local$i',
              name: row['name'] as String, group: row['group'] as String)
      ];
      final result = await service.load(channels, revision: 1, at: now);
      expect(result.events, isEmpty);
      expect(result.unscheduled.length, greaterThan(100));
      expect(result.unscheduled.map((c) => c.sport).toSet(),
          containsAll(['football', 'basketball', 'hockey', 'soccer']));
      final counts = <String, int>{};
      for (final entry in result.unscheduled) {
        counts.update(entry.sport, (n) => n + 1, ifAbsent: () => 1);
      }
      // ignore: avoid_print
      print('Offline replay channel labels: $counts. Availability unverified.');
    }, createHttpClient: (_) => throw StateError('No network allowed'));
  }, skip: labelPath.isEmpty ? 'Optional sanitized playlist labels' : false);

  test(
      'maps only current guide IDs, respects overrides and visible channel set',
      () async {
    guide.programmes = [
      programme('NBA: Celtics v Knicks (Replay)', id: 'nba'),
      programme('Tennis: Alcaraz v Sinner (Replay)', id: 'past', stop: now),
      programme('Tennis: Alcaraz v Sinner (Replay)',
          id: 'future', start: now.add(const Duration(minutes: 1))),
      programme('Volleyball: Texas v Stanford (Replay)', id: 'hidden'),
    ];
    final chosen = channel('stream-123', epg: ' NBA ');
    final result = await service.load([
      chosen,
      channel('past'),
      channel('future'),
      channel('xt_vod_42', epg: 'nba')
    ], revision: 1, at: now);
    expect(result.events, hasLength(1));
    expect(result.events.single.broadcasts.single.channel, same(chosen));
    expect(result.channelsWithGuide, 1);
  });

  test('groups exact simulcasts but separates sport, division and event dates',
      () async {
    guide.programmes = [
      programme('NBA: Celtics v Knicks (Replay)',
          id: 'nba', description: '21 October'),
      programme('NBA: Celtics v Knicks (Replay)',
          id: 'nba2', description: '21 October'),
      programme('NBA: Celtics v Knicks (Replay)',
          id: 'classic', description: '21 October 1998'),
      programme('NCAA Women’s Soccer: FAU v USF (Replay)', id: 'women'),
      programme('NCAA Men’s Soccer: FAU v USF (Replay)', id: 'men'),
      programme('NCAA Volleyball: FAU v USF (Replay)', id: 'volleyball'),
    ];
    final result = await service.load([
      for (final id in ['nba', 'nba2', 'classic', 'women', 'men', 'volleyball'])
        channel(id, favorite: id == 'nba2'),
    ], revision: 1, at: now);
    expect(result.events, hasLength(5));
    final simulcast =
        result.events.singleWhere((e) => e.broadcasts.length == 2);
    expect(simulcast.broadcasts.first.channel.rawId, 'nba2');
    expect(simulcast.broadcasts.map((b) => b.programme.description).toSet(),
        {'21 October'});
  });

  test(
      'cache invalidates on guide/mapping changes and exactly at programme end',
      () async {
    guide.programmes = [
      programme('NBA Celtics v Knicks (Replay)',
          stop: now.add(const Duration(seconds: 10)))
    ];
    final channels = [channel('sport')];
    final first = await service.load(channels, revision: 1, at: now);
    expect(
        await service.load(channels,
            revision: 1, at: now.add(const Duration(seconds: 2))),
        same(first));
    expect(guide.scans, 1);
    expect(
        (await service.load(channels,
                revision: 1, at: now.add(const Duration(seconds: 10))))
            .events,
        isEmpty);
    guide.programmes = [programme('Volleyball Texas v Stanford (Replay)')];
    guide.notifyListeners();
    expect(
        (await service.load(channels, revision: 1, at: now))
            .events
            .single
            .sport,
        'volleyball');
    expect((await service.load([], revision: 2, at: now)).events, isEmpty);
  });

  test('full guide rows invalidate replay cache without a broad notification',
      () async {
    guide.programmes = [programme('NBA Celtics v Knicks (Replay)')];
    final channels = [channel('sport')];
    final first = await service.load(channels, revision: 1, at: now);
    final revision = guide.changeRevision;
    guide.programmes = [programme('Volleyball Texas v Stanford (Replay)')];
    guide.guideRowsLoaded.value++;
    expect(guide.changeRevision, revision);
    final updated = await service.load(channels, revision: 1, at: now);
    expect(updated, isNot(same(first)));
    expect(updated.events.single.sport, 'volleyball');
    expect(await service.load(channels, revision: 1, at: now), same(updated));
    expect(guide.scans, 2);
  });

  test('shares dates only for identical detailed narratives with no conflict',
      () async {
    const narrative =
        'The Celtics take on the Knicks at Madison Square Garden in the opening match of their season.';
    const title = 'NBA: Boston Celtics v New York Knicks (Replay)';
    guide.programmes = [
      programme(title,
          id: 'dated', description: '$narrative (Basketball) - 2026-10-17'),
      programme(title,
          id: 'unknown', description: '$narrative (Sports, Basketball) - 2019'),
      programme(title,
          id: 'different',
          description: 'A different match featuring these same teams.'),
    ];
    final channels = [
      for (final id in ['dated', 'unknown', 'different', 'conflict'])
        channel(id)
    ];
    final result = await service.load(channels, revision: 1, at: now);
    expect(result.events, hasLength(2));
    expect(result.events.where((e) => e.eventDate != null).single.broadcasts,
        hasLength(2));
    expect(
        result.events
            .firstWhere(
                (e) => e.broadcasts.any((b) => b.channel.rawId == 'unknown'))
            .eventDate
            ?.label,
        '17 Oct 2026');
    expect(
        result.events
            .firstWhere((e) => e.broadcasts.first.channel.rawId == 'different')
            .eventDate,
        isNull);
    guide.programmes.add(programme(title,
        id: 'conflict', description: '$narrative (Basketball) - 2026-10-18'));
    guide.notifyListeners();
    final conflict = await service.load(channels, revision: 1, at: now);
    expect(conflict.events, hasLength(4));
    expect(
        conflict.events
            .firstWhere(
                (e) => e.broadcasts.any((b) => b.channel.rawId == 'unknown'))
            .eventDate,
        isNull);
  });

  test(
      'genre-only footers share dates, explicit short dates merge exact fixtures',
      () async {
    const narrative =
        'The Minnesota Timberwolves visit the Miami Heat at Kaseya Center in Miami, Florida.';
    guide.programmes = [
      programme('NBA: Minnesota at Miami',
          id: 'a', description: '$narrative (Basketball) - 2026-10-21'),
      programme('NBA: Minnesota at Miami',
          id: 'b', description: '$narrative (Basketball, Sports)'),
      programme('Raptors in 30 - 2026: Chicago at Toronto',
          id: 'c',
          description: 'From Oct. 21, 2026. (Basketball) - 2026-10-22'),
      programme('Raptors in 30 : 2026: Chicago at Toronto',
          id: 'd', description: 'From Oct. 21, 2026.'),
      programme('NBA: Minnesota at Miami',
          id: 'e', description: '$narrative (First leg)'),
    ];
    final result = await service.load([
      for (final id in ['a', 'b', 'c', 'd', 'e']) channel(id)
    ], revision: 1, at: now);
    expect(result.events, hasLength(3));
    expect(result.events.where((e) => e.broadcasts.length == 2), hasLength(2));
    expect(
        result.events
            .firstWhere((e) => e.broadcasts.first.channel.rawId == 'e')
            .eventDate,
        isNull);
  });

  test('sport hints require matching detailed guide copies and agreement',
      () async {
    const title = 'Condensed Game: 2026: Kansas State vs. Cincinnati';
    const narrative =
        'Battle of two unbeaten teams in the Big 12 during Week 4 between Kansas State and Cincinnati. From Sept. 26, 2026.';
    final missing = programme(title, id: 'missing', description: narrative);
    expect(classifySportsReplay(missing, allowLikely: true), isNull);
    guide.programmes = [
      programme(title, id: 'known', description: '$narrative (Football)'),
      missing,
      programme(title,
          id: 'different',
          description:
              'A different game, without any sport or identity evidence.'),
      EpgProgram(
          channelId: 'live',
          title: title,
          description: narrative,
          start: now.subtract(const Duration(minutes: 10)),
          stop: now.add(const Duration(minutes: 30)),
          isLive: true),
    ];
    final channels = [
      for (final id in ['known', 'missing', 'different', 'live', 'conflict'])
        channel(id)
    ];
    final result = await service.load(channels, revision: 1, at: now);
    expect(result.events, hasLength(1));
    expect(result.events.single.broadcasts, hasLength(2));
    expect(result.events.single.eventDate?.label, '26 Sep 2026');
    guide.programmes.add(programme(title,
        id: 'conflict', description: '$narrative (Basketball)'));
    guide.notifyListeners();
    final conflict = await service.load(channels, revision: 1, at: now);
    expect(
        conflict.events
            .expand((e) => e.broadcasts)
            .any((b) => b.channel.rawId == 'missing'),
        false);
  });

  test('large simulcast guide reuses analysis without losing broadcasts',
      () async {
    final channels = [for (var i = 0; i < 9000; i++) channel('sport$i')];
    guide.programmes = [
      for (var i = 0; i < channels.length; i++)
        programme('NBA Celtics v Knicks (Replay)',
            id: 'sport$i',
            description: 'Full match replay from 20 October 2026. Basketball.')
    ];
    var beats = 0, previous = 0, longest = 0;
    final watch = Stopwatch()..start();
    final pulse = Timer.periodic(const Duration(milliseconds: 1), (_) {
      beats++;
      final elapsed = watch.elapsedMicroseconds;
      final gap = elapsed - previous;
      if (gap > longest) longest = gap;
      previous = elapsed;
    });
    try {
      final first = await service.load(channels, revision: 1, at: now);
      expect(first.events.single.broadcasts, hasLength(channels.length));
      expect(beats, greaterThan(0));
      // A forced refresh must preserve every separate channel and its date.
      final refreshed =
          await service.load(channels, revision: 1, at: now, force: true);
      expect(refreshed.events.single.broadcasts, hasLength(channels.length));
      expect(refreshed.events.single.eventDate?.day,
          first.events.single.eventDate?.day);
      expect(guide.scans, 2);
      // Diagnostic only: host timings are not TV performance assertions.
      // ignore: avoid_print
      print('Large replay guide: ${watch.elapsedMilliseconds}ms; '
          '$beats yields; max gap $longest us');
    } finally {
      pulse.cancel();
      watch.stop();
    }
  });

  test('cache eviction and corrections preserve per-channel evidence',
      () async {
    final channels = [for (var i = 0; i < 5000; i++) channel('sport$i')];
    guide.programmes = [
      for (var i = 0; i < channels.length; i++)
        programme('NBA Celtics v Knicks (Replay)',
            id: 'sport$i',
            stop: now.add(Duration(minutes: 40, seconds: i)),
            description: 'Full basketball match replay from 20 October 2026.')
    ];
    final first = await service.load(channels, revision: 1, at: now);
    expect(first.events.single.broadcasts, hasLength(5000));
    final second =
        await service.load(channels, revision: 1, at: now, force: true);
    expect(second.events.single.broadcasts, hasLength(5000));
    guide.programmes[0] = EpgProgram(
        channelId: 'sport0',
        title: 'NBA Celtics v Knicks (Replay)',
        description: guide.programmes[0].description,
        start: guide.programmes[0].start,
        stop: guide.programmes[0].stop,
        isLive: true);
    guide.programmes[1] = programme('Movie night', id: 'sport1');
    final corrected =
        await service.load(channels, revision: 1, at: now, force: true);
    expect(corrected.events.single.broadcasts, hasLength(4998));
    expect(
        corrected.events.single.broadcasts.any(
            (b) => b.channel.rawId == 'sport0' || b.channel.rawId == 'sport1'),
        isFalse);
  });

  test('80k channels yield while indexing, reuse guide scan on warm view',
      () async {
    final channels = [
      for (var i = 0; i < 80000; i++)
        channel('channel$i', epg: i < 4 ? 'sport' : null)
    ];
    guide.programmes = [programme('NBA Celtics v Knicks (Replay)')];
    var beats = 0, previous = 0;
    final gaps = <int>[];
    final watch = Stopwatch()..start();
    final pulse = Timer.periodic(const Duration(milliseconds: 1), (_) {
      beats++;
      final elapsed = watch.elapsedMicroseconds;
      gaps.add(elapsed - previous);
      previous = elapsed;
    });
    final result = await service.load(channels, revision: 1, at: now);
    watch.stop();
    pulse.cancel();
    expect(result.events.single.broadcasts, hasLength(4));
    expect(beats, greaterThan(0));
    final cached = Stopwatch()..start();
    expect(await service.load(channels, revision: 1, at: now), same(result));
    cached.stop();
    expect(guide.scans, 1);
    // Development machine observation, not a device performance assertion.
    // ignore: avoid_print
    print(
        'Replay discovery: 80k channels ${watch.elapsedMilliseconds}ms; $beats yields; max gap ${(gaps..sort()).last}µs; warm ${cached.elapsedMicroseconds}µs');
  });
}
