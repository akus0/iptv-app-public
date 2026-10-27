import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/guide_scroll_acceleration.dart';

void main() {
  test('holds ramp gradually, throttle repeats, and reset on taps/reversal',
      () {
    final p = GuideScrollAcceleration();
    int step(int ms, {int dir = 1, bool repeat = true}) =>
        p.step(dir, Duration(milliseconds: ms), repeat: repeat, count: 80000);
    expect(step(0, repeat: false), 1);
    expect(step(50), 0);
    expect(step(450), 1);
    expect(step(900), 1);
    expect(step(4500), 1);
    expect(step(4999), 1);
    expect(step(5100), 3);
    expect(step(7500), 8);
    expect(step(9500), 20);
    expect(step(11500), 50);
    expect(step(14500), 200);
    expect(step(14600, dir: -1), -1);
    expect(step(14700, repeat: false), 1);
    p.reset();
    expect(step(15000), 1);
    expect(step(14000), 1, reason: 'Clock resets cannot preserve acceleration');
  });
}
