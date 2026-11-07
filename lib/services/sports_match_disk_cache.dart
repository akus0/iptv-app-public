import 'dart:async';
import 'dart:convert';
import 'dart:io';

class StoredSportsMatch {
  StoredSportsMatch(this.rows, this.savedAt, this.expiresAt);
  final List<dynamic> rows;
  final DateTime savedAt, expiresAt;
}

/// Small derived-data cache. Production reads/encoding run in the matching
/// isolate; keys fingerprint the catalogue, guide and fixture, never URLs.
class SportsMatchDiskCache {
  SportsMatchDiskCache(this.file);
  final File file;
  static const maxBytes = 2 * 1024 * 1024;
  static const maxEntries = 512;
  final _entries = <String, StoredSportsMatch>{};
  bool _loaded = false, _dirty = false;
  Future<void>? _writing;

  Future<void> load(DateTime now) async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await file.exists() || await file.length() > maxBytes) return;
      final data = jsonDecode(await file.readAsString()) as Map;
      if (data['version'] != 1) return;
      final entries = data['entries'] as Map;
      if (entries.length > maxEntries) return;
      for (final entry in entries.entries) {
        final value = entry.value as Map;
        final rows = value['rows'] as List;
        if (rows.length > 32) continue;
        final record = StoredSportsMatch(
            rows,
            DateTime.fromMillisecondsSinceEpoch(value['saved'] as int),
            DateTime.fromMillisecondsSinceEpoch(value['until'] as int));
        if (_valid(record, now)) _entries[entry.key as String] = record;
      }
    } catch (_) {
      _entries.clear();
    }
  }

  bool _valid(StoredSportsMatch entry, DateTime now) =>
      !now.isBefore(entry.savedAt) &&
      now.isBefore(entry.expiresAt) &&
      now.difference(entry.savedAt) < const Duration(minutes: 5);

  StoredSportsMatch? read(String key, DateTime now) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (_valid(entry, now)) return entry;
    _entries.remove(key);
    return null;
  }

  void put(String key, List<dynamic> rows, DateTime now, DateTime until) {
    if (rows.length > 32 || !until.isAfter(now)) return;
    _entries.removeWhere((_, entry) => !_valid(entry, now));
    _entries.remove(key);
    _entries[key] = StoredSportsMatch(rows, now, until);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _dirty = true;
  }

  void clear() {
    _loaded = true;
    _entries.clear();
    _dirty = true;
    unawaited(flush());
  }

  /// Coalesce progressive batches; never write once per event or UI frame.
  Future<void> flush() =>
      _writing ??= _flush().whenComplete(() => _writing = null);

  Future<void> _flush() async {
    while (_dirty) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      _dirty = false;
      try {
        final entries = <String, dynamic>{};
        var bytes = 64;
        for (final entry in _entries.entries.toList().reversed) {
          final value = {
            'rows': entry.value.rows,
            'saved': entry.value.savedAt.millisecondsSinceEpoch,
            'until': entry.value.expiresAt.millisecondsSinceEpoch,
          };
          bytes += utf8.encode(jsonEncode({entry.key: value})).length + 1;
          if (bytes > maxBytes) break;
          entries[entry.key] = value;
        }
        final temp = File('${file.path}.tmp');
        await temp
            .writeAsString(jsonEncode({'version': 1, 'entries': entries}));
        await temp.rename(file.path);
      } catch (_) {
        // A cache failure must never interrupt playback or matching.
      }
    }
  }
}
