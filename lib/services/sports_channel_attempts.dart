import '../models/sports.dart';
import 'sports_channel_matcher.dart';

/// Session-only viewing history. Trying a stream is not evidence that it
/// carries the event, so this never changes matching scores or saved picks.
class SportsChannelAttempts {
  SportsChannelAttempts({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  static final shared = SportsChannelAttempts();
  final DateTime Function() _clock;
  final _events = <String, (DateTime, DateTime, Set<String>)>{};

  String _key(SportsGame game) => SportsChannelPicks.eventKey(game);

  void _prune() {
    final now = _clock();
    _events.removeWhere((_, entry) =>
        now.isBefore(entry.$1) ||
        now.difference(entry.$1) >= const Duration(hours: 12));
  }

  Set<String> forGame(SportsGame game) {
    _prune();
    final entry = _events[_key(game)];
    return Set.unmodifiable(entry != null &&
            entry.$2.difference(game.start).abs() < const Duration(hours: 12)
        ? entry.$3
        : const <String>{});
  }

  void record(SportsGame game, String channelId) {
    _prune();
    final key = _key(game);
    final ids = Set<String>.of(forGame(game));
    _events.remove(key);
    ids.remove(channelId);
    ids.add(channelId);
    if (ids.length > 128) ids.remove(ids.first);
    _events[key] = (_clock(), game.start, ids);
    while (_events.length > 80) {
      _events.remove(_events.keys.first);
    }
  }
}
