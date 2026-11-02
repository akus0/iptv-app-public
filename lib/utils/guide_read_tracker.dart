import 'dart:typed_data';

/// Exact channel dependencies for one completed scoring batch. Evicted tracking
/// data fails closed: its results must be rechecked after any snapshot change.
class GuideReadEvidence {
  GuideReadEvidence(this._bits, this.usesSynopsis);
  Uint32List? _bits;
  final bool usesSynopsis;

  bool affectedBy(Uint32List? changes, {required bool synopsisChanged}) {
    final bits = _bits;
    if (bits == null || changes == null || bits.length != changes.length) {
      return true;
    }
    if (usesSynopsis && synopsisChanged) return true;
    for (var i = 0; i < bits.length; i++) {
      if ((bits[i] & changes[i]) != 0) return true;
    }
    return false;
  }
}

/// Bitsets avoid retaining a separate collection of channel strings per event.
/// Several events share a batch's evidence; no programme or decision is stored.
class GuideReadTracker {
  GuideReadTracker({this.maxBatches = 64, this.maxBytes = 1024 * 1024});
  final int maxBatches, maxBytes;
  Map<String, int> _channels = {};
  final _retained = <GuideReadEvidence>[];
  int _bytes = 0;
  Uint32List? _active;
  bool _unknown = false;

  void configure(Iterable<String> channels) {
    for (final evidence in _retained) {
      evidence._bits = null;
    }
    _retained.clear();
    _bytes = 0;
    _active = null;
    _channels = {};
    for (final id in channels) {
      _channels.putIfAbsent(id, () => _channels.length);
    }
  }

  Uint32List _empty() => Uint32List((_channels.length + 31) ~/ 32);

  void begin() {
    _active = _empty();
    _unknown = false;
  }

  void cancel() => _active = null;

  void record(String id) {
    final bits = _active;
    if (bits == null) return;
    final at = _channels[id];
    if (at == null) {
      _unknown = true;
    } else {
      bits[at >> 5] |= 1 << (at & 31);
    }
  }

  GuideReadEvidence? finish({required bool usesSynopsis}) {
    final bits = _active;
    _active = null;
    if (bits == null || _unknown || bits.lengthInBytes > maxBytes) return null;
    while (_retained.isNotEmpty &&
        (_retained.length >= maxBatches ||
            _bytes + bits.lengthInBytes > maxBytes)) {
      final oldest = _retained.removeAt(0);
      _bytes -= oldest._bits!.lengthInBytes;
      oldest._bits = null;
    }
    if (maxBatches <= 0) return null;
    final evidence = GuideReadEvidence(bits, usesSynopsis);
    _retained.add(evidence);
    _bytes += bits.lengthInBytes;
    return evidence;
  }

  Uint32List? changes(Iterable<String> ids) {
    final bits = _empty();
    for (final id in ids) {
      final at = _channels[id];
      if (at == null) return null;
      bits[at >> 5] |= 1 << (at & 31);
    }
    return bits;
  }
}
