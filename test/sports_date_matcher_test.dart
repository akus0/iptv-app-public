import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/sports_date_matcher.dart';

// Previous matcher, kept as an independent oracle for the cached window.
bool original(SportsListingDate d, DateTime reference) {
  for (final offset in const [-1, 0, 1]) {
    final day = reference.add(Duration(days: offset));
    if (d.year != null && day.year != d.year) continue;
    if (day.month == d.month && day.day == d.day) return true;
    if (d.ambiguous && day.month == d.day && day.day == d.month) return true;
  }
  return false;
}

void main() {
  test('year, adjacent-day allowance and ambiguous numeric dates are retained',
      () {
    final matcher = SportsDateMatcher();
    final reference = DateTime.utc(2026, 10, 11, 12);
    expect(
        matcher.matches(
            (year: 2026, month: 10, day: 10, ambiguous: false), reference),
        isTrue);
    expect(
        matcher.matches(
            (year: 2026, month: 10, day: 12, ambiguous: false), reference),
        isTrue);
    expect(
        matcher.matches(
            (year: 2026, month: 10, day: 13, ambiguous: false), reference),
        isFalse);
    expect(
        matcher.matches(
            (year: 2025, month: 10, day: 11, ambiguous: false), reference),
        isFalse);
    expect(
        matcher.matches(
            (year: null, month: 11, day: 10, ambiguous: true), reference),
        isTrue);
    expect(
        matcher.matches(
            (year: null, month: 11, day: 10, ambiguous: false), reference),
        isFalse);
  });

  test('month, leap-year and year transitions agree for every listing date',
      () {
    final matcher = SportsDateMatcher();
    for (final reference in [
      DateTime.utc(1900, 3, 1),
      DateTime.utc(2000, 2, 29),
      DateTime.utc(2024, 3, 1),
      DateTime.utc(2026, 12, 31, 23, 59, 59),
      DateTime.utc(2027, 1, 1),
      DateTime.utc(1969, 12, 31),
    ]) {
      for (final year in [
        null,
        reference.year - 1,
        reference.year,
        reference.year + 1
      ]) {
        for (var month = 0; month <= 13; month++) {
          for (var day = 0; day <= 32; day++) {
            for (final ambiguous in [false, true]) {
              final date =
                  (year: year, month: month, day: day, ambiguous: ambiguous);
              expect(
                  matcher.matches(date, reference), original(date, reference));
            }
          }
        }
      }
    }
  });

  test(
      'UTC midnight and clock rewinds replace the window at the exact boundary',
      () {
    final matcher = SportsDateMatcher();
    for (final midnight in [DateTime.utc(1970), DateTime.utc(2026, 11, 1)]) {
      final oldest = midnight.subtract(const Duration(days: 2));
      final date = (
        year: oldest.year,
        month: oldest.month,
        day: oldest.day,
        ambiguous: false
      );
      final before = midnight.subtract(const Duration(microseconds: 1));
      expect(matcher.matches(date, before), isTrue);
      expect(matcher.matches(date, midnight), isFalse);
      expect(
          matcher.matches(date, midnight.add(const Duration(microseconds: 1))),
          isFalse);
      expect(matcher.matches(date, before), isTrue);
    }
  });

  test('local DST references retain original duration arithmetic', () {
    final matcher = SportsDateMatcher();
    for (final reference in [
      DateTime(2026, 3, 8, 23, 30),
      DateTime(2026, 11, 1, 0, 30),
      DateTime(2026, 4, 5, 0, 30),
      DateTime(2026, 10, 4, 23, 30),
    ]) {
      for (var offset = -3; offset <= 3; offset++) {
        final day = reference.add(Duration(days: offset));
        final date =
            (year: day.year, month: day.month, day: day.day, ambiguous: false);
        // Interleave UTC and local representations of the same instant.
        for (final instant in [
          reference.toUtc(),
          reference,
          reference.toUtc()
        ]) {
          expect(matcher.matches(date, instant), original(date, instant));
        }
      }
    }
  });

  test('DateTime extremes preserve successful matches and overflow behaviour',
      () {
    final matcher = SportsDateMatcher();
    Object outcome(bool Function() f) {
      try {
        return f();
      } catch (error) {
        return error.runtimeType;
      }
    }

    const limit = 8640000000000000000;
    for (final stamp in [
      -limit,
      -limit + Duration.microsecondsPerDay,
      limit - Duration.microsecondsPerDay,
      limit,
    ]) {
      final reference = DateTime.fromMicrosecondsSinceEpoch(stamp, isUtc: true);
      for (final day in [
        reference.day - 1,
        reference.day,
        reference.day + 1,
        0
      ]) {
        final date = (
          year: reference.year,
          month: reference.month,
          day: day,
          ambiguous: false
        );
        expect(outcome(() => matcher.matches(date, reference)),
            outcome(() => original(date, reference)));
      }
    }
  });

  test('random references and repeated windows match the original calculation',
      () {
    final random = Random(163);
    final matcher = SportsDateMatcher();
    for (var i = 0; i < 3000; i++) {
      final reference = DateTime.utc(
          1900 + random.nextInt(200),
          1 + random.nextInt(12),
          1 + random.nextInt(31),
          random.nextInt(24),
          random.nextInt(60));
      for (var offset = -2; offset <= 2; offset++) {
        final day = reference.add(Duration(days: offset));
        final date = (
          year: random.nextBool() ? day.year : null,
          month: day.month,
          day: day.day,
          ambiguous: random.nextBool()
        );
        expect(matcher.matches(date, reference), original(date, reference));
      }
    }
  });
}
