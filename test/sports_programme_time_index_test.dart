import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/sports_programme_time_index.dart';

// The previous hourly-set implementation is the candidate oracle. Exact
// scoring windows are intentionally narrower than these conservative buckets.
class _HourlySets {
  final hours = <int, Set<int>>{};
  final longSlots = <int>{};

  void add(DateTime start, DateTime stop, int row) {
    final first = (start.millisecondsSinceEpoch - 35 * 60000) ~/ 3600000;
    final last = stop.millisecondsSinceEpoch ~/ 3600000;
    if (last - first > 16) {
      longSlots.add(row);
      return;
    }
    for (var hour = first; hour <= last; hour++) {
      (hours[hour] ??= {}).add(row);
    }
  }

  bool contains(int row, int hour) =>
      (hours[hour]?.contains(row) ?? false) || longSlots.contains(row);
}

void main() {
  test('hour boundaries retain preview margin and inclusive stop bucket', () {
    final index = SportsProgrammeTimeIndex();
    index.add(
        DateTime.utc(2026, 10, 31, 12, 35), DateTime.utc(2026, 10, 31, 14));
    index.add(DateTime.utc(2026, 10, 31, 12, 34, 59, 999),
        DateTime.utc(2026, 10, 31, 14));
    final hour =
        DateTime.utc(2026, 10, 31, 12).millisecondsSinceEpoch ~/ 3600000;
    expect(index.containsHour(0, hour - 1), isFalse);
    expect(index.containsHour(1, hour - 1), isTrue);
    for (final row in [0, 1]) {
      expect(index.containsHour(row, hour), isTrue);
      expect(index.containsHour(row, hour + 2), isTrue);
      expect(index.containsHour(row, hour + 3), isFalse);
    }
  });

  test('long slots retain broad fallback only above sixteen hours', () {
    final index = SportsProgrammeTimeIndex();
    final start = DateTime.utc(2026, 10, 31, 0, 35);
    index.add(start, DateTime.utc(2026, 10, 31, 16, 59));
    index.add(start, DateTime.utc(2026, 10, 31, 17));
    final hour = start.millisecondsSinceEpoch ~/ 3600000;
    for (final distant in [hour - 100, hour + 100]) {
      expect(index.containsHour(0, distant), isFalse);
      expect(index.containsHour(1, distant), isTrue);
    }
  });

  test('append, malformed intervals and date extremes match hourly sets', () {
    final index = SportsProgrammeTimeIndex(), before = _HourlySets();
    final random = Random(165);
    final intervals = <(DateTime, DateTime)>[];
    for (final base in [
      -8640000000000000,
      -3600000,
      0,
      DateTime.utc(2026, 10, 31).millisecondsSinceEpoch,
      8640000000000000 - 200000000,
    ]) {
      for (var n = 0; n < 100; n++) {
        final a = base + random.nextInt(100000000);
        final b = base + random.nextInt(100000000);
        intervals.add((
          DateTime.fromMillisecondsSinceEpoch(a, isUtc: true),
          DateTime.fromMillisecondsSinceEpoch(b, isUtc: true)
        ));
      }
    }
    for (var row = 0; row < intervals.length; row++) {
      final (start, stop) = intervals[row];
      index.add(start, stop);
      before.add(start, stop, row);
      // Recheck earlier rows after appending, as a reused prefix grows.
      for (final r in {0, row ~/ 2, row}) {
        final middle = intervals[r].$1.millisecondsSinceEpoch ~/ 3600000;
        for (var delta = -40; delta <= 40; delta++) {
          expect(index.containsHour(r, middle + delta),
              before.contains(r, middle + delta),
              reason: 'row $r/$row, $delta');
        }
      }
    }
  });

  test('local and UTC views of the same instants have identical candidates',
      () {
    final utc = SportsProgrammeTimeIndex(), local = SportsProgrammeTimeIndex();
    final start = DateTime.utc(2026, 11, 1, 5, 45);
    final stop = start.add(const Duration(hours: 5));
    utc.add(start, stop);
    local.add(start.toLocal(), stop.toLocal());
    final middle = start.millisecondsSinceEpoch ~/ 3600000;
    for (var hour = middle - 10; hour < middle + 20; hour++) {
      expect(local.containsHour(0, hour), utc.containsHour(0, hour));
    }
  });
}
