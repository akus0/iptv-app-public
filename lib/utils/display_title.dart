/// Display-only cleanup of provider-decorated titles — the stored names are
/// never changed (ids, search, TMDB matching and Continue Watching keep using
/// the raw ones). Best-effort: when stripping would leave nothing, the
/// original text is returned.
library;

const _tagWords =
    r'(?:[A-Z]{2,3}|4K|8K|UHD|FHD|HDR|HDR10|HD|SD|HEVC|H265|H264|x265|x264|'
    r'MULTI|MULTISUB|MULTI-SUB|MULTI SUB|SUB|SUBS|DUB|VOST|VOSTFR|VF|VFF|VO|'
    r'NF|AMZN|DSNP|ATVP|HMAX|WEB|WEBDL|WEB-DL|NETFLIX)';

/// "EN - ", "4K-EN - ", "EN| ", "|EN| ", "[EN] ", "(EN) " at the start.
/// Only dash/pipe/bullet separators — never a colon ("CSI: Miami").
final RegExp _leadingTag = RegExp(r'^\s*(?:(?:[\[\(|]\s*' +
    _tagWords +
    r'(?:[-_+ ]' +
    _tagWords +
    r')*\s*[\]\)|]\s*[-|•]?\s*)|(?:' +
    _tagWords +
    r'(?:[-_+]' +
    _tagWords +
    r')*\s*[-|•]\s+))');

/// Any "[...]" group, anywhere ("[MULTI-SUB]", "[4K]").
final RegExp _bracketGroup = RegExp(r'\s*\[[^\]]*\]\s*');

/// "(2019)" or "(MULTI SUB)"-style parentheses — only a year or tag words.
final RegExp _parenTagOrYear = RegExp(
    r'\s*\(\s*(?:(?:19|20)\d{2}|' +
        _tagWords +
        r'(?:[-_ ]' +
        _tagWords +
        r')*)\s*\)\s*',
    caseSensitive: false);

/// Trailing quality/language tags ("Title 4K", "Title - MULTI").
final RegExp _trailingTag = RegExp(
    r'(?:\s*[-|•]?\s+(?:4K|8K|UHD|FHD|HDR|HDR10|HEVC|H265|MULTI|MULTISUB|'
    r'MULTI-SUB|VOSTFR|VOST|VFF|VF))+\s*$',
    caseSensitive: false);

final RegExp _edgeSeparators = RegExp(r'^[\s\-|•:·–—]+|[\s\-|•:·–—]+$');
final RegExp _spaces = RegExp(r'\s{2,}');

/// "S01E03", "S1 E3", "S01 - E03", "1x03", "S01" alone, "E03" alone, and the
/// app's own "S1E3 — " prefix (see `XtreamApiService.getSeriesEpisodes`).
final RegExp _episodeCode = RegExp(
    r'\b(?:S\d{1,3}\s*[-.]?\s*E\d{1,4}(?:\s*-\s*E?\d{1,4})?|\d{1,2}x\d{1,3}|S\d{1,3}|E\d{1,4}|EP\.?\s*\d{1,4})\b',
    caseSensitive: false);

/// "Episode 3", "Épisode 3", "Episodio 3", "Ep 3", or just "3".
final RegExp _genericEpisode = RegExp(
    r'^(?:(?:episode|épisode|episodio|folge|aflevering|ep\.?)\s*)?\d{1,4}$',
    caseSensitive: false);

/// A series/movie name for display: drops a leading language/quality tag,
/// bracketed tags, a "(2019)" year and trailing quality tags.
String cleanDisplayTitle(String raw) {
  var t = raw;
  for (var i = 0; i < 3; i++) {
    final next = t.replaceFirst(_leadingTag, '');
    if (next == t) break;
    t = next;
  }
  t = t.replaceAll(_bracketGroup, ' ');
  t = t.replaceAll(_parenTagOrYear, ' ');
  t = t.replaceFirst(_trailingTag, '');
  t = t.replaceAll(_spaces, ' ').replaceAll(_edgeSeparators, '');
  t = stripReleaseTags(t);
  return t.isEmpty ? raw.trim() : t;
}

/// Streaming-service / quality / codec / release tags, as they appear in
/// provider names ("After Life S01E01 NF - 4K", "Title 2160p WEB-DL").
/// Case-sensitive on purpose: the short ones are only tags in capitals
/// ("WEB", "HD") — "The Web" stays a title. Longer variants first.
const _releaseTags = r'(?:NF|AMZN|DSNP|HMAX|ATVP|HULU|PCOK|PMTP|STAN|CRAV|'
    r'WEB-DL|WEBDL|WEB-Rip|WEBRip|WEBRIP|WEB|BluRay|BLURAY|BDRip|BRRip|'
    r'HDR10\+|HDR10|HDR|DoVi|DV|4K|8K|UHD|2160p|1080p|720p|576p|480p|FHD|HD|'
    r'SD|[xX]26[45]|[hH]\.?26[45]|HEVC|AVC|10bit|DDP?\s?[257]\.1|DD\+|EAC3|'
    r'AC3|AAC|ATMOS|Atmos|MULTI-SUB|MULTISUB|MULTI|VOSTFR|VOST|VFF|VFQ|VF|VO|'
    r'SUBS|SUB|DUB|REPACK|PROPER)';
const _tagSep = r'[\s\-|.•·_/]';

/// One tag (or a "[...]" group) at the very end / very start of a title.
final RegExp _trailingRelease = RegExp(
    r'(?:^|' + _tagSep + r'+)(?:' + _releaseTags + r'|\[[^\]]*\])' +
        _tagSep +
        r'*$');
final RegExp _leadingRelease = RegExp(r'^' +
    _tagSep +
    r'*(?:' +
    _releaseTags +
    r'|\[[^\]]*\])(?=$|' +
    _tagSep +
    r')' +
    _tagSep +
    r'*');
final RegExp _edgeTagSeparators = RegExp(r'^[\s\-|•:·–—._/]+|[\s\-|•:·–—._/]+$');

/// Drops runs of release tags from both ends ("NF - 4K", "2160p WEB-DL",
/// "[MULTI-SUB]") and the separators left between them. Only the edges:
/// a tag word in the middle of a real title is left alone. May return ''
/// when the text was nothing but tags.
String stripReleaseTags(String raw) {
  var t = raw;
  for (var i = 0; i < 12; i++) {
    final next = t
        .replaceFirst(_trailingRelease, '')
        .replaceFirst(_leadingRelease, '');
    if (next == t) break;
    t = next;
  }
  return t.replaceAll(_edgeTagSeparators, '').replaceAll(_spaces, ' ').trim();
}

/// Picture-quality chips derivable from a decorated provider name
/// ("... 4K (2026)" -> ["4K"]): "4K" for 4K/UHD/2160p, plus "HDR".
List<String> qualityTagsOf(String raw) {
  final tags = <String>[];
  if (RegExp(r'\b(?:4K|UHD|2160p)\b', caseSensitive: false).hasMatch(raw)) {
    tags.add('4K');
  }
  if (RegExp(r'\b(?:HDR10\+?|HDR|DV|DoVi)\b').hasMatch(raw)) tags.add('HDR');
  return tags;
}

/// The year in a decorated title ("Lioness (2023)"), if there is one.
int? yearFromTitle(String raw) {
  final match = RegExp(r'\((19|20)\d{2}\)').firstMatch(raw);
  if (match == null) return null;
  return int.tryParse(match.group(0)!.substring(1, 5));
}

/// An episode's own title with the series name and any SxxEyy code removed,
/// or null when nothing meaningful is left (the caller then shows
/// "Episode N"). [rawTitle] is the provider's `title` (or the channel name).
String? episodeDisplayTitle(String rawTitle, String seriesName) {
  var t = rawTitle;
  // The app's own "S1E3 — " prefix, if handed the channel name.
  t = t.replaceFirst(RegExp(r'^S\d+E[^\s]*\s+—\s+'), '');
  for (final name in {seriesName, cleanDisplayTitle(seriesName)}) {
    final n = name.trim();
    if (n.length < 2) continue;
    t = t.replaceAll(RegExp(RegExp.escape(n), caseSensitive: false), ' ');
  }
  t = t.replaceAll(_episodeCode, ' ');
  t = cleanDisplayTitle(t);
  // cleanDisplayTitle falls back to its input; recheck what's really left
  // — "NF - 4K" (all release tags) is nothing.
  final stripped =
      stripReleaseTags(t.replaceAll(_edgeSeparators, '').trim());
  if (stripped.isEmpty ||
      _genericEpisode.hasMatch(stripped) ||
      !RegExp(r'[A-Za-zÀ-ÿ0-9]').hasMatch(stripped)) {
    return null;
  }
  return stripped;
}
