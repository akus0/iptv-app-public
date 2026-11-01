import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/guide_read_tracker.dart';

void main() {
  test('dependencies include missing rows and bits across word boundaries', () {
    final tracker = GuideReadTracker()
      ..configure([for (var i = 0; i < 100; i++) '$i']);
    tracker.begin();
    for (final id in ['0', '31', '32', '99']) {
      tracker.record(id);
    }
    final evidence = tracker.finish(usesSynopsis: false)!;
    for (final id in ['0', '31', '32', '99']) {
      expect(evidence.affectedBy(tracker.changes([id]), synopsisChanged: false),
          true);
    }
    expect(
        evidence.affectedBy(tracker.changes(['1', '98']),
            synopsisChanged: false),
        false);
    expect(
        evidence.affectedBy(tracker.changes(['unknown']),
            synopsisChanged: false),
        true);
  });

  test('new synopsis evidence invalidates even a batch with no channel reads',
      () {
    final tracker = GuideReadTracker()..configure(['a']);
    tracker.begin();
    final evidence = tracker.finish(usesSynopsis: true)!;
    expect(evidence.affectedBy(tracker.changes(['a']), synopsisChanged: false),
        false);
    expect(evidence.affectedBy(tracker.changes(['a']), synopsisChanged: true),
        true);
  });

  test('eviction and catalogue replacement fail closed', () {
    final tracker = GuideReadTracker(maxBatches: 1)..configure(['a', 'b']);
    tracker.begin();
    tracker.record('a');
    final old = tracker.finish(usesSynopsis: false)!;
    tracker.begin();
    tracker.record('b');
    final recent = tracker.finish(usesSynopsis: false)!;
    expect(old.affectedBy(tracker.changes([]), synopsisChanged: false), true);
    expect(recent.affectedBy(tracker.changes(['a']), synopsisChanged: false),
        false);
    tracker.configure(['b', 'a']);
    expect(
        recent.affectedBy(tracker.changes([]), synopsisChanged: false), true);
  });

  test('unknown reads, byte limit and cancelled work cannot produce evidence',
      () {
    final tracker = GuideReadTracker()..configure(['a']);
    tracker.begin();
    tracker.record('unknown');
    expect(tracker.finish(usesSynopsis: false), isNull);
    tracker.begin();
    tracker.cancel();
    expect(tracker.finish(usesSynopsis: false), isNull);
    final bounded = GuideReadTracker(maxBytes: 4)
      ..configure([for (var i = 0; i < 33; i++) '$i']);
    bounded.begin();
    expect(bounded.finish(usesSynopsis: false), isNull);
  });
}
