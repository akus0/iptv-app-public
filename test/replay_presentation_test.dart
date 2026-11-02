import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/replay_presentation.dart';
import 'package:nox_iptv/widgets/sports_replays_panel.dart'
    show replayTitleParts;

void main() {
  test(
      'event subtitles distinguish racing sessions and recorded poker episodes',
      () {
    expect(
        replayTitleParts('NHRA Drag Racing', 'racing',
            description: '1993: World Finals\nFrom Pomona.'),
        (competition: 'NHRA Drag Racing', title: 'World Finals'));
    expect(
        replayTitleParts('Poker After Dark', 'poker',
            description:
                'S05 E49 — Week 9: Top Guns Cash Game #2\nPoker players compete.'),
        (
          competition: 'Poker After Dark',
          title: 'Week 9: Top Guns Cash Game #2'
        ));
    expect(
        replayTitleParts('World Poker Tour: Season 10', 'poker',
                description:
                    'Bay 101 Shooting Star - Part 2\nPoker players compete.')
            .title,
        'Bay 101 Shooting Star - Part 2');
    expect(replayEventSubtitle('2025 was a memorable year for the winner.'),
        isNull);
    expect(replayEventSubtitle('2025: Next event'), isNull);
    expect(
        replayTitleParts('NBA: A v B', 'basketball',
                description: '2025: A different game\nSome prose.')
            .title,
        'A v B');
  });
  test('league initials require the right sport and explicit competition', () {
    expect(replayLeagueInitials('soccer', 'AFC Champions League'), isNull);
    expect(
        replayLeagueInitials('soccer', 'Champions League highlights'), isNull);
    expect(replayLeagueInitials('soccer', 'Egyptian Premier League'), isNull);
    expect(replayLeagueInitials('soccer', 'UEFA Champions League'), 'UCL');
    expect(replayLeagueInitials('basketball', 'NBA: Boston v New York'), 'NBA');
    expect(replayLeagueInitials('basketball', 'WNBA Finals'), 'WNBA');
    expect(replayLeagueInitials('soccer', 'Women’s Premier League'), isNull);
    expect(replayLeagueInitials('soccer', 'U19 Premier League'), isNull);
    expect(replayLeagueInitials('basketball', 'NCAA Basketball'), isNull);
    expect(
        replayLeagueInitials('cricket', 'Premier League highlights'), isNull);
    expect(replayLeagueInitials('golf', 'PGA Championship'), isNull);
    expect(replayLeagueInitials('golf', 'LPGA Tour'), 'LPGA');
    expect(replayLeagueInitials('tennis', 'Wimbledon'), isNull);
    expect(replayLeagueInitials('basketball', 'Boston v New York'), isNull);
  });
  test('highlight headings split explicit leagues without inventing a fixture',
      () {
    expect(
        replayTitleParts('A-League: Phoenix v Melbourne City Hls', 'soccer',
                highlights: true)
            .title,
        'Phoenix v Melbourne City Highlights');
    final split = replayTitleParts('NBA: Tonight’s best moments', 'basketball',
        highlights: true, description: 'Boston v New York from last season.');
    expect(split, (competition: 'NBA', title: 'Tonight’s best moments'));
    expect(
        replayTitleParts('On the Fly', 'hockey',
            highlights: true,
            description: 'Toronto v Boston from last season.'),
        (competition: 'Hockey', title: 'On the Fly'));
    expect(
        replayTitleParts('Boston — New York', 'basketball', highlights: true)
            .title,
        'Boston — New York');
  });
  test('observed league aliases keep their competition priorities', () {
    expect(
        replayLeaguePriority('soccer', 'Super Lig 2026/27: A v B', null), 18);
    expect(replayLeaguePriority('rugby', 'EPCR Challenge Cup: A v B', null), 6);
  });
  test('provider genres are cleaned without deleting fixture qualifiers', () {
    expect(
        replaySynopsisForDisplay(
            'From Oct. 21, 2026. (Basketball, Sports) - 2026-10-22'),
        'From Oct. 21, 2026.');
    expect(replaySynopsisForDisplay('Full match. (Basketball, Sports)'),
        'Full match.');
    expect(replaySynopsisForDisplay('Full match. (First leg)'),
        'Full match. (First leg)');
    expect(
        replaySynopsisForDisplay('ATP Final. (23.08)'), 'ATP Final. (23.08)');
    expect(replaySynopsisForDisplay('A v B (Women)'), 'A v B (Women)');
  });
  test('search folds accents but retains non-Latin team names', () {
    expect(replaySearchText('Atlético–Mineiro / FÚTBOL'),
        'atletico mineiro futbol');
    expect(replaySearchText('東京 v 大阪'), '東京 v 大阪');
    expect(replaySearchText('    '), '');
  });
  test(
      'archive introductions reveal opponents and condensed editions stay explicit',
      () {
    expect(
        replaySynopsisMatch('EFL Play-Off Final: League 1 13/14',
            'A look back at some classic Football League play-off finals from years gone by. Here, Leyton Orient face Rotherham United at Wembley in the League One play-off final in 2014.'),
        'Leyton Orient face Rotherham United');
    expect(isCondensedReplay('Raptors in 30: Chicago at Toronto', null), true);
    expect(isCondensedReplay('NBA: Chicago at Toronto', 'A full game replay.'),
        false);
  });
  test('extracts guide opponents without splitting vs. or borrowing history',
      () {
    expect(
        replaySynopsisMatch('Predator Pro Billiard Series: Indonesia',
            'Final: Spain vs. Philippines from Oct. 5, 2026. (Billiards)'),
        'Spain vs. Philippines');
    expect(
        replaySynopsisMatch('ATP Final: Cincinnati',
            'Frances Tiafoe returns to the Cincinnati final two years on from his last appearance as he meets an in-form Arthur Fils. This match guarantees a first-time Masters champion.'),
        'Frances Tiafoe v Arthur Fils');
    expect(
        replaySynopsisMatch(
            'WBBL', 'Sydney Thunder face Perth Scorchers in the final.'),
        'Sydney Thunder face Perth Scorchers');
    expect(
        replaySynopsisMatch('A-League Men Replay',
            'Coverage from Round 1 of the A-League Men between the Wellington Phoenix and Melbourne Victory at Hnry Stadium, Wellington.'),
        'Wellington Phoenix v Melbourne Victory');
    expect(
        replaySynopsisMatch(
            'NBA: Boston v New York', 'Replay of Miami v Chicago.'),
        isNull);
    expect(
        replaySynopsisMatch(
            'Tennis Replay', 'Their previous meeting was Nadal v Federer.'),
        isNull);
    expect(
        replaySynopsisMatch('Postseason Replay',
            'Relive great games from this year’s postseason.'),
        isNull);
  });
  test('non-fixture conversations do not become matchups', () {
    expect(
        replaySynopsisMatch('Replay',
            'A discussion between the coach and the referee at the stadium.'),
        isNull);
  });
  test('league order respects sport and distinct divisions', () {
    int rank(String sport, String title) =>
        replayLeaguePriority(sport, title, null);
    expect(rank('soccer', 'UCL: Club Brugge v Lens'),
        lessThan(rank('soccer', 'PL: A v B')));
    expect(
        rank('soccer', 'PL: A v B'), lessThan(rank('soccer', 'LaLiga: A v B')));
    expect(rank('soccer', 'LaLiga: A v B'),
        lessThan(rank('soccer', 'Women’s World Cup: A v B')));
    expect(rank('soccer', 'Women’s World Cup: A v B'),
        lessThan(rank('soccer', 'FIFA U-17 Women’s World Cup')));
    expect(rank('basketball', 'NBA: A v B'),
        lessThan(rank('basketball', 'WNBA: A v B')));
    expect(rank('football', 'NFL: A v B'),
        lessThan(rank('football', 'College Football: A v B')));
    expect(rank('football', 'College Football: A v B'),
        lessThan(rank('football', 'High School Football: A v B')));
    expect(rank('tennis', 'ATP Final'), lessThan(rank('tennis', 'WTA Final')));
    expect(rank('racing', 'Formula 1: Australian Grand Prix'),
        lessThan(rank('racing', 'IndyCar: A')));
    expect(rank('cricket', 'Ashes Classic'),
        lessThan(rank('cricket', 'Sheffield Shield')));
    expect(rank('soccer', 'Unknown League: A v B'), 30);
  });
}
