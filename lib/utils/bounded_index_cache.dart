/// Retain the latest index and the most expensive reusable indexes that fit.
/// Costs represent retained storage, not time or cached matching decisions.
class BoundedIndexCache<T> {
  BoundedIndexCache(
      {required this.costOf, required this.maxCost, this.maxEntries = 2})
      : assert(maxCost > 0),
        assert(maxEntries > 0);

  final int Function(T) costOf;
  final int maxCost, maxEntries;
  final _entries = <T>[];
  Iterable<T> get values => _entries;

  T? largestWhere(bool Function(T) matches) {
    T? found;
    var largest = -1;
    for (final entry in _entries) {
      final cost = costOf(entry);
      if (cost > largest && matches(entry)) {
        found = entry;
        largest = cost;
      }
    }
    return found;
  }

  void clear() => _entries.clear();
  void removeWhere(bool Function(T) predicate) =>
      _entries.removeWhere(predicate);

  // Release storage before a growing/replacement index allocates its postings.
  // The caller owns this index until retain(), including oversized indexes.
  void reserve(T entry, int cost) {
    _entries.remove(entry);
    while (_entries.isNotEmpty && _cost + cost > maxCost) {
      _removeSmallest();
    }
  }

  void retain(T entry) {
    final cost = costOf(entry);
    reserve(entry, cost);
    if (cost > maxCost) return;
    while (_entries.length >= maxEntries) {
      _removeSmallest();
    }
    _entries.add(entry);
  }

  int get _cost => _entries.fold(0, (total, entry) => total + costOf(entry));

  void _removeSmallest() {
    var at = 0;
    for (var i = 1; i < _entries.length; i++) {
      if (costOf(_entries[i]) < costOf(_entries[at])) at = i;
    }
    _entries.removeAt(at);
  }
}
