/// A manual cross-playlist link — see
/// `AppConstants.keyChannelLinks`'s doc comment. Identifies another
/// [Channel] by its own (playlistId, rawId), the same pair
/// `PlaylistManager.resolveChannelLink` looks a live [Channel] back up
/// from.
typedef ChannelLink = ({String playlistId, String rawId});

/// A single playable entry parsed from an M3U playlist (a live TV channel
/// or a VOD/movie item — the app treats both the same way at this level).
class Channel {
  Channel({
    required this.id,
    required this.rawId,
    required this.playlistId,
    required this.name,
    required this.group,
    required this.url,
    this.logoUrl,
    this.subtitleUrl,
    this.isFavorite = false,
    this.rating,
    this.addedAt,
    this.seriesId,
    this.seriesName,
    this.seriesCoverUrl,
    this.epgIdOverride,
    this.epgKey,
    this.tmdbId,
    this.releaseDate,
    this.posterUrl,
    this.backdropUrl,
    this.providerPosterUrl,
    this.providerBackdropUrl,
  });

  /// Stable identifier: the M3U `tvg-id` when present (used to match EPG
  /// programmes), otherwise a generated fallback. Already prefixed with
  /// `playlistId` at construction time (see `XtreamApiService`/
  /// `M3uParser`) so ids stay globally unique once channels from more than
  /// one playlist are merged into the same lists — two different
  /// providers can easily reuse the same raw `stream_id`/`tvg-id`.
  final String id;

  /// The pre-multi-playlist-support id shape, unprefixed — e.g.
  /// `xt_vod_$streamId`, `xt_ep_$episodeId`, `xt_live_$streamId`/an
  /// `epg_channel_id`, or an M3U `tvg-id`. [id] is `'$playlistId::$rawId'`.
  /// Kept as its own field (not derived by string-stripping [id] at every
  /// call site — `playlistId` is variable-length, `::` splitting would be
  /// fragile) purely for the handful of places that pattern-match on the
  /// provider's own id shape: [isLiveId], the Movies/TV-Shows "Continue
  /// Watching" `xt_vod_`/`xt_ep_` prefix filters, and
  /// `PlaylistManager.getVodDescription`'s raw-stream-id extraction.
  final String rawId;

  /// Which playlist this channel came from — the same id every group,
  /// hidden-groups entry, and cache-file name for this playlist share
  /// (see `PlaylistProfile.id`). Used to detect a playlist boundary when
  /// rendering merged group lists (a divider between Playlist A's and
  /// Playlist B's groups), and to scope Group Management/favorites-group
  /// lookups.
  final String playlistId;
  final String name;
  final String group;
  final String url;
  final String? logoUrl;
  final String? subtitleUrl;
  bool isFavorite;

  /// Provider-supplied rating (e.g. Xtream's `rating` field on VOD items).
  /// Meaningless for live channels — null there.
  final String? rating;

  /// When the provider says this title showed up in its catalog (Xtream's
  /// `added` field on VOD items, epoch seconds). Null for live channels,
  /// for M3U playlists (no such concept exists there at all), and whenever
  /// the provider didn't report it — the "What's New" carousel simply has
  /// nothing to show in those cases rather than guessing an order.
  final DateTime? addedAt;

  /// Set on episode channels only (see PlaylistManager.loadSeriesEpisodes)
  /// — the series this episode belongs to, so "Continue Watching" can show
  /// and reopen the actual show instead of just this one episode. Mutable
  /// (like [isFavorite]) rather than requiring a full reconstruction each
  /// time a season screen is opened.
  int? seriesId;
  String? seriesName;
  String? seriesCoverUrl;

  /// Manual EPG identifier override; null falls back to [rawId]. Applied in place and
  /// restored from PlaylistSession when channels reload, so assigning a guide entry does not
  /// require a full catalogue reload.
  String? epgIdOverride;

  /// TMDB lookup id, provided by some catalogues or resolved through title search during
  /// enrichment. Mutable so enrichment can stamp the existing channel object.
  String? tmdbId;

  /// Actual release date from TMDB, distinct from the provider ingestion date [addedAt]. Null
  /// until enrichment completes. Mutable so asynchronous enrichment can update existing
  /// channel objects.
  DateTime? releaseDate;

  /// Poster returned by the same TMDB lookup used for [releaseDate]. Prefer it when present,
  /// falling back to provider artwork; update existing channel objects in place.
  String? posterUrl;

  /// Landscape artwork returned alongside TMDB metadata. Use it for wide hero banners; null
  /// retains the poster fallback.
  String? backdropUrl;

  /// The provider's own bigger artwork from `get_vod_info` (`cover_big`,
  /// else `movie_image`) — keyless, unlike [posterUrl]. Only fetched when a
  /// movie's detail screen opens or the browse hero dwells on it (the same
  /// one request that brings its plot), then persisted. Null until then.
  String? providerPosterUrl;

  /// `get_vod_info`'s `backdrop_path` (first entry) — a landscape image for
  /// the hero/detail background when no TMDB [backdropUrl] exists. Same
  /// on-demand fetch and persistence as [providerPosterUrl].
  String? providerBackdropUrl;

  /// Hero/detail background order: TMDB backdrop, then the provider's.
  String? get anyBackdropUrl {
    for (final u in [backdropUrl, providerBackdropUrl]) {
      if (u != null && u.isNotEmpty) return u;
    }
    return null;
  }

  /// The id every EPG lookup call site uses — see [epgIdOverride]'s doc
  /// comment. Never [rawId] directly from an EPG-lookup call site; that
  /// would bypass a manual assignment.
  String get epgId => epgIdOverride ?? epgKey ?? rawId;

  /// The provider's own EPG id (`epg_channel_id`/`tvg-id`) when [rawId] is
  /// not it — set by [withUniqueIds] for channels that shared one. Null =
  /// [rawId] is the EPG id.
  final String? epgKey;

  /// Gives channels that share an id (the id is the provider's EPG id, and
  /// "ESPN 4K", "ESPN HD" and "ESPN FHD" often all carry the same one) ids
  /// of their own, so starring, hiding or picking one no longer hits all of
  /// them. Each one becomes `<epg id>#<last URL segment>` (the stream id —
  /// stable across reloads), with the EPG id kept in [epgKey] so the guide
  /// still finds them. Channels with a unique id are untouched, so nothing
  /// saved for them changes. Idempotent: an already-fixed list (from the
  /// cache) has nothing left to fix.
  static List<Channel> withUniqueIds(List<Channel> channels) {
    final counts = <String, int>{};
    for (final c in channels) {
      counts[c.id] = (counts[c.id] ?? 0) + 1;
    }
    if (!counts.values.any((n) => n > 1)) return channels;
    final used = {
      for (final e in counts.entries)
        if (e.value == 1) e.key
    };
    return [
      for (final c in channels)
        if (counts[c.id] == 1) c else c._withUniqueRawId(used)
    ];
  }

  Channel _withUniqueRawId(Set<String> used) {
    final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    var key = segments.isEmpty ? '' : segments.last;
    final dot = key.lastIndexOf('.');
    if (dot > 0) key = key.substring(0, dot);
    final base = key.isEmpty ? '$rawId#' : '$rawId#$key';
    var newRaw = base;
    for (var n = 2; used.contains('$playlistId::$newRaw'); n++) {
      newRaw = '$base~$n';
    }
    used.add('$playlistId::$newRaw');
    return copyWith(
        id: '$playlistId::$newRaw', rawId: newRaw, epgKey: epgKey ?? rawId);
  }

  Channel copyWith(
          {bool? isFavorite, String? id, String? rawId, String? epgKey}) =>
      Channel(
        id: id ?? this.id,
        rawId: rawId ?? this.rawId,
        epgKey: epgKey ?? this.epgKey,
        playlistId: playlistId,
        name: name,
        group: group,
        url: url,
        logoUrl: logoUrl,
        subtitleUrl: subtitleUrl,
        isFavorite: isFavorite ?? this.isFavorite,
        rating: rating,
        addedAt: addedAt,
        seriesId: seriesId,
        seriesName: seriesName,
        seriesCoverUrl: seriesCoverUrl,
        epgIdOverride: epgIdOverride,
        tmdbId: tmdbId,
        releaseDate: releaseDate,
        posterUrl: posterUrl,
        backdropUrl: backdropUrl,
        providerPosterUrl: providerPosterUrl,
        providerBackdropUrl: providerBackdropUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'rawId': rawId,
        if (epgKey != null) 'epgKey': epgKey,
        'playlistId': playlistId,
        'name': name,
        'group': group,
        'url': url,
        'logoUrl': logoUrl,
        'subtitleUrl': subtitleUrl,
        'isFavorite': isFavorite,
        'rating': rating,
        'addedAt': addedAt?.millisecondsSinceEpoch,
        'seriesId': seriesId,
        'seriesName': seriesName,
        'seriesCoverUrl': seriesCoverUrl,
        'tmdbId': tmdbId,
        'releaseDate': releaseDate?.millisecondsSinceEpoch,
        'posterUrl': posterUrl,
        'backdropUrl': backdropUrl,
        'providerPosterUrl': providerPosterUrl,
        'providerBackdropUrl': providerBackdropUrl,
      };

  /// `playlistId` defaults to `'migrated_default'` and `rawId` to [id]
  /// itself when absent from a decoded blob — belt-and-suspenders only:
  /// every on-disk cache file this reads gained a playlist-id-suffixed
  /// name in this same release (see `PlaylistManager`'s per-session cache
  /// naming), so a pre-multi-playlist cache file is simply never looked up
  /// again under its old unsuffixed name post-upgrade, not silently
  /// misread as if it had these fields.
  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        rawId: json['rawId'] as String? ?? json['id'] as String,
        epgKey: json['epgKey'] as String?,
        playlistId: json['playlistId'] as String? ?? 'migrated_default',
        name: json['name'] as String,
        group: json['group'] as String,
        url: json['url'] as String,
        logoUrl: json['logoUrl'] as String?,
        subtitleUrl: json['subtitleUrl'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        rating: json['rating'] as String?,
        addedAt: json['addedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['addedAt'] as int)
            : null,
        seriesId: json['seriesId'] as int?,
        seriesName: json['seriesName'] as String?,
        seriesCoverUrl: json['seriesCoverUrl'] as String?,
        tmdbId: json['tmdbId'] as String?,
        releaseDate: json['releaseDate'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['releaseDate'] as int)
            : null,
        posterUrl: json['posterUrl'] as String?,
        backdropUrl: json['backdropUrl'] as String?,
        providerPosterUrl: json['providerPosterUrl'] as String?,
        providerBackdropUrl: json['providerBackdropUrl'] as String?,
      );

  /// Best-effort "is this a live channel, not VOD/an episode" signal from
  /// just a raw id — the same convention `PlayerScreen._searchScope`
  /// already used in one place; centralized here so every caller that
  /// needs to tell live apart from VOD (without trusting the video
  /// controller's own `duration`, which some live HLS streams misreport as
  /// their current DVR sliding-window length instead of zero/unknown —
  /// see `PlayerControls.isLive`'s doc comment) shares one answer instead
  /// of each guessing separately. Xtream ids are prefixed at creation time
  /// (`xt_vod_...`/`xt_ep_...` — see XtreamApiService); M3U-mode channels
  /// carry no such distinction at all, a pre-existing, separate
  /// limitation — this only returns a confident answer for Xtream ids.
  /// Takes a raw id (`Channel.rawId`, not `Channel.id`) — the playlist
  /// prefix on `id` would otherwise mask these provider-native prefixes.
  /// Archive tab titles (`arc_vod_`/`arc_ep_`, see ArchiveService) are VOD too.
  static bool isLiveId(String rawId) =>
      !(rawId.startsWith('xt_vod_') ||
          rawId.startsWith('xt_ep_') ||
          isArchiveId(rawId));

  /// An Archive tab movie/episode (ArchiveService.resolve) — no playlist
  /// profile backs it.
  static bool isArchiveId(String rawId) =>
      rawId.startsWith('arc_vod_') || rawId.startsWith('arc_ep_');
}
