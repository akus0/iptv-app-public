/// Provider-neutral sports models shared by schedule, score and guide adapters. Store
/// times in UTC and convert only for display.
library;

import 'epg_program.dart';

part 'motorsport_leagues.dart';

/// Team sports are two sides with a score. The others are "event sports":
/// ESPN lists athletes instead of teams, so they get their own parsing and
/// cards (see [SportsEventInfo]).
enum SportsKind {
  /// A current guide programme; no invented teams, score or live timing.
  broadcast,
  team,

  /// One multi-day tournament per event, a leaderboard of 70-150 players.
  golf,

  /// One event per race weekend; each session (qualifying, sprint, race)
  /// becomes its own card.
  racing,

  /// One event per fight card; the main event's two fighters play the part
  /// of the two teams.
  fight,

  /// One event per tournament; each main-draw singles match is its own card,
  /// the two players playing the part of the two teams (score = sets won).
  tennis,
}

class SportsLeague {
  const SportsLeague({
    required this.id,
    required this.espnPath,
    required this.name,
    required this.shortName,
    required this.logoUrl,
    this.soccer = false,
    this.region,
    this.hasStandings = true,
    this.kind = SportsKind.team,
    this.seriesPhrases = const [],
    this.source = 'ESPN',
  });

  final SportsKind kind;
  final String source;

  /// Event sports: how channels and guide titles name the series ("formula
  /// 1", "nascar", "pga tour"), lower-case — the channel matcher's fallback
  /// when no channel names the event itself.
  final List<String> seriesPhrases;

  /// Golf and racing — no two sides, a leaderboard instead.
  bool get isField =>
      kind == SportsKind.golf ||
      kind == SportsKind.racing ||
      kind == SportsKind.broadcast;

  /// Stable id stored in prefs (`nhl`, `eng.1`, ...).
  final String id;

  /// `{sport}/{league}` segment of ESPN's site API.
  final String espnPath;
  final String name;
  final String shortName;
  final String logoUrl;

  /// Soccer reads "Home vs Away" and shows a minute clock; North American
  /// leagues read "Away at Home".
  final bool soccer;

  /// Bank leagues only: the League manager's group heading (English, shown
  /// through `tr`). Null for the base leagues.
  final String? region;

  /// False for cups/tournaments ESPN has no table for — kept out of
  /// Standings instead of showing "could not be loaded".
  final bool hasStandings;

  bool get isBase => region == null;
}

/// Known guide competitions stay visible even when no broadcast is airing.
/// They read the existing EPG snapshot and never query a scoreboard.
const List<SportsLeague> kGuideSportsLeagues = [
  SportsLeague(
      id: 'guide.racing',
      espnPath: 'racing/guide',
      name: 'Motorsport · live TV coverage',
      shortName: 'Motorsport',
      logoUrl: '',
      kind: SportsKind.broadcast,
      region: 'Motorsport',
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.mma',
      espnPath: 'mma/guide',
      name: 'MMA events',
      shortName: 'MMA events',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.one',
      espnPath: 'mma/guide',
      name: 'ONE Championship',
      shortName: 'ONE Championship',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.muay-thai',
      espnPath: 'mma/guide',
      name: 'Muay Thai & kickboxing',
      shortName: 'Muay Thai & kickboxing',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.boxing',
      espnPath: 'boxing/guide',
      name: 'Boxing',
      shortName: 'Boxing',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.poker',
      espnPath: 'poker/guide',
      name: 'Poker',
      shortName: 'Poker',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.npb',
      espnPath: 'baseball/guide',
      name: 'NPB · Japanese baseball',
      shortName: 'NPB',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.kbo',
      espnPath: 'baseball/guide',
      name: 'KBO · Korean baseball',
      shortName: 'KBO',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
  SportsLeague(
      id: 'guide.cpbl',
      espnPath: 'baseball/guide',
      name: 'CPBL · Taiwanese baseball',
      shortName: 'CPBL',
      logoUrl: '',
      kind: SportsKind.broadcast,
      hasStandings: false,
      source: 'Channel guide'),
];

const kLiveRugbyLeague = SportsLeague(
    id: 'rugby.live',
    espnPath: 'rugby/all',
    name: 'Rugby · live matches',
    shortName: 'Live rugby',
    logoUrl: '',
    hasStandings: false);
const kAutomaticSportsLeagues = [...kGuideSportsLeagues, kLiveRugbyLeague];

bool matchesSportsLeague(SportsLeague league, String? filter) =>
    filter == null ||
    league.id == filter ||
    (filter == 'rugby.live' && league.espnPath.startsWith('rugby/'));

/// The base leagues — always available in the League manager, in the
/// default order. Extra leagues come from [kSportsLeagueBank].
const List<SportsLeague> kSportsLeagues = [
  SportsLeague(
      id: 'nhl',
      espnPath: 'hockey/nhl',
      name: 'NHL',
      shortName: 'NHL',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/nhl.png'),
  SportsLeague(
      id: 'nfl',
      espnPath: 'football/nfl',
      name: 'NFL',
      shortName: 'NFL',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/nfl.png'),
  SportsLeague(
      id: 'nba',
      espnPath: 'basketball/nba',
      name: 'NBA',
      shortName: 'NBA',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/nba.png'),
  SportsLeague(
      id: 'mlb',
      espnPath: 'baseball/mlb',
      name: 'MLB',
      shortName: 'MLB',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/mlb.png'),
  SportsLeague(
      id: 'college-football',
      espnPath: 'football/college-football',
      name: 'College Football',
      shortName: 'NCAAF',
      logoUrl:
          'https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-football-college.png'),
  SportsLeague(
      id: 'wnba',
      espnPath: 'basketball/wnba',
      name: 'WNBA',
      shortName: 'WNBA',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/wnba.png'),
  SportsLeague(
      id: 'usa.1',
      espnPath: 'soccer/usa.1',
      name: 'MLS',
      shortName: 'MLS',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/19.png',
      soccer: true),
  SportsLeague(
      id: 'eng.1',
      espnPath: 'soccer/eng.1',
      name: 'Premier League',
      shortName: 'EPL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/23.png',
      soccer: true),
  SportsLeague(
      id: 'uefa.champions',
      espnPath: 'soccer/uefa.champions',
      name: 'Champions League',
      shortName: 'UCL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2.png',
      soccer: true),
  SportsLeague(
      id: 'esp.1',
      espnPath: 'soccer/esp.1',
      name: 'LaLiga',
      shortName: 'LaLiga',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/15.png',
      soccer: true),
  SportsLeague(
      id: 'ger.1',
      espnPath: 'soccer/ger.1',
      name: 'Bundesliga',
      shortName: 'BUN',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/10.png',
      soccer: true),
  SportsLeague(
      id: 'ita.1',
      espnPath: 'soccer/ita.1',
      name: 'Serie A',
      shortName: 'SA',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/12.png',
      soccer: true),
  SportsLeague(
      id: 'fra.1',
      espnPath: 'soccer/fra.1',
      name: 'Ligue 1',
      shortName: 'L1',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/9.png',
      soccer: true),
  ...kAutomaticSportsLeagues,
];

/// Full coverage by default, including new competitions added to the catalogue.
final List<String> kDefaultSportsLeagueIds = List.unmodifiable({
  for (final league in [...kSportsLeagues, ...kSportsLeagueBank]) league.id,
});

/// Additional competitions included in the default catalogue. Each entry declares its
/// data source, event kind and standings support.
const List<SportsLeague> kSportsLeagueBank = [
  ...kMotorsportCalendarLeagues,
  ...kAdditionalEnduranceLeagues,
  SportsLeague(
      id: 'rugby.180659',
      espnPath: 'rugby/180659',
      name: "Six Nations",
      shortName: "Six Nations",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.244293',
      espnPath: 'rugby/244293',
      name: "The Rugby Championship",
      shortName: "Rugby Championship",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.271937',
      espnPath: 'rugby/271937',
      name: "European Rugby Champions Cup",
      shortName: "Champions Cup",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.272073',
      espnPath: 'rugby/272073',
      name: "European Rugby Challenge Cup",
      shortName: "Challenge Cup",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: false),
  SportsLeague(
      id: 'rugby.267979',
      espnPath: 'rugby/267979',
      name: "Gallagher Prem",
      shortName: "Prem Rugby",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.270559',
      espnPath: 'rugby/270559',
      name: "French Top 14",
      shortName: "Top 14",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: false),
  SportsLeague(
      id: 'rugby.17567',
      espnPath: 'rugby/17567',
      name: "Nations Championship",
      shortName: "Nations Championship",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.242041',
      espnPath: 'rugby/242041',
      name: "Super Rugby Pacific",
      shortName: "Super Rugby",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.270563',
      espnPath: 'rugby/270563',
      name: "New Zealand NPC",
      shortName: "NPC",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.289237',
      espnPath: 'rugby/289237',
      name: "Women's Rugby World Cup",
      shortName: "Women\u2019s RWC",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.289262',
      espnPath: 'rugby/289262',
      name: "Major League Rugby",
      shortName: "MLR",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: false),
  SportsLeague(
      id: 'rugby.289234',
      espnPath: 'rugby/289234',
      name: "International Test Match",
      shortName: "Tests",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: true),
  SportsLeague(
      id: 'rugby.268565',
      espnPath: 'rugby/268565',
      name: "British and Irish Lions Tour",
      shortName: "Lions",
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby',
      hasStandings: false),
  SportsLeague(
      id: 'golf.pga',
      espnPath: 'golf/pga',
      name: 'PGA Tour',
      shortName: 'PGA',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/pgatour.png',
      region: 'Golf',
      hasStandings: false,
      kind: SportsKind.golf,
      seriesPhrases: ['pga tour', 'golf channel']),
  SportsLeague(
      id: 'golf.lpga',
      espnPath: 'golf/lpga',
      name: 'LPGA Tour',
      shortName: 'LPGA',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/lpga.png',
      region: 'Golf',
      hasStandings: false,
      kind: SportsKind.golf,
      seriesPhrases: ['lpga', 'golf channel']),
  SportsLeague(
      id: 'golf.eur',
      espnPath: 'golf/eur',
      name: 'DP World Tour',
      shortName: 'DPWT',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/espn/teamlogos/500/european_tour.png',
      region: 'Golf',
      hasStandings: false,
      kind: SportsKind.golf,
      seriesPhrases: ['dp world tour', 'golf channel']),
  SportsLeague(
      id: 'golf.liv',
      espnPath: 'golf/liv',
      name: 'LIV Golf',
      shortName: 'LIV',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/livgolf.png',
      region: 'Golf',
      hasStandings: false,
      kind: SportsKind.golf,
      seriesPhrases: ['liv golf', 'golf channel']),
  SportsLeague(
      id: 'mma.ufc',
      espnPath: 'mma/ufc',
      name: 'UFC',
      shortName: 'UFC',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/ufc.png',
      region: 'Fighting',
      hasStandings: false,
      kind: SportsKind.fight,
      seriesPhrases: ['ufc']),
  SportsLeague(
      id: 'mma.pfl',
      espnPath: 'mma/pfl',
      name: 'PFL',
      shortName: 'PFL',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/pfl.png',
      region: 'Fighting',
      hasStandings: false,
      kind: SportsKind.fight,
      seriesPhrases: ['pfl']),
  SportsLeague(
      id: 'racing.f1',
      espnPath: 'racing/f1',
      name: 'Formula 1',
      shortName: 'F1',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/f1.png',
      region: 'Motorsport',
      hasStandings: true,
      kind: SportsKind.racing,
      seriesPhrases: ['formula 1', 'formula one', 'sky sports f1', 'f1']),
  SportsLeague(
      id: 'racing.nascar-premier',
      espnPath: 'racing/nascar-premier',
      name: 'NASCAR Cup Series',
      shortName: 'NASCAR',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-NASCAR.png',
      region: 'Motorsport',
      hasStandings: true,
      kind: SportsKind.racing,
      seriesPhrases: ['nascar cup', 'nascar']),
  SportsLeague(
      id: 'racing.irl',
      espnPath: 'racing/irl',
      name: 'IndyCar',
      shortName: 'INDYCAR',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/espn/teamlogos/500/indycar_series.png',
      region: 'Motorsport',
      hasStandings: true,
      kind: SportsKind.racing,
      seriesPhrases: ['indycar']),
  SportsLeague(
      id: 'tennis.atp',
      espnPath: 'tennis/atp',
      name: 'ATP Tour',
      shortName: 'ATP',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-tennis.png',
      region: 'Tennis',
      hasStandings: false,
      kind: SportsKind.tennis,
      seriesPhrases: ['atp', 'tennis channel', 'tennis']),
  SportsLeague(
      id: 'tennis.wta',
      espnPath: 'tennis/wta',
      name: 'WTA Tour',
      shortName: 'WTA',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-tennis.png',
      region: 'Tennis',
      hasStandings: false,
      kind: SportsKind.tennis,
      seriesPhrases: ['wta', 'tennis channel', 'tennis']),
  SportsLeague(
      id: 'usa.ncaa.m.1',
      espnPath: 'soccer/usa.ncaa.m.1',
      name: "NCAA Men's Soccer",
      shortName: 'NCAAMS',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/sports-soccer-solid.png',
      region: 'Americas',
      soccer: true),
  SportsLeague(
      id: 'usa.ncaa.w.1',
      espnPath: 'soccer/usa.ncaa.w.1',
      name: "NCAA Women's Soccer",
      shortName: 'NCAAWS',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/sports-soccer-solid.png',
      region: 'Americas',
      soccer: true),
  SportsLeague(
      id: 'ger.2',
      espnPath: 'soccer/ger.2',
      name: '2. Bundesliga',
      shortName: 'BUN2',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/97.png',
      region: 'Germany',
      soccer: true),
  SportsLeague(
      id: 'eng.2',
      espnPath: 'soccer/eng.2',
      name: 'EFL Championship',
      shortName: 'EFL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/24.png',
      region: 'England',
      soccer: true),
  SportsLeague(
      id: 'eng.3',
      espnPath: 'soccer/eng.3',
      name: 'EFL League One',
      shortName: 'LEAGUE 1',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/25.png',
      region: 'England',
      soccer: true),
  SportsLeague(
      id: 'eng.4',
      espnPath: 'soccer/eng.4',
      name: 'EFL League Two',
      shortName: 'LEAGUE 2',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/26.png',
      region: 'England',
      soccer: true),
  SportsLeague(
      id: 'eng.5',
      espnPath: 'soccer/eng.5',
      name: 'National League',
      shortName: 'NATIONAL',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/teamlogos/soccer/500/default-team-logo-500.png&w=100&h=100',
      region: 'England',
      soccer: true),
  SportsLeague(
      id: 'esp.2',
      espnPath: 'soccer/esp.2',
      name: 'LALIGA 2',
      shortName: 'LALIGA2',
      logoUrl: 'http://a.espncdn.com/i/leaguelogos/soccer/500/107.png',
      region: 'Spain',
      soccer: true),
  SportsLeague(
      id: 'ita.2',
      espnPath: 'soccer/ita.2',
      name: 'Serie B',
      shortName: 'SB',
      logoUrl: 'http://a.espncdn.com/i/leaguelogos/soccer/500/99.png',
      region: 'Italy',
      soccer: true),
  SportsLeague(
      id: 'fra.2',
      espnPath: 'soccer/fra.2',
      name: 'Ligue 2',
      shortName: 'L2',
      logoUrl: 'http://a.espncdn.com/i/leaguelogos/soccer/500/96.png',
      region: 'France',
      soccer: true),
  SportsLeague(
      id: 'ned.1',
      espnPath: 'soccer/ned.1',
      name: 'Eredivisie',
      shortName: 'ERE',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/11.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'por.1',
      espnPath: 'soccer/por.1',
      name: 'Primeira Liga',
      shortName: 'LIGA PT',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/14.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'tur.1',
      espnPath: 'soccer/tur.1',
      name: 'Turkish Super Lig',
      shortName: 'SÜPER LIG',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/18.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'sco.1',
      espnPath: 'soccer/sco.1',
      name: 'Scottish Premiership',
      shortName: 'SPFL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/45.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'bel.1',
      espnPath: 'soccer/bel.1',
      name: 'Belgian Pro League',
      shortName: 'JPL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/6.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'aut.1',
      espnPath: 'soccer/aut.1',
      name: 'Austrian Bundesliga',
      shortName: 'AUT',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/5.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'gre.1',
      espnPath: 'soccer/gre.1',
      name: 'Greek Super League',
      shortName: 'GRE',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/98.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'rus.1',
      espnPath: 'soccer/rus.1',
      name: 'Russian Premier League',
      shortName: 'RPL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/106.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'den.1',
      espnPath: 'soccer/den.1',
      name: 'Danish Superliga',
      shortName: 'DEN',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/teamlogos/soccer/500/default-team-logo-500.png&w=100&h=100',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'nor.1',
      espnPath: 'soccer/nor.1',
      name: 'Norwegian Eliteserien',
      shortName: 'NOR',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/teamlogos/soccer/500/default-team-logo-500.png&w=100&h=100',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'swe.1',
      espnPath: 'soccer/swe.1',
      name: 'Swedish Allsvenskan',
      shortName: 'ALLSV',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/16.png',
      region: 'Europe',
      soccer: true),
  SportsLeague(
      id: 'mex.1',
      espnPath: 'soccer/mex.1',
      name: 'Liga MX',
      shortName: 'LIGA MX',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/22.png',
      region: 'Americas',
      soccer: true),
  SportsLeague(
      id: 'arg.1',
      espnPath: 'soccer/arg.1',
      name: 'Liga Profesional (ARG)',
      shortName: 'LPF',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/1.png',
      region: 'Americas',
      soccer: true),
  SportsLeague(
      id: 'bra.1',
      espnPath: 'soccer/bra.1',
      name: 'Brasileirão Série A',
      shortName: 'BRA',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/85.png',
      region: 'Americas',
      soccer: true),
  SportsLeague(
      id: 'jpn.1',
      espnPath: 'soccer/jpn.1',
      name: 'J1 League',
      shortName: 'J1',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2199.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'chn.1',
      espnPath: 'soccer/chn.1',
      name: 'Chinese Super League',
      shortName: 'CSL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2350.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'aus.1',
      espnPath: 'soccer/aus.1',
      name: 'A-League Men',
      shortName: 'A-LEAGUE',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/1308.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'ind.1',
      espnPath: 'soccer/ind.1',
      name: 'Indian Super League',
      shortName: 'ISL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2334.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'rsa.1',
      espnPath: 'soccer/rsa.1',
      name: 'South African Premiership',
      shortName: 'RSA',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/teamlogos/soccer/500/default-team-logo-500.png&w=100&h=100',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'uefa.europa',
      espnPath: 'soccer/uefa.europa',
      name: 'UEFA Europa League',
      shortName: 'UEL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2310.png',
      region: 'Cups',
      soccer: true),
  SportsLeague(
      id: 'uefa.europa.conf',
      espnPath: 'soccer/uefa.europa.conf',
      name: 'UEFA Conference League',
      shortName: 'UECL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/20296.png',
      region: 'Cups',
      soccer: true),
  SportsLeague(
      id: 'uefa.champions_qual',
      espnPath: 'soccer/uefa.champions_qual',
      name: 'UEFA Champions League Qualifying',
      shortName: 'UCL Q',
      logoUrl: '',
      region: 'Cups',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'uefa.super_cup',
      espnPath: 'soccer/uefa.super_cup',
      name: 'UEFA Super Cup',
      shortName: 'SUPER CUP',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/1272.png',
      region: 'Cups',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'uefa.euro',
      espnPath: 'soccer/uefa.euro',
      name: 'UEFA EURO',
      shortName: 'EURO',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/74.png',
      region: 'Cups',
      soccer: true),
  SportsLeague(
      id: 'uefa.nations',
      espnPath: 'soccer/uefa.nations',
      name: 'UEFA Nations League',
      shortName: 'UNL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2395.png',
      region: 'Cups',
      soccer: true),
  SportsLeague(
      id: 'eng.fa',
      espnPath: 'soccer/eng.fa',
      name: 'English FA Cup',
      shortName: 'FA CUP',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/40.png',
      region: 'England',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'eng.league_cup',
      espnPath: 'soccer/eng.league_cup',
      name: 'Carabao Cup',
      shortName: 'EFL CUP',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/41.png',
      region: 'England',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'ger.dfb_pokal',
      espnPath: 'soccer/ger.dfb_pokal',
      name: 'DFB-Pokal',
      shortName: 'POKAL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2061.png',
      region: 'Germany',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'esp.copa_del_rey',
      espnPath: 'soccer/esp.copa_del_rey',
      name: 'Spanish Copa del Rey',
      shortName: 'COPA',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/80.png',
      region: 'Spain',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'ita.coppa_italia',
      espnPath: 'soccer/ita.coppa_italia',
      name: 'Coppa Italia',
      shortName: 'COPPA',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2192.png',
      region: 'Italy',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'esp.super_cup',
      espnPath: 'soccer/esp.super_cup',
      name: 'Spanish Supercopa',
      shortName: 'SUPERCOPA',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/431.png',
      region: 'Spain',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'ita.super_cup',
      espnPath: 'soccer/ita.super_cup',
      name: 'Italian Supercoppa',
      shortName: 'SUPERCOPPA',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/teamlogos/soccer/500/default-team-logo-500.png&w=100&h=100',
      region: 'Italy',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'fra.coupe_de_france',
      espnPath: 'soccer/fra.coupe_de_france',
      name: 'Coupe de France',
      shortName: 'CDF',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/182.png',
      region: 'France',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'fifa.world',
      espnPath: 'soccer/fifa.world',
      name: 'FIFA World Cup',
      shortName: 'WORLD CUP',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/4.png',
      region: 'Cups',
      soccer: true),
  SportsLeague(
      id: 'fifa.wwc',
      espnPath: 'soccer/fifa.wwc',
      name: "FIFA Women's World Cup",
      shortName: 'WWC',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/60.png',
      region: 'Cups',
      soccer: true),
  SportsLeague(
      id: 'fifa.worldq.concacaf',
      espnPath: 'soccer/fifa.worldq.concacaf',
      name: 'World Cup Qualifying (Concacaf)',
      shortName: 'WCQ',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/64.png',
      region: 'Cups',
      soccer: true),
  SportsLeague(
      id: 'afc.champions',
      espnPath: 'soccer/afc.champions',
      name: 'AFC Champions League Elite',
      shortName: 'ACL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2200.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'caf.champions',
      espnPath: 'soccer/caf.champions',
      name: 'CAF Champions League',
      shortName: 'CAF CL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2391.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'afc.asian.cup',
      espnPath: 'soccer/afc.asian.cup',
      name: 'AFC Asian Cup',
      shortName: 'ASIAN CUP',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/i/leaguelogos/soccer/500/2243.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'caf.nations',
      espnPath: 'soccer/caf.nations',
      name: 'Africa Cup of Nations',
      shortName: 'AFCON',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/76.png',
      region: 'World',
      soccer: true),
  SportsLeague(
      id: 'concacaf.champions',
      espnPath: 'soccer/concacaf.champions',
      name: 'Concacaf Champions Cup',
      shortName: 'CCC',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2298.png',
      region: 'Americas',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'concacaf.gold',
      espnPath: 'soccer/concacaf.gold',
      name: 'Concacaf Gold Cup',
      shortName: 'GOLD CUP',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/59.png',
      region: 'Americas',
      soccer: true),
  SportsLeague(
      id: 'conmebol.libertadores',
      espnPath: 'soccer/conmebol.libertadores',
      name: 'CONMEBOL Libertadores',
      shortName: 'LIBERTADORES',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/58.png',
      region: 'Americas',
      soccer: true),
  SportsLeague(
      id: 'usa.open',
      espnPath: 'soccer/usa.open',
      name: 'U.S. Open Cup',
      shortName: 'US OPEN CUP',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/69.png',
      region: 'Americas',
      soccer: true,
      hasStandings: false),
  SportsLeague(
      id: 'eng.w.1',
      espnPath: 'soccer/eng.w.1',
      name: "Women's Super League",
      shortName: 'WSL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2314.png',
      region: 'Women',
      soccer: true),
  SportsLeague(
      id: 'esp.w.1',
      espnPath: 'soccer/esp.w.1',
      name: 'Liga F',
      shortName: 'LIGA F',
      logoUrl: '',
      region: 'Women',
      soccer: true),
  SportsLeague(
      id: 'fra.w.1',
      espnPath: 'soccer/fra.w.1',
      name: 'Première Ligue (women)',
      shortName: 'D1F',
      logoUrl: '',
      region: 'Women',
      soccer: true),
  SportsLeague(
      id: 'usa.nwsl',
      espnPath: 'soccer/usa.nwsl',
      name: 'NWSL',
      shortName: 'NWSL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2323.png',
      region: 'Women',
      soccer: true),
  SportsLeague(
      id: 'uefa.wchampions',
      espnPath: 'soccer/uefa.wchampions',
      name: "UEFA Women's Champions League",
      shortName: 'UWCL',
      logoUrl: 'https://a.espncdn.com/i/leaguelogos/soccer/500/2408.png',
      region: 'Women',
      soccer: true),
  SportsLeague(
      id: 'basketball.mens-college-basketball',
      espnPath: 'basketball/mens-college-basketball',
      name: "NCAA Men's Basketball",
      shortName: 'NCAAM',
      logoUrl:
          'https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-basketball.png',
      region: 'Basketball'),
  SportsLeague(
      id: 'basketball.womens-college-basketball',
      espnPath: 'basketball/womens-college-basketball',
      name: "NCAA Women's Basketball",
      shortName: 'NCAAW',
      logoUrl:
          'https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-basketball.png',
      region: 'Basketball'),
  SportsLeague(
      id: 'baseball.college-baseball',
      espnPath: 'baseball/college-baseball',
      name: 'NCAA Baseball',
      shortName: 'CBASE',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-baseball.png',
      region: 'Baseball'),
  SportsLeague(
      id: 'hockey.mens-college-hockey',
      espnPath: 'hockey/mens-college-hockey',
      name: "NCAA Men's Ice Hockey",
      shortName: 'NCAAH',
      logoUrl:
          'https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-hockey.png',
      region: 'Hockey'),
  SportsLeague(
      id: 'hockey.womens-college-hockey',
      espnPath: 'hockey/womens-college-hockey',
      name: "NCAA Women's Hockey",
      shortName: 'CWHOC',
      logoUrl:
          'https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-hockey.png',
      region: 'Hockey'),
  SportsLeague(
      id: 'australian-football.afl',
      espnPath: 'australian-football/afl',
      name: 'AFL',
      shortName: 'AFL',
      logoUrl: 'https://a.espncdn.com/i/teamlogos/leagues/500/afl.png',
      region: 'Other'),
  SportsLeague(
      id: 'rugby.270557',
      espnPath: 'rugby/270557',
      name: 'United Rugby Championship',
      shortName: 'URC',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby'),
  SportsLeague(
      id: 'rugby.164205',
      espnPath: 'rugby/164205',
      name: 'Rugby World Cup',
      shortName: 'RWC',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-rugby.png',
      region: 'Rugby'),
  SportsLeague(
      id: 'volleyball.womens-college-volleyball',
      espnPath: 'volleyball/womens-college-volleyball',
      name: "NCAA Women's Volleyball",
      shortName: 'NCAA WVB',
      logoUrl:
          'https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/sports-volleyball-solid.png',
      region: 'Other'),
];

/// Bank group headings, in display order.
const List<String> kSportsLeagueRegions = [
  'England',
  'Spain',
  'Germany',
  'Italy',
  'France',
  'Europe',
  'Cups',
  'Americas',
  'World',
  'Women',
  'Basketball',
  'Hockey',
  'Baseball',
  'Golf',
  'Tennis',
  'Fighting',
  'Motorsport',
  'Rugby',
  'Other',
];

SportsLeague? sportsLeagueById(String id) {
  for (final l in kSportsLeagues) {
    if (l.id == id) return l;
  }
  for (final l in kSportsLeagueBank) {
    if (l.id == id) return l;
  }
  return null;
}

/// ESPN serves original logos up to 500 px (~100 KB each); its own resizer
/// returns a ~8 KB version — what a weak TV box should download and decode.
String? sportsLogoUrl(String? url, {int size = 96}) {
  if (url == null || url.isEmpty) return null;
  // Upstream's compact variant avoids fetching large supplemental logos.
  if (size <= 100 &&
      url.startsWith('https://r2.thesportsdb.com/') &&
      url.endsWith('.png')) {
    return '$url/tiny';
  }
  const host = 'https://a.espncdn.com/';
  if (!url.startsWith(host) || url.contains('/combiner/')) return url;
  final path = url.substring(host.length - 1);
  return '${host}combiner/i?img=$path&w=$size&h=$size';
}

/// ESPN's dark-background variant of a team/league logo (`/500-dark/`) —
/// navy or black logos (Capitals, Nets, Raiders) vanish on the app's black
/// theme otherwise. Not every team has one (404) — callers fall back to the
/// original. Null when the URL isn't an ESPN `/500/` logo.
String? sportsDarkLogoUrl(String? url) {
  if (url == null) return null;
  for (final segment in const ['/500/scoreboard/', '/500/']) {
    if (url.contains(segment)) return url.replaceFirst(segment, '/500-dark/');
  }
  return null;
}

enum GameState { pre, live, post }

class SportsTeam {
  const SportsTeam({
    required this.id,
    required this.name,
    required this.shortName,
    required this.abbreviation,
    this.location,
    this.logoUrl,
    this.color,
    this.record,
    this.score,
  });

  final String id;

  /// Full name ("Detroit Red Wings").
  final String name;

  /// Nickname ("Red Wings"; soccer: "Bremen").
  final String shortName;
  final String abbreviation;

  /// School/city identity supplied by the scoreboard, without the mascot.
  final String? location;
  final String? logoUrl;

  /// Hex without `#`, e.g. `e30526`.
  final String? color;

  /// "1-3-1" (W-L-OTL / W-D-L).
  final String? record;
  final String? score;
}

class SportsGame {
  const SportsGame({
    required this.id,
    required this.league,
    required this.start,
    required this.state,
    required this.statusText,
    required this.home,
    required this.away,
    this.broadcasts = const [],
    this.event,
    this.end,
    this.leaders = const [],
    this.situation,
    this.source = 'ESPN',
    this.onlineBroadcasts = const [],
    this.guideProgrammes = const [],
  });

  /// The scoreboard's top performers (in-game once it starts), at most one
  /// per stat — the live list's fantasy line. Team sports only.
  final List<SportsLeader> leaders;

  /// Football: down & distance / red zone; baseball: count, outs, bases.
  final SportsSituation? situation;

  final String id;
  final SportsLeague league;
  final DateTime start;

  /// Golf: the tournament's last day (ESPN's US-Eastern midnight). The
  /// event shows on every day from [start] to here.
  final DateTime? end;

  /// Event sports only (golf / racing / fight): what the card shows instead
  /// of two teams. For golf and racing [home]/[away] are placeholders named
  /// after the event; for a fight card they're the main event's fighters.
  final SportsEventInfo? event;
  final GameState state;

  /// Provider's short status ("End of 2nd", "73'", "Final", "7:00 PM").
  final String statusText;
  final SportsTeam home;
  final SportsTeam away;

  /// TV networks the provider lists ("ESPN", "TNT", "MSGB").
  final List<String> broadcasts;
  final String source;

  /// Calendar windows are estimates, not live timing or broadcast proof.
  bool get isScheduleOnly => source == 'RaceTV Guide' || source == 'Jolpica';

  /// Exact current guide slots, not keyword-based broadcaster suggestions.
  final List<EpgProgram> guideProgrammes;
  bool get isGuideEvent => source == 'Channel guide';
  bool get isOnAirOnly => isGuideEvent && statusText.startsWith('On air');
  final List<SportsBroadcast> onlineBroadcasts;

  SportsGame withOnlineBroadcasts(List<SportsBroadcast> listings) => SportsGame(
      id: id,
      league: league,
      start: start,
      state: state,
      statusText: statusText,
      home: home,
      away: away,
      broadcasts: broadcasts,
      event: event,
      end: end,
      leaders: leaders,
      situation: situation,
      source: source,
      onlineBroadcasts: listings,
      guideProgrammes: guideProgrammes);

  /// The two sides in on-screen order (see [SportsLeague.soccer]).
  /// Fights read "A vs B" in the order ESPN bills them, like soccer.
  bool get _homeFirst => league.soccer || league.kind != SportsKind.team;
  SportsTeam get first => _homeFirst ? home : away;
  SportsTeam get second => _homeFirst ? away : home;
  String get joiner => _homeFirst ? 'vs' : 'at';

  String get title => league.isField
      ? (event?.title ?? first.name)
      : '${first.shortName} $joiner ${second.shortName}';
}

/// An event-specific listing, kept separate from generic broadcaster guesses.
class SportsBroadcast {
  const SportsBroadcast(this.name,
      {required this.source,
      this.country = '',
      this.tournamentOnly = false,
      this.programme,
      this.expiresAt});
  final String name, source, country;

  /// Optional exact linear schedule evidence. Never written into provider EPG.
  final EpgProgram? programme;
  final DateTime? expiresAt;

  String get evidenceKey => '$name|$country|$source|$tournamentOnly|'
      '${programme?.start.millisecondsSinceEpoch}|'
      '${programme?.stop.millisecondsSinceEpoch}|${programme?.title}|'
      '${programme?.description}|${expiresAt?.millisecondsSinceEpoch}';

  /// A tournament listing cannot establish which court this feed will show.
  final bool tournamentOnly;
}

/// A stat leader from the scoreboard ("PASS  G. Stockton  181 YDS, 1 TD").
class SportsLeader {
  const SportsLeader({
    required this.stat,
    required this.name,
    required this.value,
    this.teamId,
    this.position,
  });

  /// ESPN's short label ("PASS", "G", "Pts", "HR").
  final String stat;

  /// "G. Stockton".
  final String name;

  /// Game line ("11/18, 181 YDS, 1 TD") or a bare number ("29").
  final String value;
  final String? teamId;

  /// "QB", "C".
  final String? position;
}

/// Live game state beyond the clock.
class SportsSituation {
  const SportsSituation({
    this.text,
    this.possessionTeamId,
    this.redZone = false,
    this.lastPlay,
  });

  /// "3rd & 8 at AUB 28" / "2 out · 1st, 3rd".
  final String? text;
  final String? possessionTeamId;
  final bool redZone;
  final String? lastPlay;
}

/// The game-detail pop-up's data (ESPN `summary`), see
/// [SportsService.gameSummary].
class SportsGameSummary {
  const SportsGameSummary({
    this.teamStats = const [],
    this.players = const {},
    this.leaders = const {},
    this.injuries = const {},
    this.goals = const [],
    this.tables = const [],
  });

  /// Side by side: (label, away value, home value).
  final List<(String, String, String)> teamStats;

  /// Box score per team id: a few columns of the top players per category.
  final Map<String, List<SportsPlayerGroup>> players;

  /// Per team id, ESPN's leader categories ("Passing Yards" → line).
  final Map<String, List<SportsLeader>> leaders;

  /// Per team id: "T. Badie RB · Questionable (Thumb)".
  final Map<String, List<SportsInjury>> injuries;

  /// Every goal, in order (soccer and hockey) — the box score only lists a
  /// few players per position, so it can't say who scored.
  final List<SportsGoal> goals;

  /// The standings groups that hold either team.
  final List<SportsSummaryTable> tables;

  bool get isEmpty =>
      teamStats.isEmpty &&
      players.isEmpty &&
      leaders.isEmpty &&
      goals.isEmpty &&
      tables.isEmpty;
}

class SportsPlayerGroup {
  const SportsPlayerGroup(
      {required this.title, required this.labels, required this.rows});

  /// "passing", "forwards", "batting" — translated at the display site.
  final String title;
  final List<String> labels;

  /// (short name, values in [labels] order).
  final List<(String, List<String>)> rows;
}

class SportsInjury {
  const SportsInjury(
      {required this.name, required this.status, this.position, this.detail});
  final String name;
  final String status;
  final String? position;
  final String? detail;
}

class SportsGoal {
  const SportsGoal(
      {required this.minute,
      required this.scorer,
      this.teamId,
      this.penalty = false,
      this.period,
      this.assists = const [],
      this.score});
  final String minute;
  final String scorer;
  final String? teamId;
  final bool penalty;

  /// Hockey: "1st", "2nd", "OT" ([minute] is then the period clock).
  final String? period;

  /// Hockey: the assisting players' short names.
  final List<String> assists;

  /// The score right after this goal, away-home ("0-3").
  final String? score;
}

class SportsSummaryTable {
  const SportsSummaryTable(
      {required this.title, required this.labels, required this.rows});

  /// "Metropolitan Division".
  final String title;
  final List<String> labels;

  /// (team id, team name, values in [labels] order).
  final List<(String, String, List<String>)> rows;
}

/// One line of an event's leaderboard / running order.
class SportsEventEntry {
  const SportsEventEntry({
    required this.position,
    required this.name,
    this.flagUrl,
    this.value,
  });

  /// "1", "T3" (golf ties).
  final String position;

  /// "M. Verstappen".
  final String name;
  final String? flagUrl;

  /// Golf: score to par ("-12", "E"). Racing: none.
  final String? value;
}

/// What an event-sport card shows ([SportsKind.golf], `racing`, `fight`).
class SportsEventInfo {
  const SportsEventInfo({
    required this.title,
    this.session,
    this.venue,
    this.matchingNames = const [],
    this.court,
    this.leaders = const [],
  });

  /// "Singapore Airlines Singapore Grand Prix", "UFC Fight Night: Allen vs.
  /// Duncan", "Butterfield Bermuda Championship".
  final String title;

  /// "Race", "Qualifying", "Round 2" (English, shown through `tr`), or a
  /// fight's weight class.
  final String? session;

  /// Circuit / arena / city.
  final String? venue;

  /// Short tournament names supplied alongside the scoreboard title.
  /// Used for matching only; the displayed tournament name stays unchanged.
  final List<String> matchingNames;

  /// Explicit court supplied for a tennis match; never inferred from its order.
  final String? court;

  /// Top of the leaderboard (golf, racing), best first. Empty for fights.
  final List<SportsEventEntry> leaders;
}

/// One team's line in a standings table. [stats] is keyed by the provider's
/// stat name (`wins`, `points`, `streak`, ...) with display-ready values, so
/// each sport can pick its own columns without the model knowing them.
class SportsStandingRow {
  const SportsStandingRow({
    required this.team,
    required this.position,
    required this.stats,
    this.noteColor,
    this.note,
  });

  final SportsTeam team;

  /// 1-based place in its group (after sorting).
  final int position;
  final Map<String, String> stats;

  /// Soccer qualification zone ("Champions League", "Relegation") and its
  /// hex colour (no `#`).
  final String? noteColor;
  final String? note;

  String stat(String name) => stats[name] ?? '';
}

/// A conference, division or league table.
class SportsStandingGroup {
  const SportsStandingGroup({required this.name, required this.rows});
  final String name;
  final List<SportsStandingRow> rows;
}

/// A team in My Teams. Team ids are only unique within a league.
class FollowedTeam {
  const FollowedTeam(this.leagueId, this.teamId);

  final String leagueId;
  final String teamId;

  /// Stored form, `leagueId|teamId`; null when malformed.
  static FollowedTeam? parse(String raw) {
    final i = raw.indexOf('|');
    if (i <= 0 || i == raw.length - 1) return null;
    return FollowedTeam(raw.substring(0, i), raw.substring(i + 1));
  }

  String get key => '$leagueId|$teamId';

  @override
  bool operator ==(Object other) =>
      other is FollowedTeam &&
      other.leagueId == leagueId &&
      other.teamId == teamId;

  @override
  int get hashCode => Object.hash(leagueId, teamId);
}

/// One team's season: who they are, where they stand, every game.
class SportsTeamSchedule {
  const SportsTeamSchedule({
    required this.league,
    required this.team,
    required this.games,
    this.standingSummary,
  });

  final SportsLeague league;

  /// [SportsTeam.record] is the season record ("1-3-2").
  final SportsTeam team;

  /// "8th in Atlantic Division".
  final String? standingSummary;

  /// Oldest first.
  final List<SportsGame> games;

  /// The game being played now, else the next one, else null.
  SportsGame? get nextGame =>
      games.where((g) => g.state == GameState.live).firstOrNull ??
      games.where((g) => g.state == GameState.pre).firstOrNull;

  SportsGame? get lastGame =>
      games.where((g) => g.state == GameState.post).lastOrNull;

  /// Live and upcoming games starting within [days] days.
  List<SportsGame> upcoming({int days = 14}) {
    final until = DateTime.now().toUtc().add(Duration(days: days));
    return [
      for (final g in games)
        if (g.state == GameState.live ||
            (g.state == GameState.pre && g.start.isBefore(until)))
          g,
    ];
  }
}

class SportsStandings {
  const SportsStandings({
    required this.league,
    required this.groups,
    this.season,
    this.preseason = false,
  });

  final SportsLeague league;
  final List<SportsStandingGroup> groups;

  /// "2026-27".
  final String? season;

  /// Exhibition-game records (the NBA publishes those before opening night).
  final bool preseason;
}
