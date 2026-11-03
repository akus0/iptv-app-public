/// Conservative hourly candidates for programme coverage. Exact start/stop
/// checks still belong to scoring; this index cannot establish a match.
///
/// Each row occupies a contiguous range, so retain its endpoints instead of
/// duplicating its ID in a set for every hour. Append order matches programme
/// postings, including when an unchanged prefix is extended.
class SportsProgrammeTimeIndex {
  static const _hourMs = 60 * 60 * 1000;
  static const _marginMs = 35 * 60 * 1000;
  static const _longWindowHours = 16;

  final _windows = <(int, int)>[];

  void add(DateTime start, DateTime stop) {
    // Preserve truncation toward zero, including dates before the Unix epoch.
    // The 35 minutes cover the 30-minute preview plus decision-expiry margin.
    _windows.add((
      (start.millisecondsSinceEpoch - _marginMs) ~/ _hourMs,
      stop.millisecondsSinceEpoch ~/ _hourMs
    ));
  }

  bool containsHour(int row, int hour) {
    final (first, last) = _windows[row];
    // Long slots used to bypass hourly buckets. Retain that conservative
    // fallback; scoring remains responsible for their actual time window.
    return last - first > _longWindowHours || (first <= hour && hour <= last);
  }
}
