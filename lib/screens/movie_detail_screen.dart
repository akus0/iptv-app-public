import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/vod_details.dart';
import '../services/desktop_mini_player.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../services/tracker_api.dart';
import '../services/tracker_sync.dart';
import '../services/watch_tracker.dart';
import '../utils/display_title.dart';
import '../utils/image_urls.dart';
import '../utils/tv_theme.dart';
import '../widgets/detail_header.dart';
import '../widgets/hold_to_activate.dart';
import 'desktop_player_screen.dart';
import 'player_screen.dart';

/// Movie details and playback actions. Fetch metadata on demand through
/// PlaylistManager.getVodDetails, shared with the browse cache. Navigate explicitly
/// between the back button and action row.
class MovieDetailScreen extends StatefulWidget {
  const MovieDetailScreen({super.key, required this.channel});

  final Channel channel;

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  VodDetails? _details;
  bool _loading = true;

  final _backNode = FocusNode(debugLabel: 'movie-back');
  final _playNode = FocusNode(debugLabel: 'movie-play');
  final _restartNode = FocusNode(debugLabel: 'movie-restart');
  final _favNode = FocusNode(debugLabel: 'movie-fav');
  final _pageScroll = ScrollController();
  final List<Timer> _refreshTimers = [];

  @override
  void initState() {
    super.initState();
    final playlist = context.read<PlaylistManager>();
    _details = playlist.peekVodDetails(widget.channel.id);
    _loading = _details == null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playNode.requestFocus();
    });
    _load(playlist);
    unawaited(_syncTrackers());
  }

  /// Trakt / Simkl by the provider's TMDB id: the play is reported, and a
  /// watch or pause made elsewhere fills in this movie's mark / resume.
  Future<void> _syncTrackers() async {
    final tmdb = widget.channel.tmdbId;
    if (tmdb == null || tmdb.isEmpty || tmdb == '0') return;
    WatchTracker.instance
        .register(widget.channel.id, TrackedItem.movie(null, tmdb: tmdb));
    final changed = await TrackerSync.instance.applyToMovie(
        context.read<StorageService>(),
        tmdb: tmdb,
        channelId: widget.channel.id);
    if (changed && mounted) setState(() {});
  }

  Future<void> _load(PlaylistManager playlist) async {
    try {
      // Cache-first — also stamps the provider's HD poster/backdrop onto
      // the channel (see PlaylistManager.getVodDetails).
      final details = await playlist.getVodDetails(widget.channel);
      if (mounted) setState(() => _details = details);
    } catch (e) {
      debugPrint('MovieDetailScreen: load failed: ${e.runtimeType}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    for (final t in _refreshTimers) {
      t.cancel();
    }
    for (final n in [_backNode, _playNode, _restartNode, _favNode]) {
      n.dispose();
    }
    _pageScroll.dispose();
    super.dispose();
  }

  // --- Actions ------------------------------------------------------------

  /// Progress lives in prefs, written by the player; re-read after it pops
  /// (same follow-up refreshes as SeriesDetailScreen — Android's player
  /// saves the final position in a post-frame stop after its route is gone).
  void _refreshProgress() {
    if (!mounted) return;
    setState(() {});
    for (final timer in _refreshTimers) {
      timer.cancel();
    }
    _refreshTimers.clear();
    for (final ms in const [500, 1500]) {
      _refreshTimers.add(Timer(Duration(milliseconds: ms), () {
        if (mounted) setState(() {});
      }));
    }
  }

  bool _openingPlayback = false;
  Future<void> _play({bool restart = false}) async {
    if (_openingPlayback || ModalRoute.of(context)?.isCurrent == false) return;
    _openingPlayback = true;
    try {
      final channel = widget.channel;
      final storage = context.read<StorageService>();
      if (restart) await storage.setLastPosition(channel.id, 0);
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      // See TvHomeScreen._selectChannel's matching comment — Windows has no
      // PlaybackService-compatible player at all, so this bypasses it (and
      // Continue Watching/resume) entirely via a standalone screen.
      if (Platform.isWindows) {
        // Abandons any minimized live channel first, so it can't keep
        // playing audio in the background behind this unrelated movie.
        DesktopMiniPlayer.instance.clear();
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DesktopPlayerScreen(channel: channel)));
        _refreshProgress();
        return;
      }
      // The player owns the single play request and can show connection status
      // immediately, rather than leaving the details page waiting for a stream.
      await PlayerScreen.open(Navigator.of(context), channel);
      _refreshProgress();
    } finally {
      _openingPlayback = false;
    }
  }

  Future<void> _toggleFavorite(Channel current) async {
    final messenger = ScaffoldMessenger.of(context);
    await context.read<PlaylistManager>().toggleFavorite(current);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(SnackBar(
      content: Text(current.isFavorite
          ? tr('Added to Favorites')
          : tr('Removed from Favorites')),
      duration: const Duration(seconds: 2),
    ));
  }

  void _goBack() {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    // Same stray-Select guard as SeriesDetailScreen._goBack.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).maybePop();
  }

  void _revealTop() {
    if (_pageScroll.hasClients && _pageScroll.offset != 0) {
      _pageScroll.jumpTo(0);
    }
  }

  static Map<ShortcutActivator, VoidCallback> _arrows({
    VoidCallback? up,
    VoidCallback? down,
    VoidCallback? left,
    VoidCallback? right,
  }) {
    void none() {}
    return {
      const SingleActivator(LogicalKeyboardKey.arrowUp): up ?? none,
      const SingleActivator(LogicalKeyboardKey.arrowDown): down ?? none,
      const SingleActivator(LogicalKeyboardKey.arrowLeft): left ?? none,
      const SingleActivator(LogicalKeyboardKey.arrowRight): right ?? none,
    };
  }

  // --- Display helpers -----------------------------------------------------

  String get _title => cleanDisplayTitle(widget.channel.name);

  /// TMDB backdrop, then the provider's (get_vod_info backdrop_path).
  String? get _backdropUrl =>
      widget.channel.anyBackdropUrl ?? _details?.backdropUrl;

  /// TMDB poster, then the provider's bigger cover, then the list icon.
  String? get _posterUrl => firstImageUrl([
        widget.channel.posterUrl,
        _details?.posterUrl,
        widget.channel.providerPosterUrl,
        widget.channel.logoUrl,
      ]);

  int? get _durationMs {
    final secs = _details?.durationSeconds;
    if (secs != null && secs > 0) return secs * 1000;
    final saved =
        context.read<StorageService>().getLastDuration(widget.channel.id);
    return saved > 0 ? saved : null;
  }

  String? get _rating {
    final r = _details?.rating ?? widget.channel.rating;
    if (r == null) return null;
    final v = double.tryParse(r);
    if (v == null || v <= 0) return null;
    return r;
  }

  List<String> _metaChips(bool watched) {
    final chips = <String>[];
    final year = _details?.year ??
        widget.channel.releaseDate?.year ??
        yearFromTitle(widget.channel.name);
    if (year != null) chips.add('$year');
    final ms = _durationMs;
    if (ms != null) {
      chips.add(_formatMinutes(math.max((ms / 60000).round(), 1)));
    }
    chips.addAll(qualityTagsOf(widget.channel.name));
    final genre = _details?.genre;
    if (genre != null) {
      chips.addAll(genre
          .split(RegExp(r'\s*[,/&|]\s*'))
          .where((g) => g.isNotEmpty)
          .take(2));
    }
    if (watched) chips.add(tr('Watched'));
    return chips;
  }

  String? get _credits {
    final cast = _details?.cast;
    final director = _details?.director;
    final parts = <String>[
      if (director != null) tr('Director: {names}', {'names': director}),
      if (cast != null)
        tr('Cast: {names}', {
          'names': cast.split(RegExp(r'\s*,\s*')).take(4).join(', '),
        }),
    ];
    return parts.isEmpty ? null : parts.join('   ·   ');
  }

  static String _formatMinutes(int minutes) {
    if (minutes >= 60) {
      return tr('{h} h {m} min', {
        'h': minutes ~/ 60,
        'm': (minutes % 60).toString().padLeft(2, '0'),
      });
    }
    return tr('{m} min', {'m': minutes});
  }

  // --- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    // Re-read the live copy so the favorite star reflects toggles made here.
    final current = playlist.allCachedVod.firstWhere(
      (c) => c.id == widget.channel.id,
      orElse: () => widget.channel,
    );
    return withTvThemeIfNeeded(
      context,
      (context) => Scaffold(
        backgroundColor: Colors.black,
        body: SwallowHeldActivate(
          child: CallbackShortcuts(
            bindings: {
              if (Platform.isWindows)
                const SingleActivator(LogicalKeyboardKey.escape): _goBack,
            },
            child: LayoutBuilder(builder: (context, c) {
              final narrow = c.maxWidth < 640 || c.maxHeight > c.maxWidth;
              final s = narrow
                  ? 1.0
                  : math
                      .min(c.maxWidth / 960, c.maxHeight / 540)
                      .clamp(1.0, 2.2);
              return DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white),
                child: narrow
                    ? _buildNarrow(c, current)
                    : _buildWide(c, s, current),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildWide(BoxConstraints c, double s, Channel current) {
    final w = c.maxWidth;
    final h = c.maxHeight;
    final backdrop = _backdropUrl;
    final poster = backdrop == null ? _posterUrl : null;
    final pad = 32 * s;
    final posterW = 150 * s;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          right: 0,
          width: backdrop != null ? w * 0.74 : w,
          height: h * 0.8,
          child: DetailBackdrop(url: backdrop, fadeLeft: true),
        ),
        SingleChildScrollView(
          controller: _pageScroll,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: h),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad - 8 * s, 14 * s, pad, 0),
                    child: _buildBackButton(s),
                  ),
                  const Spacer(),
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, 12 * s, pad, 36 * s),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (poster != null) ...[
                          DetailPoster(url: poster, width: posterW),
                          SizedBox(width: 24 * s),
                        ],
                        ConstrainedBox(
                          constraints: BoxConstraints(
                              maxWidth: math.min(
                                  w * 0.6,
                                  w -
                                      2 * pad -
                                      (poster != null ? posterW + 24 * s : 0))),
                          child: _buildHeaderText(s, current),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackButton(double s) {
    return CallbackShortcuts(
      bindings: _arrows(down: _playNode.requestFocus),
      child: DetailPillButton(
        focusNode: _backNode,
        icon: Icons.arrow_back,
        scale: s,
        compact: true,
        onPressed: _goBack,
        onFocused: _revealTop,
      ),
    );
  }

  Widget _buildHeaderText(double s, Channel current, {bool narrow = false}) {
    final scheme = Theme.of(context).colorScheme;
    final storage = context.read<StorageService>();
    final watched = storage.isFullyWatched(widget.channel.id);
    final plot = _details?.plot ??
        context
            .read<PlaylistManager>()
            .peekCachedDescription(widget.channel.id);
    final credits = _credits;
    final rating = _rating;
    final chips = _metaChips(watched);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: (narrow ? 26 : 34) * s,
            fontWeight: FontWeight.w800,
            height: 1.1,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 12)],
          ),
        ),
        SizedBox(height: 10 * s),
        Wrap(
          spacing: 6 * s,
          runSpacing: 6 * s,
          children: [
            if (rating != null)
              DetailMetaChip(
                scale: s,
                leading: Icon(Icons.star_rounded,
                    size: 14 * s, color: scheme.primary),
                label: rating,
                strong: true,
              ),
            for (final chip in chips) DetailMetaChip(scale: s, label: chip),
          ],
        ),
        if (plot != null) ...[
          SizedBox(height: 10 * s),
          Text(
            plot,
            maxLines: narrow ? 6 : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 13.5 * s,
              height: 1.4,
              shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
            ),
          ),
        ] else if (_loading) ...[
          SizedBox(height: 12 * s),
          SizedBox(
            width: 18 * s,
            height: 18 * s,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
        if (credits != null) ...[
          SizedBox(height: 6 * s),
          Text(
            credits,
            maxLines: narrow ? 3 : 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white54, fontSize: 12 * s),
          ),
        ],
        SizedBox(height: 16 * s),
        _buildActions(s, current, narrow: narrow),
      ],
    );
  }

  Widget _buildActions(double s, Channel current, {bool narrow = false}) {
    final storage = context.read<StorageService>();
    final id = widget.channel.id;
    final positionMs = storage.getLastPosition(id);
    final watched = storage.isFullyWatched(id);
    final resume = positionMs > 0 && !watched;
    final fraction = resume ? storage.getWatchedFraction(id) : null;

    String playLabel = tr('Play');
    if (resume) {
      playLabel = tr('Resume');
      final total = _durationMs;
      if (total != null && total > positionMs) {
        final left = math.max(((total - positionMs) / 60000).ceil(), 1);
        playLabel =
            '$playLabel  ·  ${tr('{minutes} min left', {'minutes': left})}';
      }
    }

    final nodes = <FocusNode>[
      _playNode,
      if (resume) _restartNode,
      _favNode,
    ];
    void move(int delta) {
      final i = nodes.indexWhere((n) => n.hasFocus);
      final j = i + delta;
      if (i >= 0 && j >= 0 && j < nodes.length) nodes[j].requestFocus();
    }

    final row = Wrap(
      spacing: 10 * s,
      runSpacing: 10 * s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DetailPillButton(
          focusNode: _playNode,
          icon: Icons.play_arrow_rounded,
          label: playLabel,
          emphasized: true,
          scale: s,
          // A finished movie starts over; a started one resumes where the
          // player saved it (PlaybackService reads the same position).
          onPressed: () => _play(restart: watched),
          onFocused: _revealTop,
        ),
        if (resume)
          DetailPillButton(
            focusNode: _restartNode,
            icon: Icons.replay_rounded,
            label: tr('Restart'),
            scale: s,
            onPressed: () => _play(restart: true),
            onFocused: _revealTop,
          ),
        DetailPillButton(
          focusNode: _favNode,
          icon: current.isFavorite
              ? Icons.star_rounded
              : Icons.star_border_rounded,
          label: tr('Favorites'),
          selected: current.isFavorite,
          scale: s,
          onPressed: () => _toggleFavorite(current),
          onFocused: _revealTop,
        ),
      ],
    );

    final scheme = Theme.of(context).colorScheme;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fraction != null) ...[
          SizedBox(
            width: 280 * s,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 4 * s,
                backgroundColor: Colors.white24,
                color: scheme.secondary,
              ),
            ),
          ),
          SizedBox(height: 10 * s),
        ],
        row,
      ],
    );
    if (narrow) return content;
    return CallbackShortcuts(
      bindings: _arrows(
        up: _backNode.requestFocus,
        left: () => move(-1),
        right: () => move(1),
      ),
      child: content,
    );
  }

  // --- Narrow (phone portrait) ---------------------------------------------------

  Widget _buildNarrow(BoxConstraints c, Channel current) {
    final backdrop = _backdropUrl;
    final poster = backdrop == null ? _posterUrl : null;
    final topInset = MediaQuery.of(context).padding.top;
    return SingleChildScrollView(
      controller: _pageScroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              SizedBox(
                width: c.maxWidth,
                height: backdrop != null
                    ? c.maxWidth * 9 / 16 + topInset
                    : 120 + topInset,
                child: DetailBackdrop(url: backdrop, fadeLeft: false),
              ),
              Positioned(
                top: topInset + 8,
                left: 8,
                child: DetailPillButton(
                  focusNode: _backNode,
                  icon: Icons.arrow_back,
                  scale: 1,
                  compact: true,
                  onPressed: _goBack,
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                16, 0, 16, 24 + MediaQuery.of(context).padding.bottom),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (poster != null) ...[
                  DetailPoster(url: poster, width: 96),
                  const SizedBox(width: 14),
                ],
                Expanded(child: _buildHeaderText(1, current, narrow: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
