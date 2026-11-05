import '../models/sports.dart';
import 'sports_channel_matcher.dart';

/// A pass can yield between later fixtures without splitting live feed owners.
/// Stores evidence identities, not match results; changed inputs remain pending.
class SportsMatchBatchPlan {
  SportsMatchBatchPlan(
      {this.maxLaterEvents = 128, this.maxLaterSpan = const Duration(hours: 8)})
      : assert(maxLaterEvents > 0),
        assert(maxLaterSpan > Duration.zero);

  final int maxLaterEvents;
  final Duration maxLaterSpan;
  final _completed = <String, String>{};
  Map<String, String>? _orderedFor, _readyFor;
  List<SportsGame> _ordered = const [];
  bool _activeReady = false;
  Set<String> _readyKeys = const {};

  void invalidateTennis() {
    for (final game in _ordered) {
      if (game.league.kind == SportsKind.tennis) {
        _completed.remove(SportsChannelPicks.eventKey(game));
      }
    }
    _readyFor = null;
  }

  List<SportsGame> next(
      List<SportsGame> games, Map<String, String> identities, DateTime now) {
    if (!identical(identities, _orderedFor)) {
      _orderedFor = identities;
      _ordered = [...games]..sort((a, b) {
          final finished = (a.state == GameState.post ? 1 : 0)
              .compareTo(b.state == GameState.post ? 1 : 0);
          if (finished != 0) return finished;
          final time = a.start.compareTo(b.start);
          return time != 0
              ? time
              : SportsChannelPicks.eventKey(a)
                  .compareTo(SportsChannelPicks.eventKey(b));
        });
      _completed.removeWhere((key, _) => !identities.containsKey(key));
    }
    final ready = _ordered
        .where((g) => SportsChannelMatcher.isReadyToWatch(g, now))
        .toList();
    bool pending(SportsGame game) {
      final key = SportsChannelPicks.eventKey(game);
      return _completed[key] != identities[key];
    }

    // Changes elsewhere can add tournament context or remove a competing live
    // fixture. Recheck the entire live cohort, normally using existing results.
    if (ready.isNotEmpty &&
        (!identical(_readyFor, identities) ||
            ready.any(pending) ||
            ready.length != _readyKeys.length ||
            ready.any(
                (g) => !_readyKeys.contains(SportsChannelPicks.eventKey(g))))) {
      _activeReady = true;
      return ready;
    }
    _activeReady = false;
    final later = <SportsGame>[];
    for (final game in _ordered) {
      if (!pending(game)) continue;
      if (later.isNotEmpty &&
          (later.length >= maxLaterEvents ||
              game.start.difference(later.first.start).abs() > maxLaterSpan)) {
        break;
      }
      later.add(game);
    }
    return later;
  }

  void complete(List<SportsGame> batch, Map<String, String> expected) {
    for (final game in batch) {
      final key = SportsChannelPicks.eventKey(game);
      if (expected[key] case final identity?) _completed[key] = identity;
    }
    if (_activeReady) {
      _readyFor = expected;
      _readyKeys = batch.map(SportsChannelPicks.eventKey).toSet();
    }
  }
}
