import 'dart:collection';
import 'dart:typed_data';
import 'sports_language.dart';

/// Literal multi-keyword search with the same language fallback as guide reads.
/// Aho–Corasick checks ASCII-only keyword sets in any title in one pass.
/// Mixed native keyword sets retain the existing RegExp case folding.
class SportsTitleMatcher {
  /// Precomputation is intended for bulk worker filtering. Small/local checks
  /// keep the sparse automaton and avoid the extra construction work.
  SportsTitleMatcher(Iterable<String> terms,
      {SportsTitleTextCache? textCache, bool precomputeTransitions = false})
      : _textCache = textCache {
    final unique = terms.toSet();
    final native = unique.where(_nonAscii.hasMatch).toList();
    _native = native.isEmpty
        ? null
        : RegExp(native.map(RegExp.escape).join('|'), caseSensitive: false);
    _pattern = native.isEmpty
        ? null
        : RegExp(unique.map(RegExp.escape).join('|'), caseSensitive: false);
    _ascii = _LiteralIndex(unique.where((term) => !_nonAscii.hasMatch(term)),
        precomputeTransitions: precomputeTransitions);
    _empty = unique.isEmpty;
  }
  static final _nonAscii = RegExp(r'[^\x00-\x7f]');
  final SportsTitleTextCache? _textCache;
  late final RegExp? _pattern;
  late final RegExp? _native;
  late final _LiteralIndex _ascii;
  late final bool _empty;

  // An exact ASCII hit is sufficient even when other query terms or title
  // characters are native. On a miss, retain the original combined expression
  // for native query/text pairs: splitting it can change Unicode case folding.
  bool _literal(String text) {
    if (_empty || _ascii.matches(text)) return true;
    if (_native == null) return false;
    return _nonAscii.hasMatch(text)
        ? _pattern!.hasMatch(text)
        : _native.hasMatch(text);
  }

  bool matches(String title) {
    if (_literal(title)) return true;
    final fallback =
        _textCache == null ? _fallback(title) : _textCache.fallback(title);
    return fallback != null && _literal(fallback);
  }
}

String? _fallback(String title) {
  final translated = sportsLanguageText(title);
  if (translated == title && !SportsTitleMatcher._nonAscii.hasMatch(title)) {
    return null;
  }
  return normalizeSportsName(translated);
}

/// Query-independent language work only: never stores matches or confidence.
/// A small bounded dictionary avoids retranslating the same guide titles for
/// successive event batches. Its owner releases it with the filtering worker.
class SportsTitleTextCache {
  SportsTitleTextCache({this.maxEntries = 16384, this.maxCharacters = 2097152})
      : assert(maxEntries > 0),
        assert(maxCharacters > 0);
  final int maxEntries, maxCharacters;
  final _values = <String, _TitleTextEntry>{};
  final _recent = LinkedList<_TitleTextEntry>();
  int _characters = 0;

  String? fallback(String title) {
    final cached = _values[title];
    if (cached != null) {
      cached.unlink();
      _recent.add(cached);
      return cached.value;
    }
    final value = _fallback(title);
    // Plain ASCII misses need no derived text. Caching their nulls can evict
    // every expensive language/Unicode result during a large dictionary scan,
    // forcing that work again in the next fixture batch. Keep the same bounds
    // for useful fallback text; matching decisions are never cached here.
    if (value == null) return null;
    final cost = title.length + value.length;
    if (cost > 2048 || cost > maxCharacters) return value;
    while (_values.isNotEmpty &&
        (_values.length >= maxEntries || _characters + cost > maxCharacters)) {
      // Map.keys.first can scan an ever-growing prefix of deleted slots when
      // a full-dictionary query churns this cache. Keep eviction constant-time
      // and avoid removing/reinserting map keys on every cache hit.
      final oldest = _recent.first..unlink();
      _values.remove(oldest.title);
      _characters -= oldest.characters;
    }
    final entry = _TitleTextEntry(title, value, cost);
    _values[title] = entry;
    _recent.add(entry);
    _characters += cost;
    return value;
  }
}

final class _TitleTextEntry extends LinkedListEntry<_TitleTextEntry> {
  _TitleTextEntry(this.title, this.value, this.characters);
  final String title;
  final String value;
  final int characters;
}

class _Node {
  final next = <int, int>{};
  int fallback = 0;
  bool terminal = false;
}

class _LiteralIndex {
  _LiteralIndex(Iterable<String> terms, {bool precomputeTransitions = false}) {
    for (final term in terms) {
      var at = 0;
      for (final c in term.toLowerCase().codeUnits) {
        at = nodes[at].next.putIfAbsent(c, () {
          nodes.add(_Node());
          return nodes.length - 1;
        });
      }
      nodes[at].terminal = true;
    }
    final queue = ListQueue<int>.from(nodes.first.next.values);
    while (queue.isNotEmpty) {
      final parent = queue.removeFirst();
      for (final entry in nodes[parent].next.entries) {
        final child = nodes[entry.value];
        var fallback = nodes[parent].fallback;
        while (fallback != 0 && !nodes[fallback].next.containsKey(entry.key)) {
          fallback = nodes[fallback].fallback;
        }
        child.fallback = nodes[fallback].next[entry.key] ?? 0;
        child.terminal |= nodes[child.fallback].terminal;
        queue.add(entry.value);
      }
    }
    if (precomputeTransitions) _buildTable();
  }
  final nodes = <_Node>[_Node()];
  Uint16List? _table;
  Uint8List? _symbols, _accepting;
  int _width = 0;

  void _buildTable() {
    if (nodes.first.terminal || nodes.length > 65536) return;
    final alphabet = {for (final node in nodes) ...node.next.keys}.toList();
    final width = alphabet.length;
    // At most 1 MiB across all retained arrays. Large keyword sets keep the
    // original sparse automaton; state IDs must also fit unsigned 16 bits.
    if (width == 0 || nodes.length * (width * 2 + 1) + 128 > 1024 * 1024) {
      return;
    }
    final table = Uint16List(nodes.length * width);
    final symbols = Uint8List(128);
    final accepting = Uint8List(nodes.length);
    for (var c = 0; c < width; c++) {
      symbols[alphabet[c]] = c + 1;
    }
    // Breadth-first order prepares every shorter fallback row before use.
    // Missing root transitions read zero from the initially empty table.
    final queue = ListQueue<int>()..add(0);
    while (queue.isNotEmpty) {
      final at = queue.removeFirst(), node = nodes[at];
      accepting[at] = node.terminal ? 1 : 0;
      for (var c = 0; c < width; c++) {
        table[at * width + c] =
            node.next[alphabet[c]] ?? table[node.fallback * width + c];
      }
      queue.addAll(node.next.values);
    }
    _table = table;
    _symbols = symbols;
    _accepting = accepting;
    _width = width;
    nodes.clear();
  }

  bool _matchesTable(String text, Uint16List table) {
    final symbols = _symbols!, accepting = _accepting!, width = _width;
    var at = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.codeUnitAt(i);
      if (c >= 65 && c <= 90) c += 32;
      final symbol = c < 128 ? symbols[c] : 0;
      if (symbol == 0) {
        at = 0;
        continue;
      }
      at = table[at * width + symbol - 1];
      if (accepting[at] != 0) return true;
    }
    return false;
  }

  bool matches(String text) {
    final table = _table;
    if (table != null) return _matchesTable(text, table);
    if (nodes.first.terminal) return true;
    // Native-only queries have no ASCII terms to scan for.
    if (nodes.length == 1) return false;
    var at = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.codeUnitAt(i);
      if (c >= 65 && c <= 90) c += 32;
      while (at != 0 && !nodes[at].next.containsKey(c)) {
        at = nodes[at].fallback;
      }
      at = nodes[at].next[c] ?? 0;
      if (nodes[at].terminal) return true;
    }
    return false;
  }
}
