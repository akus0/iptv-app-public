import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/bounded_index_cache.dart';

class _Index {
  _Index(this.rows, {this.generation = 1});
  int rows;
  final int generation;
}

void main() {
  late BoundedIndexCache<_Index> cache;
  setUp(() =>
      cache = BoundedIndexCache(costOf: (index) => index.rows, maxCost: 100));

  test('small tail batches retain the expensive index and the latest index',
      () {
    final large = _Index(60);
    cache.retain(large);
    for (var i = 1; i <= 20; i++) {
      final tail = _Index(i);
      cache.retain(tail);
      expect(cache.values.toList(), [large, tail]);
    }
  });

  test('longest compatible prefix wins independently of insertion order', () {
    final short = _Index(10), long = _Index(60);
    cache.retain(short);
    cache.retain(long);
    expect(cache.largestWhere((_) => true), same(long));
    expect(cache.largestWhere((i) => i.rows < 50), same(short));
    expect(cache.largestWhere((i) => i.generation == 2), isNull);
  });

  test('reserve releases storage before growing an index', () {
    final growing = _Index(10), large = _Index(60);
    cache.retain(growing);
    cache.retain(large);
    cache.reserve(growing, 80);
    expect(cache.values, isEmpty);
    growing.rows = 80;
    cache.retain(growing);
    expect(cache.values.toList(), [growing]);
  });

  test('replacement respects storage budget even when both indexes are large',
      () {
    cache.retain(_Index(60));
    final next = _Index(70);
    cache.retain(next);
    expect(cache.values.toList(), [next]);
  });

  test('oversized index is not retained or counted twice', () {
    final index = _Index(60);
    cache.retain(index);
    cache.retain(index);
    expect(cache.values.toList(), [index]);
    cache.reserve(index, 101);
    index.rows = 101;
    cache.retain(index);
    expect(cache.values, isEmpty);
  });

  test('guide generation changes discard all obsolete postings', () {
    cache.retain(_Index(60));
    final current = _Index(20, generation: 2);
    cache.retain(current);
    cache.removeWhere((i) => i.generation != 2);
    expect(cache.values.toList(), [current]);
    cache.clear();
    expect(cache.values, isEmpty);
  });
}
