/// A series entry from the Xtream Codes API — a container of seasons and
/// episodes, not directly playable. Tapping one fetches its episodes on
/// demand via [XtreamApiService.getSeriesEpisodes].
class XtreamSeries {
  XtreamSeries({
    required this.seriesId,
    required this.playlistId,
    required this.name,
    required this.categoryId,
    this.coverUrl,
    this.isFavorite = false,
    this.rating,
    this.addedAt,
    this.tmdbId,
    this.releaseDate,
    this.posterUrl,
    this.backdropUrl,
    this.providerBackdropUrl,
  }) : id = '$playlistId::series_$seriesId';

  /// The raw per-provider integer Xtream itself uses — kept because
  /// `getSeriesEpisodes` still needs it for the `get_series_info` API
  /// call. Not safely unique across two different providers on its own
  /// (see `id`).
  final int seriesId;

  /// Which playlist this series came from — see `Channel.playlistId`.
  final String playlistId;

  /// Globally-unique stable identifier, derived from [playlistId] and
  /// [seriesId] — this class had no string id at all before multi-playlist
  /// support; two providers can easily both assign the same raw
  /// `seriesId`, so favoriting/lookup code (`PlaylistManager
  /// .toggleSeriesFavorite`, `CatalogDatabase`'s `series_items` primary
  /// key) uses this instead of the bare int.
  final String id;
  final String name;
  final String categoryId;
  final String? coverUrl;

  /// Provider rating from `get_series`, displayed like [Channel.rating].
  final String? rating;

  /// When this show showed up in the provider's catalog — `get_series`
  /// reports it as `last_modified` (epoch seconds), not the `added` field
  /// `get_vod_streams` uses for movies (see `Channel.addedAt`); same
  /// meaning, different key per content type. Null when not reported.
  final DateTime? addedAt;

  /// See `Channel.tmdbId`'s doc comment — same field, same source call
  /// (`get_series`), same purpose, same mutable-in-place pattern.
  String? tmdbId;

  /// See `Channel.releaseDate`'s doc comment — same reasoning and the same
  /// mutable-in-place pattern, for the same reason.
  DateTime? releaseDate;

  /// See `Channel.posterUrl`'s doc comment — same reasoning, same source.
  String? posterUrl;

  /// See `Channel.backdropUrl`'s doc comment — same reasoning, same
  /// source.
  String? backdropUrl;

  /// The provider's own landscape fanart — `backdrop_path` from the
  /// `get_series` list when the panel sends it there, else filled in from
  /// `get_series_info` (hero dwell / detail open) and persisted. Keyless,
  /// unlike [backdropUrl].
  String? providerBackdropUrl;

  /// Hero background order: TMDB backdrop, then the provider's.
  String? get anyBackdropUrl {
    for (final u in [backdropUrl, providerBackdropUrl]) {
      if (u != null && u.isNotEmpty) return u;
    }
    return null;
  }

  /// Mutable, flipped in place by `PlaylistManager.toggleSeriesFavorite` —
  /// same pattern as `Channel.isFavorite`.
  bool isFavorite;

  Map<String, dynamic> toJson() => {
        'seriesId': seriesId,
        'playlistId': playlistId,
        'name': name,
        'categoryId': categoryId,
        'coverUrl': coverUrl,
        'isFavorite': isFavorite,
        'rating': rating,
        'addedAt': addedAt?.millisecondsSinceEpoch,
        'tmdbId': tmdbId,
        'releaseDate': releaseDate?.millisecondsSinceEpoch,
        'posterUrl': posterUrl,
        'backdropUrl': backdropUrl,
        'providerBackdropUrl': providerBackdropUrl,
      };

  /// `playlistId` defaults to `'migrated_default'` for the same reason as
  /// `Channel.fromJson` — see its doc comment.
  factory XtreamSeries.fromJson(Map<String, dynamic> json) => XtreamSeries(
        seriesId: json['seriesId'] as int,
        playlistId: json['playlistId'] as String? ?? 'migrated_default',
        name: json['name'] as String,
        categoryId: json['categoryId'] as String,
        coverUrl: json['coverUrl'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        rating: json['rating'] as String?,
        addedAt: json['addedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['addedAt'] as int)
            : null,
        tmdbId: json['tmdbId'] as String?,
        releaseDate: json['releaseDate'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['releaseDate'] as int)
            : null,
        posterUrl: json['posterUrl'] as String?,
        backdropUrl: json['backdropUrl'] as String?,
        providerBackdropUrl: json['providerBackdropUrl'] as String?,
      );
}
