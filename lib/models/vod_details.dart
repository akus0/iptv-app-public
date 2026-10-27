/// What `get_vod_info` returns for one movie beyond the list entry: the
/// plot, the provider's own bigger art and the display metadata the movie
/// detail screen shows. Every field is optional — panels vary wildly in
/// what they fill in. In-memory only (the art is also persisted, see
/// `Channel.providerPosterUrl`).
class VodDetails {
  const VodDetails({
    this.plot,
    this.posterUrl,
    this.backdropUrls = const [],
    this.genre,
    this.cast,
    this.director,
    this.releaseDate,
    this.durationSeconds,
    this.rating,
  });

  static const empty = VodDetails();

  final String? plot;

  /// `info.cover_big`, else `info.movie_image`.
  final String? posterUrl;

  /// `info.backdrop_path` — landscape fanart, usually TMDB.
  final List<String> backdropUrls;
  final String? genre;
  final String? cast;
  final String? director;

  /// `info.releasedate` / `info.release_date`, raw (usually `YYYY-MM-DD`).
  final String? releaseDate;

  /// `info.duration_secs`, else parsed from `info.duration` ("01:52:10").
  final int? durationSeconds;

  /// `info.rating`, already filtered of the "0"/empty placeholders.
  final String? rating;

  String? get backdropUrl => backdropUrls.isEmpty ? null : backdropUrls.first;

  /// Four-digit year out of [releaseDate], when it has one.
  int? get year {
    final raw = releaseDate;
    if (raw == null) return null;
    final match = RegExp(r'(19|20)\d{2}').firstMatch(raw);
    return match == null ? null : int.tryParse(match.group(0)!);
  }
}
