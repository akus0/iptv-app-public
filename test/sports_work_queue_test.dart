import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/sports_work_queue.dart';

void main() {
  test('interactive work follows the active task but precedes queued refreshes',
      () async {
    final queue = SportsWorkQueue(), gate = Completer<void>();
    final order = <String>[];
    final active = queue.run(() async {
      await gate.future;
      order.add('active');
    });
    final refresh = queue.run(() async => order.add('refresh'));
    final picker =
        queue.run(() async => order.add('picker'), interactive: true);
    gate.complete();
    await Future.wait([active, refresh, picker]);
    expect(order, ['active', 'picker', 'refresh']);
  });

  test('interactive requests cannot cross a catalogue preparation barrier',
      () async {
    final queue = SportsWorkQueue(), gate = Completer<void>();
    final order = <String>[];
    final jobs = [
      queue.run(() => gate.future),
      queue.run(() async => order.add('old catalogue')),
      queue.run(() async => order.add('prepare'), barrier: true),
      queue.run(() async => order.add('new catalogue'), interactive: true),
    ];
    gate.complete();
    await Future.wait(jobs);
    expect(order, ['old catalogue', 'prepare', 'new catalogue']);
  });

  test('rapid user actions do not starve background work or overlap jobs',
      () async {
    final queue = SportsWorkQueue(), gate = Completer<void>();
    final order = <String>[];
    var running = false;
    Future<void> work(String id) async {
      expect(running, false);
      running = true;
      await Future<void>.delayed(Duration.zero);
      order.add(id);
      running = false;
    }

    final jobs = [
      queue.run(() => gate.future),
      queue.run(() => work('refresh'))
    ];
    for (var i = 0; i < 8; i++) {
      jobs.add(queue.run(() => work('picker$i'), interactive: true));
    }
    gate.complete();
    await Future.wait(jobs);
    expect(order.indexOf('refresh'), 3);
    expect(order.where((id) => id.startsWith('picker')),
        List.generate(8, (i) => 'picker$i'));
  });

  test('a failed request does not poison the queue', () async {
    final queue = SportsWorkQueue();
    await expectLater(
        queue.run(() async => throw StateError('failed')), throwsStateError);
    expect(await queue.run(() async => 42), 42);
  });
}
