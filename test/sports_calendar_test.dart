import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/utils/sports_calendar.dart';

String dateKey(DateTime day) =>
    '${day.year}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';
http.Response race(DateTime at) => http.Response(
    jsonEncode({
      'events': [
        {
          'id': 'race',
          'name': 'Test Grand Prix',
          'date': at.toUtc().toIso8601String(),
          'competitions': [
            {
              'id': 'session',
              'date': at.toUtc().toIso8601String(),
              'competitors': []
            }
          ]
        }
      ]
    }),
    200);

void main() {
  test(
      'local sports dates cross DST, month and year boundaries without elapsed-hour drift',
      () {
    for (final (from, offset, expected) in [
      (DateTime(2026, 4, 5), 1, DateTime(2026, 4, 6)),
      (DateTime(2026, 10, 5), -1, DateTime(2026, 10, 4)),
      (DateTime(2026, 10, 3, 23, 45), 2, DateTime(2026, 10, 5)),
      (DateTime(2026, 12, 31), 1, DateTime(2027)),
      (DateTime(2028, 3, 1), -1, DateTime(2028, 2, 29)),
    ]) {
      expect(sportsCalendarDay(from, offset), expected);
      expect(sportsCalendarDayOffset(from, expected), offset);
    }
    // Ensure the timezone-specific regression run really exercises 23/25h days.
    if (Platform.environment['TZ'] == 'Australia/Melbourne') {
      expect(DateTime(2026, 4, 6).difference(DateTime(2026, 4, 5)).inHours, 25);
      expect(
          DateTime(2026, 10, 5).difference(DateTime(2026, 10, 4)).inHours, 23);
    }
  });

  test(
      'score requests cover three distinct neighbouring calendar dates at DST changes',
      () async {
    for (final day in [DateTime(2026, 4, 5), DateTime(2026, 10, 5)]) {
      final dates = <String?>[];
      final service = SportsService.withClient(MockClient((request) async {
        dates.add(request.url.queryParameters['dates']);
        return http.Response('{"events":[]}', 200);
      }));
      await service.gamesForDay([sportsLeagueById('nhl')!], day);
      expect(
          dates,
          unorderedEquals([
            dateKey(day),
            dateKey(DateTime(day.year, day.month, day.day - 1)),
            dateKey(DateTime(day.year, day.month, day.day + 1)),
          ]));
      expect(dates.toSet(), hasLength(3));
    }
  });

  test(
      'next-event windows are date-specific and identical callers share a request',
      () async {
    final ranges = <String?>[];
    final gate = Completer<void>();
    final firstDay = DateTime(2026, 4, 1);
    final laterDay = DateTime(2026, 10, 1);
    final firstRace = DateTime(2026, 4, 10, 12),
        laterRace = DateTime(2026, 10, 10, 12);
    final service = SportsService.withClient(MockClient((request) async {
      final range = request.url.queryParameters['dates'];
      ranges.add(range);
      await gate.future;
      return race(range!.startsWith('20260401') ? firstRace : laterRace);
    }));
    final league = sportsLeagueById('racing.f1')!;
    final first = service.nextGameStart(league, firstDay);
    final duplicate = service.nextGameStart(league, firstDay);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(ranges, ['20260401-20260531']);
    gate.complete();
    expect(await first, firstRace);
    expect(await duplicate, firstRace);
    expect(await service.nextGameStart(league, laterDay), laterRace);
    expect(ranges, ['20260401-20260531', '20261001-20261130']);
    expect(await service.nextGameStart(league, firstDay), firstRace);
    expect(ranges, hasLength(2));
  });

  test(
      'next-game lookups share the scoreboard concurrency limit and recover after failure',
      () async {
    final gate = Completer<void>(), sixStarted = Completer<void>();
    var requests = 0, active = 0, peak = 0;
    var failNext = true;
    final service = SportsService.withClient(MockClient((request) async {
      requests++;
      peak = max(peak, ++active);
      if (requests == 6) sixStarted.complete();
      await gate.future;
      active--;
      if (request.url.path.contains('/racing/')) {
        if (failNext) return http.Response('offline', 503);
        return race(DateTime(2026, 10, 10, 12));
      }
      return http.Response('{"events":[]}', 200);
    }));
    final day = DateTime(2026, 10, 5);
    final loading = service
        .gamesForDay([sportsLeagueById('nhl')!, sportsLeagueById('nfl')!], day);
    await sixStarted.future;
    final league = sportsLeagueById('racing.f1')!;
    final next = service.nextGameStart(league, day);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requests, 6, reason: 'next-game lookup waits for an existing slot');
    gate.complete();
    await loading;
    expect(await next, isNull);
    expect(peak, lessThanOrEqualTo(6));
    expect(service.lastError, isNull,
        reason: 'next-game errors do not replace score status');
    failNext = false;
    expect(
        await service.nextGameStart(league, day), DateTime(2026, 10, 10, 12));
    expect(requests, 8);
  });
}
