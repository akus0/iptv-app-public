import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/sports_language.dart';
import 'package:nox_iptv/utils/extended_sports.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  final rows = <EpgProgram>[];
  int queries = 0;
  @override
  EpgProgram? getCurrentProgram(String id) =>
      rows.where((p) => p.channelId == id).firstOrNull;
  @override
  EpgProgram? getNextProgram(String id) => null;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) async {
    queries++;
    return rows
        .where((p) => terms.any((t) =>
            p.title.toLowerCase().contains(t) ||
            normalizeSportsName(sportsLanguageText(p.title)).contains(t)))
        .toList();
  }

  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      rows.where((p) => ids.contains(p.channelId)).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 29, 12);
  SportsGame game(
          {String league = 'tennis.atp',
          String home = 'Carlos Alcaraz',
          String away = 'Jannik Sinner'}) =>
      SportsGame(
          id: 'match',
          league: sportsLeagueById(league)!,
          start: now,
          state: GameState.live,
          statusText: 'Live',
          home: SportsTeam(
              id: 'h', name: home, shortName: home, abbreviation: ''),
          away: SportsTeam(
              id: 'a', name: away, shortName: away, abbreviation: ''));
  EpgProgram programme(String title,
          {String? description, String id = 'one', bool live = false}) =>
      EpgProgram(
          channelId: id,
          title: title,
          description: description,
          start: now,
          stop: now.add(const Duration(hours: 2)),
          isLive: live);
  late _Guide guide;
  late SportsChannelPicks picks;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
    picks = SportsChannelPicks.load(storage);
  });
  tearDown(() => guide.dispose());

  test('translated matchups retain dedicated-channel discovery context', () {
    expect(
        extendedGuideSport('Leinster contre Munster', '',
            channelName: 'Sky Sports Rugby'),
        'rugby');
    expect(
        extendedGuideSport('Leinster vs Munster', '',
            channelName: 'Sky Sports ラグビー'),
        'rugby');
    expect(
        extendedGuideSport('Evening movie', 'A family comedy',
            channelName: 'Cinema'),
        isNull);
  });

  test('names keep native scripts and Latin/full-width variants normalise', () {
    for (final name in ['張本智和', '장우진', 'Андрей Рублёв', 'กุลวุฒิ วิทิตศานต์']) {
      expect(sportsNormalize(name).trim(), isNotEmpty);
    }
    expect(sportsNormalize('张本智和'), isNot(sportsNormalize('樊振东')));
    expect(sportsNormalize('ＡＴＰ １２'), ' atp 12 ');
    expect(sportsNormalize('Sébastien'), sportsNormalize('Se\u0301bastien'));
  });

  test('native-script opponent names match only the same pair', () {
    for (final (home, away) in [
      ('Андрей Рублёв', 'Даниил Медведев'),
      ('錦織圭', '西岡良仁'),
      ('권순우', '정현')
    ]) {
      final fixture = game(home: home, away: away);
      expect(
          SportsChannelMatcher.tennisProgrammeIsExact(
              fixture, programme('Tennis: $home vs $away')),
          true);
      expect(
          SportsChannelMatcher.tennisProgrammeIsExact(
              fixture, programme('Tennis: $home vs Carlos Alcaraz')),
          false);
    }
  });
  for (final sport in [
    'Tenis',
    'Tênis',
    'Tenisz',
    'Теннис',
    'テニス',
    '网球',
    '網球',
    '테니스',
    'เทนนิส'
  ]) {
    test('$sport retains exact tennis evidence', () {
      expect(
          SportsChannelMatcher.tennisProgrammeIsExact(
              game(), programme('$sport: Carlos Alcaraz vs Jannik Sinner')),
          true);
    });
  }
  for (final label in [
    'Repetición',
    'Rediffusion',
    'Wiederholung',
    'Herhaling',
    'Reapresentação',
    'Replica',
    'Powtórka',
    'Повтор',
    '再放送',
    '重播',
    '재방송',
    'ย้อนหลัง',
    'Resumen',
    'Résumé',
    'Melhores momentos',
    'Zusammenfassung',
    'Samenvatting',
    'Sintesi',
    'Özet',
    'Обзор',
    'ハイライト',
    '精彩集锦',
    '하이라이트',
    'ไฮไลท์'
  ]) {
    test('$label cannot confirm a live tennis fixture', () {
      final p = programme('$label: Tenis Carlos Alcaraz vs Jannik Sinner',
          live: true);
      expect(SportsChannelMatcher.tennisProgrammeIsExact(game(), p), false);
      expect(isLiveSportsProgramme(p), false);
    });
  }
  for (final sport in [
    'Baloncesto',
    'Pallacanestro',
    'Koszykówka',
    'Košarka',
    'Баскетбол',
    '篮球',
    '농구',
    'バスケットボール',
    'Voleibol',
    '野球',
    'Tischtennis',
    'Tenis de mesa',
    '탁구'
  ]) {
    test('$sport cannot confirm tennis despite identical names', () {
      expect(
          SportsChannelMatcher.tennisProgrammeIsExact(
              game(), programme('$sport: Carlos Alcaraz vs Jannik Sinner')),
          false);
    });
  }
  test('translated fixture separators work without translating player names',
      () {
    for (final separator in ['contra', 'contre', 'gegen', 'против', '対']) {
      expect(
          SportsChannelMatcher.tennisProgrammeIsExact(game(),
              programme('Tenis: Carlos Alcaraz $separator Jannik Sinner')),
          true,
          reason: separator);
    }
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(
            game(), programme('テニス: カルロス・アルカラス 対 ヤニック・シナー')),
        false);
  });
  test('translated gender and replay intros override similar names and flags',
      () {
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(game(),
            programme('Tenis femenino: Carlos Alcaraz vs Jannik Sinner')),
        false);
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(
            game(), programme('テニス女子: Carlos Alcaraz vs Jannik Sinner')),
        false);
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(
            game(),
            programme('Tenis: Carlos Alcaraz vs Jannik Sinner',
                description: 'Repetición del partido.')),
        false);
    expect(
        isLiveSportsProgramme(programme('Tenis',
            description:
                'En directo: Carlos Alcaraz vs Jannik Sinner. Ver repetición mañana.')),
        true);
  });
  test('replays and highlights share vocabulary but preserve visible titles',
      () {
    for (final (title, sport) in [
      ('Repetición: Baloncesto Madrid vs Barcelona', 'basketball'),
      ('Rediffusion: Tennis de table Final', 'table-tennis'),
      ('Wiederholung: Fußball Spanien vs Italien', 'soccer'),
      ('再放送 野球 日本 対 韓国', 'baseball'),
      ('재방송 배구 A vs B', 'volleyball')
    ]) {
      final result = classifySportsReplay(programme(title));
      expect(result?.sport, sport, reason: title);
      expect(result?.title, title);
      expect(classifySportsHighlights(programme(title)), isNull);
    }
    for (final (title, sport) in [
      ('Resumen: Voleibol España vs Italia', 'volleyball'),
      ('Résumé: Tennis de table Final', 'table-tennis'),
      ('Zusammenfassung: Fußball Spanien vs Italien', 'soccer'),
      ('ハイライト 野球 日本 対 韓国', 'baseball'),
      ('하이라이트 배구', 'volleyball')
    ]) {
      final result = classifySportsHighlights(programme(title, live: true));
      expect(result?.sport, sport, reason: title);
      expect(result?.title, title);
      expect(classifySportsReplay(programme(title)), isNull);
    }
  });
  test('translated news and documentaries are not event replays or highlights',
      () {
    for (final title in [
      'Resumen: Noticias de Fútbol',
      'Résumé: Actualités Tennis',
      'ハイライト テニス ニュース',
      'Wiederholung: Fußball Dokumentation',
      'Repetición: Película de Baloncesto'
    ]) {
      expect(classifySportsReplay(programme(title)), isNull, reason: title);
      expect(classifySportsHighlights(programme(title)), isNull, reason: title);
    }
  });
  test('words inside names and incidental replay copy are not translations',
      () {
    for (final name in [
      'Tenison',
      'Boxer',
      'Livewire',
      'Finalement',
      'Courtney'
    ]) {
      expect(sportsLanguageText(name), name);
    }
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(
            game(),
            programme('Tenis: Carlos Alcaraz vs Jannik Sinner',
                description:
                    'Live coverage. Replay available after the match.')),
        true);
    expect(
        isLiveSportsProgramme(programme('Tenis',
            description: 'A film about watching live tennis.')),
        false);
  });
  for (final background in [false, true]) {
    test(
        'translated title/synopsis retrieves and ranks the right channel; worker=$background',
        () async {
      final matcher = background
          ? SportsChannelMatcher.background(guide, clock: () => now)
          : SportsChannelMatcher(guide, clock: () => now);
      addTearDown(matcher.dispose);
      guide.rows.addAll([
        programme('Tenis', description: 'Carlos Alcaraz contra Jannik Sinner.'),
        programme('Resumen: Tenis Carlos Alcaraz contra Jannik Sinner',
            id: 'replay'),
        programme('Baloncesto Carlos Alcaraz contra Jannik Sinner',
            id: 'wrong'),
      ]);
      await matcher.prepare([
        for (final row in guide.rows)
          Channel(
              id: row.channelId,
              rawId: row.channelId,
              playlistId: 'test',
              name: 'Event ${row.channelId}',
              group: 'Sports',
              url: 'https://example.invalid/unused',
              epgIdOverride: row.channelId)
      ]);
      final result =
          (await matcher.matchDay([game()], picks))['tennis.atp:match']!;
      expect(
          result.where((m) => m.isConfident).map((m) => m.channel.id), ['one']);
      final calls = guide.queries;
      await matcher.matchDay([game()], picks);
      expect(guide.queries, calls);
    });
  }
  test('translated tournament, court and round retain precise tennis scope',
      () {
    final base = game();
    final fixture = SportsGame(
        id: base.id,
        league: base.league,
        start: now,
        state: base.state,
        statusText: 'Live',
        home: base.home,
        away: base.away,
        event: const SportsEventInfo(
            title: 'Australian Open',
            court: 'Court 2',
            session: 'Quarterfinal'));
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(fixture,
            programme('Tenis: Open de Australia, cuartos de final, pista 2'),
            requireTournament: true),
        true);
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(fixture,
            programme('Tenis: Open de Australia, cuartos de final, pista 3'),
            requireTournament: true),
        false);
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(
            fixture,
            programme(
                'Tenis: Open de Australia Dobles: Carlos Alcaraz vs Jannik Sinner')),
        false);
    expect(
        SportsChannelMatcher.tennisProgrammeIsExact(fixture,
            programme('全豪オープン テニス ダブルス Carlos Alcaraz 対 Jannik Sinner')),
        false);
    expect(sportsLanguageText('桌球'), '桌球',
        reason: 'Region-dependent term must stay ambiguous');
    expect(sportsLanguageText('La reprise du match'), 'La reprise du match');
  });
  test('translated youth labels cannot match senior teams or a different age',
      () async {
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    guide.rows.addAll([
      programme('Fútbol Sub-17: Alemania contra España'),
      programme('Fútbol Sub-19: Alemania contra España', id: 'other')
    ]);
    await matcher.prepare([
      for (final row in guide.rows)
        Channel(
            id: row.channelId,
            rawId: row.channelId,
            playlistId: 'test',
            name: 'Event ${row.channelId}',
            group: 'Sports',
            url: 'https://example.invalid/unused',
            epgIdOverride: row.channelId)
    ]);
    final senior = game(league: 'fifa.world', home: 'Germany', away: 'Spain');
    final youth =
        game(league: 'fifa.world', home: 'Germany U17', away: 'Spain U17');
    final seniorMatches = (await matcher
        .matchDay([senior], picks))[SportsChannelPicks.eventKey(senior)]!;
    expect(seniorMatches.where((m) => m.isConfident), isEmpty);
    final youthMatches = (await matcher
        .matchDay([youth], picks))[SportsChannelPicks.eventKey(youth)]!;
    expect(youthMatches.where((m) => m.isConfident).map((m) => m.channel.id),
        ['one']);
  });
  test('country aliases retain both opponents and sport guards', () async {
    final matcher = SportsChannelMatcher(guide, clock: () => now);
    addTearDown(matcher.dispose);
    final fixture = game(league: 'fifa.world', home: 'Germany', away: 'Spain');
    guide.rows.addAll([
      programme('Fútbol: Alemania contra España'),
      programme('Fútbol: Alemania contra Italia', id: 'other'),
      programme('Baloncesto: Alemania contra España', id: 'wrong')
    ]);
    await matcher.prepare([
      for (final row in guide.rows)
        Channel(
            id: row.channelId,
            rawId: row.channelId,
            playlistId: 'test',
            name: 'Event ${row.channelId}',
            group: 'Sports',
            url: 'https://example.invalid/unused',
            epgIdOverride: row.channelId)
    ]);
    final result = (await matcher
        .matchDay([fixture], picks))[SportsChannelPicks.eventKey(fixture)]!;
    expect(
        result.where((m) => m.isConfident).map((m) => m.channel.id), ['one']);
  });
}
