import '../utils/constants.dart';

/// One playlist's login/config, part of the app's list of playlists (see
/// `PlaylistManager`, `StorageService.getPlaylists`/`setPlaylists`).
/// Replaces what used to be a handful of single global scalar prefs
/// (`keyM3uUrl`, `keyXtreamServer`/`Username`/`Password`, etc.) — those
/// only ever supported exactly one playlist app-wide.
class PlaylistProfile {
  PlaylistProfile({
    required this.id,
    required this.name,
    required this.mode,
    this.m3uUrl,
    this.epgUrl,
    this.xtreamServer,
    this.xtreamUsername,
    this.xtreamPassword,
    this.enabled = true,
    this.includeLive = true,
    this.includeMovies = true,
    this.includeSeries = true,
    this.categoryLayout = 'auto',
    required this.sortOrder,
    this.liveSortOrder,
    this.vodSortOrder,
    this.seriesSortOrder,
    this.syncFrequencyDays = AppConstants.defaultSyncFrequencyDays,
    required this.createdAt,
    this.expiresAt,
    this.maxConnections,
    List<String>? backupServers,
    this.lastWorkingServer,
  }) : backupServers = backupServers ?? <String>[];

  /// Stable identifier, generated once and never reused — every
  /// per-playlist prefs key, cache-file name, and catalog-database row
  /// this playlist owns is namespaced by this id (see `Channel
  /// .playlistId`'s doc comment). `'migrated_default'` is reserved for the
  /// one playlist an upgrade from the old single-playlist version
  /// synthesizes — see `PlaylistManager._migrateLegacySinglePlaylist`.
  final String id;

  final String name;

  /// 'm3u' or 'xtream' — same values `StorageService.getPlaylistMode`
  /// used to store as a single global scalar.
  final String mode;

  final String? m3uUrl;
  final String? epgUrl;
  final String? xtreamServer;
  final String? xtreamUsername;
  final String? xtreamPassword;

  bool enabled;

  /// auto preserves the organisation of installs predating this setting.
  final String categoryLayout; // auto, provider, organised

  /// Display/load order in every merged list (Live TV groups, Movies/TV
  /// Shows categories) — lower sorts first, so "Playlist A's groups, then
  /// a separator, then Playlist B's groups" has a stable, user-visible
  /// order instead of whatever order a Map/Set happens to iterate in. The
  /// base/fallback order — see [liveSortOrder]/[vodSortOrder]/
  /// [seriesSortOrder] for the per-tab overrides that take priority over
  /// this when set.
  int sortOrder;

  /// Independent per-tab overrides of [sortOrder]. Null retains the shared playlist order;
  /// changing one tab does not reorder the others.
  int? liveSortOrder;
  int? vodSortOrder;
  int? seriesSortOrder;

  /// [sortOrder], unless a 'tv'/'vod'/'series' override is set for
  /// [tabCategory] — see [liveSortOrder]'s doc comment.
  int sortOrderFor(String tabCategory) => switch (tabCategory) {
        'tv' => liveSortOrder ?? sortOrder,
        'vod' => vodSortOrder ?? sortOrder,
        'series' => seriesSortOrder ?? sortOrder,
        _ => sortOrder,
      };

  /// "Update content every N days" — used to live as one global setting
  /// (`AppConstants.keySyncFrequencyDays`); now per-playlist, since two
  /// playlists can reasonably want different refresh cadences.
  int syncFrequencyDays;

  final DateTime createdAt;

  /// From the Xtream account's own `user_info.exp_date` (an epoch-seconds
  /// string) — null for M3U playlists (no such concept), and also null
  /// for an Xtream account that hasn't reported one yet, or reports "0"/
  /// no expiry at all (some panels use that for a lifetime/reseller-
  /// unlimited account) — never a fabricated placeholder date either way.
  /// Refreshed every time `PlaylistSession.loadFromXtream` successfully
  /// re-authenticates, not just once at add time, so a provider that
  /// extends/changes an account's expiry shows the current value on the
  /// next connect rather than whatever it was when first added.
  DateTime? expiresAt;

  /// Provider-reported maximum connections, refreshed on successful authentication. Null
  /// means unknown; zero may denote an unlimited account. This metadata is distinct from
  /// local decoder capacity.
  int? maxConnections;

  /// Alternate server URLs for this same account, tried in order when
  /// [xtreamServer] itself can't be reached (see
  /// `PlaylistSession.connectWithFallback`). Same username/password —
  /// providers that hand out more than one server hand out extra
  /// hostnames for one subscription, not extra subscriptions.
  ///
  /// Deliberately only editable from the playlist's own manager screen
  /// after it exists, never from the initial add form: a first-time add
  /// is already the step most likely to be fumbled, and nobody knows
  /// their backup hostnames before they've got the playlist working.
  List<String> backupServers;

  /// Whichever of [xtreamServer]/[backupServers] actually answered last
  /// time, re-tried first on the next connect. Without this, a primary
  /// that's been down for a week costs every single launch the full
  /// failed-attempt-plus-delay cycle before falling back to the server
  /// that's been doing the work all along.
  ///
  /// Not a reordering of the user's own list — the primary they
  /// configured stays the primary they see. This is runtime memory of
  /// what worked, nothing more, and is simply ignored if it no longer
  /// appears in either field (e.g. they edited the server since).
  String? lastWorkingServer;

  /// Every server worth trying for this playlist, in the order to try
  /// them: last-known-good first (if it's still one of the configured
  /// ones), then the primary, then the backups. Duplicates removed —
  /// the last-known-good server is normally also the primary or one of
  /// the backups, and trying it twice would just double the wait.
  List<String> get serverCandidates {
    final configured = <String>[
      if (xtreamServer != null && xtreamServer!.isNotEmpty) xtreamServer!,
      ...backupServers.where((s) => s.isNotEmpty),
    ];
    final last = lastWorkingServer;
    return <String>{
      if (last != null && configured.contains(last)) last,
      ...configured,
    }.toList();
  }

  /// Content supplied by this playlist; independent of main-tab visibility.
  final bool includeLive, includeMovies, includeSeries;

  PlaylistProfile copyWith({
    String? name,
    String? mode,
    String? m3uUrl,
    String? epgUrl,
    String? xtreamServer,
    String? xtreamUsername,
    String? xtreamPassword,
    bool? enabled,
    bool? includeLive,
    bool? includeMovies,
    bool? includeSeries,
    String? categoryLayout,
    int? sortOrder,
    // Nullable fields that need their own "was this even passed" flag —
    // a plain `?? this.liveSortOrder` can't distinguish "caller wants
    // this cleared back to null (fall back to sortOrder)" from "caller
    // didn't mention it at all", unlike every other field above where
    // null-means-unset was never a meaningful distinct state to begin
    // with.
    int? liveSortOrder,
    bool clearLiveSortOrder = false,
    int? vodSortOrder,
    bool clearVodSortOrder = false,
    int? seriesSortOrder,
    bool clearSeriesSortOrder = false,
    int? syncFrequencyDays,
    DateTime? expiresAt,
    int? maxConnections,
    List<String>? backupServers,
    String? lastWorkingServer,
  }) =>
      PlaylistProfile(
        id: id,
        name: name ?? this.name,
        mode: mode ?? this.mode,
        m3uUrl: m3uUrl ?? this.m3uUrl,
        epgUrl: epgUrl ?? this.epgUrl,
        xtreamServer: xtreamServer ?? this.xtreamServer,
        xtreamUsername: xtreamUsername ?? this.xtreamUsername,
        xtreamPassword: xtreamPassword ?? this.xtreamPassword,
        enabled: enabled ?? this.enabled,
        includeLive: includeLive ?? this.includeLive,
        includeMovies: includeMovies ?? this.includeMovies,
        includeSeries: includeSeries ?? this.includeSeries,
        categoryLayout: categoryLayout ?? this.categoryLayout,
        sortOrder: sortOrder ?? this.sortOrder,
        liveSortOrder:
            clearLiveSortOrder ? null : (liveSortOrder ?? this.liveSortOrder),
        vodSortOrder:
            clearVodSortOrder ? null : (vodSortOrder ?? this.vodSortOrder),
        seriesSortOrder: clearSeriesSortOrder
            ? null
            : (seriesSortOrder ?? this.seriesSortOrder),
        syncFrequencyDays: syncFrequencyDays ?? this.syncFrequencyDays,
        createdAt: createdAt,
        expiresAt: expiresAt ?? this.expiresAt,
        maxConnections: maxConnections ?? this.maxConnections,
        backupServers: backupServers ?? List<String>.from(this.backupServers),
        lastWorkingServer: lastWorkingServer ?? this.lastWorkingServer,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mode': mode,
        'm3uUrl': m3uUrl,
        'epgUrl': epgUrl,
        'xtreamServer': xtreamServer,
        'xtreamUsername': xtreamUsername,
        'xtreamPassword': xtreamPassword,
        'enabled': enabled,
        'includeLive': includeLive,
        'includeMovies': includeMovies,
        'includeSeries': includeSeries,
        'categoryLayout': categoryLayout,
        'sortOrder': sortOrder,
        'liveSortOrder': liveSortOrder,
        'vodSortOrder': vodSortOrder,
        'seriesSortOrder': seriesSortOrder,
        'syncFrequencyDays': syncFrequencyDays,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'maxConnections': maxConnections,
        'backupServers': backupServers,
        'lastWorkingServer': lastWorkingServer,
      };

  factory PlaylistProfile.fromJson(Map<String, dynamic> json) =>
      PlaylistProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        mode: json['mode'] as String,
        m3uUrl: json['m3uUrl'] as String?,
        epgUrl: json['epgUrl'] as String?,
        xtreamServer: json['xtreamServer'] as String?,
        xtreamUsername: json['xtreamUsername'] as String?,
        xtreamPassword: json['xtreamPassword'] as String?,
        enabled: json['enabled'] as bool? ?? true,
        includeLive: json['includeLive'] as bool? ?? true,
        includeMovies: json['includeMovies'] as bool? ?? true,
        includeSeries: json['includeSeries'] as bool? ?? true,
        categoryLayout:
            const {'provider', 'organised'}.contains(json['categoryLayout'])
                ? json['categoryLayout'] as String
                : 'auto',
        sortOrder: json['sortOrder'] as int? ?? 0,
        liveSortOrder: json['liveSortOrder'] as int?,
        vodSortOrder: json['vodSortOrder'] as int?,
        seriesSortOrder: json['seriesSortOrder'] as int?,
        syncFrequencyDays: json['syncFrequencyDays'] as int? ??
            AppConstants.defaultSyncFrequencyDays,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.tryParse(json['expiresAt'] as String),
        maxConnections: json['maxConnections'] as int?,
        backupServers: (json['backupServers'] as List?)
                ?.map((e) => e.toString())
                .where((s) => s.isNotEmpty)
                .toList() ??
            <String>[],
        lastWorkingServer: json['lastWorkingServer'] as String?,
      );

  bool get isXtream => mode == 'xtream';
}
