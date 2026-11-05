/// Remote repeat policy. No autonomous scrolling or queued repeat backlog:
/// only incoming key repeats advance, at most ten updates per second.
class GuideScrollAcceleration {
  int? _direction;
  Duration? _started, _lastMove;

  int? get direction => _direction;

  int step(int direction, Duration stamp,
      {required bool repeat, required int count}) {
    if (!repeat ||
        _direction != direction ||
        _started == null ||
        stamp < _lastMove!) {
      _direction = direction;
      _started = _lastMove = stamp;
      return direction;
    }
    if (stamp - _lastMove! < const Duration(milliseconds: 100)) return 0;
    _lastMove = stamp;
    final elapsed = (stamp - _started!).inMilliseconds;
    final stride = switch (elapsed) {
      < 5000 => 1,
      < 7000 => 3,
      < 9000 => 8,
      < 11000 => 20,
      < 14000 => 50,
      _ => (count ~/ 400).clamp(50, 200),
    };
    return direction * stride;
  }

  void reset() {
    _direction = null;
    _started = _lastMove = null;
  }
}
