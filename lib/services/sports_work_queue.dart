import 'dart:async';
import 'dart:collection';

/// Serial ownership of the matcher, with bounded priority for user actions.
/// Catalogue changes are barriers: no request can overtake its preparation.
class SportsWorkQueue {
  final _pending = ListQueue<_SportsWork>();
  bool _draining = false;
  int _interactiveStreak = 0;

  Future<T> run<T>(Future<T> Function() action,
      {bool interactive = false, bool barrier = false}) {
    final result = Completer<T>();
    _pending.add(_SportsWork(() async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }, interactive, barrier));
    if (!_draining) unawaited(_drain());
    return result.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        var work = _pending.first;
        if (_interactiveStreak < 3) {
          for (final candidate in _pending) {
            if (candidate.barrier) break;
            if (candidate.interactive) {
              work = candidate;
              break;
            }
          }
        }
        _pending.remove(work);
        _interactiveStreak = work.interactive ? _interactiveStreak + 1 : 0;
        await work.action();
      }
    } finally {
      _draining = false;
    }
  }
}

class _SportsWork {
  const _SportsWork(this.action, this.interactive, this.barrier);
  final Future<void> Function() action;
  final bool interactive, barrier;
}
