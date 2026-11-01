import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/series_details.dart';
import '../models/xtream_series.dart';
import '../services/desktop_mini_player.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../services/tracker_api.dart';
import '../services/tracker_sync.dart';
import '../services/watch_tracker.dart';
import '../utils/display_title.dart';
import '../utils/image_urls.dart';
import '../utils/tv_theme.dart';
import '../widgets/detail_header.dart';
import '../widgets/hd_network_image.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/sports_widgets.dart' show SportsRowArrows;
import 'desktop_player_screen.dart';
import 'player_screen.dart';

/// What the primary button plays: the episode to resume (saved position,
/// not finished), else the one after the last finished, else the first.
typedef _NextUp = ({Channel episode, bool resume});

/// Series details, season selection and episode playback. Fetch episodes and metadata on
/// demand; the series container itself is not playable. Phone portrait uses a lazy
/// vertical episode list. Optional loadEpisodes and playEpisode callbacks support
/// external catalogue sources.
class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({
    super.key,
    required this.series,
    this.loadEpisodes,
    this.playEpisode,
    this.showFavorite = true,
    this.imdbId,
  });

  /// The show's IMDb id when known (Media Hub shows): with
  /// [XtreamSeries.tmdbId] (IPTV, from the provider) it matches the show
  /// on Trakt/Simkl — watched episodes get their mark, plays are reported.
  final String? imdbId;

  final XtreamSeries series;

  /// Replaces `PlaylistManager.loadSeriesEpisodes` when set.
  final Future<SeriesEpisodesResult> Function()? loadEpisodes;

  /// Replaces the push to the player when set: gets the episode and the
  /// whole ordered list (the up-next queue). Restart is already applied.
  final Future<void> Function(Channel episode, List<Channel> allEpisodes)?
      playEpisode;

  /// Favorites belong to a playlist; Archive shows have none.
  final bool showFavorite;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  SeriesEpisodesResult? _data;
  bool _failed = false;

  List<int> _seasons = const [];

  /// Every episode across all seasons, in order — the auto-advance queue.
  List<Channel> _allEpisodes = const [];
  final Map<String, int> _seasonOfEpisode = {};
  int? _season;

  /// Highlighted (focused, or last focused) episode index per season — the
  /// detail strip shows it, and Down/Up returns to it.
  final Map<int, int> _highlight = {};

  final _backNode = FocusNode(debugLabel: 'series-back');
  final _playNode = FocusNode(debugLabel: 'series-play');
  final _restartNode = FocusNode(debugLabel: 'series-restart');
  final _favNode = FocusNode(debugLabel: 'series-fav');
  final Map<int, FocusNode> _seasonNodes = {};
  final Map<int, FocusNode> _episodeNodes = {};
  final _episodeScroll = ScrollController();
  final _pageScroll = ScrollController();
  final _seasonsKey = GlobalKey();
  final _episodesKey = GlobalKey();
  final List<Timer> _refreshTimers = [];

  /// Where focus goes when there's no Play button: Favorites, or Back
  /// when the page shows no Favorites.
  FocusNode get _fallbackNode => widget.showFavorite ? _favNode : _backNode;

  FocusNode _seasonNode(int season) => _seasonNodes.putIfAbsent(
      season, () => FocusNode(debugLabel: 'season-$season'));
  FocusNode _episodeNode(int index) => _episodeNodes.putIfAbsent(
      index, () => FocusNode(debugLabel: 'episode-$index'));

  bool get _loaded => _data != null;
  SeriesDetails? get _details => _data?.details;

  @override
  void initState() {
    super.initState();
    // Something visible holds focus while the episodes load (and stays
    // there if loading fails); Play takes it over once they're in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_loaded) _backNode.requestFocus();
    });
    _load();
  }

  Future<void> _load() async {
    final playlist = context.read<PlaylistManager>();
    try {
      final custom = widget.loadEpisodes;
      final result = custom != null
          ? await custom()
          : await playlist.loadSeriesEpisodes(widget.series);
      // Shares its plot with the Movies/TV Shows browse hero's description
      // cache — browsing back to this title shows it instantly afterward.
      if (custom == null) {
        playlist.cacheDescription(widget.series.id, result.plot);
      }
      if (!mounted) return;
      final seasons = result.episodes.keys
          .where((s) => result.episodes[s]!.isNotEmpty)
          .toList()
        ..sort();
      setState(() {
        _data = result;
        _seasons = seasons;
        _allEpisodes = [for (final s in seasons) ...result.episodes[s]!];
        _resumeTargetDirty = true;
        for (final s in seasons) {
          for (final e in result.episodes[s]!) {
            _seasonOfEpisode[e.id] = s;
          }
        }
        final next = _nextUp();
        if (next != null) {
          final s = _seasonOfEpisode[next.episode.id]!;
          _season = s;
          _highlight[s] = _episodesOf(s).indexOf(next.episode);
        } else {
          _season = seasons.isEmpty ? null : seasons.first;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_allEpisodes.isNotEmpty) _playNode.requestFocus();
        _scrollEpisodeIntoView(_highlight[_season] ?? 0);
      });
      unawaited(_syncTrackers(result));
    } catch (e) {
      debugPrint('SeriesDetailScreen: load failed: ${e.runtimeType}');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Season / episode number per episode channel (the provider's or the
  /// meta's numbering) — what Trakt/Simkl match on.
  Map<String, (int, int)> _episodeNumbers(SeriesEpisodesResult result) => {
        for (final e in _allEpisodes)
          if (result.details?.episodes[e.id] case final d?
              when d.episodeNumber != null)
            e.id: (d.season, d.episodeNumber!),
      };

  /// Trakt / Simkl: plays of these episodes are reported, and episodes
  /// watched (or paused) elsewhere are filled in, then the page redraws.
  Future<void> _syncTrackers(SeriesEpisodesResult result) async {
    final imdb = widget.imdbId;
    final tmdb = widget.series.tmdbId;
    if (imdb == null && (tmdb == null || tmdb.isEmpty)) return;
    final numbers = _episodeNumbers(result);
    for (final e in numbers.entries) {
      WatchTracker.instance.register(
          e.key,
          TrackedItem.episode(imdb,
              tmdb: tmdb, season: e.value.$1, episode: e.value.$2));
    }
    final storage = context.read<StorageService>();
    final changed = await TrackerSync.instance
        .applyToSeries(storage, imdb: imdb, tmdb: tmdb, episodes: numbers);
    if (changed && mounted) setState(() => _resumeTargetDirty = true);
  }

  @override
  void dispose() {
    for (final t in _refreshTimers) {
      t.cancel();
    }
    for (final n in [
      _backNode,
      _playNode,
      _restartNode,
      _favNode,
      ..._seasonNodes.values,
      ..._episodeNodes.values,
    ]) {
      n.dispose();
    }
    _episodeScroll.dispose();
    _pageScroll.dispose();
    super.dispose();
  }

  List<Channel> _episodesOf(int season) =>
      _data?.episodes[season] ?? const <Channel>[];

  // --- Progress / next up -------------------------------------------------

  /// Positions are the ones `PlaybackService` saves under `Channel.id` (the
  /// same `playlistId::xt_ep_<id>` ids built in `getSeriesEpisodes`, and
  /// the same objects handed to the player). "Watched" is derived:
  /// [StorageService.isFullyWatched] (>= 95% of the saved duration).
  _NextUp? _resumeTarget;
  bool _resumeTargetDirty = true;
  // Episode focus changes only presentation. Recompute watch progress after
  // playback or a watched-state edit, not on every remote movement.
  _NextUp? _nextUp() {
    if (_resumeTargetDirty) {
      _resumeTarget = _computeNextUp();
      _resumeTargetDirty = false;
    }
    return _resumeTarget;
  }

  _NextUp? _computeNextUp() {
    if (_allEpisodes.isEmpty) return null;
    final storage = context.read<StorageService>();
    final index = <String, int>{
      for (var i = 0; i < _allEpisodes.length; i++) _allEpisodes[i].id: i,
    };
    _NextUp after(int i) => (
          episode: _allEpisodes[math.min(i + 1, _allEpisodes.length - 1)],
          resume: false,
        );
    // 1. The most recently played episode of this show (Continue Watching).
    for (final c in context.read<PlaybackService>().recentlyPlayed) {
      final i = index[c.id];
      if (i == null) continue;
      if (storage.isFullyWatched(c.id)) return after(i);
      return (
        episode: _allEpisodes[i],
        resume: storage.getLastPosition(c.id) > 0,
      );
    }
    // 2. No history entry (cleared, Windows, ...): the saved positions.
    var lastStarted = -1;
    var lastFinished = -1;
    for (var i = 0; i < _allEpisodes.length; i++) {
      final id = _allEpisodes[i].id;
      if (storage.isFullyWatched(id)) {
        lastFinished = i;
      } else if (storage.getLastPosition(id) > 0) {
        lastStarted = i;
      }
    }
    if (lastStarted > lastFinished) {
      return (episode: _allEpisodes[lastStarted], resume: true);
    }
    if (lastFinished >= 0) return after(lastFinished);
    return (episode: _allEpisodes.first, resume: false);
  }

  /// Progress lives in prefs, written by the player; re-read after it pops.
  /// Android's player saves the final position in a post-frame stop after
  /// its route is gone, so a couple of short follow-up refreshes catch it.
  void _refreshProgress() {
    if (!mounted) return;
    setState(() => _resumeTargetDirty = true);
    for (final timer in _refreshTimers) {
      timer.cancel();
    }
    _refreshTimers.clear();
    for (final ms in const [500, 1500]) {
      _refreshTimers.add(Timer(Duration(milliseconds: ms), () {
        if (mounted) setState(() => _resumeTargetDirty = true);
      }));
    }
  }

  // --- Actions ------------------------------------------------------------

  bool _openingPlayback = false;
  Future<void> _play(Channel episode, {bool restart = false}) async {
    if (_openingPlayback || ModalRoute.of(context)?.isCurrent == false) return;
    _openingPlayback = true;
    try {
      final storage = context.read<StorageService>();
      // A watched episode starts over: one marked by hold sits at 100%, so
      // resuming it would hit the end at once and auto-advance.
      if (restart || storage.isFullyWatched(episode.id)) {
        await storage.setLastPosition(episode.id, 0);
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final custom = widget.playEpisode;
      if (custom != null) {
        await custom(episode, _allEpisodes);
        _refreshProgress();
        return;
      }
      // See TvHomeScreen._selectChannel's matching comment — Windows has no
      // PlaybackService-compatible player at all, so this bypasses it via a
      // standalone screen; the queue is passed so Previous/Next still works.
      if (Platform.isWindows) {
        // Abandons any minimized live channel first, so it can't keep
        // playing audio behind this unrelated episode.
        DesktopMiniPlayer.instance.clear();
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                DesktopPlayerScreen(channel: episode, queue: _allEpisodes)));
      } else {
        // The queue lets playback auto-advance into the next episode near the
        // end (see `PlaybackService._nextInQueue`), across seasons too.
        context.read<PlaybackService>().setUpNextQueue(_allEpisodes);
        await PlayerScreen.open(Navigator.of(context), episode);
      }
      _refreshProgress();
    } finally {
      _openingPlayback = false;
    }
  }

  void _toggleFavorite() {
    context.read<PlaylistManager>().toggleSeriesFavorite(widget.series);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(widget.series.isFavorite
          ? tr('Added to Favorites')
          : tr('Removed from Favorites')),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Hold on an episode: mark it watched (position = duration, so every
  /// progress bar, "Watched" label and Next Up treat it as finished) or,
  /// when it already is, back to unwatched. With no duration known yet
  /// (never played, no provider runtime) a 1 ms stand-in still reads as
  /// 100%; the player overwrites it with the real one on the next play.
  Future<void> _toggleWatched(Channel episode) async {
    final storage = context.read<StorageService>();
    final wasWatched = storage.isFullyWatched(episode.id);
    // Same mark on Trakt / Simkl, when the show is matched there.
    final numbers = _data == null ? null : _episodeNumbers(_data!)[episode.id];
    final tmdb = widget.series.tmdbId;
    if (numbers != null &&
        (widget.imdbId != null || (tmdb != null && tmdb.isNotEmpty))) {
      unawaited(TrackerSync.instance.setWatched(
          TrackedItem.episode(widget.imdbId,
              tmdb: tmdb, season: numbers.$1, episode: numbers.$2),
          watched: !wasWatched));
    }
    if (wasWatched) {
      await storage.setLastPosition(episode.id, 0);
    } else {
      var durationMs = storage.getLastDuration(episode.id);
      if (durationMs <= 0) {
        durationMs =
            (_details?.episodes[episode.id]?.durationSeconds ?? 0) * 1000;
      }
      if (durationMs <= 0) durationMs = 1;
      await storage.setLastDuration(episode.id, durationMs);
      await storage.setLastPosition(episode.id, durationMs);
    }
    if (!mounted) return;
    setState(() => _resumeTargetDirty = true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
            wasWatched ? tr('Marked as unwatched') : tr('Marked as watched')),
        duration: const Duration(seconds: 2),
      ));
  }

  void _goBack() {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    // A stray D-pad Select key-up landing on the tile underneath (the one
    // that opened this screen) used to reopen it right after Back —
    // unfocusing before the pop leaves nothing "armed" for it to hit.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).maybePop();
  }

  void _selectSeason(int season) {
    if (_season == season) return;
    setState(() => _season = season);
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollEpisodeIntoView(_highlight[season] ?? 0, reset: true));
  }

  // --- Focus / scrolling ----------------------------------------------------

  /// Set from the layout scale on every build.
  double _cardExtent = 182;
  double _rowPadding = 24;

  /// Keeps episode [index] inside the row's viewport — computed from the
  /// fixed item extent, so it works for cards the lazy list hasn't built.
  void _scrollEpisodeIntoView(int index, {bool reset = false}) {
    if (!_episodeScroll.hasClients) return;
    final p = _episodeScroll.position;
    final start = _rowPadding + index * _cardExtent;
    final end = start + _cardExtent;
    var target = reset ? 0.0 : p.pixels;
    if (start - _rowPadding < target) target = start - _rowPadding;
    if (end + _rowPadding > target + p.viewportDimension) {
      target = end + _rowPadding - p.viewportDimension;
    }
    target = target.clamp(p.minScrollExtent, p.maxScrollExtent);
    if (target != p.pixels) _episodeScroll.jumpTo(target);
  }

  void _focusEpisode(int index) {
    final season = _season;
    if (season == null) return;
    final count = _episodesOf(season).length;
    if (count == 0) return;
    final i = index.clamp(0, count - 1);
    _scrollEpisodeIntoView(i);
    final node = _episodeNode(i);
    if (node.context != null) {
      node.requestFocus();
    } else {
      // Not built yet by the lazy row — it will be after the jump above.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _episodeNode(i).requestFocus();
      });
    }
  }

  void _focusSeasonsOrEpisodes() {
    if (_seasons.length > 1 && _season != null) {
      _seasonNode(_season!).requestFocus();
    } else {
      _focusEpisode(_highlight[_season] ?? 0);
    }
  }

  /// Vertical page scroll only matters on short windows; on a TV the whole
  /// page fits and this is a no-op.
  void _reveal(GlobalKey key, {required bool atEnd}) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        duration: Duration.zero,
        alignmentPolicy: atEnd
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
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

  String get _title => cleanDisplayTitle(widget.series.name);

  String? get _backdropUrl {
    final fromInfo = _details?.firstBackdrop;
    if (fromInfo != null) return fromInfo;
    // TMDB's, then the get_series list's / an earlier visit's (persisted).
    final known = widget.series.anyBackdropUrl;
    if (known != null) return known;
    // An episode still is landscape too — better than cropping the poster.
    for (final e in _allEpisodes.take(3)) {
      final still = e.logoUrl;
      if (still != null &&
          still.isNotEmpty &&
          still != widget.series.coverUrl) {
        return still;
      }
    }
    return null;
  }

  String? get _posterUrl {
    for (final url in [
      widget.series.posterUrl,
      _details?.coverUrl,
      widget.series.coverUrl,
    ]) {
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  int? get _year =>
      _details?.year ??
      widget.series.releaseDate?.year ??
      yearFromTitle(widget.series.name);

  String? get _rating {
    final r = _details?.rating ?? widget.series.rating;
    if (r == null) return null;
    final v = double.tryParse(r);
    if (v == null || v <= 0) return null;
    return r;
  }

  List<String> get _metaChips {
    final chips = <String>[];
    final year = _year;
    if (year != null) chips.add('$year');
    if (_loaded) {
      if (_seasons.length > 1) {
        chips.add(tr('{n} seasons', {'n': _seasons.length}));
      }
      final n = _allEpisodes.length;
      if (n > 0) {
        chips.add(n == 1 ? tr('1 episode') : tr('{n} episodes', {'n': n}));
      }
    }
    final runTime = _details?.episodeRunTimeMinutes;
    if (runTime != null && runTime > 0) chips.add(_formatMinutes(runTime));
    final genre = _details?.genre;
    if (genre != null) {
      chips.addAll(genre
          .split(RegExp(r'\s*[,/&|]\s*'))
          .where((g) => g.isNotEmpty)
          .take(2));
    }
    return chips;
  }

  String? get _credits {
    final cast = _details?.cast;
    if (cast != null) {
      final names = cast.split(RegExp(r'\s*,\s*')).take(4).join(', ');
      return tr('Cast: {names}', {'names': names});
    }
    final director = _details?.director;
    if (director != null) return tr('Director: {names}', {'names': director});
    return null;
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

  String _seasonLabel(int season) {
    final name = _details?.seasonNames[season];
    if (season == 0) return name ?? tr('Specials');
    // Panels' own names are usually just "Season 1" in English — only a
    // distinctive one is worth showing over the translated label.
    if (name != null &&
        !RegExp(r'^(season|saison|temporada|stagione)\s*\d+$',
                caseSensitive: false)
            .hasMatch(name.trim())) {
      return name;
    }
    return tr('Season {season}', {'season': season});
  }

  int _episodeNumber(Channel episode) {
    final n = _details?.episodes[episode.id]?.episodeNumber;
    if (n != null) return n;
    final season = _seasonOfEpisode[episode.id];
    final list = season == null ? const <Channel>[] : _episodesOf(season);
    return list.indexOf(episode) + 1;
  }

  String _episodeCode(Channel episode) =>
      'S${_seasonOfEpisode[episode.id] ?? 1}E${_episodeNumber(episode)}';

  /// The episode's own title, or null (caller shows "Episode N").
  String? _episodeTitle(Channel episode) {
    final raw = _details?.episodes[episode.id]?.title ?? episode.name;
    return episodeDisplayTitle(raw, widget.series.name);
  }

  /// An episode card's image fallbacks, in order: its own still, the
  /// series backdrop (the header's), the series poster — each one also
  /// taken over when the previous fails to load (see [_Thumb]).
  List<_ThumbImage> _episodeImages(String? still) {
    final out = <_ThumbImage>[];
    void add(String? url, ImageKind kind) {
      if (url == null || url.isEmpty || out.any((i) => i.url == url)) return;
      out.add((url: url, kind: kind));
    }

    add(still, ImageKind.still);
    add(_backdropUrl, ImageKind.backdrop);
    add(_posterUrl, ImageKind.poster);
    return out;
  }

  _EpisodeInfo _info(Channel episode, StorageService storage) {
    final d = _details?.episodes[episode.id];
    final number = _episodeNumber(episode);
    var durationMs = (d?.durationSeconds ?? 0) * 1000;
    if (durationMs <= 0) durationMs = storage.getLastDuration(episode.id);
    final positionMs = storage.getLastPosition(episode.id);
    final watched = storage.isFullyWatched(episode.id);
    final fraction = watched ? null : storage.getWatchedFraction(episode.id);
    String? durationText;
    if (watched) {
      durationText = tr('Watched');
    } else if (fraction != null && durationMs > 0) {
      final left = ((durationMs - positionMs) / 60000).ceil();
      durationText = tr('{minutes} min left', {'minutes': math.max(left, 1)});
    } else if (durationMs > 0) {
      durationText = _formatMinutes(math.max((durationMs / 60000).round(), 1));
    } else if ((_details?.episodeRunTimeMinutes ?? 0) > 0) {
      durationText = _formatMinutes(_details!.episodeRunTimeMinutes!);
    }
    String? airDate;
    final rawDate = d?.airDate;
    if (rawDate != null) {
      final parsed = DateTime.tryParse(rawDate);
      airDate = parsed != null ? DateFormat.yMMMd().format(parsed) : null;
    }
    final title = _episodeTitle(episode);
    return _EpisodeInfo(
      number: number,
      title: title ?? tr('Episode {n}', {'n': number}),
      hasOwnTitle: title != null,
      plot: d?.plot,
      durationText: durationText,
      airDate: airDate,
      watched: watched,
      progress: fraction,
      images: _episodeImages(episode.logoUrl),
    );
  }

  // --- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
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
              _cardExtent = (168 + 14) * s;
              _rowPadding = 24 * s;
              return DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white),
                child: narrow ? _buildNarrow(c) : _buildWide(c, s),
              );
            }),
          ),
        ),
      ),
    );
  }

  // --- Wide (TV / Windows / tablet) --------------------------------------------

  Widget _buildWide(BoxConstraints c, double s) {
    final w = c.maxWidth;
    final h = c.maxHeight;
    final backdrop = _backdropUrl;
    final poster = backdrop == null ? _posterUrl : null;
    final pad = 32 * s;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          right: 0,
          width: backdrop != null ? w * 0.74 : w,
          height: h * 0.74,
          child: DetailBackdrop(url: backdrop, fadeLeft: true),
        ),
        SingleChildScrollView(
          controller: _pageScroll,
          padding: EdgeInsets.only(top: 8 * s, bottom: 10 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: pad - 8 * s),
                child: _buildBackButton(s),
              ),
              SizedBox(height: 4 * s),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (poster != null) ...[
                      DetailPoster(url: poster, width: 116 * s),
                      SizedBox(width: 22 * s),
                    ],
                    ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: math.min(w * 0.6,
                              w - 2 * pad - (poster != null ? 138 * s : 0))),
                      child: _buildHeaderText(s),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12 * s),
              ..._buildEpisodeSection(s, pad),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBackButton(double s) {
    return CallbackShortcuts(
      bindings: _arrows(
        down: () =>
            (_loaded && _allEpisodes.isNotEmpty ? _playNode : _fallbackNode)
                .requestFocus(),
      ),
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

  Widget _buildHeaderText(double s, {bool narrow = false}) {
    final scheme = Theme.of(context).colorScheme;
    final plot = _data?.plot ??
        context.read<PlaylistManager>().peekCachedDescription(widget.series.id);
    final credits = _credits;
    final rating = _rating;
    final chips = _metaChips;
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
            fontSize: (narrow ? 26 : 32) * s,
            fontWeight: FontWeight.w800,
            height: 1.1,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 12)],
          ),
        ),
        SizedBox(height: 8 * s),
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
          SizedBox(height: 8 * s),
          Text(
            plot,
            // 2 on a TV: 3 pushed the episode plot strip off the bottom
            // of a 960x540 (logical) Formuler screen.
            maxLines: narrow ? 5 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 13.5 * s,
              height: 1.4,
              shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
            ),
          ),
        ],
        if (credits != null) ...[
          SizedBox(height: 6 * s),
          Text(
            credits,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white54, fontSize: 12 * s),
          ),
        ],
        SizedBox(height: 12 * s),
        _buildActions(s, narrow: narrow),
      ],
    );
  }

  Widget _buildActions(double s, {bool narrow = false}) {
    final next = _loaded ? _nextUp() : null;
    final nodes = <FocusNode>[
      if (next != null) _playNode,
      if (next != null && next.resume) _restartNode,
      if (widget.showFavorite) _favNode,
    ];
    void move(int delta) {
      final i = nodes.indexWhere((n) => n.hasFocus);
      final j = i + delta;
      if (i >= 0 && j >= 0 && j < nodes.length) nodes[j].requestFocus();
    }

    final buttons = <Widget>[
      if (next != null)
        DetailPillButton(
          focusNode: _playNode,
          icon: Icons.play_arrow_rounded,
          label: next.resume
              ? tr('Resume {code}', {'code': _episodeCode(next.episode)})
              : tr('Play {code}', {'code': _episodeCode(next.episode)}),
          emphasized: true,
          scale: s,
          onPressed: () => _play(next.episode),
          onFocused: _revealTop,
        )
      else if (!_loaded && !_failed)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 8 * s),
          child: SizedBox(
            width: 22 * s,
            height: 22 * s,
            child: const CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      if (next != null && next.resume)
        DetailPillButton(
          focusNode: _restartNode,
          icon: Icons.replay_rounded,
          label: tr('Restart'),
          scale: s,
          onPressed: () => _play(next.episode, restart: true),
          onFocused: _revealTop,
        ),
      if (widget.showFavorite)
        DetailPillButton(
          focusNode: _favNode,
          icon: widget.series.isFavorite
              ? Icons.star_rounded
              : Icons.star_border_rounded,
          label: tr('Favorites'),
          selected: widget.series.isFavorite,
          scale: s,
          onPressed: _toggleFavorite,
          onFocused: _revealTop,
        ),
    ];
    final row = Wrap(
      spacing: 10 * s,
      runSpacing: 10 * s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: buttons,
    );
    if (narrow) return row;
    return CallbackShortcuts(
      bindings: _arrows(
        up: _backNode.requestFocus,
        down:
            _loaded && _allEpisodes.isNotEmpty ? _focusSeasonsOrEpisodes : null,
        left: () => move(-1),
        right: () => move(1),
      ),
      child: row,
    );
  }

  List<Widget> _buildEpisodeSection(double s, double pad) {
    if (_failed || (_loaded && _allEpisodes.isEmpty)) {
      return [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: Text(
            _failed ? tr('Failed to load episodes.') : tr('No episodes found.'),
            style: TextStyle(color: Colors.white70, fontSize: 14 * s),
          ),
        ),
      ];
    }
    if (!_loaded || _season == null) return const [];
    final season = _season!;
    final episodes = _episodesOf(season);
    final storage = context.read<StorageService>();
    final cardW = 168 * s;
    final thumbH = cardW * 9 / 16;
    final focusPad = 10 * s;
    final textH = 44 * s;
    final highlighted = (_highlight[season] ?? 0)
        .clamp(0, math.max(episodes.length - 1, 0))
        .toInt();
    final info =
        episodes.isEmpty ? null : _info(episodes[highlighted], storage);

    return [
      KeyedSubtree(
        key: _seasonsKey,
        child: _seasons.length > 1
            ? _buildSeasonChips(s, pad)
            : Padding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                child: Text(
                  _seasonLabel(season),
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15 * s,
                      fontWeight: FontWeight.bold),
                ),
              ),
      ),
      SizedBox(height: 4 * s),
      KeyedSubtree(
        key: _episodesKey,
        child: CallbackShortcuts(
          bindings: _arrows(
            up: () => _seasons.length > 1
                ? _seasonNode(season).requestFocus()
                : _playNode.requestFocus(),
            left: () => _focusEpisode((_highlight[season] ?? 0) - 1),
            right: () => _focusEpisode((_highlight[season] ?? 0) + 1),
          ),
          child: SizedBox(
            height: thumbH + textH + 2 * focusPad,
            child: SportsRowArrows(
              controller: _episodeScroll,
              arrowAreaHeight: thumbH + 2 * focusPad,
              child: ListView.builder(
                controller: _episodeScroll,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                    horizontal: _rowPadding - 7 * s, vertical: focusPad),
                itemExtent: _cardExtent,
                itemCount: episodes.length,
                itemBuilder: (context, i) {
                  final episode = episodes[i];
                  return Padding(
                    padding: EdgeInsets.symmetric(horizontal: 7 * s),
                    child: _EpisodeCard(
                      info: _info(episode, storage),
                      focusNode: _episodeNode(i),
                      width: cardW,
                      thumbHeight: thumbH,
                      scale: s,
                      highlighted: i == highlighted,
                      onTap: () => _play(episode),
                      onHold: () => _toggleWatched(episode),
                      onFocused: () {
                        if (_highlight[season] != i) {
                          setState(() => _highlight[season] = i);
                        }
                        _scrollEpisodeIntoView(i);
                        _reveal(_episodesKey, atEnd: true);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      if (info != null)
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 2 * s, pad, 0),
          child: _EpisodeStrip(info: info, scale: s, maxWidth: 760 * s),
        ),
    ];
  }

  Widget _buildSeasonChips(double s, double pad) {
    void move(int delta) {
      final i = _seasons.indexWhere((x) => _seasonNode(x).hasFocus);
      final j = i + delta;
      if (i >= 0 && j >= 0 && j < _seasons.length) {
        _seasonNode(_seasons[j]).requestFocus();
      }
    }

    // Build the small season list eagerly so each focus target exists before navigation.
    return CallbackShortcuts(
      bindings: _arrows(
        up: () => (_allEpisodes.isNotEmpty ? _playNode : _fallbackNode)
            .requestFocus(),
        down: () => _focusEpisode(_highlight[_season] ?? 0),
        left: () => move(-1),
        right: () => move(1),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: pad - 2 * s, vertical: 6 * s),
        child: Row(
          children: [
            for (final season in _seasons)
              Padding(
                padding: EdgeInsets.only(right: 8 * s),
                child: Builder(
                  builder: (chipContext) => DetailPillButton(
                    focusNode: _seasonNode(season),
                    label: _seasonLabel(season),
                    selected: season == _season,
                    scale: s,
                    compact: true,
                    // Focus already selected it (Apple TV style); Select
                    // drops into that season's episodes.
                    onPressed: () {
                      _selectSeason(season);
                      _focusEpisode(_highlight[season] ?? 0);
                    },
                    onFocused: () {
                      _selectSeason(season);
                      Scrollable.ensureVisible(chipContext,
                          duration: Duration.zero,
                          alignmentPolicy:
                              ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
                      _reveal(_episodesKey, atEnd: true);
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- Narrow (phone portrait) ---------------------------------------------------

  Widget _buildNarrow(BoxConstraints c) {
    final backdrop = _backdropUrl;
    final poster = backdrop == null ? _posterUrl : null;
    final topInset = MediaQuery.of(context).padding.top;
    final storage = context.read<StorageService>();
    final season = _season;
    final episodes = season == null ? const <Channel>[] : _episodesOf(season);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Stack(
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
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (poster != null) ...[
                  DetailPoster(url: poster, width: 96),
                  const SizedBox(width: 14),
                ],
                Expanded(child: _buildHeaderText(1, narrow: true)),
              ],
            ),
          ),
        ),
        if (_failed || (_loaded && _allEpisodes.isEmpty))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _failed
                    ? tr('Failed to load episodes.')
                    : tr('No episodes found.'),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        if (_loaded && season != null) ...[
          SliverToBoxAdapter(
            child: _seasons.length > 1
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Row(
                      children: [
                        for (final x in _seasons)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: DetailPillButton(
                              focusNode: _seasonNode(x),
                              label: _seasonLabel(x),
                              selected: x == season,
                              scale: 1,
                              compact: true,
                              onPressed: () => _selectSeason(x),
                            ),
                          ),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    child: Text(
                      _seasonLabel(season),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
          ),
          SliverList.builder(
            itemCount: episodes.length,
            itemBuilder: (context, i) => _EpisodeListRow(
              key: ValueKey(episodes[i].id),
              info: _info(episodes[i], storage),
              onTap: () => _play(episodes[i]),
              onLongPress: () => _toggleWatched(episodes[i]),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(height: 24 + MediaQuery.of(context).padding.bottom),
          ),
        ],
      ],
    );
  }
}

// --- Pieces ---------------------------------------------------------------------

class _EpisodeInfo {
  const _EpisodeInfo({
    required this.number,
    required this.title,
    required this.hasOwnTitle,
    required this.plot,
    required this.durationText,
    required this.airDate,
    required this.watched,
    required this.progress,
    required this.images,
  });

  final int number;

  /// The clean title, or "Episode N" when [hasOwnTitle] is false.
  final String title;
  final bool hasOwnTitle;
  final String? plot;
  final String? durationText;
  final String? airDate;
  final bool watched;

  /// 0-1 for a started, unfinished episode; null otherwise.
  final double? progress;

  /// Fallback chain — see `_SeriesDetailScreenState._episodeImages`.
  final List<_ThumbImage> images;

  /// The card shows the episode's own still (not a series-art stand-in).
  bool get hasOwnStill =>
      images.isNotEmpty && images.first.kind == ImageKind.still;
}

typedef _ThumbImage = ({String url, ImageKind kind});

/// Watched check (top right) and progress bar (bottom) over a thumbnail.
class _ThumbOverlays extends StatelessWidget {
  const _ThumbOverlays({required this.info, required this.scale});

  final _EpisodeInfo info;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = scale;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (info.watched)
          Positioned(
            top: 5 * s,
            right: 5 * s,
            child: Container(
              decoration: const BoxDecoration(
                  color: Colors.black87, shape: BoxShape.circle),
              child: Icon(Icons.check_circle_rounded,
                  size: 20 * s, color: scheme.primary),
            ),
          ),
        if (info.progress != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.7),
              child: Padding(
                padding: EdgeInsets.all(3 * s),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: info.progress,
                    minHeight: 4 * s,
                    backgroundColor: Colors.white24,
                    color: scheme.secondary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.info,
    required this.width,
    required this.height,
    required this.scale,
  });

  final _EpisodeInfo info;
  final double width;
  final double height;
  final double scale;

  /// Image [i] of the fallback chain; a load error moves on to the next,
  /// and past the last one comes the themed placeholder.
  Widget _image(BuildContext context, int i) {
    if (i >= info.images.length) {
      return _ThumbFallback(number: info.number, scale: scale);
    }
    final image = info.images[i];
    // Decode only enough pixels for the card; a TMDB still comes as
    // w300 on a TV box (original only on Windows).
    return HdNetworkImage(
      url: image.url,
      kind: image.kind,
      decodeWidth: HdNetworkImage.cardDecodeWidth(context, width),
      fadeInDuration: Duration.zero,
      errorWidget: (c) => _image(c, i + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _image(context, 0),
        // Series art standing in for a missing still: darkened, with the
        // episode number on it so a row of them doesn't look identical.
        if (!info.hasOwnStill && info.images.isNotEmpty) ...[
          const ColoredBox(color: Color(0x80000000)),
          Center(child: _EpisodeNumberMark(number: info.number, scale: scale)),
        ],
        _ThumbOverlays(info: info, scale: scale),
      ],
    );
  }
}

class _EpisodeNumberMark extends StatelessWidget {
  const _EpisodeNumberMark({required this.number, required this.scale});

  final int number;
  final double scale;

  @override
  Widget build(BuildContext context) => Text(
        'E$number',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: 30 * scale,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
          shadows: const [Shadow(color: Colors.black, blurRadius: 10)],
        ),
      );
}

/// No image at all (or none loaded): an accent-tinted card with the
/// episode number, in the app's palette rather than a flat grey box.
class _ThumbFallback extends StatelessWidget {
  const _ThumbFallback({required this.number, required this.scale});

  final int number;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.28), Colors.grey.shade900),
            Colors.black,
          ],
        ),
      ),
      child: Center(child: _EpisodeNumberMark(number: number, scale: scale)),
    );
  }
}

/// A landscape (16:9) episode card for the wide layout's row.
class _EpisodeCard extends StatefulWidget {
  const _EpisodeCard({
    required this.info,
    required this.focusNode,
    required this.width,
    required this.thumbHeight,
    required this.scale,
    required this.highlighted,
    required this.onTap,
    required this.onHold,
    required this.onFocused,
  });

  final _EpisodeInfo info;
  final FocusNode focusNode;
  final double width;
  final double thumbHeight;
  final double scale;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHold;
  final VoidCallback onFocused;

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.scale;
    final info = widget.info;
    final radius = 4 * s;
    // Hold OK (or a long mouse/touch press) = mark watched / unwatched.
    return HoldToActivate(
      onTap: widget.onTap,
      onHold: widget.onHold,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (f) {
          if (_focused != f) setState(() => _focused = f);
          if (f) widget.onFocused();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Windows (mouse): the first click focuses (shows this episode's
          // plot below the row), a click on the focused card plays — same
          // "look before you open" idea as PosterCard's Windows handling.
          onTap: () {
            if (Platform.isWindows && !_focused) {
              widget.focusNode.requestFocus();
            } else {
              widget.onTap();
            }
          },
          child: RepaintBoundary(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: widget.width,
                  height: widget.thumbHeight,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: _focused
                          ? scheme.primary
                          : widget.highlighted
                              ? scheme.primary.withValues(alpha: 0.45)
                              : Colors.white12,
                      width: 2,
                    ),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: RepaintBoundary(
                      child: _Thumb(
                    info: info,
                    width: widget.width,
                    height: widget.thumbHeight,
                    scale: s,
                  )),
                ),
                SizedBox(height: 6 * s),
                Text.rich(
                  TextSpan(children: [
                    if (info.hasOwnTitle)
                      TextSpan(
                        text: 'E${info.number}  ',
                        style: TextStyle(
                            color: scheme.primary, fontWeight: FontWeight.w800),
                      ),
                    TextSpan(text: info.title),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _focused ? scheme.primary : Colors.white,
                    fontSize: 12.5 * s,
                    fontWeight: _focused ? FontWeight.bold : FontWeight.w600,
                  ),
                ),
                if (info.durationText != null)
                  Padding(
                    padding: EdgeInsets.only(top: 2 * s),
                    child: Text(
                      info.durationText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: info.watched
                            ? scheme.primary.withValues(alpha: 0.85)
                            : Colors.white54,
                        fontSize: 11 * s,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Under the episode row: the highlighted episode's title line and plot.
class _EpisodeStrip extends StatelessWidget {
  const _EpisodeStrip({
    required this.info,
    required this.scale,
    required this.maxWidth,
  });

  final _EpisodeInfo info;
  final double scale;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = scale;
    final meta = [
      if (info.durationText != null) info.durationText!,
      if (info.airDate != null) info.airDate!,
    ].join('  ·  ');
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: tr('Episode {n}', {'n': info.number}),
                style: TextStyle(
                    color: scheme.primary, fontWeight: FontWeight.w800),
              ),
              if (info.hasOwnTitle) TextSpan(text: '  ·  ${info.title}'),
              if (meta.isNotEmpty)
                TextSpan(
                  text: '    $meta',
                  style: TextStyle(
                      color: Colors.white54,
                      fontWeight: FontWeight.normal,
                      fontSize: 12 * s),
                ),
              TextSpan(
                text:
                    '    ${info.watched ? tr('Hold to mark as unwatched') : tr('Hold to mark as watched')}',
                style: TextStyle(
                    color: Colors.white38,
                    fontWeight: FontWeight.normal,
                    fontSize: 11.5 * s),
              ),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white,
                fontSize: 14 * s,
                fontWeight: FontWeight.bold),
          ),
          if (info.plot != null)
            Padding(
              padding: EdgeInsets.only(top: 4 * s),
              child: Text(
                info.plot!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white70, fontSize: 12.5 * s, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// Phone portrait: one episode per row (thumbnail + text, plot below).
class _EpisodeListRow extends StatelessWidget {
  const _EpisodeListRow({
    super.key,
    required this.info,
    required this.onTap,
    required this.onLongPress,
  });

  final _EpisodeInfo info;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const thumbW = 136.0;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: thumbW,
                  height: thumbW * 9 / 16,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _Thumb(
                      info: info,
                      width: thumbW,
                      height: thumbW * 9 / 16,
                      scale: 1),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(children: [
                          if (info.hasOwnTitle)
                            TextSpan(
                              text: 'E${info.number}  ',
                              style: TextStyle(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w800),
                            ),
                          TextSpan(text: info.title),
                        ]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                      if (info.durationText != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            info.durationText!,
                            style: TextStyle(
                                color: info.watched
                                    ? scheme.primary
                                    : Colors.white54,
                                fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (info.plot != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  info.plot!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 12.5, height: 1.35),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
