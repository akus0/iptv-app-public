import 'dart:io';

/// What an image is used as — picks the TMDB size ladder in [hdImageUrl].
enum ImageKind { poster, backdrop, still }

/// TMDB's documented size tokens per kind (`/3/configuration`). Anything
/// else (`w600`, `w999`) is a 400 — never build one of those. `original`
/// is handled separately, see [hdImageUrl].
const _posterWidths = [154, 185, 342, 500, 780];
const _backdropWidths = [300, 780, 1280];
const _stillWidths = [185, 300];

/// `https://image.tmdb.org/t/p/<size>/<file>` — and the website-style
/// `themoviedb.org/t/p/...` copies some panels store. Group 1 = the size
/// token (`w185`, `w600_and_h900_bestv2`, `original`), group 2 = `/<file>`.
final RegExp _tmdbImage = RegExp(
    r'^(?:https?:)?//(?:image\.tmdb\.org|(?:www\.)?themoviedb\.org)/t/p/([^/]+)(/[^/?#]+)$',
    caseSensitive: false);

/// Rewrites a TMDB image link to the documented size that best fits
/// [targetPx] (the *decoded* width in physical pixels) for [kind]. Many
/// Xtream panels hand out TMDB links at w185/w300 — TMDB's image CDN needs
/// no API key, so asking for a bigger rendition is free HD. Forces https.
///
/// Anything that isn't a TMDB image (provider-hosted art, channel logos,
/// SVGs) comes back untouched — those have no size ladder to pick from.
///
/// `original` (a 4K backdrop is ~33 MB decoded) is never picked on
/// Android — weak Fire Sticks; the largest ladder step is used instead.
/// Desktop gets it only when [targetPx] exceeds every ladder step.
String hdImageUrl(String url, ImageKind kind, int targetPx) {
  final match = _tmdbImage.firstMatch(url.trim());
  if (match == null) return url;
  final file = match.group(2)!;
  if (file.toLowerCase().endsWith('.svg')) return url;
  final widths = switch (kind) {
    ImageKind.poster => _posterWidths,
    ImageKind.backdrop => _backdropWidths,
    ImageKind.still => _stillWidths,
  };
  String size = 'w${widths.last}';
  var found = false;
  for (final w in widths) {
    if (w >= targetPx) {
      size = 'w$w';
      found = true;
      break;
    }
  }
  if (!found && !Platform.isAndroid) size = 'original';
  return 'https://image.tmdb.org/t/p/$size$file';
}

/// The first of [urls] that is non-null and non-empty, else null.
String? firstImageUrl(Iterable<String?> urls) {
  for (final u in urls) {
    if (u != null && u.trim().isNotEmpty) return u;
  }
  return null;
}
