import '../services/sports_replay_service.dart';

/// One current browse projection, reused across progress and preview updates.
/// Expires at programme boundaries or midnight, including when the clock moves
/// backwards. It never retains earlier snapshots or accumulates filter results.
class ReplayBrowseIndex {
  Object? _configuration;
  List<SportsReplay>? _source;
  DateTime? _computedAt, _expires;
  ReplayBrowseView? _view;

  ReplayBrowseView resolve({
    required List<SportsReplay> events,
    required Object configuration,
    required DateTime now,
    required bool Function(SportsReplay event, DateTime now) matches,
    required int Function(SportsReplay a, SportsReplay b) compare,
  }) {
    if (_view != null &&
        identical(events, _source) &&
        configuration == _configuration &&
        !now.isBefore(_computedAt!) &&
        now.isBefore(_expires!)) {
      return _view!;
    }
    final selected = <SportsReplay>[];
    var expires = DateTime(now.year, now.month, now.day + 1);
    for (final event in events) {
      for (final broadcast in event.broadcasts) {
        for (final boundary in [
          broadcast.programme.start,
          broadcast.programme.stop
        ]) {
          if (boundary.isAfter(now) && boundary.isBefore(expires)) {
            expires = boundary;
          }
        }
      }
      if (matches(event, now) &&
          event.broadcasts.any((b) => b.programme.isNowPlaying(now))) {
        selected.add(event);
      }
    }
    selected.sort(compare);
    final positions = <String, int>{};
    final counts = <String, int>{};
    final ranges = <(int, int)>[];
    for (var i = 0; i < selected.length; i++) {
      positions[selected[i].id] = i;
      counts.update(selected[i].sport, (n) => n + 1, ifAbsent: () => 1);
    }
    for (var start = 0; start < selected.length;) {
      final end = start + counts[selected[start].sport]!;
      ranges.add((start, end));
      start = end;
    }
    _source = events;
    _configuration = configuration;
    _computedAt = now;
    _expires = expires;
    return _view = ReplayBrowseView(selected, positions, counts, ranges);
  }
}

/// Comparator must group by sport first; ranges are contiguous sport sections.
class ReplayBrowseView {
  const ReplayBrowseView(this.events, this.positions, this.counts, this.ranges);
  final List<SportsReplay> events;
  final Map<String, int> positions, counts;
  final List<(int, int)> ranges;
}
