import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/utils/replay_event_date.dart';

ReplayEventDate? date(String title, String description) =>
    replayEventDate(EpgProgram(
        channelId: 'test',
        title: title,
        description: description,
        start: DateTime.utc(2026, 10, 22),
        stop: DateTime.utc(2026, 10, 22, 2)));

void main() {
  test('structured event subtitle years stay coarse and reject narrative years',
      () {
    expect(date('NHRA Drag Racing', '1993: World Finals\nFrom Pomona.')?.year,
        1993);
    expect(date('NHRA Drag Racing', '1993: World Finals\nFrom Pomona.')?.day,
        isNull);
    expect(
        date('Cyprus II', 'S2022 E25 — Main Event\nFinal table.')?.year, 2022);
    expect(date('Poker', 'S05 E49 — Cash Game')?.year, isNull);
    expect(date('Golf', 'The 2025 winner returns in 2026.'), isNull);
    expect(date('Poker', r'$2020: Cash Game'), isNull);
    expect(date('Racing', '2029: Future race'), isNull);
    expect(date('Racing 2026', '2025: Previous race')?.year, 2026);
  });
  test('poker buy-ins are not event years', () {
    expect(date(r'Poker Masters $2000 NL Holdem Final Table', ''), isNull);
    expect(date(r'WSOP $2000 Final Table 2025', '')?.year, 2025);
    expect(date('Poker €2020 Final', ''), isNull);
  });
  test(
      'date ranges separate precise recent dates, older seasons and uncertain dates',
      () {
    final now = DateTime.utc(2026, 10, 22);
    final recent = date('Football: A v B', 'From Oct. 21, 2026.');
    final old = date('Football: A v B', 'From Sep. 10, 2026.');
    final season = date('Football 2016/17: A v B', '');
    final currentSeason = date('Football 2026/27: A v B', '');
    expect(replayDateInRange(recent, ReplayDateRange.recent, now), true);
    expect(replayDateInRange(old, ReplayDateRange.recent, now), false);
    expect(replayDateInRange(season, ReplayDateRange.older, now), true);
    expect(
        replayDateInRange(currentSeason, ReplayDateRange.unknown, now), true);
    expect(replayDateInRange(null, ReplayDateRange.unknown, now), true);
    final possible = ReplayEventDate(
        ReplayDatePrecision.day, '21 Oct 2026', 'Possible',
        day: DateTime.utc(2026, 10, 21), isPossible: true);
    expect(replayDateInRange(possible, ReplayDateRange.recent, now), false);
    expect(replayDateInRange(possible, ReplayDateRange.unknown, now), true);
  });

  test('recent covers four weeks with an exact boundary', () {
    final now = DateTime.utc(2026, 10, 22);
    expect(
        replayDateInRange(date('Football: A v B', 'From Oct. 1, 2026.'),
            ReplayDateRange.recent, now),
        true);
    expect(
        replayDateInRange(date('Football: A v B', 'From Sep. 25, 2026.'),
            ReplayDateRange.recent, now),
        true);
    expect(
        replayDateInRange(date('Football: A v B', 'From Sep. 24, 2026.'),
            ReplayDateRange.older, now),
        true);
    expect(
        replayDateInRange(date('Football: A v B', 'From Sep. 24, 2026.'),
            ReplayDateRange.recent, now),
        false);
  });
  test('additional date formats use explicit years and preserve ambiguity', () {
    expect(date('Gala de Boxe, 4 juin 2026', '')?.label, '4 Jun 2026');
    expect(date('Football: A v B, 16.10.2026', '')?.label, '16 Oct 2026');
    expect(date('Football: A v B', 'From 16-10-2026.')?.label, '16 Oct 2026');
    expect(date('ATP 2025 Final: Cincinnati', 'From 23 August.')?.label,
        '23 Aug 2025');
    expect(date('ATP Final: Cincinnati', 'From 23 August.')?.year, isNull);
    expect(date('Football 2025-26: A v B', '')?.label, '2025/26 season');
    expect(date('Football 2025-2026: A v B', '(Soccer) - 2026-05-17')?.label,
        '17 May 2026');
    expect(date('Football: A v B', 'From 03.04.2026.'), isNull);
  });
  test(
      'synopsis programme dates cannot overwrite a conflicting title year or season',
      () {
    expect(
        date('Boxing: 2019: Ruiz vs Joshua II', '(Boxing) - 2026-10-21')?.label,
        '2019');
    expect(date('SPFL 16/17: Rangers v Celtic', '(Soccer) - 20261021')?.label,
        '2016/17 season');
    expect(
        date('Boxing: 2019: Ruiz vs Joshua II', 'From Oct. 21, 2026.')?.label,
        '2019');
    expect(date('LaLiga 2025/26: A v B', '(Soccer) - 2026-05-17')?.label,
        '17 May 2026');
  });
  test('additional observed guide formats preserve source and uncertainty', () {
    expect(date("PL Greatest: West Ham/Man Utd '11", '')?.label, '2011');
    expect(
        date("PL Greatest: West Ham/Man Utd '11",
                'Relive the match in the 2010-11 season.')
            ?.label,
        '2010/11 season');
    expect(date('Football: A v B, 17 October 2026', '')?.label, '17 Oct 2026');
    expect(
        date('PL: Manchester City vs Ipswich', 'Premier League. - 20261021')
            ?.label,
        '21 Oct 2026');
    final yesterday = date('Racing Replay',
        "Another chance to watch yesterday's racing action from Newmarket.")!;
    expect(yesterday.label, '21 Oct 2026');
    expect(yesterday.isPossible, true);
    expect(yesterday.sortKey, isNull);
    expect(date('Racing Replay', 'He won yesterday but this is a classic.'),
        isNull);
  });
  test('explicit original date wins over conflicting provider programme date',
      () {
    final value = date('Big 12 Basketball Replay: Texas Tech vs. Arizona',
        'From Feb. 14, 2026. (Basketball) - 2026-02-28')!;
    expect(value.label, '14 Feb 2026');
    expect(value.isGuideDate, false);
    expect(value.day, DateTime.utc(2026, 2, 14));
    expect(
        date('Predator Pro Billiard Series: Indonesia',
                'Final: Spain vs. Philippines from Oct. 5, 2026. (Billiards) - 2026-10-21')
            ?.day,
        DateTime.utc(2026, 10, 5));
    expect(
        date('Gala de Boxe, 4 juin 2026',
                'Présentation du combat. (Boxing) - 2026-06-04')
            ?.day,
        DateTime.utc(2026, 6, 4));
  });
  test(
      'synopsis dates support month names, ordinals, ISO and unambiguous numbers',
      () {
    for (final text in [
      'From Oct. 16, 2026.',
      'Played on 16 October 2026.',
      'Full game replay from October 16th, 2026.',
      'From 2026-10-16.',
      'From 10/16/2026.',
      'From 16/10/2026.'
    ]) {
      expect(date('Football: Vanden vs. Vacaville', text)?.day,
          DateTime.utc(2026, 10, 16),
          reason: text);
    }
  });
  test(
      'provider footer is labelled as guide date, not claimed as verified event date',
      () {
    final value = date('College Football: Louisville at Syracuse',
        'Week 7. (Football) - 2026-10-17')!;
    expect(value.label, '17 Oct 2026');
    expect(value.isGuideDate, true);
    expect(value.ageLabel(DateTime(2026, 10, 22)), '5 days ago');
  });
  test('partial dates never invent a year or a recent age', () {
    for (final text in [
      'Full match replay from 23 August.',
      'From Aug. 23.',
      'Tiafoe meets Fils. (23.08)'
    ]) {
      final value = date('ATP Final: Cincinnati', text)!;
      expect(value.label, '23 Aug · year not listed');
      expect(value.precision, ReplayDatePrecision.monthDay);
      expect(value.sortKey, isNull);
      expect(value.ageLabel(DateTime(2026, 10, 22)), isNull);
    }
  });
  test(
      'season and year keep their precision, including active cross-year season',
      () {
    expect(date('SPFL 16/17: Rangers v Celtic', '')?.label, '2016/17 season');
    expect(
        date('Ashes Classic: 2006/07 2nd Test', '')?.label, '2006/07 season');
    expect(
        date('Classic Match',
                'CHE v TOT. Classic Match from the 2015/2016 season.')
            ?.label,
        '2015/16 season');
    final season = date('LaLiga 2025/26: Barcelona vs. Madrid', '')!;
    expect(season.label, '2025/26 season');
    expect(season.day, isNull);
    expect(date('Boxing: 2019: Ruiz vs. Joshua II', '')?.label, '2019');
  });
  test(
      'no arbitrary historical dates, generic series dates, impossible or future dates',
      () {
    for (final text in [
      'Their previous meeting was from Oct. 16, 2026.',
      'Watch A vs B and their previous meeting from Oct. 16, 2026.',
      'The club was founded in 1902.',
      'From 03/04/2026.',
      'From Feb. 30, 2026.',
      'From Oct. 23, 2026.',
      'From February 29, 2025.',
      'Tennis final. (08.09)',
      'From Octopus 16, 2026.',
      '(Football) - 2019'
    ]) {
      expect(date('Football: A v B', text), isNull, reason: text);
    }
    expect(date('Postseason Replay', '(Baseball) - 2022-10-08'), isNull);
    expect(date('Football: A v B 2027-01-12', ''), isNull);
  });
  test('recent labels use calendar dates and older events retain exact date',
      () {
    final value = date('Football: A v B', 'From Oct. 21, 2026.')!;
    expect(value.ageLabel(DateTime(2026, 10, 21, 23)), 'Today');
    expect(value.ageLabel(DateTime(2026, 10, 22, 0, 1)), 'Yesterday');
    expect(value.ageLabel(DateTime(2026, 10, 20)), isNull);
    expect(value.ageLabel(DateTime(2026, 12, 22)), '2 months ago');
    expect(value.ageLabel(DateTime(2028, 12, 22)), '2 years ago');
  });
  test('recent order keeps undated and yearless events behind dated events',
      () {
    final entries = [
      date('Football: A v B', 'From 23 August.'),
      date('Football: 1997: A v B', ''),
      date('Football: A v B', 'From Oct. 21, 2026.'),
      date('Football: 2016/17 A v B', ''),
      date('Football: A v B', ''),
    ]..sort((a, b) => (b?.sortKey ?? -1).compareTo(a?.sortKey ?? -1));
    expect(entries.take(3).map((e) => e!.label),
        ['21 Oct 2026', '2016/17 season', '1997']);
    expect(entries.skip(3).every((e) => e?.sortKey == null), true);
    expect(date('LaLiga 2026/27: A v B', '')!.sortKey,
        lessThan(date('Football: A v B', 'From Oct. 21, 2026.')!.sortKey!));
  });
}
