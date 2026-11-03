import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Optional memo of pure channel-name processing, used only by the matcher
/// worker. IDs, URLs, guide rows and matching decisions are never cached here.
/// Bump [version] when fixture normalization or network aliases change.
class SportsChannelTextCache {
  SportsChannelTextCache(this.file);
  final File file;
  static const version = 2;
  // Every newly translated club/qualifier contains one of these scripts.
  // Flags, accents and full-width Latin alone keep their existing text.
  static final _nativeClubScript =
      RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');
  static const maxEntries = 24000;
  static const maxUnits = 1500000;
  static const maxBytes = 8 * 1024 * 1024;
  final _rows = <String, (String, String)>{};
  var _units = 0;
  bool _loaded = false, _dirty = false;
  Future<void>? _writing;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await file.exists() || await file.length() > maxBytes) return;
      final data = jsonDecode(await file.readAsString()) as Map;
      final previous = data['version'] == 1;
      if (!previous && data['version'] != version) return;
      final rows = data['entries'] as List;
      if (rows.length > maxEntries ||
          sha256.convert(utf8.encode(jsonEncode(rows))).toString() !=
              data['checksum']) {
        return;
      }
      for (final row in rows) {
        final parts = (row as List).cast<String>();
        if (parts.length != 3 ||
            !_fits(parts[0], parts[1], parts[2]) ||
            _rows.containsKey(parts[0])) {
          throw const FormatException('Invalid derived text cache');
        }
        _rows[parts[0]] = (parts[1], parts[2]);
        _units += parts[0].length + parts[1].length + parts[2].length;
      }
      if (previous) {
        // Version 2 adds native club identities only. Other normalization and
        // network keys are unchanged, so retain those expensive startup hits.
        _rows.removeWhere((name, row) {
          if (!_nativeClubScript.hasMatch(name)) return false;
          _units -= name.length + row.$1.length + row.$2.length;
          return true;
        });
        _dirty = true;
      }
    } catch (_) {
      _rows.clear();
      _units = 0;
    }
  }

  (String, String)? operator [](String name) => _rows[name];

  bool _fits(String name, String normalized, String canonical) =>
      name.length <= 512 &&
      normalized.length <= 2048 &&
      canonical.length <= 512 &&
      _rows.length < maxEntries &&
      _units + name.length + normalized.length + canonical.length <= maxUnits;

  void retainNames(Set<String> names) {
    _rows.removeWhere((name, row) {
      if (names.contains(name)) return false;
      _units -= name.length + row.$1.length + row.$2.length;
      _dirty = true;
      return true;
    });
  }

  void remember(String name, String normalized, String canonical) {
    if (_rows.containsKey(name) || !_fits(name, normalized, canonical)) return;
    _rows[name] = (normalized, canonical);
    _units += name.length + normalized.length + canonical.length;
    _dirty = true;
  }

  Future<void> flush() =>
      _writing ??= _flush().whenComplete(() => _writing = null);

  Future<void> _flush() async {
    while (_dirty) {
      // Let the first live job start; never write once per channel.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _dirty = false;
      File? temp;
      try {
        final rows = [
          for (final row in _rows.entries) [row.key, row.value.$1, row.value.$2]
        ];
        final bytes = utf8.encode(jsonEncode({
          'version': version,
          'checksum': sha256.convert(utf8.encode(jsonEncode(rows))).toString(),
          'entries': rows,
        }));
        if (bytes.length > maxBytes) return;
        temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}'
            '.${identityHashCode(this)}.tmp');
        await temp.writeAsBytes(bytes);
        await temp.rename(file.path);
      } catch (_) {
        // The source playlist remains authoritative if storage is unavailable.
      } finally {
        try {
          if (temp != null && await temp.exists()) await temp.delete();
        } catch (_) {}
      }
    }
  }
}
