import '../models/sports.dart';

/// Small offline labels: no requests or work across the playlist catalogue.
String leagueDescription(SportsLeague league) {
  if (league.kind == SportsKind.racing && league.source != 'ESPN') {
    return switch (league.id) {
      'racing.supercars' => 'Touring cars',
      'racing.motogp' || 'racing.moto2' || 'racing.moto3' => 'Grand Prix bikes',
      'racing.worldsbk' => 'Superbikes',
      'racing.wec' || 'racing.imsa' => 'Endurance racing',
      'racing.formula-e' => 'Electric racing',
      'racing.f2' || 'racing.f3' || 'racing.f1-academy' => 'Formula racing',
      'racing.gtwc' ||
      'racing.gtwc-america' ||
      'racing.gtwc-asia' ||
      'racing.gtwc-australia' ||
      'racing.igtc' ||
      'racing.dtm' =>
        'GT racing',
      'racing.elms' ||
      'racing.asian-le-mans' ||
      'racing.le-mans-cup' ||
      'racing.24h-series' ||
      'racing.nls' ||
      'racing.super-taikyu' =>
        'Endurance racing',
      'racing.british-gt' ||
      'racing.gt-open' ||
      'racing.imsa-pilot' =>
        'GT & endurance racing',
      'racing.ewc' => 'Motorcycle endurance',
      'racing.wrc' || 'racing.erc' => 'Rallying',
      _ => 'Motor racing',
    };
  }
  if (league.source == 'Channel guide') {
    return switch (league.id) {
      'guide.npb' => 'Japanese baseball',
      'guide.kbo' => 'Korean baseball',
      'guide.cpbl' => 'Taiwanese baseball',
      'guide.poker' => 'Tables on TV',
      'guide.racing' => 'Live races & support coverage',
      'guide.rugby-nrl' ||
      'guide.rugby-super-league' ||
      'guide.rugby-state-of-origin' =>
        'Rugby league · on TV',
      'guide.rugby-nrlw' => 'Women’s rugby league · on TV',
      _ when league.espnPath.startsWith('rugby/') => 'Rugby coverage · on TV',
      _ => 'TV coverage',
    };
  }
  if (league.source != 'ESPN') return 'Extra schedule · ${league.source}';
  final sport = league.espnPath.split('/').first;
  final id = league.id;
  if (id.contains('ncaa') || id.contains('college')) {
    final women = id.contains('.w.') || id.contains('womens-');
    final kind = switch (sport) {
      'soccer' => 'soccer',
      'football' => 'football',
      'hockey' => 'hockey',
      'basketball' => 'basketball',
      'baseball' => 'baseball',
      _ => sport,
    };
    return '${women ? "Women’s college" : "College"} $kind';
  }
  return switch (id) {
    'nfl' => 'Pro football',
    'nba' => 'Pro basketball',
    'wnba' => 'Women’s basketball',
    'nhl' => 'Pro ice hockey',
    'mlb' => 'Pro baseball',
    'usa.1' => 'US / Canada soccer',
    'eng.1' => 'English soccer',
    'eng.2' => 'England · 2nd tier',
    'eng.3' => 'England · 3rd tier',
    'eng.4' => 'England · 4th tier',
    'eng.5' => 'England · 5th tier',
    'esp.1' => 'Spanish soccer',
    'ger.1' => 'German soccer',
    'ita.1' => 'Italian soccer',
    'fra.1' => 'French soccer',
    'uefa.champions' => 'Europe’s club cup',
    'uefa.wchampions' => 'Women’s club cup',
    'fifa.world' => 'World Cup',
    'fifa.wwc' => 'Women’s World Cup',
    'tennis.atp' => 'Men’s tennis',
    'tennis.wta' => 'Women’s tennis',
    'golf.pga' => 'Men’s golf',
    'golf.lpga' => 'Women’s golf',
    'golf.eur' => 'European golf',
    'golf.liv' => 'Team golf',
    'racing.f1' => 'Formula racing',
    'racing.irl' => 'IndyCar racing',
    'racing.nascar-premier' => 'Stock-car racing',
    'mma.ufc' || 'mma.pfl' => 'Mixed martial arts',
    'australian-football.afl' => 'Aussie rules',
    _ when sport == 'soccer' => league.region == 'Women'
        ? 'Women’s soccer'
        : '${league.region == null || league.region == 'Cups' ? 'Club' : league.region} soccer',
    _ => switch (sport) {
        'football' => 'American football',
        'hockey' => 'Ice hockey',
        'rugby' => 'Rugby',
        _ =>
          sport.isEmpty ? '' : '${sport[0].toUpperCase()}${sport.substring(1)}',
      },
  };
}

/// Offline editorial order shared by event rows and the league picker. These
/// are browsing priorities within each sport, not a live popularity ranking.
/// Keep distinct competitions explicit: a women's cup must not inherit the
/// men's cup's rank merely because their names are similar.
int leagueDisplayPriority(SportsLeague league) => switch (league.id) {
      'fifa.world' => 0,
      'uefa.champions' || 'rugby.164205' => 1,
      'uefa.euro' ||
      'nfl' ||
      'nba' ||
      'nhl' ||
      'mlb' ||
      'racing.f1' ||
      'tennis.atp' ||
      'golf.pga' ||
      'mma.ufc' ||
      'australian-football.afl' =>
        2,
      'racing.supercars' ||
      'racing.motogp' ||
      'eng.1' ||
      'college-football' ||
      'basketball.mens-college-basketball' ||
      'tennis.wta' ||
      'golf.eur' ||
      'racing.nascar-premier' ||
      'mma.pfl' ||
      'rugby.270557' =>
        3,
      'racing.wec' ||
      'racing.imsa' ||
      'racing.worldsbk' ||
      'esp.1' ||
      'wnba' ||
      'golf.liv' ||
      'racing.irl' =>
        4,
      'guide.rugby-internationals' || 'rugby.180659' || 'rugby.244293' => 2,
      'guide.rugby-nrl' ||
      'guide.rugby-six-nations' ||
      'guide.rugby-rugby-championship' ||
      'rugby.242041' ||
      'rugby.271937' =>
        3,
      'guide.rugby-super-rugby' ||
      'guide.rugby-super-league' ||
      'guide.rugby-premiership' ||
      'guide.rugby-top14' ||
      'guide.rugby-urc' ||
      'guide.rugby-champions-cup' ||
      'rugby.267979' ||
      'rugby.270559' =>
        4,
      'guide.rugby-nrlw' || 'rugby.289237' => 8,
      'guide.npb' => 3,
      'guide.kbo' => 4,
      'guide.cpbl' => 6,
      'ita.1' || 'golf.lpga' || 'basketball.womens-college-basketball' => 5,
      'ger.1' => 6,
      'fra.1' => 7,
      'uefa.europa' => 8,
      'conmebol.libertadores' => 9,
      'eng.fa' => 10,
      'uefa.nations' || 'uefa.europa.conf' => 11,
      'afc.asian.cup' || 'caf.nations' || 'concacaf.gold' => 12,
      'bra.1' || 'arg.1' || 'ned.1' || 'por.1' || 'usa.1' || 'mex.1' => 13,
      'eng.league_cup' ||
      'ger.dfb_pokal' ||
      'esp.copa_del_rey' ||
      'ita.coppa_italia' ||
      'fra.coupe_de_france' ||
      'uefa.champions_qual' =>
        14,
      'fifa.wwc' => 15,
      'uefa.wchampions' => 16,
      'eng.w.1' || 'usa.nwsl' => 17,
      'eng.2' || 'tur.1' || 'sco.1' || 'bel.1' || 'aus.1' => 18,
      'esp.w.1' || 'fra.w.1' => 19,
      'ger.2' || 'esp.2' || 'ita.2' || 'fra.2' => 20,
      'eng.3' => 21,
      'eng.4' => 22,
      'eng.5' => 23,
      _ when league.id.contains('college') || league.id.contains('ncaa') =>
        league.id.contains('.w.') || league.id.contains('womens-') ? 41 : 40,
      _ => 30,
    };

List<SportsGame> orderSportsGames(Iterable<SportsGame> games,
    {required bool Function(SportsGame) followed}) {
  final ranked = [
    for (final game in games)
      (
        game: game,
        followed: followed(game),
        rank: leagueDisplayPriority(game.league)
      )
  ];
  final indices = {for (var i = 0; i < ranked.length; i++) ranked[i].game: i};
  ranked.sort((a, b) {
    final rank = a.rank.compareTo(b.rank);
    if (rank != 0) return rank;
    if (a.followed != b.followed) return a.followed ? -1 : 1;
    return indices[a.game]!.compareTo(indices[b.game]!);
  });
  return [for (final entry in ranked) entry.game];
}
