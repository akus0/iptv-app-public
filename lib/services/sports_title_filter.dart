import 'dart:async';
import 'dart:isolate';
import '../utils/sports_title_matcher.dart';

/// CPU-only filtering of bounded title batches. Database cursors and writes
/// stay with their owner. A failed worker uses the identical local matcher.
class SportsTitleFilter {
  _TitleWorker? _worker;
  Timer? _idle;
  int _active = 0;

  Future<List<String>> matches(List<String> terms, List<String> titles) async {
    if (titles.isEmpty) return const [];
    if (titles.length < 64) return _local(terms, titles);
    _idle?.cancel();
    _active++;
    final worker = _worker ??= _TitleWorker();
    try {
      return await worker.matches(terms, titles);
    } catch (_) {
      worker.close();
      if (identical(_worker, worker)) _worker = null;
      return await _local(terms, titles);
    } finally {
      if (--_active == 0 && _worker != null) {
        _idle = Timer(const Duration(seconds: 30), dispose);
      }
    }
  }

  void dispose() {
    _idle?.cancel();
    _idle = null;
    _worker?.close();
    _worker = null;
  }
}

Future<List<String>> _local(List<String> terms, List<String> titles) async {
  final matcher = SportsTitleMatcher(terms);
  final result = <String>[];
  final slice = Stopwatch()..start();
  for (final title in titles) {
    if (matcher.matches(title)) result.add(title);
    if (slice.elapsedMilliseconds >= 2) {
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
  }
  return result;
}

class _TitleWorker {
  _TitleWorker() {
    // Install an error listener before spawning: disposal or an early isolate
    // failure can happen before a request starts awaiting the handshake.
    unawaited(_ready.future.then<void>((_) {}, onError: (Object _) {}));
    _messages.listen((dynamic message) {
      if (_closed) return;
      if (message is SendPort) {
        if (!_ready.isCompleted) _ready.complete(message);
      } else if (message is (int, List<String>)) {
        _pending.remove(message.$1)?.complete(message.$2);
      }
    });
    _errors.listen((_) => close());
    unawaited(Isolate.spawn(_filterTitles, _messages.sendPort,
            onError: _errors.sendPort,
            onExit: _errors.sendPort,
            debugName: 'Guide title filtering')
        .then<void>((isolate) {
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    }, onError: (Object _) => close()));
  }

  final _messages = ReceivePort();
  final _errors = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<List<String>>>{};
  Isolate? _isolate;
  bool _closed = false;
  int _sequence = 0;

  Future<List<String>> matches(List<String> terms, List<String> titles) async {
    final send = await _ready.future.timeout(const Duration(seconds: 10));
    if (_closed) throw StateError('Title filter closed');
    final id = ++_sequence;
    final done = Completer<List<String>>();
    _pending[id] = done;
    send.send((id, terms, titles));
    return done.future.timeout(const Duration(seconds: 30));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final error = StateError('Title filter unavailable');
    _isolate?.kill(priority: Isolate.immediate);
    _messages.close();
    _errors.close();
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final done in _pending.values) {
      done.completeError(error);
    }
    _pending.clear();
  }
}

void _filterTitles(SendPort reply) {
  final receive = ReceivePort();
  reply.send(receive.sendPort);
  final textCache = SportsTitleTextCache();
  List<String>? previous;
  SportsTitleMatcher? matcher;
  receive.listen((dynamic message) {
    final (id, terms, titles) = message as (int, List<String>, List<String>);
    if (previous == null ||
        previous!.length != terms.length ||
        !Iterable.generate(terms.length)
            .every((i) => previous![i] == terms[i])) {
      previous = terms;
      // Bulk checks amortise table construction off the UI thread. Small local
      // checks and worker failures retain the original sparse matcher.
      matcher = SportsTitleMatcher(terms,
          textCache: textCache, precomputeTransitions: true);
    }
    reply.send((id, titles.where(matcher!.matches).toList()));
  });
}
