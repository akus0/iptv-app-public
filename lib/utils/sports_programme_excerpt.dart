/// Presentation only: highlighted words explain context, never change confidence.
/// One instance per picker; bounded text/cache and literal phrases keep this
/// independent of playlist size. No fetching or fuzzy matching in row builds.
class SportsProgrammeExcerpt {
  const SportsProgrammeExcerpt(this.text, this.emphasis);
  final String text;
  final List<({int start, int end})> emphasis;
}

class SportsProgrammeHighlighter {
  SportsProgrammeHighlighter(Iterable<String> terms,
      {Iterable<String> names = const []})
      : _pattern = _compile([...names, ...terms]),
        _names = _compile(names);

  final RegExp? _pattern, _names;
  final _cache = <String, SportsProgrammeExcerpt>{};
  static final _space = RegExp(r'\s+');
  static const _generic = {
    'live',
    'women',
    'womens',
    'ladies',
    'men',
    'mens',
    'sport',
    'sports',
    'final',
    'race',
    'round',
    'home',
    'away',
    'tba',
    'tbd',
    'unknown'
  };

  static RegExp? _compile(Iterable<String> values) {
    final phrases = values
        .map((s) => s.trim().replaceAll(_space, ' ').toLowerCase())
        .where((s) => s.length >= 3 && s.length <= 80 && !_generic.contains(s))
        .toSet()
        .take(24)
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (phrases.isEmpty) return null;
    return RegExp(
        r'(?<![\p{L}\p{N}])(?:' +
            phrases.map(RegExp.escape).join('|') +
            r')(?![\p{L}\p{N}])',
        caseSensitive: false,
        unicode: true);
  }

  SportsProgrammeExcerpt excerpt(String description) {
    // Bound work even for malformed, multi-page provider descriptions.
    final bounded = description.length > 4096
        ? description.substring(0, 4096)
        : description;
    final cached = _cache[bounded];
    if (cached != null) return cached;
    final text = bounded.replaceAll(_space, ' ').trim();
    final anchor = _names?.firstMatch(text) ?? _pattern?.firstMatch(text);
    var start = text.length <= 320
        ? 0
        : ((anchor?.start ?? 0) - 80).clamp(0, text.length - 320);
    if (start > 0) {
      final boundary = text.indexOf(' ', start);
      if (boundary >= start && boundary < start + 30) start = boundary + 1;
    }
    var end = (start + 320).clamp(0, text.length);
    if (end < text.length) {
      final boundary = text.lastIndexOf(' ', end);
      if (boundary > end - 30) end = boundary;
    }
    final excerpt =
        '${start > 0 ? '… ' : ''}${text.substring(start, end)}${end < text.length || bounded.length < description.length ? ' …' : ''}';
    final result = SportsProgrammeExcerpt(excerpt, [
      for (final match
          in _pattern?.allMatches(excerpt).take(24) ?? const <RegExpMatch>[])
        (start: match.start, end: match.end),
    ]);
    if (_cache.length >= 64) _cache.remove(_cache.keys.first);
    _cache[bounded] = result;
    return result;
  }
}
