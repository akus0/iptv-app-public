/// Conservative cross-provider channel-name matching. Normalize region prefixes/suffixes and
/// quality markers, then require exact token sets to avoid merging distinct regional
/// channels.
library;

/// Pure quality/format markers — safe to discard when comparing names,
/// since they never distinguish one real channel from another the way a
/// region, city, or service-tier word does.
const Set<String> _qualityTokens = {
  'HD',
  'HEVC',
  'UHD',
  'FHD',
  'SD',
  'HDR',
  'H265',
  'H264',
  'RAW',
};

/// Splits off a leading region/category tag before the first `|`, `:`, or
/// ` - ` — whichever a given name actually uses (see this file's own doc
/// comment for the three real conventions this was built against).
/// Leaves the name untouched if none of them appear at all.
String _stripLeadingTag(String name) {
  var bestIndex = -1;
  var bestSepLength = 0;
  for (final sep in const ['|', ':', ' - ']) {
    final idx = name.indexOf(sep);
    if (idx > 0 && (bestIndex == -1 || idx < bestIndex)) {
      bestIndex = idx;
      bestSepLength = sep.length;
    }
  }
  if (bestIndex == -1) return name;
  return name.substring(bestIndex + bestSepLength);
}

/// The token set a channel name reduces to for matching — upper-cased,
/// punctuation-normalized words with the leading region/category tag and
/// any pure quality tokens removed. `+` is kept as part of a word (not
/// treated as punctuation to strip) specifically so `ESPN+` stays
/// distinct from `ESPN` rather than both collapsing to the same token.
Set<String> normalizedChannelTokens(String name) {
  final withoutTag = _stripLeadingTag(name);
  final cleaned = withoutTag.toUpperCase().replaceAll(RegExp(r'[^\w+]'), ' ');
  return cleaned
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !_qualityTokens.contains(t))
      .toSet();
}

/// True only on an exact token-set match (both directions, so neither
/// name is missing something the other has) — see this file's own doc
/// comment for why this is exact rather than fuzzy.
bool channelNamesMatch(String a, String b) =>
    canonicalChannelKey(a).isNotEmpty &&
    canonicalChannelKey(a) == canonicalChannelKey(b);

/// [normalizedChannelTokens] collapsed into one comparable/hashable
/// `String` (sorted, so token order in the original name never matters)
/// — lets a bulk "auto-pair everything" operation bucket hundreds or
/// thousands of channels by this key once, up front, rather than
/// recomputing and comparing token sets pairwise for every candidate
/// (quadratic — noticeable on a real catalog this size, not just in
/// theory). Empty for a name that reduces to nothing (rare, but a title
/// that's *only* quality tokens isn't unheard of) — callers treat that as
/// "never matches anything", same as [channelNamesMatch] does.
String canonicalChannelKey(String name) {
  final tokens = normalizedChannelTokens(name).toList()..sort();
  return tokens.join('\u0000');
}
