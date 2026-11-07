import '../widgets/tv_text_field_gate.dart';
import '../models/sports_favourites_filter.dart';
import 'dart:math' as math;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../utils/sports_browse_selection.dart';
import '../widgets/sports_schedule_panel.dart';
import '../widgets/sports_event_controls.dart';
import '../services/sports_standings_service.dart';
import '../widgets/sports_panel.dart';
import '../utils/guarded_dialog.dart';
import '../widgets/sports_details_panel.dart';
import '../models/sports_channel_filters.dart';
import 'sports_teams_screen.dart';
import '../utils/sports_coverage_models.dart';
import '../widgets/sports_feed_diagnostics.dart';
import '../utils/open_multiview.dart';
import '../utils/interface_colors.dart';
import '../widgets/tv_preview_remote_navigation.dart';
import '../utils/formula_one.dart';
import '../widgets/sports_header_controls.dart';
import '../widgets/sports_hub_layout.dart';
import '../widgets/sports_toolbar_navigation.dart';
import '../utils/sports_time_filter.dart';
import '../utils/sports_scroll_anchor.dart';
import '../utils/sports_calendar.dart';
import '../services/sports_match_session.dart';
import '../services/sports_match_batch_plan.dart';
import '../services/sports_browse_cache.dart';
import '../utils/sports_guide_coverage.dart';
import '../utils/sports_channel_filter.dart';
import '../widgets/iptv_bottom_bar.dart';
import '../widgets/sports_channel_picker.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/channel_now_label.dart';
import '../utils/sports_presentation.dart';
import '../widgets/sports_filter_picker.dart';
import '../widgets/sports_refresh_control.dart';
import '../widgets/sports_replays_panel.dart';

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../models/sports.dart';
import '../models/sports_progress.dart';
import '../widgets/sports_activity_status.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/sports_channel_matcher.dart';
import '../services/sports_match_inputs.dart';
import '../services/sports_channel_attempts.dart';
import '../services/sports_supplement_service.dart';
import '../services/sports_follows.dart';
import '../services/sports_service.dart';
import '../services/storage_service.dart';
import '../utils/time_format.dart';
import '../utils/route_observer.dart';
import '../utils/tv_theme.dart';
import '../widgets/preview_player_controls.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/live_resume_hint.dart';
import '../widgets/player_controls.dart';
import '../widgets/sports_widgets.dart';

import 'player_screen.dart';
import 'sports_live_list_screen.dart';

import 'sports_league_manager_screen.dart';
import '../l10n/l10n.dart';

/// Sports events, replays and highlights with shared preview playback. Apply sport,
/// league, time and channel filters; resolve channel suggestions through
/// SportsChannelMatcher. Explicit remote navigation keeps lazy event rows and toolbar
/// controls reachable.
class SportsScreen extends StatefulWidget {
  const SportsScreen(
      {super.key,
      this.supplement,
      this.scores,
      this.clock,
      this.standings,
      this.onChooseChannel,
      this.selectionTitle});

  /// Selection-only browse: reuse the Sports Hub without creating a preview.
  final Future<void> Function(Channel)? onChooseChannel;
  final String? selectionTitle;

  /// Allows offline integration tests to exercise supplemental event arrivals.
  final SportsSupplementService? supplement;
  final SportsService? scores;

  /// Deterministic foreground/resume expiry tests; production uses wall time.
  final DateTime Function()? clock;
  final SportsStandingsService? standings;

  @override
  State<SportsScreen> createState() => _SportsScreenState();
}

class _Section {
  _Section(this.id, this.label, this.games);
  final String id;
  final String label;
  final List<SportsGame> games;
  late final cardIndices = {
    for (final (index, game) in games.indexed)
      ValueKey('card-${SportsChannelPicks.eventKey(game)}'): index,
  };
}

class _SportsScreenState extends State<SportsScreen>
    with RouteAware, WidgetsBindingObserver {
  late final StorageService _storage;
  late final SportsChannelMatcher _matcher;
  late SportsChannelPicks _picks;
  late SportsFollows _follows;
  SportsFavouritesFilter _favouritesFilter = SportsFavouritesFilter.all;
  SportsFavouritesFilter _browseFavouritesFilter = SportsFavouritesFilter.all;
  bool get _onlyFavourites => _favouritesFilter.isFiltered;
  final _toolbarKey = GlobalKey();

  late List<SportsLeague> _leagues;
  late List<SportsLeague> _eventLeagues;
  late Set<String> _favouriteLeagueIds;
  late List<SportsLeague> _favouriteFeeds;
  late List<SportsLeague> _favouriteScheduleFeeds;
  late final _allScheduleFeeds =
      sportsBrowseLeagues.where(supportsSportsSchedule).toList();
  List<SportsLeague> get _browseCatalogue =>
      _onlyFavourites ? _favouriteFeeds : sportsBrowseLeagues;
  bool _isFavouriteGame(SportsGame game) =>
      (_favouritesFilter.includesLeagues &&
          _favouriteLeagueIds.contains(game.league.id)) ||
      (_favouritesFilter.includesTeams && _follows.involves(game));
  List<SportsLeague> _feedsFor(SportsFavouritesFilter filter) => {
        if (filter.includesLeagues)
          for (final league in _leagues) league.id: league,
        if (filter.includesTeams)
          for (final team in _follows.teams)
            if (sportsLeagueById(team.leagueId) case final league?)
              league.id: league,
      }.values.toList();

  void _updateFavouriteFeeds() {
    _favouriteFeeds = _feedsFor(_favouritesFilter);
    _favouriteScheduleFeeds = _feedsFor(_browseFavouritesFilter)
        .where(supportsSportsSchedule)
        .toList();
  }

  String? _leagueFilter;
  String? _sportFilter;
  String? _browseSport, _browseLeague;
  bool _leaving = false;
  int _dayOffset = 0;

  /// Empty day with one league picked: that league's next game (from
  /// [SportsService.nextGameStart]), offered as a jump. Null = none found.
  DateTime? _nextGame;
  bool _nextGameLooked = false;
  bool _hideScores = false;
  SportsChannelFilter _channelFilter = SportsChannelFilter.possible;
  bool get _withChannel => _channelFilter != SportsChannelFilter.all;
  Set<String> get _checkedGames => _matchSession.checked;
  String? _channelError, _scoreError;
  final _scoreActivity = ValueNotifier<SportsWorkProgress?>(null);
  final _channelActivity = ValueNotifier<SportsWorkProgress?>(null);
  final _channelStage = ValueNotifier<SportsWorkStage?>(null);
  final _moreEventsActivity = ValueNotifier<bool>(false);
  final _activityReason = ValueNotifier<String>('Loading sports');
  final _pullActivity = ValueNotifier<String?>(null);
  bool _pending(SportsGame g) => !_checkedGames.contains(_gameKey(g));
  void _onChannelActivity() {
    // Only stage changes notify visible card footers. Per-entry counters never
    // rebuild the grid, player or every pending card.
    _channelStage.value = _channelActivity.value?.stage;
  }

  bool get _showPendingChannels =>
      (_loading || _matching) && _channelError == null;
  bool _acceptsChannel(SportsGame g) =>
      _channelFilter.accepts(_matches[_gameKey(g)] ?? const [],
          pending: _showPendingChannels && _pending(g));
  SportsTimeFilter _timeFilter = SportsTimeFilter.liveAndSoon;
  String _sportsView = 'events';
  bool _sportsPanelOpen = false;
  // Keep the native player mounted when moving between live and guide layouts.
  final _heroKey = GlobalKey(debugLabel: 'sports-hero');
  bool get _events => _sportsView == 'events';
  bool get _schedule => _sportsView == 'schedule';
  final _scheduleBrowse = SportsScheduleBrowseState();
  final _scheduleFocus = FocusNode(debugLabel: 'sports-schedule-entry');
  bool get _standings => _sportsView == 'standings';
  bool get _replays => _sportsView == 'replays' || _sportsView == 'highlights';
  final _standingsBrowse = SportsStandingsBrowseState();
  final _standingsFocus = FocusNode(debugLabel: 'sports-standings-entry');
  final _standingsSearchFocus =
      FocusNode(debugLabel: 'sports-standings-search');

  bool get _highlights => _sportsView == 'highlights';
  bool _onlineExtras = true;
  bool _backgrounded = false;
  Timer? _listingTimer;
  String? _extraKey;
  Future<void>? _extrasTask;
  List<SportsGame>? _appliedExtras;
  String? _appliedExtrasKey;
  late final _supplement =
      widget.supplement ?? SportsSupplementService.instance;

  List<SportsLeague> get _displayLeagues => {
        for (final league in _leagues) league.id: league,
        if (sportsLeagueById(_leagueFilter ?? '') case final league?)
          league.id: league,
        for (final game in _games) game.league.id: game.league,
      }.values.toList();

  List<SportsGame> _guideGames = const [];
  int _guidePlaylistRevision = -1;
  Object? _completedGuideDiscovery;
  DateTime? _guideDiscoveryUntil;
  List<SportsGame> _withGuideGames(List<SportsGame> games, DateTime day) {
    return mergeSportsGuideCoverage([
      ...games.where((g) =>
          !g.isGuideEvent &&
          (!g.league.espnPath.startsWith('rugby/') || g.isLive)),
    ], [
      if (sportsCalendarDayOffset(_now, day) == 0 &&
          _guidePlaylistRevision ==
              context.read<PlaylistManager>().liveRevision)
        ..._guideGames.where((g) =>
            g.end?.isAfter(_now) == true &&
            (sportsLeagueById(g.league.id) == null ||
                _eventLeagues.any((l) => l.id == g.league.id))),
    ]);
  }

  List<SportsGame> _withExtras(List<SportsGame> games, DateTime day) =>
      _withGuideGames(
          !_onlineExtras
              ? games
              : mergeSupplementGames(
                      games, _supplement.cachedGamesForDay(_eventLeagues, day))
                  .map(_supplement.enrichCached)
                  .toList(),
          day);

  void _loadExtras(DateTime day) {
    if (!_onlineExtras ||
        _backgrounded ||
        _covered ||
        _sportsPanelOpen ||
        !_events ||
        _indexedPlaylistRevision < 0) {
      return;
    }
    final key =
        '${day.toIso8601String()}:${_eventLeagues.map((l) => l.id).join(',')}';
    if (_extraKey == key && _extrasTask != null) return;
    _extraKey = key;
    _moreEventsActivity.value = true;
    _extrasTask = () async {
      bool cancelled() =>
          !mounted ||
          _backgrounded ||
          _covered ||
          _sportsPanelOpen ||
          !_onlineExtras ||
          !_events ||
          _extraKey != key;
      void applyExtras() {
        if (cancelled()) return;
        final extra = _supplement.cachedGamesForDay(_eventLeagues, day);
        if (_appliedExtrasKey == key && identical(_appliedExtras, extra)) {
          return;
        }
        if (extra.isEmpty && _appliedExtras == null) return;
        _appliedExtras = extra;
        _appliedExtrasKey = key;
        setState(() => _games = _withGuideGames(
            mergeSupplementGames(
                    _games
                        .where((g) => supportsSportsScoreboard(g.league))
                        .toList(),
                    extra)
                .map(_supplement.enrichCached)
                .toList(),
            day));
        unawaited(_rematch(null, 'Auto · new events'));
      }

      await Future.wait([
        () async {
          await _supplement.warmMotorsport(_eventLeagues, cancelled: cancelled);
          applyExtras();
        }(),
        () async {
          await _supplement.warmBroadcasts(_games, cancelled: cancelled);
          if (cancelled()) return;
          final enriched = _games.map(_supplement.enrichCached).toList();
          String listingKey(SportsGame g) =>
              g.onlineBroadcasts.map((b) => b.evidenceKey).join('~');
          if (enriched.indexed
              .any((e) => listingKey(e.$2) != listingKey(_games[e.$1]))) {
            setState(() => _games = enriched);
            unawaited(_rematch(null, 'Auto · listings'));
          }
          await _supplement.gamesForDay(_eventLeagues, day,
              cancelled: cancelled);
          applyExtras();
        }(),
      ]);
    }()
        .whenComplete(() {
      if (mounted && _extraKey == key) {
        _extrasTask = null;
        _moreEventsActivity.value = false;
      }
    });
  }

  void _queueListings(SportsGame game) {
    _listingTimer?.cancel();
    if (!_onlineExtras || game.isGuideEvent) return;
    _listingTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted &&
          !_covered &&
          !_backgrounded &&
          !_sportsPanelOpen &&
          _events) {
        unawaited(_onlineMatches(game));
      }
    });
  }

  final _listingRequests = <String, Future<List<ChannelMatch>>>{};
  Future<List<ChannelMatch>> _pickerMatches(SportsGame game) async {
    final scope = _matchScope;
    await _rematch();
    if (!_currentMatchScope(scope)) return const [];
    if (_onlineExtras && !game.isGuideEvent) return _onlineMatches(game);
    return _matches[_gameKey(game)] ?? const [];
  }

  Future<List<ChannelMatch>> _onlineMatches(SportsGame game) {
    final key = _gameKey(game);
    return _listingRequests[key] ??= _fetchOnlineMatches(game)
        .catchError((Object _) => _matches[key] ?? const <ChannelMatch>[])
        .whenComplete(() {
      _listingRequests.remove(key);
    });
  }

  Future<List<ChannelMatch>> _fetchOnlineMatches(SportsGame game) async {
    final key = _gameKey(game), scope = _matchScope;
    final fixture = SportsChannelMatcher.matchingIdentity(game, _picks,
        includeBroadcasts: false);
    final listings = await _supplement.broadcastsFor(game,
        cancelled: () =>
            !_currentMatchScope(scope) || !_onlineExtras || _backgrounded);
    if (!_currentMatchScope(scope) || !_onlineExtras) {
      return _matches[key] ?? const [];
    }
    if (listings.isEmpty) {
      // Reopening immediately after a pick must also receive the completed
      // local check, even when no online provider has additional evidence.
      await _rematch();
      return _currentMatchScope(scope) ? _matches[key] ?? const [] : const [];
    }
    final current = _games.where((g) => _gameKey(g) == key).firstOrNull;
    if (current == null ||
        fixture !=
            SportsChannelMatcher.matchingIdentity(current, _picks,
                includeBroadcasts: false)) {
      return const [];
    }
    final enriched = current.withOnlineBroadcasts(listings);
    if (SportsChannelMatcher.matchingIdentity(current, _picks) !=
        SportsChannelMatcher.matchingIdentity(enriched, _picks)) {
      setState(() => _games = [
            for (final g in _games)
              if (_gameKey(g) == key) enriched else g,
          ]);
    }
    // Online enrichment shares the same serialized, input-validated commit
    // path as guide/score updates. Never replace the entire day from a stale
    // standalone enrichment request.
    await _rematch();
    return _currentMatchScope(scope) ? _matches[key] ?? const [] : const [];
  }

  var _matchSession = SportsMatchSession();
  Object get _guideVersion {
    final guide = context.read<EpgService>();
    return (
      guide.changeRevision,
      guide.currentGuideRevision,
      guide.lastUpdated
    );
  }

  Object get _browseCacheKey => (
        _storage,
        context.read<PlaylistManager>(),
        context.read<EpgService>(),
        widget.scores ?? SportsService.instance,
        _supplement,
        _matcher,
        _onlineExtras,
        _storage.getActiveViewerId(),
        _day,
        context.read<PlaylistManager>().liveRevision,
        _guideVersion,
      );

  void _restoreRecentMatches() {
    final cached = SportsBrowseCache.shared.read(_browseCacheKey, _now);
    if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
      debugPrint(
          'IPTV_SPORTS restore hit=${cached != null} guide=$_guideVersion');
    }
    if (cached == null) return;
    _matchSession = cached.restoreSession(at: _now);
    _guideGames = cached.guideGames;
    _guidePlaylistRevision = context.read<PlaylistManager>().liveRevision;
    _indexedPlaylistRevision = _guidePlaylistRevision;
    _lastMatchSignature = cached.signature;
  }

  List<SportsGame> _gameData = const [];
  bool _hasF1 = false;
  List<SportsGame> get _games => _gameData;
  set _games(List<SportsGame> value) {
    if (!listEquals(_gameData, value)) {
      _gameData = value;
      _hasF1 = value.any(isFormulaOne);
    }
    _syncMatchInputs();
  }

  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  void _syncMatchInputs() => _matchSession.updateInputs(
      _games, _picks, context.read<PlaylistManager>().liveRevision, _now,
      evidenceVersion: _guideVersion);
  Map<String, List<ChannelMatch>> get _matches => _matchSession.matches;
  final _matchWork = SportsMatchWork();
  Object? _lastMatchSignature;
  DateTime? _lastProgressSnapshot;
  int _indexedPlaylistRevision = -1;
  bool _loading = true;
  bool _matching = false;
  String? _error;
  int _loadToken = 0;

  final _heroFocus = ValueNotifier<SportsGame?>(null);
  SportsGame? get _heroGame => _heroFocus.value;
  set _heroGame(SportsGame? game) => _heroFocus.value = game;
  Timer? _pollTimer;
  Timer? _returnRefresh;
  DateTime? _lastLoadStarted;
  DateTime? _lastLoadCompleted;
  bool _covered = false;
  final _viewActive = ValueNotifier<bool>(true);

  /// Android: the game whose channel plays in the hero (Play/Pause on its
  /// card, or back from its fullscreen) — see [_setPreview]. Only counts
  /// while [PlaybackService] still plays [_previewChannel] (see
  /// [_livePreview]); a CH+/CH- zap in the player ends it.
  SportsGame? _previewGame;
  Channel? _previewChannel;

  /// Preview starts/stops run one at a time (see [_setPreview]).
  Future<void> _previewChain = Future.value();
  int _previewSeq = 0;

  /// The "Hold > to resume" pill covered the cards and Standings' table;
  /// hidden for as long as Sports (and anything pushed over it) is open.
  late final VoidCallback _showResumeHint;

  // Focus bookkeeping — see the class doc for the zone model.
  // TV uses one toolbar; portrait places sport/league below the tabs.
  int get _firstRowZone => _narrow ? 2 : 1;
  int get _filterZone => _narrow ? 1 : 0;
  int _zone = 0;
  FocusNode? _lastToolbarFocus;
  String? _focusedSectionId;
  String? _focusedCardKey;
  ({
    String section,
    String key,
    bool heading,
    FocusNode? origin
  })? _pendingRowFocus;
  bool _rowFocusScheduled = false;
  int _rowFocusAttempts = 0;
  int _navigationRevision = 0;
  final _replayPanelKey = GlobalKey<SportsReplaysPanelState>();
  final _highlightPanelKey = GlobalKey<SportsReplaysPanelState>();
  SportsReplaysPanelState? get _guidePanel =>
      (_highlights ? _highlightPanelKey : _replayPanelKey).currentState;
  bool get _tvNavigation => context.read<AppPreferences>().isTelevision;

  void _focusToolbar() {
    _pendingRowFocus = null;
    _navigationRevision++;
    final last = _lastToolbarFocus;
    if (last != null && sportsFocusAttached(last) && last.canRequestFocus) {
      last.requestFocus();
    } else {
      _chipNode(!_events ? 'view-$_sportsView' : _leagueChipId).requestFocus();
    }
  }

  void _focusEvents() {
    _navigationRevision++;
    final sections = _sections;
    if (sections.isEmpty) {
      _chipNode('refresh').requestFocus();
      return;
    }
    final section =
        sections.where((s) => s.id == _focusedSectionId).firstOrNull ??
            sections.first;
    final index =
        section.games.indexWhere((g) => _gameKey(g) == _focusedCardKey);
    _focusRowCard(section, index < 0 ? 0 : index);
  }

  void _revealItem(BuildContext context) {
    // Both edges matter: keepVisibleAtEnd alone never scrolls back up/left.
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
  }

  double get _horizontalSectionExtent =>
      _sportHeadingHeight +
      _sportHeadingGap +
      _rowCardHeight +
      6 +
      _sportSectionGap;

  void _focusRowHeading(_Section section) =>
      _focusRowCard(section, 0, heading: true);

  void _focusRowCard(_Section section, int index, {bool heading = false}) {
    if (section.games.isEmpty) return;
    final pending = _pendingRowFocus;
    _pendingRowFocus = (
      section: section.id,
      heading: heading,
      key: _gameKey(section.games[index.clamp(0, section.games.length - 1)]),
      origin: pending?.origin ?? FocusManager.instance.primaryFocus,
    );
    _rowFocusAttempts = 0;
    _resolveRowFocus();
  }

  void _resolveRowFocus() {
    final pending = _pendingRowFocus;
    if (!mounted || pending == null) return;
    final sections = _sections;
    final row = sections.indexWhere((s) => s.id == pending.section);
    final index = row < 0
        ? -1
        : sections[row].games.indexWhere((g) => _gameKey(g) == pending.key);
    if (index < 0) {
      _pendingRowFocus = null;
      return;
    }
    final node =
        pending.heading ? _chipNode(pending.section) : _cardNode(pending.key);
    if (sportsFocusAttached(node)) {
      _pendingRowFocus = null;
      node.requestFocus();
      _revealItem(node.context!);
      return;
    }
    // Reveal the outer row first, then its horizontal card. Keep the latest
    // requested identity while mounting; additional arrows update this target
    // instead of being consumed without moving anywhere.
    final scroll = _rowScrolls[pending.section];
    if (pending.heading || scroll == null || !scroll.hasClients) {
      if (_verticalScroll.hasClients && !_verticalGames) {
        _verticalScroll.jumpTo((row * _horizontalSectionExtent)
            .clamp(0.0, _verticalScroll.position.maxScrollExtent));
      }
    } else {
      scroll.jumpTo((index * (_rowCardWidth + 12))
          .clamp(0.0, scroll.position.maxScrollExtent));
    }
    if (_rowFocusScheduled) return;
    _rowFocusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rowFocusScheduled = false;
      final latest = _pendingRowFocus;
      if (!mounted || latest == null) return;
      if (FocusManager.instance.primaryFocus != latest.origin ||
          ++_rowFocusAttempts > 3) {
        _pendingRowFocus = null;
        return;
      }
      _resolveRowFocus();
    });
  }

  void _moveEventRow(_Section section, int delta, {bool heading = false}) {
    final sections = _sections;
    final pending = _pendingRowFocus;
    final row =
        sections.indexWhere((s) => s.id == (pending?.section ?? section.id));
    if (row < 0) return;
    final next = row + delta;
    if (next < 0) {
      _focusToolbar();
    } else if (next < sections.length) {
      if (heading && _groupedBySport) {
        _focusRowHeading(sections[next]);
      } else {
        // Preserve the column, clamping only for a shorter neighbouring row.
        // Never choose a more distant sport just because its card aligns better.
        final column = sections[row].games.indexWhere((g) => pending == null
            ? (_cardNodes[_gameKey(g)]?.hasFocus ?? false)
            : _gameKey(g) == pending.key);
        _focusRowCard(
            sections[next], column.clamp(0, sections[next].games.length - 1));
      }
    }
  }

  KeyEventResult _onHeadingKey(_Section section, KeyEvent event) {
    if (!_tvNavigation ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    _navigationRevision++;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _pendingRowFocus = null;
      _chipNode('refresh').requestFocus();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final target =
          _sections.where((s) => s.id == _pendingRowFocus?.section).firstOrNull;
      _focusRowCard(target ?? section, 0);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveEventRow(
          section, event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1,
          heading: true);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  final Map<String, FocusNode> _chipNodes = {};
  final _tabFocusMode = ValueNotifier(FocusManager.instance.highlightMode);
  void _tabFocusModeChanged(FocusHighlightMode mode) =>
      _tabFocusMode.value = mode;
  final Map<String, FocusNode> _cardNodes = {};
  final Map<String, String> _lastCardInRow = {};
  final Map<String, GlobalKey> _rowKeys = {};

  /// Per-row controllers preserve horizontal browsing positions.
  final Map<String, SportsScrollController> _rowScrolls = {};
  bool _initialFocusDone = false;
  final _verticalScroll = SportsScrollController();
  static const _verticalHeadingHeight = 36.0;
  static const _sportHeadingHeight = 30.0;
  static const _sportHeadingGap = 4.0;
  double get _sportSectionGap => _compactCards ? 4 : 8;
  List<_Section>? _browseSnapshot;
  Object? _browseScope;
  bool _restoringBrowseFocus = false;

  // Preserve order within fixture/coverage groups while browsing. Sports keep
  // alphabetical order; layout compensation keeps the focused card in view.
  void _lockBrowse() {
    if (_browseSnapshot != null) return;
    final current = _sections;
    if (current.isNotEmpty) _browseSnapshot = current;
  }

  void _releaseBrowse() {
    _browseSnapshot = null;
    _sectionsKey = null;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_tabFocusModeChanged);
    _channelActivity.addListener(_onChannelActivity);
    WidgetsBinding.instance.addObserver(this);
    _showResumeHint = LiveResumeHint.hideWhileMounted();
    // Windows: the hero plays through DesktopMiniPlayer, not PlaybackService.

    _storage = context.read<StorageService>();
    _matcher = SportsChannelMatcher.shared(context.read<EpgService>());
    _picks = SportsChannelPicks.load(_storage);
    _follows = SportsFollows.load(_storage);
    _leagues = _savedLeagues();
    _favouriteLeagueIds = _leagues.map((l) => l.id).toSet();
    final eventSelection = _storage.getSportsEventsSelection();
    if (eventSelection.length == 3) {
      _sportFilter = sportsBrowseLeagues.any(
              (league) => league.espnPath.startsWith('${eventSelection[0]}/'))
          ? eventSelection[0]
          : null;
      _leagueFilter = sportsLeagueById(eventSelection[1])?.id;
      _favouritesFilter = SportsFavouritesFilter.values.firstWhere(
          (value) => value.name == eventSelection[2],
          orElse: () => SportsFavouritesFilter.all);
    }
    _browseFavouritesFilter = _favouritesFilter;
    _updateFavouriteFeeds();
    _eventLeagues = _eventFeedsForScope;
    // Events starts unfiltered; other browsing tabs retain their own selection.
    final remembered = _storage.getSportsBrowseSelection();
    _browseSport = remembered.isNotEmpty && remembered[0].isNotEmpty
        ? remembered[0]
        : null;
    _browseLeague = remembered.length > 1 && remembered[1].isNotEmpty
        ? remembered[1]
        : favoriteSportsLeague(_storage)?.id;
    _hideScores = _storage.getSportsHideScores();
    _onlineExtras = _storage.getSportsOnlineExtras();
    _channelFilter = SportsChannelFilter.values.firstWhere(
        (v) => v.name == _storage.getSportsChannelFilter(),
        orElse: () => SportsChannelFilter.possible);
    _restoreRecentMatches();
    // Keep near-start coverage visible while preserving confidence labels.
    unawaited(_load());
    _ensureInitialFocus();
    // Live scores tick while the screen is visible; SportsService's own
    // freshness window decides whether a tick actually hits the network.
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_covered &&
          !_backgrounded &&
          !_sportsPanelOpen &&
          mounted &&
          _events) {
        unawaited(_load(silent: true));
      }
    });
  }

  @override
  void didHaveMemoryPressure() => _matchSession.discardHiddenResults();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasBackgrounded = _backgrounded;
    _backgrounded = state != AppLifecycleState.resumed;
    if (!wasBackgrounded && _backgrounded && _events) _pauseEventWork();
    if (mounted) {
      _viewActive.value = !_covered && !_backgrounded && !_sportsPanelOpen;
    }
    if (wasBackgrounded && !_backgrounded && mounted && !_covered && _events) {
      unawaited(_load(silent: true));
    }
  }

  // RouteAwareRegion owns the inherited dependency. Callback checks read the
  // route directly so opening a picker does not rebuild the whole Sports hub.
  ModalRoute<dynamic>? _route;

  @override
  void didPushNext() {
    _returnRefresh?.cancel();
    _covered = true;
    if (_events) _pauseEventWork();
    _viewActive.value = false;
  }

  @override
  void didPopNext() {
    _covered = false;
    _viewActive.value = !_backgrounded && !_sportsPanelOpen;
    _returnRefresh?.cancel();
    // Let the surface/focus handoff finish before refreshing. Repeated Back /
    // expand actions cancel this small debounce rather than rebuilding scores
    // and queuing matching on every route pop. Normal 30s polling is unchanged.
    _returnRefresh = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _covered || _backgrounded || !_events) return;
      final recent = _lastLoadStarted;
      if (_lastLoadCompleted != null &&
          recent != null &&
          _now.difference(recent) < const Duration(seconds: 5)) {
        return;
      }
      unawaited(_load(silent: true));
    });
  }

  @override
  void dispose() {
    if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
      debugPrint(
          'IPTV_SPORTS leave events=${_games.length} guide=${_guideGames.length} checked=${_checkedGames.length} matching=$_matching');
    }
    appRouteObserver.unsubscribe(this);
    FocusManager.instance.removeHighlightModeListener(_tabFocusModeChanged);
    _tabFocusMode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _previewSeq++; // Ignore queued selections after this screen closes.

    _showResumeHint();
    _pollTimer?.cancel();
    _returnRefresh?.cancel();
    _viewActive.dispose();
    _listingTimer?.cancel();
    _heroFocus.dispose();
    _scoreActivity.dispose();
    _channelActivity.dispose();
    _channelStage.dispose();
    _activityReason.dispose();
    _moreEventsActivity.dispose();
    _pullActivity.dispose();
    _extraKey = null;
    _standingsFocus.dispose();
    _scheduleFocus.dispose();
    _standingsSearchFocus.dispose();
    _verticalScroll.dispose();
    for (final n in _chipNodes.values) {
      n.dispose();
    }
    for (final n in _cardNodes.values) {
      n.dispose();
    }
    for (final c in _rowScrolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime get _day {
    final n = _now;
    return sportsCalendarDay(n, _dayOffset);
  }

  List<SportsLeague> get _shownLeagues => _displayLeagues
      .where((league) =>
          (_sportFilter == null ||
              league.espnPath.split('/').first == _sportFilter) &&
          matchesSportsLeague(league, _leagueFilter))
      .toList();

  Future<void> _load({bool silent = false, bool forceRefresh = false}) async {
    if (!_events || _sportsPanelOpen) return;
    if (silent && _loading && !forceRefresh) return;
    final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
        ? (Stopwatch()..start())
        : null;
    if (audit != null) debugPrint('IPTV_SPORTS scores=start');
    _lastLoadStarted = _now;
    _lastLoadCompleted = null;
    final token = ++_loadToken;
    if (!_matching) {
      _activityReason.value = forceRefresh
          ? 'Refreshing sports'
          : silent || _games.isNotEmpty
              ? 'Auto · scores'
              : 'Loading sports';
    }
    // Another Sports route (including multiview) may have changed a saved pick.
    _picks = SportsChannelPicks.load(_storage);
    _pullActivity.value = null;
    if (!silent) _channelActivity.value = null;
    final day = _day;
    final extraKey =
        '${day.toIso8601String()}:${_eventLeagues.map((l) => l.id).join(',')}';
    if (_extraKey != extraKey) {
      _extraKey = extraKey;
      _moreEventsActivity.value = false;
      _extrasTask =
          null; // In-flight work for another day will discard its result.
    }
    final service = widget.scores ?? SportsService.instance;
    setState(() {
      _loading = true;
      _error = null;
      _scoreError = service.errorForDay(_eventLeagues, day);
      _channelError = null;
      if (!silent) {
        _games =
            _withExtras(service.cachedGamesForDay(_eventLeagues, day), day);
      }
      _nextGame = null;
      _nextGameLooked = false;
    });
    // Warm the existing channel/guide cache during score downloads, even on
    // a cold open. The same coalesced queue handles arriving score batches.
    unawaited(_rematch(token));
    _loadExtras(day);
    final List<SportsGame> games;
    try {
      games = await service.gamesForDayWhileActive(_eventLeagues, day,
          forceRefresh: forceRefresh,
          shouldContinue: () =>
              mounted &&
              token == _loadToken &&
              _events &&
              !_covered &&
              !_backgrounded &&
              !_sportsPanelOpen,
          onStatus: (status) {
            if (mounted && token == _loadToken) _scoreActivity.value = status;
          },
          onProgress: (games) {
            if (!mounted || token != _loadToken || games.isEmpty) return;
            if (audit != null) {
              debugPrint(
                  'IPTV_SPORTS scores=progress events=${games.length} ms=${audit.elapsedMilliseconds}');
            }
            setState(() => _games = _withExtras(games, day));
            _ensureInitialFocus();
            unawaited(_rematch(token, 'Auto · new events'));
          });
    } catch (_) {
      // Normal feed failures are handled by the service. A failed cache/read or
      // unexpected provider response must also release refresh, while retaining
      // any events and channel checks that have already arrived.
      if (!mounted || token != _loadToken) return;
      _scoreActivity.value = null;
      setState(() {
        _loading = false;
        _scoreError = 'Could not update events. Try refreshing again.';
        _error = _games.isEmpty ? _scoreError : null;
      });
      _ensureInitialFocus();
      return;
    }
    if (!mounted || token != _loadToken) return;
    if (audit != null) {
      debugPrint(
          'IPTV_SPORTS scores=done events=${games.length} ms=${audit.elapsedMilliseconds}');
    }
    _scoreActivity.value = null;
    setState(() {
      _scoreError = service.errorForDay(_eventLeagues, day);
      _games = _withExtras(games, day);
      _loading = false;
      _lastLoadCompleted = _now;
      _error = _games.isEmpty ? _scoreError : null;
      final heroKey = _heroGame == null ? null : _gameKey(_heroGame!);
      _heroGame = _games.where((g) => _gameKey(g) == heroKey).firstOrNull;
    });
    _ensureInitialFocus();
    // Saved choices, channel names and broadcasters are available first;
    // the more expensive guide lookup can then enrich those results.
    unawaited(_rematch(token));
    _loadExtras(day);
    final filtered = sportsLeagueById(_leagueFilter ?? '');
    if (filtered != null &&
        service.errorForDay([filtered], day) == null &&
        !games.any((g) => g.league.id == filtered.id)) {
      final next = await service.nextGameStart(filtered, day);
      if (!mounted || token != _loadToken) return;
      setState(() {
        _nextGame = next;
        _nextGameLooked = true;
      });
    }
  }

  Future<void>? _refreshTask;
  Future<void> _refreshScores() {
    if (_loading && _refreshTask == null) return Future.value();
    return _refreshTask ??= _performRefresh().whenComplete(() {
      _refreshTask = null;
      if (mounted) setState(() {});
    });
  }

  Future<void> _performRefresh() async {
    _lastMatchSignature = null;
    final task = _load(silent: true, forceRefresh: true);
    final token = _loadToken;
    await task;
    if (!mounted || token != _loadToken) return;
    final error = _scoreError;
    if (error != null) {
      showSportsFeedNotice(context, onDetails: _showFeedDetails);
    }
  }

  // Scoreboard request tokens change every poll. Matching belongs to the
  // selected day/league scope, and must be allowed to finish across those polls.
  String get _matchScope =>
      '${_day.toIso8601String()}:${_eventLeagues.map((l) => l.id).join(',')}';
  bool _currentMatchScope(String scope) =>
      mounted && _events && !_sportsPanelOpen && scope == _matchScope;

  Object _matchingSignature(String scope) {
    final guide = context.read<EpgService>();
    final playlist = context.read<PlaylistManager>();
    return (
      scope,
      _now.millisecondsSinceEpoch ~/ 60000,
      playlist.liveRevision,
      guide.changeRevision,
      guide.currentGuideRevision,
      guide.lastUpdated,
      _matchSession.identities
    );
  }

  Future<void> _rematch([int? token, String reason = 'Auto · coverage']) {
    if (!_events ||
        _sportsPanelOpen ||
        (token != null && token != _loadToken)) {
      return Future.value();
    }
    final scope = _matchScope;
    _syncMatchInputs();
    return _matchWork.request(() async {
      if (!_currentMatchScope(scope)) return;
      final signature = _matchingSignature(scope);
      if (signature == _lastMatchSignature &&
          _checkedGames.length == _games.length) {
        return;
      }
      try {
        if (!_loading && !_matching) _activityReason.value = reason;
        final completedSignature = await _matchVisibleGames(scope);
        // Record completed work even if a score poll queued a follow-up. The
        // follow-up compares actual evidence inputs and usually becomes a no-op.
        if (completedSignature != null &&
            _currentMatchScope(scope) &&
            !_matching) {
          _lastMatchSignature = completedSignature;
          SportsBrowseCache.shared.save(_browseCacheKey, _matchSession,
              _guideGames, completedSignature, _now,
              games: _games);
          if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
            debugPrint(
                'IPTV_SPORTS saved events=${_games.length} guide=${_guideGames.length} checked=${_checkedGames.length} version=$_guideVersion');
          }
        }
      } catch (_) {
        if (!_currentMatchScope(scope)) return;
        setState(() {
          _matching = false;
          _channelActivity.value = null;
          _channelError =
              'Channel check interrupted. Existing matches retained.';
        });
      }
    });
  }

  bool _publishGuideDiscovery(List<SportsGame> discovered,
      {required String scope,
      required int revision,
      required Object guideVersion,
      Map<String, List<ChannelMatch>> matches = const {},
      bool complete = true,
      DateTime? validUntil}) {
    if (!_currentMatchScope(scope)) return false;
    final playlist = context.read<PlaylistManager>();
    if (playlist.liveRevision != revision || _guideVersion != guideVersion) {
      unawaited(_rematch());
      return false;
    }
    final completed = complete ? (revision, guideVersion) : null;
    if (!complete || completed != _completedGuideDiscovery) {
      _guideDiscoveryUntil = null;
    }
    _completedGuideDiscovery = completed;
    if (complete && validUntil != null) _guideDiscoveryUntil = validUntil;
    // A refresh may discover existing cards in a different order. Retain
    // still-current coverage until the complete scan can confirm removals.
    final coverage = complete || _guidePlaylistRevision != revision
        ? discovered
        : <String, SportsGame>{
            for (final game in _guideGames) game.id: game,
            for (final game in discovered) game.id: game,
          }.values.toList(growable: false);
    var changed = false;
    if (_guidePlaylistRevision != revision ||
        !sameGuideCoverage(coverage, _guideGames)) {
      _guideGames = coverage;
      _guidePlaylistRevision = revision;
      _games = _withGuideGames(_games, _day);
      if (_games.isNotEmpty) _error = null;
      changed = true;
    }
    if (matches.isNotEmpty) {
      // Discovery carries exact current/next programme bindings. Honour local
      // rejections and leave saved picks to the normal decision-aware pass.
      final accepted = <String, List<ChannelMatch>>{};
      for (final game in discovered) {
        final key = _gameKey(game);
        if (_picks.channelIdFor(game) != null || !matches.containsKey(key)) {
          continue;
        }
        final rejected = _picks.rejectedKeysFor(game);
        accepted[key] = matches[key]!
            .where((m) =>
                !sportsChannelRejected(rejected, m.channel.id, m.programme))
            .toList();
      }
      changed = _matchSession.apply(
              accepted, _matchSession.identities, revision, _now,
              complete: false) ||
          changed;
    }
    if (changed) setState(() {});
    return true;
  }

  Future<Object?> _matchVisibleGames(String scope) async {
    final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
        ? (Stopwatch()..start())
        : null;
    var lastAudit = -1000;
    if (audit != null) {
      debugPrint('IPTV_SPORTS pass=start events=${_games.length}');
    }
    if (!_matching) setState(() => _matching = true);
    final playlist = context.read<PlaylistManager>();
    void status(SportsWorkProgress update) {
      if (audit != null && audit.elapsedMilliseconds - lastAudit >= 1000) {
        lastAudit = audit.elapsedMilliseconds;
        debugPrint(
            'IPTV_SPORTS stage=${update.stage.name} completed=${update.completed} total=${update.total} ms=$lastAudit');
      }
      if (_currentMatchScope(scope)) _channelActivity.value = update;
    }

    var preparedPlaylist = false;
    if (_indexedPlaylistRevision != playlist.liveRevision) {
      status(const SportsWorkProgress(SportsWorkStage.channels));
      await playlist.ensureLiveChannelsLoaded();
      if (!_currentMatchScope(scope)) return null;
      final revision = playlist.liveRevision;
      await _matcher.prepare(playlist.visibleLiveChannels,
          onStatus: status,
          onGuideProgress: _dayOffset != 0
              ? null
              : (update) {
                  if (!mounted) return;
                  _publishGuideDiscovery(update.games,
                      scope: scope,
                      revision: revision,
                      guideVersion: update.evidenceVersion ?? _guideVersion,
                      matches: update.matches,
                      complete: update.complete,
                      validUntil: update.validUntil);
                });
      _supplement.configureTennisChannels(_matcher.skyTennisChannels);
      _indexedPlaylistRevision = revision;
      preparedPlaylist = true;
    }
    if (!_currentMatchScope(scope)) return null;
    if (preparedPlaylist) _loadExtras(_day);
    // Broadcaster/name hints can be offered while the initial guide is still
    // loading. Never downgrade a previously completed match or mark this check
    // complete; the full scorer must still validate the current programme.
    _syncMatchInputs();
    final earlyGames = _games
        .where((g) =>
            SportsChannelMatcher.isReadyToWatch(g, _now) &&
            (_matches[_gameKey(g)]?.isEmpty ?? true) &&
            !g.isGuideEvent)
        .toList();
    if (earlyGames.isNotEmpty) {
      final revision = playlist.liveRevision;
      final identities = _matchSession.identities;
      final guideVersion = _guideVersion;
      void publishHints(Map<String, List<ChannelMatch>> early) {
        if (!_currentMatchScope(scope) ||
            revision != playlist.liveRevision ||
            guideVersion != _guideVersion) {
          return;
        }
        final provisional = {
          for (final entry in early.entries)
            if (entry.value.isNotEmpty)
              entry.key: [
                for (final match in entry.value)
                  if (match.reason == MatchReason.pick || !match.isConfident)
                    match
                  else
                    ChannelMatch(match.channel, MatchReason.league, 300,
                        detail: 'Broadcaster suggestion · checking guide',
                        programme: match.programme,
                        supportingBroadcasts: match.supportingBroadcasts)
              ]
        };
        if (_matchSession.apply(provisional, identities, revision, _now,
            complete: false)) {
          setState(() {});
          if (audit != null) {
            debugPrint(
                'IPTV_SPORTS early_published events=${provisional.length} ms=${audit.elapsedMilliseconds}');
          }
        }
      }

      final early = await _matcher.matchDay(earlyGames, _picks,
          includeGuide: false, includePossible: true, onProgress: publishHints);
      if (!_currentMatchScope(scope)) return null;
      publishHints(early);
    }

    await _matcher.primeGuide(onStatus: status);
    if (!_currentMatchScope(scope)) return null;
    if (_indexedPlaylistRevision != playlist.liveRevision) {
      unawaited(_rematch());
      return null;
    }
    // Cold discovery normally arrives during index preparation. If it could
    // not run (or evidence changed), retain the ordinary progressive fallback.
    final revision = playlist.liveRevision;
    final guideVersion = _guideVersion;
    var discoveryPending = _dayOffset == 0 &&
        (_completedGuideDiscovery != (revision, guideVersion) ||
            !_now.isBefore(_guideDiscoveryUntil ?? _now));
    bool publishDiscovery(List<SportsGame> discovered,
        {Map<String, List<ChannelMatch>> matches = const {},
        bool complete = true,
        DateTime? validUntil}) {
      final accepted = _publishGuideDiscovery(discovered,
          scope: scope,
          revision: revision,
          guideVersion: guideVersion,
          matches: matches,
          complete: complete,
          validUntil: validUntil);
      if (accepted && complete) discoveryPending = false;
      return accepted;
    }

    void publishGuideProgress(SportsGuideDiscovery update) {
      if (update.evidenceVersion != null &&
          update.evidenceVersion != guideVersion) {
        return;
      }
      publishDiscovery(update.games,
          matches: update.matches,
          complete: update.complete,
          validUntil: update.validUntil);
    }

    Future<bool> discover() async =>
        publishDiscovery(await _matcher.discoverGuideEvents(
            onStatus: status, onProgress: publishGuideProgress));

    final plan = SportsMatchBatchPlan();
    Map<String, String>? contextFor;
    while (_currentMatchScope(scope)) {
      // A newer guide/catalogue must start a new pass. No partially stale batch
      // can acquire a completed signature or overwrite newer channel evidence.
      if (playlist.liveRevision != revision || _guideVersion != guideVersion) {
        unawaited(_rematch());
        return null;
      }
      _syncMatchInputs();
      final identities = _matchSession.identities;
      final currentGames = _games;
      if (!identical(contextFor, identities)) {
        final changed = await _matcher.rememberMatchContext(currentGames);
        if (changed) plan.invalidateTennis();
        contextFor = identities;
        // Scores/enrichment may have arrived while the worker learned context.
        // Select the next batch from the latest immutable input map.
        continue;
      }
      final batch = plan.next(currentGames, identities, _now);
      if (discoveryPending &&
          !batch.any((g) => SportsChannelMatcher.isReadyToWatch(g, _now))) {
        if (!await discover()) return null;
        continue;
      }
      if (batch.isEmpty) {
        setState(() {
          _matching = false;
          _channelActivity.value = null;
          _channelError = null;
        });
        // Capture the inputs actually completed, before another queued update
        // can run. A partial, failed or obsolete pass returns no signature.
        return _matchingSignature(scope);
      }
      final guideKeys =
          batch.where((g) => g.isGuideEvent).map(_gameKey).toSet();
      void apply(Map<String, List<ChannelMatch>> matches,
          {bool complete = false}) {
        if (!_currentMatchScope(scope) ||
            playlist.liveRevision != revision ||
            _guideVersion != guideVersion) {
          return;
        }
        // Discovery has already bound these cards to their actual programme.
        // A provisional fixture preview must not hide that exact coverage.
        // The final batch still applies its ordinary conflict resolution.
        if (!complete && guideKeys.isNotEmpty) {
          matches = {
            for (final entry in matches.entries)
              if (!guideKeys.contains(entry.key)) entry.key: entry.value
          };
        }
        // New live competitors must be checked before promoting old confident
        // assignments. Empty/possible results and manual picks are already safe
        // to retain as completed, so progress does not fall back to zero.
        var provisionalChanged = false;
        if (!identical(identities, _matchSession.identities) &&
            batch.any((g) => g.state == GameState.live)) {
          provisionalChanged = _matchSession.apply({
            for (final entry in matches.entries)
              if (!guideKeys.contains(entry.key))
                entry.key: [
                  for (final match in entry.value)
                    if (!match.isConfident || match.reason == MatchReason.pick)
                      match
                    else
                      ChannelMatch(match.channel, MatchReason.league,
                          math.min(match.score, 300),
                          detail: 'Checking other live fixtures',
                          programme: match.programme,
                          supportingBroadcasts: match.supportingBroadcasts)
                ]
          }, identities, revision, _now, complete: false);
          matches = {
            for (final entry in matches.entries)
              if (entry.value
                  .every((m) => !m.isConfident || m.reason == MatchReason.pick))
                entry.key: entry.value
          };
        }
        final changed = _matchSession.apply(matches, identities, revision, _now,
                complete: complete) ||
            provisionalChanged;
        if (changed || complete) {
          final now = _now;
          if (complete ||
              _lastProgressSnapshot == null ||
              now.difference(_lastProgressSnapshot!) >=
                  const Duration(seconds: 1)) {
            SportsBrowseCache.shared.save(
                _browseCacheKey, _matchSession, _guideGames, null, now,
                games: _games);
            _lastProgressSnapshot = now;
          }
          setState(() {});
        }
      }

      final batchKeys = batch.map(_gameKey).toSet();
      final otherChecked =
          _checkedGames.where((key) => !batchKeys.contains(key)).length;
      late final Map<String, List<ChannelMatch>> matches;
      try {
        matches = await _matcher.matchDay(batch, _picks,
            includePossible: true,
            onGuideProgress: discoveryPending ? publishGuideProgress : null,
            onProgress: apply, onStatus: (update) {
          status(update.stage == SportsWorkStage.matching
              ? SportsWorkProgress(update.stage,
                  completed: (otherChecked + update.completed)
                      .clamp(0, currentGames.length),
                  total: currentGames.length,
                  detail: update.detail,
                  failed: update.failed)
              : update);
        });
      } catch (error, stack) {
        // A failed title query must not hide guide-only coverage that can be
        // recovered from the current snapshot without another title query.
        if (_currentMatchScope(scope) &&
            (discoveryPending || _guideGames.isNotEmpty)) {
          try {
            if (!discoveryPending || await discover()) {
              _syncMatchInputs();
              final expected = _matchSession.identities;
              final guideOnly = _games.where((g) => g.isGuideEvent).toList();
              final fallback = await _matcher.matchDay(guideOnly, _picks,
                  includePossible: true);
              if (_currentMatchScope(scope) &&
                  playlist.liveRevision == revision &&
                  _guideVersion == guideVersion &&
                  _matchSession.apply(fallback, expected, revision, _now,
                      complete: true)) {
                SportsBrowseCache.shared.save(
                    _browseCacheKey, _matchSession, _guideGames, null, _now,
                    games: _games);
                setState(() {});
              }
            }
          } catch (_) {
            // Preserve the original failure; the next refresh can retry.
          }
        }
        Error.throwWithStackTrace(error, stack);
      }
      if (!_currentMatchScope(scope)) return null;
      if (playlist.liveRevision != revision || _guideVersion != guideVersion) {
        unawaited(_rematch());
        return null;
      }
      apply(matches, complete: true);
      plan.complete(batch, identities);
      if (audit != null) {
        debugPrint('IPTV_SPORTS batch=done events=${batch.length} '
            'checked=${_checkedGames.length}/${_games.length} ms=${audit.elapsedMilliseconds}');
      }
      // Retain the completed work, release worker ownership and reconsider live
      // arrivals before another bounded part of the later schedule.
      await Future<void>.delayed(Duration.zero);
    }
    return null;
  }

  static String _gameKey(SportsGame g) => SportsChannelPicks.eventKey(g);

  bool get _groupedBySport => _sportFilter == null && _leagueFilter == null;
  bool get _verticalGames => _narrow && !_groupedBySport;
  String _sportOf(SportsGame game) => game.league.espnPath.split('/').first;

  // Picker counts cover all enabled leagues for this day, irrespective of
  // the sport or Live filter. With channel applies to both counts and cards.
  Iterable<SportsGame> get _countableGames => _games.where(_acceptsChannel);
  Iterable<SportsGame> get _visibleGames => _scopedGames();
  Iterable<SportsGame> _scopedGames({bool favourites = true}) {
    final now = _now;
    return _countableGames.where((g) =>
        (_sportFilter == null || _sportOf(g) == _sportFilter) &&
        matchesSportsLeague(g.league, _leagueFilter) &&
        (!favourites || !_onlyFavourites || _isFavouriteGame(g)) &&
        _timeFilter.accepts(g, now));
  }

  Future<void> _chooseTimeFilter() async {
    final choice = await showSportsChoices(context,
        title: 'Show events',
        selected: _timeFilter,
        choices: [
          for (final mode in SportsTimeFilter.values)
            SportsChoice(mode, mode.label, mode.description,
                key: ValueKey('time-filter-${mode.name}'),
                icon: mode == SportsTimeFilter.live
                    ? Icons.sensors
                    : Icons.schedule)
        ]);
    if (choice != null && mounted) _setTimeFilter(choice);
  }

  void _setTimeFilter(SportsTimeFilter choice) {
    if (_timeFilter == choice) return;
    setState(() {
      _timeFilter = choice;
      _heroGame = null;
    });
    if (choice != SportsTimeFilter.all && _dayOffset != 0) _setDay(0);
  }

  void _saveEventsSelection() {
    unawaited(_storage.setSportsEventsSelection(
        _sportFilter, _leagueFilter, _favouritesFilter.name));
  }

  void _selectSport(String? sport) {
    _rememberBrowseContext(sport, null);
    setState(() {
      _sportFilter = sport;
      _leagueFilter = null;
      _heroGame = null;
    });
    _saveEventsSelection();
    _syncEventLeagueScope();
    // Favourite league scores are already loaded: changing sport stays local.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusZone(0, _sections);
    });
  }

  Future<void> _chooseChannelFilter() async {
    final selected = await showSportsChoices(context,
        title: 'Channel matches',
        selected: _channelFilter,
        choices: [
          for (final mode in SportsChannelFilter.values)
            SportsChoice(mode, mode.label, mode.description,
                key: ValueKey('channel-filter-${mode.name}'),
                icon: Icons.live_tv_outlined)
        ]);
    if (!mounted || selected == null) return;
    await _setChannelFilter(selected);
  }

  Future<void> _setChannelFilter(SportsChannelFilter selected) async {
    if (_channelFilter == selected) return;
    setState(() {
      _channelFilter = selected;
      if (_heroGame != null && !_acceptsChannel(_heroGame!)) _heroGame = null;
    });
    await _storage.setSportsChannelFilter(selected.name);
    await _storage.setSportsWithChannel(_withChannel);
  }

  Object? _orderedSectionsKey;
  List<_Section> _orderedSections = const [];
  Object? _sectionsKey;
  List<_Section> _cachedSections = const [];
  List<_Section> get _sections {
    final scope = (
      _favouritesFilter,
      _sportFilter,
      _leagueFilter,
      _timeFilter,
      _channelFilter,
      _day,
      _leagues.map((l) => l.id).join('|')
    );
    if (_browseScope != scope) {
      if (_browseScope != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _browseScope == scope && _verticalScroll.hasClients) {
            _verticalScroll.jumpTo(0);
          }
        });
      }
      _browseScope = scope;
      _releaseBrowse();
    }
    // Possible-channel cards are visible while checking. Completion can remove
    // an unmatched card even when its empty match list has not changed.
    final sourceKey = (
      _games,
      _matches,
      _channelFilter == SportsChannelFilter.possible ? _checkedGames : null,
      _channelFilter == SportsChannelFilter.possible
          ? _showPendingChannels
          : false,
      _sportFilter,
      _leagueFilter,
      _timeFilter,
      _channelFilter,
      _dayOffset,
      (_timeFilter.includesSoon || _hasF1)
          ? _now.millisecondsSinceEpoch ~/ 60000
          : null,
      _follows.revision,
      _favouriteLeagueIds
    );
    if (_orderedSectionsKey != sourceKey) {
      _orderedSectionsKey = sourceKey;
      _orderedSections = _makeSections(includeAllFavourites: true);
    }
    final key = (_favouritesFilter, sourceKey);
    if (_sectionsKey != key) {
      _sectionsKey = key;
      // Favourites preserve the already ranked order; toggling never re-sorts
      // an unchanged feed. Keep only one base snapshot and one local subset.
      final latest = _onlyFavourites
          ? [
              for (final section in _orderedSections)
                if (section.games.where(_isFavouriteGame).toList()
                    case final games when games.isNotEmpty)
                  _Section(section.id, section.label, games),
            ]
          : _orderedSections;
      final snapshot = _browseSnapshot;
      if (snapshot == null) {
        _cachedSections = latest;
      } else {
        final previous = {for (final section in snapshot) section.id: section};
        final stable = <_Section>[];
        for (final fresh in latest) {
          final old = previous[fresh.id];
          if (old == null) {
            stable.add(fresh);
            continue;
          }
          final games = {for (final g in fresh.games) _gameKey(g): g};
          stable.add(_Section(
              fresh.id,
              fresh.label,
              sportsFixturesFirst([
                for (final g in old.games)
                  if (games.remove(_gameKey(g)) case final current?) current,
                ...games.values,
              ])));
        }
        _preserveBrowsePositions(_cachedSections, stable);
        _browseSnapshot = stable;
        _cachedSections = stable;
      }
    }
    return _cachedSections;
  }

  void _preserveBrowsePositions(List<_Section> before, List<_Section> after) {
    bool sameOrder() {
      if (before.length != after.length) return false;
      for (var i = 0; i < before.length; i++) {
        if (before[i].id != after[i].id ||
            before[i].games.length != after[i].games.length) {
          return false;
        }
        for (var j = 0; j < before[i].games.length; j++) {
          if (_gameKey(before[i].games[j]) != _gameKey(after[i].games[j])) {
            return false;
          }
        }
      }
      return true;
    }

    if (sameOrder()) return;
    final cardHeight = _rowCardHeight + 6;
    final rowHeight = _horizontalSectionExtent;
    final focusedKey = _focusedCardKey;
    final hasCardFocus =
        focusedKey != null && (_cardNodes[focusedKey]?.hasFocus ?? false);
    final focusedHeading = before
        .where((s) => _chipNodes[s.id]?.hasFocus ?? false)
        .firstOrNull
        ?.id;
    double anchorDelta(Map<String, double> before, Map<String, double> after,
        double offset, double extent, String? preferred) {
      if (preferred != null &&
          before.containsKey(preferred) &&
          after.containsKey(preferred)) {
        return after[preferred]! - before[preferred]!;
      }
      return sportsAnchorDelta(before, after, offset, extent);
    }

    Map<String, double> positions(List<_Section> sections) {
      final out = <String, double>{};
      var top = _verticalGames ? 4.0 : 0.0;
      for (final section in sections) {
        if (_verticalGames) {
          top += _verticalHeadingHeight;
          for (final g in section.games) {
            out[_gameKey(g)] = top;
            top += cardHeight;
          }
        } else {
          out[section.id] = top;
          top += rowHeight;
        }
      }
      return out;
    }

    if (_verticalScroll.hasClients) {
      _verticalScroll.compensate(anchorDelta(
          positions(before),
          positions(after),
          _verticalScroll.offset,
          _verticalGames ? cardHeight : rowHeight,
          hasCardFocus
              ? (_verticalGames ? focusedKey : _focusedSectionId)
              : (_verticalGames ? null : focusedHeading)));
    }
    if (!_verticalGames) {
      final next = {for (final s in after) s.id: s};
      final width = _rowCardWidth + 12;
      for (final s in before) {
        final controller = _rowScrolls[s.id], updated = next[s.id];
        if (controller == null || !controller.hasClients || updated == null) {
          continue;
        }
        Map<String, double> columns(_Section row) => {
              for (final (i, g) in row.games.indexed) _gameKey(g): i * width,
            };
        controller.compensate(anchorDelta(columns(s), columns(updated),
            controller.offset, width, hasCardFocus ? focusedKey : null));
      }
    }
    final oldKeys = [for (final s in before) ...s.games.map(_gameKey)];
    final newKeys = {for (final s in after) ...s.games.map(_gameKey)};
    final focused =
        oldKeys.where((k) => _cardNodes[k]?.hasFocus ?? false).firstOrNull;
    final removedHeading = before
        .where((s) =>
            (_chipNodes[s.id]?.hasFocus ?? false) &&
            !after.any((n) => n.id == s.id))
        .firstOrNull;
    if (focused != null && newKeys.contains(focused)) {
      _zone = _firstRowZone +
          after.indexWhere((s) => s.games.any((g) => _gameKey(g) == focused));
      return;
    }
    if (focused == null && removedHeading == null) return;
    final index = focused == null ? 0 : oldKeys.indexOf(focused);
    final replacement =
        oldKeys.skip(index).where(newKeys.contains).firstOrNull ??
            oldKeys.take(index).where(newKeys.contains).lastOrNull ??
            newKeys.firstOrNull;
    final navigation = _navigationRevision, scope = _browseScope;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          navigation != _navigationRevision ||
          scope != _browseScope) {
        return;
      }
      _restoringBrowseFocus = true;
      final sections = _sections;
      final section = sections
          .where((s) => s.games.any((g) => _gameKey(g) == replacement))
          .firstOrNull;
      if (section != null) {
        _focusRowCard(section,
            section.games.indexWhere((g) => _gameKey(g) == replacement));
      } else {
        _focusZone(_filterZone, sections);
      }
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _restoringBrowseFocus = false);
    });
  }

  List<_Section> _makeSections({bool includeAllFavourites = false}) {
    final visible = _scopedGames(favourites: !includeAllFavourites).toList();
    List<SportsGame> followedFirst(Iterable<SportsGame> games) =>
        orderSportsGames(games, followed: _follows.involves);
    if (_groupedBySport) {
      final bySport = <String, List<SportsGame>>{};
      for (final game in visible) {
        (bySport[_sportOf(game)] ??= []).add(game);
      }
      final sports = bySport.keys.toList()
        ..sort((a, b) => sportLabel(a).compareTo(sportLabel(b)));
      return [
        for (final sport in sports)
          _Section(
              'sport:$sport',
              sportLabel(sport),
              sportsFixturesFirst([
                ...followedFirst(bySport[sport]!.where((g) => g.isLive)),
                ...followedFirst(
                    bySport[sport]!.where((g) => g.state == GameState.pre)),
                ...followedFirst(
                    bySport[sport]!.where((g) => g.state == GameState.post)),
              ]))
      ];
    }
    final live = followedFirst(visible.where((g) => g.isLive));
    final pre = followedFirst(visible.where((g) => g.state == GameState.pre));
    final post = followedFirst(visible.where((g) => g.state == GameState.post));
    final laterLabel = switch (_dayOffset) {
      0 => tr('Later today'),
      1 => tr('Tomorrow'),
      _ when _dayOffset < 0 => tr('Not played'),
      _ => tr('Scheduled'),
    };
    return [
      if (live.isNotEmpty)
        _Section(
            'live',
            live.any((g) => g.isGuideEvent) ? 'Live & on air' : tr('Live now'),
            live),
      if (pre.isNotEmpty)
        _Section(
            'pre',
            pre.any((g) => isF1BuildUp(g, _now))
                ? 'Build-up & upcoming'
                : laterLabel,
            pre),
      if (post.isNotEmpty) _Section('post', tr('Final'), post),
    ];
  }

  // ---------------------------------------------------------------- focus

  FocusNode _chipNode(String id) =>
      _chipNodes[id] ??= FocusNode(debugLabel: 'sports-chip-$id');

  FocusNode _cardNode(String key) =>
      _cardNodes[key] ??= FocusNode(debugLabel: 'sports-card-$key');

  String get _leagueChipId => 'sport-picker';
  String get _dayChipId => 'day';

  void _ensureInitialFocus() {
    if (!_events) return;
    if (_initialFocusDone) return;
    _initialFocusDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_events ||
          _sportsPanelOpen ||
          _route?.isCurrent == false) {
        return;
      }
      // Fill an empty route without resetting a choice made before this
      // callback runs, including while scores are still loading.
      final focused = FocusManager.instance.primaryFocus;
      var alreadyInside = false;
      if (focused is! FocusScopeNode && focused?.context?.mounted == true) {
        focused!.context!.visitAncestorElements((element) {
          alreadyInside = identical(element, context);
          return !alreadyInside;
        });
      }
      if (alreadyInside) return;
      _chipNode('view-events').requestFocus();
    });
  }

  void _focusVerticalCard(String key) {
    final node = _cardNode(key);
    void focus() {
      if (!mounted || !sportsFocusAttached(node)) return;
      node.requestFocus();
      Scrollable.ensureVisible(node.context!);
    }

    if (sportsFocusAttached(node)) {
      focus();
      return;
    }
    var offset = 4.0;
    for (final section in _sections) {
      offset += _verticalHeadingHeight;
      final index = section.games.indexWhere((g) => _gameKey(g) == key);
      if (index >= 0) {
        if (_verticalScroll.hasClients) {
          _verticalScroll.jumpTo(
              (offset + index * (_GameCard.compactHeight + 6))
                  .clamp(0.0, _verticalScroll.position.maxScrollExtent));
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => focus());
        return;
      }
      offset += section.games.length * (_GameCard.compactHeight + 6);
    }
  }

  void _focusZone(int zone, List<_Section> sections) {
    if (zone == 0) {
      // requestFocus alone doesn't scroll the chip row to it.
      final node = _chipNode(_narrow ? 'view-events' : _leagueChipId);
      node.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = node.context;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.5);
      });
    } else if (_narrow && zone == 1) {
      _chipNode(_leagueChipId).requestFocus();
    } else if (sections.isEmpty) {
      _chipNode(_error == null ? 'nextgame' : 'retry-scores').requestFocus();
    } else {
      final s = sections[zone - _firstRowZone];
      final remembered = _lastCardInRow[s.id];
      final key = s.games.any((g) => _gameKey(g) == remembered)
          ? remembered!
          : _gameKey(s.games.first);
      if (_verticalGames) {
        _focusVerticalCard(key);
      } else {
        if (_groupedBySport) {
          _focusRowHeading(s);
        } else {
          _focusRowCard(s, s.games.indexWhere((g) => _gameKey(g) == key));
        }
      }
    }
    _zone = zone;
  }

  static const _liveAllId = 'liveall';

  /// "See all" beside Live now: with 2+ live games.
  bool get _showLiveAll => _visibleGames.where((g) => g.isLive).length >= 2;

  bool get _onLiveAll => _chipNodes[_liveAllId]?.hasFocus ?? false;

  /// Up from one of Live now's first two cards reaches "See all" (it sits
  /// above them); Down from it goes back to the row.
  bool _liveAllStep(int delta, List<_Section> sections) {
    if (!_showLiveAll || sections.firstOrNull?.id != 'live') return false;
    if (_onLiveAll) {
      _focusZone(delta < 0 ? _firstRowZone - 1 : _firstRowZone, sections);
      return true;
    }
    if (delta > 0 || _zone != _firstRowZone) return false;
    final live = sections.first.games;
    final i =
        live.indexWhere((g) => _cardNodes[_gameKey(g)]?.hasFocus ?? false);
    if (i < 0 || i > 1) return false;
    _chipNode(_liveAllId).requestFocus();
    _ensureRowVisible('live');
    return true;
  }

  Future<void> _openLiveList() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SportsLiveListScreen(
        leagues: _shownLeagues,
        day: _day,
        follows: _follows,
        hideScores: _hideScores,
        matchGames: (games) => _matchGames(games, includePossible: true),
        onWatch: (channel) => _play(channel),
        onMenu: (game, matches, watch) => _openGame(game, matches, watch),
        initialGames: _visibleGames.toList(),
        channelFilter: _channelFilter,
        scores: widget.scores,
        initialMatches: _matches,
      ),
    ));
  }

  void _moveZone(int delta) {
    _navigationRevision++;
    if (_tvNavigation) {
      if (delta < 0) {
        _focusToolbar();
      } else {
        _focusEvents();
      }
      return;
    }
    final refresh = _chipNode('refresh');
    if (refresh.hasFocus) {
      _focusZone(delta < 0 ? _filterZone : _firstRowZone, _sections);
      return;
    }
    final sections = _sections;
    if ((_zone == _filterZone && delta > 0) ||
        (_zone == _firstRowZone &&
            delta < 0 &&
            (!_groupedBySport ||
                (sections.isNotEmpty &&
                    _chipNode(sections.first.id).hasFocus)))) {
      refresh.requestFocus();
      return;
    }
    if (_groupedBySport && _zone >= _firstRowZone) {
      final sections = _sections;
      final index = _zone - _firstRowZone;
      if (index < sections.length) {
        final section = sections[index];
        final heading = _chipNode(section.id);
        if (delta > 0 && heading.hasFocus) {
          final key = _lastCardInRow[section.id];
          final game =
              section.games.where((g) => _gameKey(g) == key).firstOrNull ??
                  section.games.first;
          _cardNode(_gameKey(game)).requestFocus();
          return;
        }
        if (delta < 0 && !heading.hasFocus) {
          heading.requestFocus();
          if (heading.context != null) {
            Scrollable.ensureVisible(heading.context!);
          }
          return;
        }
      }
    }
    if (_verticalGames) {
      final cards = _sections.expand((s) => s.games).toList();
      final current =
          cards.indexWhere((g) => _cardNodes[_gameKey(g)]?.hasFocus ?? false);
      final next = current + delta;
      if (current >= 0 && next >= 0 && next < cards.length) {
        _focusVerticalCard(_gameKey(cards[next]));
        return;
      }
    }
    if (_liveAllStep(delta, sections)) return;
    final target = _zone + delta;
    final rows = sections.isEmpty && _nextGame != null ? 1 : sections.length;
    if (target < 0 || target >= _firstRowZone + rows) return;
    _focusZone(target, sections);
  }

  /// Touch controls on Android phones.
  bool get _touch =>
      defaultTargetPlatform == TargetPlatform.android &&
      !context.read<AppPreferences>().isTelevision;

  /// Portrait layout: vertical games and persistent bottom navigation.
  bool get _landscape => sportsLandscape(context);
  bool get _compactCards => _narrow || _landscape;
  double get _rowCardWidth => _landscape
      ? _GameCard.landscapeWidth
      : _narrow
          ? _GameCard.compactWidth
          : _GameCard.width;
  double get _rowCardHeight => _landscape
      ? _GameCard.landscapeHeight
      : _narrow
          ? _GameCard.compactHeight
          : _GameCard.height;
  bool get _narrow => MediaQuery.sizeOf(context).width < 600;

  void _ensureRowVisible(String sectionId) {
    if (_restoringBrowseFocus) return;
    // A tap focuses the card; scrolling the page then would yank it away.
    if (_touch || _narrow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          (_tvNavigation && _focusedSectionId != sectionId) ||
          (_pendingRowFocus != null &&
              _pendingRowFocus!.section != sectionId)) {
        return;
      }
      final ctx = _rowKeys[sectionId]?.currentContext;
      if (ctx != null) _revealItem(ctx);
    });
  }

  // -------------------------------------------------------------- actions

  void _setLeagueFilter(String? id) {
    if (_leagueFilter == id) return;
    _rememberBrowseContext(
        id == null
            ? _sportFilter
            : sportsLeagueById(id)?.espnPath.split('/').first,
        id);
    setState(() {
      _leagueFilter = id;
      if (id != null) {
        _sportFilter = sportsLeagueById(id)?.espnPath.split('/').first;
      }
      _heroGame = null;
    });
    _saveEventsSelection();
    _syncEventLeagueScope();
  }

  List<SportsLeague> get _eventFeedsForScope => _onlyFavourites
      ? _favouriteFeeds
      : sportsBrowseLeagues
          .where((league) =>
              (_sportFilter == null ||
                  league.espnPath.startsWith('$_sportFilter/')) &&
              matchesSportsLeague(league, _leagueFilter))
          .toList();

  void _syncEventLeagueScope() {
    final next = _eventFeedsForScope;
    if (next.length == _eventLeagues.length &&
        next.indexed
            .every((entry) => entry.$2.id == _eventLeagues[entry.$1].id)) {
      return;
    }
    _eventLeagues = next;
    // A hidden tab must not briefly publish the previous league's games when
    // it reopens. The visible load restores the appropriate service cache.
    _games = const [];
    _error = null;
    _lastLoadCompleted = null;
    // Invalidate stale feed callbacks before changing scope, even on a hidden tab.
    _loadToken++;
    if (_events) unawaited(_load());
  }

  void _jumpToNextGame() {
    final next = _nextGame;
    if (next == null) return;
    final offset = sportsCalendarDayOffset(_now, next);
    _setDay(offset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chipNode(_dayChipId).requestFocus();
    });
  }

  void _setDay(int offset) {
    if (_dayOffset == offset) return;
    setState(() {
      _dayOffset = offset;
      if (offset != 0) _timeFilter = SportsTimeFilter.all;
      _heroGame = null;
    });
    unawaited(_load());
  }

  Future<void> _toggleScores() async {
    setState(() => _hideScores = !_hideScores);
    await _storage.setSportsHideScores(_hideScores);
  }

  /// Shown leagues from storage: base leagues plus bank leagues the user
  /// added (a bank id that was sent back is dropped).
  List<SportsLeague> _savedLeagues() => savedSportsLeagues(_storage);

  void _pauseEventWork() {
    // Invalidate completion as well as progress. A cancelled partial load must
    // never be recorded as complete and suppress missing feeds on return.
    _loadToken++;
    _loading = false;
    _matching = false;
    _listingTimer?.cancel();
  }

  Future<T?> _showSportsPanel<T>(WidgetBuilder builder,
      {bool besidePreview = false, bool fullWidth = false}) async {
    if (_sportsPanelOpen) return null;
    _sportsPanelOpen = true;
    _pendingRowFocus = null;
    _navigationRevision++;
    _pauseEventWork();
    _viewActive.value = false;
    try {
      return await showSportsPanel<T>(
          context: context,
          builder: builder,
          besidePreview: besidePreview,
          fullWidth: fullWidth,
          maxWidth: fullWidth ? 1000 : 600);
    } finally {
      _sportsPanelOpen = false;
      if (mounted) _viewActive.value = !_covered && !_backgrounded;
    }
  }

  void _rememberBrowseContext(String? sport, String? league) {
    if (_browseSport == sport && _browseLeague == league) return;
    _browseSport = sport;
    _browseLeague = league;
    unawaited(_storage.setSportsBrowseSelection(sport, league));
  }

  void _rememberBrowseLeague(SportsLeague league) {
    _rememberBrowseContext(league.espnPath.split('/').first, league.id);
  }

  void _rememberScheduleScope(String? sport, String? league) {
    _rememberBrowseContext(sport, league);
  }

  SportsLeague? get _initialStandingsLeague => resolveSportsBrowseLeague(
      sportsStandingsLeagues,
      leagueId: _browseLeague,
      sport: _browseSport ?? _sportFilter,
      fallbackId: _leagueFilter ??
          (widget.standings ?? SportsStandingsService.instance).lastLeagueId);

  Future<void> _showGameDetails(SportsGame game) async {
    await _showSportsPanel<void>(
        (_) => SportsDetailsPanel(
            league: game.league, game: game, hideScores: _hideScores),
        besidePreview: true);
    if (mounted && _events) _resumeEvents();
  }

  Future<void> _editLeagues() async {
    final changed = await _showSportsPanel<bool>(
        (_) => const SportsLeagueManagerScreen(embedded: true));
    if (!mounted) return;
    if (changed != true) {
      if (_events) _resumeEvents();
      return;
    }
    setState(() {
      _leagues = _savedLeagues();
      _favouriteLeagueIds = _leagues.map((l) => l.id).toSet();
      _updateFavouriteFeeds();
      _lastLoadCompleted = null;
      if (_onlyFavourites &&
          _leagueFilter != null &&
          !_favouriteFeeds.any((l) => l.id == _leagueFilter)) {
        _leagueFilter = null;
      }
      if (_onlyFavourites &&
          _sportFilter != null &&
          !_favouriteFeeds
              .any((l) => l.espnPath.startsWith('$_sportFilter/'))) {
        _sportFilter = null;
      }
    });
    _syncEventLeagueScope();
    if (_events && !_loading) unawaited(_load());
  }

  /// Channel matches for games outside the day being shown (My Teams).
  Future<Map<String, List<ChannelMatch>>> _matchGames(List<SportsGame> games,
      {bool includePossible = false}) async {
    final playlist = context.read<PlaylistManager>();
    await playlist.ensureLiveChannelsLoaded();
    await _matcher.prepare(playlist.visibleLiveChannels);
    return _matcher.matchDay(games, _picks, includePossible: includePossible);
  }

  /// OK on a card: straight to the stream when a channel is matched (your
  /// pick ranks first), otherwise the menu so one can be picked. Holding OK
  /// always opens the menu (other channels / pick / forget) — OK
  /// popping the menu even with a channel assigned was one press too many.
  /// [matches] = My Teams' own (its games aren't all on the shown day).
  Future<void> _activateGame(SportsGame game,
      [List<ChannelMatch>? matches]) async {
    // Playback stays usable even while fresh channel evidence is pending.
    if (_isPreviewing(game)) return _play(_previewChannel!, game: game);
    final best = _channelFilter
        .preferred(matches ?? _matches[_gameKey(game)] ?? const []);
    if (best == null) return _openGame(game, matches);
    await _setPreview(game, best.channel);
  }

  /// A channel chosen from the game's menu plays in the hero (OK there =
  /// full screen).
  Future<void> _watch(Channel channel, SportsGame game) =>
      _setPreview(game, channel);

  /// The active channel shared with the Live TV preview.
  static Channel? _playingNow(PlaybackService playback) =>
      playback.currentChannel;

  // ------------------------------------------------------------- preview

  /// The game playing in the hero, refreshed from the latest scores, or null
  /// when nothing Sports started is still what [PlaybackService] plays.
  SportsGame? _livePreview(PlaybackService playback) {
    final game = _previewGame;
    final channel = _previewChannel;
    if (game == null || channel == null) return null;
    if (_playingNow(playback)?.id != channel.id) return null;
    final key = _gameKey(game);
    return _games.where((g) => _gameKey(g) == key).firstOrNull ?? game;
  }

  bool _isPreviewing(SportsGame game) =>
      _livePreview(context.read<PlaybackService>()) != null &&
      _gameKey(_previewGame!) == _gameKey(game);

  SportsGame? _focusedCardGame() {
    for (final g in _games) {
      if (_cardNodes[_gameKey(g)]?.hasFocus ?? false) return g;
    }
    return null;
  }

  /// Play/Pause on a game card: its channel plays in the hero; again on the
  /// same card stops it. No channel yet = the menu, to pick one.
  void _onPlayKey() {
    final game = _focusedCardGame();
    if (game == null) return;
    if (_isPreviewing(game)) {
      unawaited(_setPreview(null, null));
      return;
    }
    final best = _channelFilter.preferred(_matches[_gameKey(game)] ?? const []);
    if (best == null) {
      unawaited(_openGame(game));
      return;
    }
    unawaited(_setPreview(game, best.channel));
  }

  /// Starts [channel] for [game] in the hero, or stops the hero's stream
  /// (null). [PlaybackService.play] closes whatever played before (a
  /// background channel too), so audio never overlaps — but only if two
  /// plays never run at once: overlapping calls can leave the first stream
  /// orphaned and still playing (same family as Multiview's audio-underneath
  /// bug). So presses run one at a time, and a press superseded while
  /// waiting is skipped. Each start also waits for the stream to open (max
  /// 10 s) before the next one: 1-connection accounts reject a new
  /// connection while the old one is still closing.
  /// [waitReady]: hold the chain until the stream is up, so a quick second
  /// Play/Pause can't start a stream over one still connecting. OK skips it:
  /// it goes full screen at once (waiting kept the Fire Stick showing the
  /// hero for seconds first).
  Future<void> _setPreview(SportsGame? game, Channel? channel,
      {bool waitReady = true}) {
    if (game != null && channel != null) {
      SportsChannelAttempts.shared.record(game, channel.id);
    }
    if (widget.onChooseChannel != null) {
      return channel == null
          ? Future.value()
          : widget.onChooseChannel!(channel);
    }
    final seq = ++_previewSeq;
    final stopId = _previewChannel?.id;
    final playback = context.read<PlaybackService>();
    setState(() {
      _previewGame = game;
      _previewChannel = channel;
    });
    return _previewChain = _previewChain.then((_) async {
      if (!mounted || seq != _previewSeq) return;

      try {
        if (channel == null) {
          // Only what the hero itself was playing.
          if (stopId != null && playback.currentChannel?.id == stopId) {
            await playback.stop();
          }
          return;
        }
        await playback.play(channel);
        if (!waitReady) return;
        await playback.initFuture
            ?.timeout(const Duration(seconds: 10), onTimeout: () {});
      } catch (_) {
        // play() reports its own errors; keep the chain alive.
      }
    });
  }

  /// [watch]: how a chosen channel plays — the hero by default; the live
  /// list passes its own (full screen, back to the list). It also turns
  /// "Play here" into "Play" full screen (no hero there).
  final _channelBrowseSession = SportsChannelBrowseSession();
  bool _gamePickerOpen = false;
  Future<void> _openGame(SportsGame game,
      [List<ChannelMatch>? gameMatches,
      Future<void> Function(Channel, SportsGame)? watch]) async {
    if (_gamePickerOpen || _route?.isCurrent == false) return;
    final play = watch ?? _watch;
    final matches =
        gameMatches ?? _matches[_gameKey(game)] ?? const <ChannelMatch>[];
    final online = gameMatches == null ? _pickerMatches(game) : null;
    Widget menu(BuildContext context) {
      final playingChannel =
          context.select<PlaybackService, Channel?>(_playingNow);
      return SwallowHeldActivate(
          child: SportsChannelPickerDialog(
        matcher: _matcher,
        browseSession: _channelBrowseSession,
        playlistNames: {
          for (final profile in context.read<PlaylistManager>().profiles)
            profile.id: profile.name
        },
        rejectedKeys: _picks.rejectedKeysFor(game),
        onDecision: (row, rejected) async {
          if (rejected) {
            await _picks.rejectForGame(game, row.channel, row.programme);
          } else {
            await _picks.restoreForGame(game, row.channel, row.programme);
          }
          if (mounted) unawaited(_rematch());
        },
        game: game,
        matches: matches,
        onlineMatches: online,
        matching: gameMatches == null && _pending(game),
        hideScores: _hideScores,
        hasPick: _picks.channelIdFor(game) != null,
        allowDetails: !game.isGuideEvent,
        selectedId: _picks.channelIdFor(game),
        playingId: playingChannel?.id,
        // Only retain a missing channel when Sports started it for this event.
        // Otherwise the picker labels playback only for the top suggestion,
        // never just because it appears among broad sport-related alternatives.
        playingChannel: _isPreviewing(game) ? playingChannel : null,
        tileMatch: _displayedMatch(
            game, _livePreview(context.read<PlaybackService>()), matches),
        playFullScreen: watch != null,
        allowMultiview:
            widget.onChooseChannel == null && canOpenMultiview(context),
      ));
    }

    final origin = FocusManager.instance.primaryFocus;
    final route =
        DialogRoute<SportsChannelChoice>(context: context, builder: menu);
    _gamePickerOpen = true;
    final SportsChannelChoice? result;
    try {
      result = await Navigator.of(context).push(route);
      // Wait for focus/overlay disposal, but don't hold this guard through the
      // subsequent connection: another event's menu must remain usable then.
      await route.completed;
    } finally {
      _gamePickerOpen = false;
    }
    if (!mounted) return;
    if (_tvNavigation) {
      final target = watch == null ? _cardNodes[_gameKey(game)] : origin;
      if (target != null &&
          sportsFocusAttached(target) &&
          target.canRequestFocus) {
        target.requestFocus();
      } else if (_route?.isCurrent ?? false) {
        _focusEvents();
      }
    }
    if (result == null) return;
    if (result.details) {
      await _showGameDetails(game);
      return;
    }
    if (result.reset) {
      await _picks.clearFor(game);
      await _rematch();
      return;
    }
    final channel = result.channel;
    if (channel == null) return;
    if (widget.onChooseChannel != null) {
      await widget.onChooseChannel!(channel);
      return;
    }
    if (result.multiview) {
      await openChannelInMultiview(context, channel);
      return;
    }
    if (!result.manual) {
      if (channel.id != _picks.channelIdFor(game)) {
        await _picks.pickForGame(game, channel.id);
        unawaited(_rematch());
      }
      await play(channel, game);
      return;
    }
    await _saveManualChannel(game, channel, play);
  }

  Future<void> _saveManualChannel(SportsGame game, Channel channel,
      Future<void> Function(Channel, SportsGame) play) async {
    final scope = await showSportsDialog<_PickScope>(
      context: context,
      builder: (_) => _PickScopeDialog(game: game, channel: channel),
    );
    if (scope == null || !mounted) return;
    switch (scope) {
      case _PickScope.game:
        await _picks.pickForGame(game, channel.id);
      case _PickScope.first when game.league.kind != SportsKind.team:
        await _picks.pickForSeries(game, channel.id);
      case _PickScope.first:
        await _picks.pickForTeam(game, game.first, channel.id);
      case _PickScope.second:
        await _picks.pickForTeam(game, game.second, channel.id);
    }
    unawaited(_rematch());
    if (!mounted) return;
    await play(channel, game);
  }

  /// Fullscreen [channel]. With [game] (Android), it goes through the hero
  /// preview, so Back from the player shows it there (one stream, no
  /// reconnect — the hero's VideoPlayerPane stays under the player the same
  /// way the TV guide's preview box does).
  Future<void> _play(Channel channel, {SportsGame? game}) async {
    if (widget.onChooseChannel != null) return widget.onChooseChannel!(channel);
    if (_openingPlayer || _leaving || _covered) return;
    _openingPlayer = true;
    try {
      // Same split as SearchScreen._openChannel: Windows has its own player.
      // A game takes the hero's session full screen (no reconnect); Back
      // there hands it back to DesktopMiniPlayer, i.e. the hero again.

      final int selection;
      final playback = context.read<PlaybackService>();
      if (game != null &&
          _previewChannel?.id == channel.id &&
          playback.currentChannel?.id == channel.id &&
          playback.controller != null) {
        // Reusing the active preview needs no connection queue. In particular,
        // opening fullscreen while it connects must not wait up to ten seconds
        // for the preview's readiness wait before showing the player.
        selection = _previewSeq;
      } else if (game != null) {
        final ready = _setPreview(game, channel, waitReady: false);
        selection = _previewSeq;
        await ready;
      } else {
        // A standalone channel: the hero goes back to normal and a preview
        // still waiting in the chain is skipped.
        selection = ++_previewSeq;
        setState(() {
          _previewGame = null;
          _previewChannel = null;
        });
        await _previewChain;
        if (!mounted || !_canOpenPlayer(selection)) return;
        await context.read<PlaybackService>().play(channel);
      }
      if (!mounted || !_canOpenPlayer(selection)) return;
      await PlayerScreen.open(Navigator.of(context), channel);
    } finally {
      _openingPlayer = false;
    }
  }

  bool _openingPlayer = false;
  bool _canOpenPlayer(int selection) =>
      mounted &&
      !_leaving &&
      !_covered &&
      selection == _previewSeq &&
      (_route?.isCurrent ?? false);

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final sections = _events ? _sections : const <_Section>[];
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Fullscreen ownership and transport status belong to the player widgets;
    // only a channel change affects the event list and its preview summary.
    context.select<PlaybackService, Channel?>(_playingNow);
    final playback = context.read<PlaybackService>();
    final preview = _livePreview(playback);
    final current = _playingNow(playback);
    final playing = current != null && Channel.isLiveId(current.rawId);
    // An unrelated current channel must not inherit the focused game's score.
    Widget buildPreview(Widget activity) => widget.onChooseChannel != null
        ? activity
        : ValueListenableBuilder<SportsGame?>(
            valueListenable: _heroFocus,
            builder: (context, focusedGame, _) {
              final hero = _replays || ((_standings || _schedule) && !playing)
                  ? null
                  : playing
                      ? preview
                      : focusedGame;
              return _Hero(
                key: _heroKey,
                activity: activity,
                replays: _replays,
                standings: _standings || _schedule,
                highlights: _highlights,
                game: hero,
                matches: hero == null
                    ? null
                    : _channelFilter == SportsChannelFilter.matched
                        ? _matches[_gameKey(hero)]
                            ?.where((m) => m.isConfident)
                            .toList()
                        : _matches[_gameKey(hero)],
                matching: hero != null && _pending(hero),
                hideScores: _hideScores,
                playing: playing,
                touch: _touch,
                narrow: _narrow,
                sidebar: _landscape,
                compact: (_standings || _schedule) && _narrow && keyboardOpen,
                onVideoTap: playing
                    ? () => _replays
                        ? _playReplay(current)
                        : _play(current, game: preview)
                    : hero != null
                        ? () => _activatePreview(hero)
                        : null,
              );
            },
          );
    final content = TvPreviewRemoteNavigation(
        enabled: widget.onChooseChannel == null &&
            context.read<AppPreferences>().isTelevision &&
            playing,
        onFullscreen: () {
          final channel = context.read<PlaybackService>().currentChannel;
          if (channel != null) {
            PlayerScreen.open(Navigator.of(context), channel);
          }
        },
        child: PopScope(
          canPop: _leaving || (_events && _groupedBySport),
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && TvTextFieldGate.editingFocusedField) return;
            if (didPop) return;
            if (_standings || _schedule) {
              _setGuideView('events');
              _chipNode('view-events').requestFocus();
            } else if (_replays) {
              final panel = _highlights ? _highlightPanelKey : _replayPanelKey;
              if (panel.currentState?.backToOverview() ?? false) return;
              _setGuideView('events');
            } else if (!_groupedBySport) {
              _selectSport(null);
            }
          },
          child: SportsScreenFrame(
              child: withTvThemeIfNeeded(
            context,
            (context) => Stack(
              children: [
                const Positioned.fill(child: SettingsGradientBackground()),
                Scaffold(
                  backgroundColor: Colors.transparent,
                  appBar: widget.onChooseChannel == null
                      ? null
                      : AppBar(
                          toolbarHeight: 42,
                          title: Text(
                              widget.selectionTitle ??
                                  'Choose a sports channel',
                              style: const TextStyle(fontSize: 15))),
                  bottomNavigationBar: _narrow &&
                          widget.onChooseChannel == null &&
                          !((_standings || _schedule) && keyboardOpen)
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: IptvBottomBar(
                              selected: 'sports', onSelect: _leaveFor))
                      : null,
                  body: SafeArea(
                    child: CallbackShortcuts(
                      bindings: {
                        if (_tvNavigation)
                          const SingleActivator(LogicalKeyboardKey.contextMenu):
                              () {
                            if (_schedule) {
                              _scheduleFocus.requestFocus();
                            } else if (_standings) {
                              _standingsFocus.requestFocus();
                            } else if (_replays) {
                              _guidePanel?.focusRefresh();
                            } else {
                              _chipNode('refresh').requestFocus();
                            }
                          },
                        if (_events) ...{
                          const SingleActivator(LogicalKeyboardKey.arrowUp):
                              () => _moveZone(-1),
                          const SingleActivator(LogicalKeyboardKey.arrowDown):
                              () => _moveZone(1),
                          // Remotes send one combined key or separate ones.
                          const SingleActivator(
                              LogicalKeyboardKey.mediaPlayPause): _onPlayKey,
                          const SingleActivator(LogicalKeyboardKey.mediaPlay):
                              _onPlayKey,
                          const SingleActivator(LogicalKeyboardKey.mediaPause):
                              _onPlayKey,
                        },
                      },
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(_narrow ? 10 : 20,
                            _narrow ? 4 : 6, _narrow ? 10 : 20, 0),
                        child: _schedule
                            ? SportsSchedulePanel(
                                key: const ValueKey('sports-inline-schedule'),
                                browseState: _scheduleBrowse,
                                follows: _follows,
                                entryFocus: _scheduleFocus,
                                onFocusToolbar: _focusToolbar,
                                service: widget.scores,
                                initialLeague: _scheduleBrowse.leagueId == null
                                    ? null
                                    : sportsLeagueById(
                                        _scheduleBrowse.leagueId!),
                                overviewLeagues:
                                    _browseFavouritesFilter.isFiltered
                                        ? _favouriteScheduleFeeds
                                        : _allScheduleFeeds,
                                favouriteLeagueIds: _favouriteLeagueIds,
                                favouritesFilter: _browseFavouritesFilter,
                                keyboardOpen: keyboardOpen,
                                onLeagueChanged: _rememberBrowseLeague,
                                onScopeChanged: _rememberScheduleScope,
                                onManageLeagues: _editLeagues,
                                onFavouritesChanged: _setBrowseFavouritesFilter,
                                onGameDetails: _showGameDetails,
                                channelMatchForGame: (game) =>
                                    _displayedMatch(game, preview),
                                onWatchGame: (game, match) =>
                                    _activateGame(game, [match]),
                                hideScores: _hideScores,
                                clock: widget.clock,
                                layoutBuilder: (filters, actions, content) =>
                                    SportsHubLayout(
                                        header: _buildHeader(filters,
                                            actions: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  actions,
                                                  _buildSportsOptions()
                                                ])),
                                        preview: buildPreview(
                                            const SizedBox.shrink()),
                                        content: content))
                            : _standings
                                ? SportsTeamsScreen(
                                    key:
                                        const ValueKey('sports-inline-standings'),
                                    follows: _follows,
                                    service: widget.standings,
                                    initialLeague: _initialStandingsLeague,
                                    onLeagueChanged: _rememberBrowseLeague,
                                    favouriteLeagueIds: _favouriteLeagueIds,
                                    favouritesFilter: _browseFavouritesFilter,
                                    onFavouritesChanged: _setBrowseFavouritesFilter,
                                    onManageLeagues: _editLeagues,
                                    embedded: true,
                                    keyboardOpen: keyboardOpen,
                                    browseState: _standingsBrowse,
                                    entryFocusNode: _standingsFocus,
                                    searchFocusNode: _standingsSearchFocus,
                                    onFocusToolbar: _focusToolbar,
                                    onTeamDetails: (league, row) => _showSportsPanel<void>((_) => SportsDetailsPanel(league: league, team: row.team, standing: row, hideScores: _hideScores), besidePreview: true),
                                    layoutBuilder: (filters, actions, content) => SportsHubLayout(header: _buildHeader(filters, actions: Row(mainAxisSize: MainAxisSize.min, children: [actions, _buildSportsOptions()])), preview: buildPreview(const SizedBox.shrink()), content: content))
                                : _replays
                                    ? ValueListenableBuilder<bool>(
                                        valueListenable: _viewActive,
                                        builder: (context, active, _) =>
                                            SportsReplaysPanel(
                                          key: _highlights
                                              ? _highlightPanelKey
                                              : _replayPanelKey,
                                          onFocusToolbar: _focusToolbar,
                                          highlights: _highlights,
                                          active: active,
                                          playingId: current?.id,
                                          onPlay: _playReplay,
                                          layoutBuilder: (filters, activity,
                                                  actions, content) =>
                                              SportsHubLayout(
                                                  showPreview:
                                                      widget.onChooseChannel ==
                                                          null,
                                                  header: _buildHeader(filters,
                                                      actions: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            actions,
                                                            _buildReplayInfo()
                                                          ])),
                                                  preview:
                                                      buildPreview(activity),
                                                  content: content),
                                        ),
                                      )
                                    : SportsHubLayout(
                                        showPreview: widget.onChooseChannel == null,
                                        header: _buildHeader(_buildPrimaryFilters(),
                                            actions: Row(mainAxisSize: MainAxisSize.min, children: [
                                              _buildFavouritesFilter(),
                                              const SizedBox(width: 6),
                                              SportsToolbarActions(children: [
                                                if (_compactEventTools)
                                                  _buildEventFilterButton(),
                                                _buildDayPicker(),
                                                _buildSportsOptions(),
                                              ]),
                                            ])),
                                        preview: buildPreview(_buildLoadingStatus()),
                                        content: _buildBody(sections, preview)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )),
        ));
    return RouteAwareRegion(
        listener: this,
        onRouteChanged: (route) => _route = route,
        child: content);
  }

  Future<void> _leaveFor(String destination) async {
    if (destination == 'sports' || _leaving) return;
    final canPopNow = _route?.popDisposition == RoutePopDisposition.pop;
    setState(() => _leaving = true);
    _previewSeq++;
    if (!mounted) return;
    if (canPopNow) {
      Navigator.of(context).pop(destination);
      return;
    }
    // A filtered/replay view first needs to update its PopScope permission.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(destination);
    });
  }

  Map<String, ({int live, int upcoming})> _pickerCounts(
      String Function(SportsGame) key) {
    final counts = <String, ({int live, int upcoming})>{};
    for (final game in _countableGames) {
      for (final id in ['', key(game)]) {
        final old = counts[id] ?? (live: 0, upcoming: 0);
        counts[id] = (
          live: old.live + (game.isLive ? 1 : 0),
          upcoming: old.upcoming + (game.state == GameState.pre ? 1 : 0)
        );
      }
    }
    return counts;
  }

  Future<void> _chooseSport() async {
    final choice = await showSportsFilterPicker(context,
        title: 'Choose sport',
        itemLabel: 'sports',
        description: _onlyFavourites
            ? _favouritesFilter.description
            : 'All leagues · use sport or league to narrow results',
        selected: _sportFilter ?? '',
        options: [
          ...sportsSportOptions(_browseCatalogue, _pickerCounts(_sportOf),
              favouriteOnly: _onlyFavourites),
          sportsManageLeaguesOption(_leagues.length),
        ]);
    if (choice == null || !mounted) return;
    if (choice == '__manage_leagues__') {
      await _editLeagues();
      return;
    }
    _selectSport(choice.isEmpty ? null : choice);
  }

  Future<void> _chooseLeague() async {
    final counts = _pickerCounts((g) => g.league.id);
    counts['rugby.live'] = (
      live: _countableGames
          .where((g) => g.league.espnPath.startsWith('rugby/') && g.isLive)
          .length,
      upcoming: 0
    );
    final choice = await showSportsFilterPicker(context,
        title: 'Choose league',
        itemLabel: 'leagues',
        description: _onlyFavourites
            ? _favouritesFilter.description
            : 'All leagues · use sport or league to narrow results',
        topFirst: true,
        selected: _leagueFilter ?? '',
        options: sportsLeagueOptions(_browseCatalogue, counts,
            sport: _sportFilter,
            favouriteCount: _leagues.length,
            favouritesOnly: _onlyFavourites));
    if (choice != null && mounted) {
      if (choice == '__manage_leagues__') {
        await _editLeagues();
      } else if (choice == '__all_sports__') {
        _selectSport(null);
      } else {
        _setLeagueFilter(choice.isEmpty ? null : choice);
      }
    }
  }

  void _setGuideView(String view) {
    if (_sportsView == view) return;
    if (view == 'schedule') {
      _scheduleBrowse.favouritesFilter = _browseFavouritesFilter;
      final league =
          _browseLeague == null ? null : sportsLeagueById(_browseLeague!);
      final scheduleLeague = league != null &&
              supportsSportsSchedule(league) &&
              league.id != 'rugby.live'
          ? league.id
          : null;
      if (!_scheduleBrowse.initialized) _scheduleBrowse.days = 1;
      if (_scheduleBrowse.sport != _browseSport ||
          _scheduleBrowse.leagueId != scheduleLeague) {
        _scheduleBrowse.sport = _browseSport;
        _scheduleBrowse.leagueId = scheduleLeague;
        _scheduleBrowse.offset = 0;
        _scheduleBrowse.selectedDay = null;
      }
      _scheduleBrowse.initialized = true;
    }
    _pullActivity.value = null;
    _channelActivity.value = null;
    _pendingRowFocus = null;
    _navigationRevision++;
    if (_events) {
      // In-flight feeds may finish into their shared cache, but hidden event
      // batches must not rebuild or steal focus from the standings pane.
      _pauseEventWork();
    }
    setState(() => _sportsView = view);
    _listingTimer?.cancel();
    if (_events) _resumeEvents();
  }

  void _resumeEvents() {
    // Present retained events before resuming cached feed preparation.
    unawaited(WidgetsBinding.instance.endOfFrame.then<void>((_) {
      if (!mounted || !_events || _sportsPanelOpen) return;
      final completed = _lastLoadCompleted;
      if (completed == null ||
          _scoreError != null ||
          _now.difference(completed) >= const Duration(seconds: 30) ||
          _now.isBefore(completed)) {
        unawaited(_load(silent: _games.isNotEmpty));
        return;
      }
      // A quick return is still inside the existing poll interval. Resume
      // channel work without regrouping every score feed.
      _loadExtras(_day);
      unawaited(_rematch());
    }));
  }

  Future<void> _playReplay(Channel channel) async {
    if (widget.onChooseChannel != null) return widget.onChooseChannel!(channel);
    final playing = _playingNow(context.read<PlaybackService>());
    if (playing?.id == channel.id) {
      await PlayerScreen.open(Navigator.of(context), channel);

      return;
    }
    await _setPreview(null, channel);
  }

  Widget _buildViewTabs() => ValueListenableBuilder<FocusHighlightMode>(
      valueListenable: _tabFocusMode,
      builder: (context, mode, _) {
        // Logical focus survives touch navigation. Only keyboard/remote input
        // should paint it; the selected page always retains its underline.
        final showFocus =
            _tvNavigation || mode == FocusHighlightMode.traditional;
        final tabs = <Widget>[
          for (final view in [
            'events',
            if (widget.onChooseChannel == null) ...['standings', 'schedule'],
            'replays',
            'highlights'
          ])
            Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Builder(
                    builder: (context) => TextButton(
                          key: ValueKey('sports-view-$view'),
                          focusNode: _chipNode('view-$view'),
                          onFocusChange: (focused) {
                            if (focused) {
                              _zone = 0;
                              _revealItem(context);
                            }
                          },
                          onPressed: () {
                            _chipNode('view-$view').requestFocus();
                            _setGuideView(view);
                            _revealItem(context);
                          },
                          style: ButtonStyle(
                            animationDuration: Duration.zero,
                            minimumSize: WidgetStatePropertyAll(Size(
                                0,
                                _tvNavigation
                                    ? 34
                                    : sportsTouchControlHeight(context))),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                    horizontal: _narrow ? 2 : 8)),
                            textStyle: const WidgetStatePropertyAll(TextStyle(
                                fontSize: 11.5, fontWeight: FontWeight.w600)),
                            foregroundColor: WidgetStatePropertyAll(
                                _sportsView == view
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                            backgroundColor: WidgetStateProperty.resolveWith(
                                (states) => showFocus &&
                                        states.contains(WidgetState.focused)
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: .18)
                                    : Colors.transparent),
                            // Resolve side explicitly: the app theme's focus
                            // border otherwise overrides the shape's side.
                            side: WidgetStateProperty.resolveWith((states) =>
                                BorderSide(
                                    color: showFocus &&
                                            states.contains(WidgetState.focused)
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent)),
                            shape: const WidgetStatePropertyAll(
                                RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.all(Radius.circular(6)))),
                          ),
                          child: Semantics(
                              selected: _sportsView == view,
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 7),
                                decoration: BoxDecoration(
                                    border: Border(
                                        bottom: BorderSide(
                                            width: 2,
                                            color: _sportsView == view
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                : Colors.transparent))),
                                child: Text(switch (view) {
                                  'standings' => 'Standings',
                                  'schedule' => 'Schedule',
                                  'replays' => 'Replays',
                                  'highlights' => 'Highlights',
                                  _ => 'Events'
                                }),
                              )),
                        ))),
        ];
        return FocusTraversalOrder(
            order: const NumericFocusOrder(0),
            child: _narrow
                ? LayoutBuilder(builder: (context, box) {
                    final scale =
                        MediaQuery.textScalerOf(context).scale(11.5) / 11.5;
                    final columns = box.maxWidth / tabs.length >= 57 * scale
                        ? tabs.length
                        : 3;
                    return Wrap(children: [
                      for (final tab in tabs)
                        SizedBox(width: box.maxWidth / columns, child: tab)
                    ]);
                  })
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: tabs)));
      });

  Widget _buildHeader(Widget filters, {required Widget actions}) =>
      SportsToolbarNavigation(
          key: _toolbarKey,
          enabled: _tvNavigation,
          onDown: (node) {
            _lastToolbarFocus = node;
            if (_schedule) {
              _scheduleFocus.requestFocus();
            } else if (_standings) {
              _standingsSearchFocus.requestFocus();
            } else if (_replays) {
              _guidePanel?.focusContent();
            } else {
              _focusEvents();
            }
          },
          child: LayoutBuilder(builder: (context, constraints) {
            final columns = _landscape && widget.onChooseChannel == null;
            return Padding(
              padding: EdgeInsets.only(
                  bottom: compactSportsControls(context) ? 2 : 4),
              child: Column(children: [
                if (_narrow)
                  _buildViewTabs()
                else
                  SizedBox(
                      height: sportsFilterHeight(context).clamp(
                          _tvNavigation
                              ? 0.0
                              : sportsTouchControlHeight(context),
                          double.infinity),
                      child: Row(children: [
                        SizedBox(
                            width: columns
                                ? sportsPreviewWidth(constraints.maxWidth)
                                : widget.onChooseChannel == null
                                    ? 280
                                    : 210,
                            child: _buildViewTabs()),
                        SizedBox(width: columns ? 12 : 8),
                        Expanded(
                            child: FocusTraversalOrder(
                                order: const NumericFocusOrder(1),
                                child: filters)),
                        const SizedBox(width: 6),
                        FocusTraversalOrder(
                            order: const NumericFocusOrder(2), child: actions),
                      ])),
                if (_narrow &&
                    !((_standings || _schedule) &&
                        MediaQuery.viewInsetsOf(context).bottom > 0)) ...[
                  SizedBox(height: compactSportsControls(context) ? 2 : 6),
                  SizedBox(
                      height: sportsFilterHeight(context).clamp(
                          _tvNavigation
                              ? 0.0
                              : (_schedule
                                  ? sportsScheduleControlHeight(context)
                                  : sportsTouchControlHeight(context)),
                          double.infinity),
                      child: FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: Row(children: [
                            Expanded(child: filters),
                            if (!_splitEventActions) ...[
                              const SizedBox(width: 4),
                              actions,
                            ],
                          ]))),
                  if (_splitEventActions) ...[
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                ],
              ]),
            );
          }));

  Widget _buildReplayInfo() => SizedBox(
      width: 30,
      child: IconButton(
          tooltip: _highlights ? 'About highlights' : 'About replays',
          icon: const Icon(Icons.info_outline, size: 18),
          padding: EdgeInsets.zero,
          onPressed: () => showSportsDialog<void>(
              context: context,
              builder: (context) => SportsCompactDialog(
                    title: _highlights
                        ? 'Highlights on your channels'
                        : 'Replays on your channels',
                    actions: [
                      TextButton(
                          onPressed: () => popRouteIfCurrent(context),
                          child: const Text('Got it'))
                    ],
                    child: Text(
                        _highlights
                            ? 'Highlight shows airing now on your channels, identified by their current guide title or description. Includes match highlights and sport roundups; general news and full-match replays stay separate.\n\nTap to preview; tap again for fullscreen. Open programme details for the full description and alternate channels. Browse by sport or search from the ••• menu.\n\nThis uses the saved guide, with no extra provider requests. Roundups may cover several games, so no single match date or score is assumed.'
                            : 'Sports programmes airing now, using replay labels, past event dates and classic seasons in the guide. Likely replays have a clear event listing but no live marker; they are marked separately.\n\nTap to preview; tap again for fullscreen. Open the details button for the full programme description and any other channels.\n\nNo scores are shown here. Use the ••• menu to hide likely replays or browse replay channels without current programme details; their availability is unverified. Highlights, info channels and inactive slots are excluded. Refresh checks the saved guide; normal guide updates continue as usual.',
                        style: const TextStyle(fontSize: 12, height: 1.4)),
                  ))));

  Widget _buildSportPicker() => Expanded(
      flex: _narrow ? 1 : 3,
      child: SportsFilterButton(
          key: const ValueKey('sport-picker'),
          minimumHeight: _tvNavigation ? 0 : sportsTouchControlHeight(context),
          caption: 'Sport',
          value: _sportFilter == null
              ? 'All sports'
              : (_narrow || _tvNavigation)
                  ? shortSportLabel(_sportFilter!)
                  : sportLabel(_sportFilter!),
          selected: _sportFilter != null,
          focusNode: _chipNode(_leagueChipId),
          onFocus: () => _zone = _filterZone,
          onTap: _chooseSport));
  Widget _buildLeaguePicker() => Expanded(
      flex: _narrow ? 1 : 4,
      child: SportsFilterButton(
          key: const ValueKey('league-picker'),
          minimumHeight: _tvNavigation ? 0 : sportsTouchControlHeight(context),
          caption: 'League',
          value: _displayLeagues
                  .where((l) => l.id == _leagueFilter)
                  .firstOrNull
                  ?.shortName ??
              'All leagues',
          selected: _leagueFilter != null,
          focusNode: _chipNode('league-picker'),
          onFocus: () => _zone = _filterZone,
          onTap: _chooseLeague));
  bool get _hasScoreIssues =>
      _scoreError != null || (_scoreActivity.value?.failed ?? 0) > 0;

  void _showFeedDetails([BuildContext? origin]) {
    final issues = (widget.scores ?? SportsService.instance)
        .issuesForDay(_eventLeagues, _day);
    showSportsDialog<void>(
        context: origin ?? context,
        builder: (_) => SportsFeedDiagnostics(issues: issues));
  }

  Widget _buildScoreRefresh() => ValueListenableBuilder<SportsWorkProgress?>(
      valueListenable: _scoreActivity,
      builder: (context, _, __) {
        final showInfo = _hasScoreIssues;
        if (!showInfo && (_chipNodes['feed-info']?.hasFocus ?? false)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_hasScoreIssues && (_route?.isCurrent ?? false)) {
              _chipNode('refresh').requestFocus();
            }
          });
        }
        return Row(mainAxisSize: MainAxisSize.min, children: [
          if (showInfo)
            SizedBox(
                width: 28,
                height: 28,
                child: Focus(
                  canRequestFocus: false,
                  onKeyEvent: (_, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                      _chipNode('refresh').requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                      _chipNode('status-details').requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      _focusToolbar();
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      _focusEvents();
                      return KeyEventResult.handled;
                    }
                    if (event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.select ||
                            event.logicalKey ==
                                LogicalKeyboardKey.gameButtonA)) {
                      _showFeedDetails();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: IconButton(
                      key: const ValueKey('sports-feed-info'),
                      focusNode: _chipNode('feed-info'),
                      tooltip: 'Event feed error details',
                      constraints:
                          const BoxConstraints.tightFor(width: 28, height: 28),
                      padding: EdgeInsets.zero,
                      onPressed: _showFeedDetails,
                      color: interfaceColor(context, Colors.white60),
                      icon: const Icon(Icons.info_outline, size: 15)),
                )),
          _buildScoreRefreshButton(),
        ]);
      });

  Widget _buildScoreRefreshButton({bool iconOnly = false}) => SizedBox(
        height: iconOnly ? 44 : (_tvNavigation ? 24 : 40),
        width: iconOnly ? 40 : null,
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (_tvNavigation &&
                (event is KeyDownEvent || event is KeyRepeatEvent)) {
              if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                _focusEvents();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                _chipNode(_hasScoreIssues ? 'feed-info' : 'status-details')
                    .requestFocus();
                return KeyEventResult.handled;
              }
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
              if (!_loading && _refreshTask == null) _refreshScores();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Tooltip(
            message: _loading
                ? 'Event feeds are already updating. Channel checks continue as events arrive.'
                : 'Reload event feeds and recheck channels using your saved guide',
            child: iconOnly
                ? IconButton(
                    key: const ValueKey('sports-refresh'),
                    focusNode: _chipNode('refresh'),
                    tooltip: _loading || _refreshTask != null
                        ? 'Updating events and channels'
                        : 'Refresh events and channel matches',
                    onPressed: () {
                      if (!_loading && _refreshTask == null) _refreshScores();
                    },
                    padding: EdgeInsets.zero,
                    color: interfaceColor(context, Colors.white38),
                    icon: const Icon(Icons.refresh, size: 16))
                : TextButton.icon(
                    key: const ValueKey('sports-refresh'),
                    focusNode: _chipNode('refresh'),

                    // Keep remote focus attached while a refresh is in progress.
                    onPressed: () {
                      if (!_loading && _refreshTask == null) _refreshScores();
                    },
                    style: ButtonStyle(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 4),
                      ),
                      minimumSize: const WidgetStatePropertyAll(Size.zero),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.focused)
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                      ),
                      foregroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.focused)
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : interfaceColor(context, Colors.white38),
                      ),
                    ),
                    icon: const Icon(Icons.refresh, size: 11),
                    label: Text(
                      _refreshTask != null
                          ? 'Refreshing…'
                          : _loading
                              ? 'Updating…'
                              : 'Refresh both',
                      style: const TextStyle(fontSize: 9.5),
                    ),
                  ),
          ),
        ),
      );
  void _toggleFavouritesFilter() => _setFavouritesFilter(_onlyFavourites
      ? SportsFavouritesFilter.all
      : SportsFavouritesFilter.favourites);

  void _setBrowseFavouritesFilter(SportsFavouritesFilter value) {
    if (_browseFavouritesFilter == value) return;
    setState(() {
      _browseFavouritesFilter = value;
      _scheduleBrowse.favouritesFilter = value;
      _updateFavouriteFeeds();
    });
  }

  void _setFavouritesFilter(SportsFavouritesFilter value) {
    if (_favouritesFilter == value) return;
    if (_verticalScroll.hasClients) _verticalScroll.jumpTo(0);
    setState(() {
      _favouritesFilter = value;
      _browseFavouritesFilter = value;
      _scheduleBrowse.favouritesFilter = value;
      _updateFavouriteFeeds();
      _heroGame = null;
    });
    _saveEventsSelection();
    _syncEventLeagueScope();
  }

  Widget _buildFavouritesFilter() => SportsFavouritesFilterButton(
      key: const ValueKey('events-favourites-only'),
      focusNode: _chipNode('events-favourites-only'),
      filter: _favouritesFilter,
      favouriteLeagueCount: _favouriteLeagueIds.length,
      favouriteTeamCount: _follows.teams.length,
      onChanged: _setFavouritesFilter);

  Widget _buildSportsOptions() => SizedBox(
      width: _tvNavigation ? 28 : 32,
      child: Focus(
          canRequestFocus: false,
          onFocusChange: (focused) {
            if (focused) _zone = 0;
          },
          child: IconButton(
              tooltip: 'Sports options',
              focusNode: _chipNode('options'),
              padding: EdgeInsets.zero,
              onPressed: _openOptions,
              icon: Icon(Icons.more_horiz,
                  size: 19, color: interfaceColor(context, Colors.white60)))));

  String _dayLabel(int offset) => switch (offset) {
        -1 => tr('Yesterday'),
        0 => tr('Today'),
        1 => tr('Tomorrow'),
        _ => DateFormat('EEE d MMM').format(sportsCalendarDay(_now, offset)),
      };

  Future<void> _chooseDay() async {
    final offset = await showSportsChoices(context,
        title: tr('Choose day'),
        selected: _dayOffset,
        choices: [
          for (final day in {for (var i = -1; i <= 6; i++) i, _dayOffset})
            SportsChoice(day, _dayLabel(day),
                DateFormat('EEEE d MMMM').format(sportsCalendarDay(_now, day)),
                icon: Icons.calendar_today_outlined)
        ]);
    if (offset != null && mounted) _setDay(offset);
  }

  Future<void> _openOptions() async {
    final detailsGame = _events ? (_heroFocus.value ?? _heroGame) : null;
    final choice = await showSportsChoices(context,
        title: tr('Sports options'),
        selected: '',
        showSelection: false,
        choices: [
          if (detailsGame != null && !detailsGame.isGuideEvent)
            SportsChoice('details', 'Game details', detailsGame.title,
                icon: Icons.info_outline),
          SportsChoice(
              'scores',
              _hideScores ? tr('Show scores') : tr('Hide scores'),
              'Control score visibility while browsing.',
              icon: Icons.visibility_outlined),
          const SportsChoice('teams', 'Favourite teams & athletes',
              'Manage the teams and athletes highlighted in Sports.',
              icon: Icons.star_border),
          if (widget.onChooseChannel == null)
            const SportsChoice('standings', 'Standings',
                'Browse league tables and favourite teams.',
                icon: Icons.table_chart_outlined),
          const SportsChoice('leagues', sportsManageLeaguesLabel,
              'Choose your default leagues in Events & Schedule.',
              icon: Icons.tune),
          SportsChoice(
              'extras',
              'Online extras: ${_onlineExtras ? 'On' : 'Off'}',
              'Extra schedules and broadcast information.',
              icon: Icons.public),
          const SportsChoice('sources', 'About sports data',
              'Where events and channel hints come from.',
              icon: Icons.info_outline),
        ]);
    if (!mounted) return;
    switch (choice) {
      case 'details':
        if (detailsGame != null) await _showGameDetails(detailsGame);
      case 'standings':
        _setGuideView('standings');
        _chipNode('view-standings').requestFocus();
      case 'teams':
        if (!_follows.isEmpty) {
          unawaited(_follows.rememberGames(_games).catchError((Object _) {}));
        }
        await _showSportsPanel<void>(
            (_) => SportsTeamsScreen(
                follows: _follows,
                favorites: true,
                panel: true,
                initialLeague: sportsLeagueById(_leagueFilter ?? '')),
            besidePreview: true);
        if (mounted) {
          setState(() {
            _browseSnapshot = null;
            _updateFavouriteFeeds();
          });
          _syncEventLeagueScope();
          if (_events) _resumeEvents();
        }
      case 'sources':
        await showSportsDialog<void>(
            context: context,
            builder: (context) => SportsCompactDialog(
                  title: 'About sports data',
                  actions: [
                    TextButton(
                        onPressed: () => popRouteIfCurrent(context),
                        child: const Text('Close'))
                  ],
                  child: const Text(
                      'Scores: ESPN. Optional extras include Jolpica F1 session calendars, NHL broadcasts, Sky Sports tennis listings, TheSportsDB schedules and TV listings, and RaceTV Guide motorsport calendars. Scheduled times are estimates; the channel guide can help identify early coverage.',
                      style: TextStyle(fontSize: 12, height: 1.4)),
                ));
      case 'scores':
        await _toggleScores();
      case 'leagues':
        await _editLeagues();
      case 'extras':
        setState(() {
          _onlineExtras = !_onlineExtras;
          _extraKey = null;
          if (!_onlineExtras) {
            _leagueFilter = null;
            _sportFilter = null;
          }
        });
        await _storage.setSportsOnlineExtras(_onlineExtras);
        if (mounted) unawaited(_load());
    }
  }

  // Keep useful labels on the smallest phones without compressing TV controls.
  bool get _splitEventActions =>
      _events && _narrow && MediaQuery.sizeOf(context).width < 360;

  bool get _compactEventTools =>
      !_tvNavigation ||
      MediaQuery.sizeOf(context).width < 900 ||
      MediaQuery.textScalerOf(context).scale(11.5) > 15;

  Widget _buildEventFilterButton() => SizedBox(
      width: _tvNavigation ? 28 : 32,
      child: IconButton(
          key: const ValueKey('event-filters'),
          focusNode: _chipNode('event-filters'),
          padding: EdgeInsets.zero,
          tooltip: 'Filters: ${_timeFilter.label} · ${_channelFilter.label}',
          color: _timeFilter != SportsTimeFilter.all || _withChannel
              ? Theme.of(context).colorScheme.primary
              : null,
          icon: const Icon(Icons.tune, size: 18),
          onPressed: () => showSportsEventFilters(context,
              time: _timeFilter,
              channels: _channelFilter,
              onTime: _setTimeFilter,
              onChannels: (mode) => unawaited(_setChannelFilter(mode)))));

  Widget _buildDayPicker() => SizedBox(
      width: _tvNavigation ? 28 : 32,
      child: IconButton(
          key: const ValueKey('sports-day'),
          focusNode: _chipNode(_dayChipId),
          padding: EdgeInsets.zero,
          tooltip:
              'Date: ${_dayLabel(_dayOffset)} · ${DateFormat('d MMM').format(_day)}',
          color: _dayOffset == 0 ? null : Theme.of(context).colorScheme.primary,
          icon: Badge(
              isLabelVisible: _dayOffset != 0,
              child: const Icon(Icons.calendar_today_outlined, size: 18)),
          onPressed: _chooseDay));

  Widget _buildLiveFilter() => SportsTimeControl(
      key: const ValueKey('live-only'),
      value: _timeFilter,
      focusNode: _chipNode('live-only'),
      onChoose: _chooseTimeFilter);

  Widget _buildChannelFilter() => SportsFilterButton(
      key: const ValueKey('with-channel'),
      caption: 'Channels',
      value: switch (_channelFilter) {
        SportsChannelFilter.matched => 'Matched',
        SportsChannelFilter.possible => 'Possible',
        SportsChannelFilter.all => 'Any'
      },
      focusNode: _chipNode('with-channel'),
      selected: _withChannel,
      onFocus: () => _zone = _filterZone,
      onTap: _chooseChannelFilter);
  Widget _buildPrimaryFilters() => SizedBox(
      height: sportsFilterHeight(context).clamp(
          _tvNavigation ? 0.0 : sportsTouchControlHeight(context),
          double.infinity),
      child: Row(children: [
        _buildSportPicker(),
        const SizedBox(width: 4),
        _buildLeaguePicker(),
        if (!_compactEventTools) ...[
          const SizedBox(width: 4),
          SizedBox(
              width: 104,
              height: sportsFilterHeight(context),
              child: _buildLiveFilter()),
          const SizedBox(width: 4),
          SizedBox(width: 88, child: _buildChannelFilter()),
        ],
      ]));

  Future<void> _activatePreview(SportsGame game) async {
    final channel =
        _channelFilter.preferred(_matches[_gameKey(game)] ?? const [])?.channel;
    if (channel == null) return _openGame(game);
    await _setPreview(game, channel);
  }

  Widget _buildLoadingStatus() => ValueListenableBuilder<bool>(
        valueListenable: _viewActive,
        builder: (context, active, _) => SportsActivityStatus(
            key: const ValueKey('sports-status-slot'),
            television: _tvNavigation,
            inline: !_tvNavigation && compactSportsPortrait(context),
            onFeedDetails: !_tvNavigation && compactSportsPortrait(context)
                ? _showFeedDetails
                : null,
            detailsFocusNode: _chipNode('status-details'),
            onDetailsRight: () =>
                _chipNode(_hasScoreIssues ? 'feed-info' : 'refresh')
                    .requestFocus(),
            scores: _scoreActivity,
            channels: _channelActivity,
            reason: _activityReason,
            moreEvents: _moreEventsActivity,
            loadingEvents: _loading,
            checkingChannels: _matching,
            hasUsableEvents: _sections.any((s) => s.games.any((g) =>
                (_matches[_gameKey(g)] ?? const <ChannelMatch>[]).isNotEmpty)),
            eventError: _scoreError,
            channelError: _channelError,
            pull: _pullActivity,
            active: active,
            eventCount: _games.length,
            checkedCount: _checkedGames.length,
            error: _channelError ?? _scoreError,
            refreshButton: !_tvNavigation && compactSportsPortrait(context)
                ? _buildScoreRefreshButton(iconOnly: true)
                : _buildScoreRefresh()),
      );

  Widget _buildBody(List<_Section> sections, SportsGame? preview) => Listener(
        onPointerDown: (_) => _lockBrowse(),
        onPointerSignal: (_) => _lockBrowse(),
        child: NotificationListener<ScrollStartNotification>(
          onNotification: (notification) {
            if (notification.dragDetails != null) _lockBrowse();
            return false;
          },
          child: _buildEventScroll(sections, preview),
        ),
      );

  Widget _buildRefreshControl() => SportsRefreshControl(
        key: const ValueKey('sports-pull-refresh'),
        externalStatus: true,
        onPullChanged: (label) {
          if (mounted) _pullActivity.value = label;
        },
        onRefresh: _loading && _refreshTask == null
            ? null
            : () async {
                await _refreshScores();
                return _scoreError == null;
              },
      );

  static const _eventScrollPhysics = BouncingScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  );

  Widget _buildEventScroll(List<_Section> sections, SportsGame? preview) {
    if ((_loading && sections.isEmpty) ||
        (_withChannel && _matching && sections.isEmpty)) {
      return CustomScrollView(
        key: const PageStorageKey('sports-events'),
        controller: _verticalScroll,
        scrollCacheExtent:
            _tvNavigation ? const ScrollCacheExtent.pixels(48) : null,
        physics: _eventScrollPhysics,
        slivers: [
          _buildRefreshControl(),
          SliverFillRemaining(
            hasScrollBody: false,
            child: SportsEventsLoading(
                scores: _scoreActivity,
                channels: _channelActivity,
                eventCount: _games.length),
          ),
        ],
      );
    }
    if (sections.isEmpty) {
      return CustomScrollView(
          key: const PageStorageKey('sports-events'),
          controller: _verticalScroll,
          scrollCacheExtent:
              _tvNavigation ? const ScrollCacheExtent.pixels(48) : null,
          physics: _eventScrollPhysics,
          slivers: [
            _buildRefreshControl(),
            SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_error != null ? Icons.cloud_off : Icons.event_busy,
                          size: 44,
                          color: interfaceColor(context, Colors.white38)),
                      const SizedBox(height: 10),
                      Text(
                          (_error != null
                                  ? 'Some event feeds are unavailable.\nRefresh to retry, or open the loading status for details.'
                                  : null) ??
                              _channelError ??
                              (_onlyFavourites && !_games.any(_isFavouriteGame)
                                  ? _favouritesFilter.emptySelectionMessage(
                                          hasLeagues:
                                              _favouriteLeagueIds.isNotEmpty,
                                          hasTeams: !_follows.isEmpty) ??
                                      'No favourites match these filters'
                                  : _timeFilter != SportsTimeFilter.all
                                      ? 'No ${_timeFilter.label.toLowerCase()} events for these filters'
                                      : _withChannel && _games.isNotEmpty
                                          ? tr(
                                              'No games with a matched channel')
                                          : tr(
                                              'No games on this day for your leagues')),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: interfaceColor(context, Colors.white70),
                              fontSize: 16)),
                      if (_onlyFavourites) ...[
                        const SizedBox(height: 10),
                        TextButton.icon(
                            onPressed: _toggleFavouritesFilter,
                            icon: const Icon(Icons.star_border, size: 18),
                            label: const Text('Show all events')),
                      ],
                      if (_error != null || _channelError != null) ...[
                        const SizedBox(height: 14),
                        SportsChip(
                          focusNode: _chipNode('retry-scores'),
                          label: tr('Retry'),
                          icon: Icons.refresh,
                          selected: false,
                          onFocus: () => _zone = _firstRowZone,
                          onTap: () => unawaited(_refreshScores()),
                        ),
                      ] else if (_nextGame != null) ...[
                        const SizedBox(height: 14),
                        SportsChip(
                          focusNode: _chipNode('nextgame'),
                          label: tr('Next game: {date}', {
                            'date': DateFormat('EEE d MMM').format(_nextGame!),
                          }),
                          icon: Icons.event,
                          selected: false,
                          onFocus: () => _zone = _firstRowZone,
                          onTap: _jumpToNextGame,
                        ),
                      ] else if (_error == null && _nextGameLooked) ...[
                        const SizedBox(height: 4),
                        Text(
                            tr('No upcoming games listed yet for this league.'),
                            style: TextStyle(
                                color: interfaceColor(context, Colors.white38),
                                fontSize: 13)),
                      ] else if (_error == null) ...[
                        const SizedBox(height: 4),
                        Text(
                            _timeFilter != SportsTimeFilter.all
                                ? 'Choose All events under Showing to include other start times.'
                                : _withChannel && _games.isNotEmpty
                                    ? tr(
                                        'Turn off With channel to see all games.')
                                    : tr(
                                        'Try another day, or add leagues in Sports options.'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: interfaceColor(context, Colors.white38),
                                fontSize: 13)),
                      ],
                    ],
                  ),
                ))
          ]);
    }
    if (_verticalGames) {
      return CustomScrollView(
        key: const PageStorageKey('sports-events'),
        physics: _eventScrollPhysics,
        controller: _verticalScroll,
        scrollCacheExtent:
            _tvNavigation ? const ScrollCacheExtent.pixels(48) : null,
        slivers: [
          _buildRefreshControl(),
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          for (var i = 0; i < sections.length; i++) ...[
            SliverToBoxAdapter(
                key: ValueKey('heading-${sections[i].id}'),
                child: SizedBox(
                    height: _verticalHeadingHeight,
                    child: _buildSection(sections[i], preview,
                        headingOnly: true))),
            SliverFixedExtentList(
              key: ValueKey('events-${sections[i].id}'),
              itemExtent: _GameCard.compactHeight + 6,
              delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildGameCard(
                      sections[i].games[index],
                      sections[i],
                      preview,
                      _firstRowZone + i), findChildIndexCallback: (key) {
                return sections[i].cardIndices[key];
              }, childCount: sections[i].games.length),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      );
    }
    return CustomScrollView(
      key: const PageStorageKey('sports-events'),
      controller: _verticalScroll,
      scrollCacheExtent:
          _tvNavigation ? const ScrollCacheExtent.pixels(48) : null,
      physics: _eventScrollPhysics,
      slivers: [
        _buildRefreshControl(),
        SliverPadding(
          padding: EdgeInsets.only(bottom: _groupedBySport ? 16 : 32),
          // Fixed row geometry lets remote navigation reveal an unbuilt row.
          // Only visible rows (and the focused row) need widgets and layout.
          sliver: _groupedBySport && !_touch
              ? SliverFixedExtentList(
                  itemExtent: _horizontalSectionExtent,
                  delegate: SliverChildBuilderDelegate(
                    (_, index) => _RetainedSportsRow(
                      key: ValueKey('sports-section-${sections[index].id}'),
                      child: _buildSection(sections[index], preview),
                    ),
                    childCount: sections.length,
                    findChildIndexCallback: (key) {
                      final index = sections.indexWhere(
                          (s) => ValueKey('sports-section-${s.id}') == key);
                      return index < 0 ? null : index;
                    },
                  ),
                )
              : SliverList.builder(
                  itemCount: sections.length,
                  findChildIndexCallback: (key) {
                    final index =
                        sections.indexWhere((s) => _rowKeys[s.id] == key);
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (_, index) =>
                      _buildSection(sections[index], preview),
                ),
        ),
      ],
    );
  }

  /// Reveal an unbuilt neighbouring card before moving focus along a lazy event row,
  /// preventing traversal into a different sport.
  KeyEventResult _onRowKey(_Section s, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _navigationRevision++;
    final pending = _pendingRowFocus;
    if (pending != null) {
      s = _sections.where((row) => row.id == pending.section).firstOrNull ?? s;
      if (pending.heading) return _onHeadingKey(s, event);
    }
    if (_tvNavigation &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      if (!_groupedBySport &&
          event.logicalKey == LogicalKeyboardKey.arrowUp &&
          _liveAllStep(-1, _sections)) {
        return KeyEventResult.handled;
      }
      _moveEventRow(
          s, event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    final delta = event.logicalKey == LogicalKeyboardKey.arrowRight
        ? 1
        : event.logicalKey == LogicalKeyboardKey.arrowLeft
            ? -1
            : 0;
    if (delta == 0) return KeyEventResult.ignored;
    final i = s.games.indexWhere((g) => pending == null
        ? (_cardNodes[_gameKey(g)]?.hasFocus ?? false)
        : _gameKey(g) == pending.key);
    if (i < 0) return KeyEventResult.ignored;
    final target = i + delta;
    if (_tvNavigation && target < 0) {
      _pendingRowFocus = null;
      if (_groupedBySport) {
        _focusRowHeading(s);
      } else {
        _chipNode('refresh').requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (_tvNavigation && target < s.games.length) {
      _focusRowCard(s, target);
      return KeyEventResult.handled;
    }
    // Row ends: stay put rather than leave the row.
    if (target < 0 || target >= s.games.length) return KeyEventResult.handled;
    final node = _cardNode(_gameKey(s.games[target]));
    void focus() {
      final ctx = node.context;
      if (ctx == null) return;
      node.requestFocus();
      // Jump directly to the focused card.
      Scrollable.ensureVisible(ctx,
          alignmentPolicy: delta > 0
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    }

    if (sportsFocusAttached(node)) {
      focus();
    } else {
      final c = _rowScrolls[s.id];
      if (c != null && c.hasClients) {
        final p = c.position;
        c.jumpTo((p.pixels + delta * (_rowCardWidth + 12))
            .clamp(p.minScrollExtent, p.maxScrollExtent));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focus();
      });
    }
    return KeyEventResult.handled;
  }

  ChannelMatch? _displayedMatch(SportsGame game, SportsGame? preview,
          [List<ChannelMatch>? matches]) =>
      displayedSportsChannel(
          matches ?? _matches[_gameKey(game)] ?? const [], _channelFilter,
          playing: preview != null && _gameKey(preview) == _gameKey(game)
              ? _previewChannel
              : null,
          savedId: _picks.channelIdFor(game));

  Widget _buildGameCard(
          SportsGame g, _Section s, SportsGame? preview, int zoneIndex) =>
      _GameCard(
        fillWidth: _verticalGames,
        compact: _compactCards,
        key: ValueKey('card-${_gameKey(g)}'),
        focusNode: _cardNode(_gameKey(g)),
        game: g,
        match: _displayedMatch(g, preview),
        matching: _pending(g),
        matchStage: _channelStage,
        matchError: _channelError,
        hasCheckedCandidates: _matches.containsKey(_gameKey(g)),
        hideScores: _hideScores,
        starred: _follows.involves(g),
        previewing: preview != null && _gameKey(preview) == _gameKey(g),
        onFocus: () {
          _lockBrowse();
          _zone = zoneIndex;
          _lastCardInRow[s.id] = _gameKey(g);
          _focusedSectionId = s.id;
          _focusedCardKey = _gameKey(g);
          if (!_verticalGames) _ensureRowVisible(s.id);
          if (_heroGame != g) {
            _heroGame = g;
            _queueListings(g);
          }
        },
        onTap: () => _activateGame(g),
        onHold: () => _openGame(g),
      );

  Widget _buildSection(_Section s, SportsGame? preview,
      {bool headingOnly = false}) {
    final rowKey = _rowKeys[s.id] ??= GlobalKey();
    final zoneIndex = _firstRowZone + _sections.indexWhere((x) => x.id == s.id);
    return Padding(
      key: rowKey,
      padding: EdgeInsets.only(bottom: headingOnly ? 0 : _sportSectionGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height:
                headingOnly ? _verticalHeadingHeight - 2 : _sportHeadingHeight,
            child: _groupedBySport
                ? Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (_, event) => _onHeadingKey(s, event),
                    child: InkWell(
                      key: ValueKey('sport-heading:${s.id.substring(6)}'),
                      focusNode: _chipNode(s.id),
                      onFocusChange: (focused) {
                        if (focused) {
                          _lockBrowse();
                          _zone = zoneIndex;
                          _focusedSectionId = s.id;
                          _ensureRowVisible(s.id);
                        }
                      },
                      onTap: () => _selectSport(s.id.substring(6)),
                      child: ListenableBuilder(
                        listenable: _chipNode(s.id),
                        builder: (context, child) {
                          final focused = _chipNode(s.id).hasFocus;
                          final accent = Theme.of(context).colorScheme.primary;
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              color: focused
                                  ? accent.withValues(alpha: 0.18)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: focused ? accent : Colors.transparent,
                              ),
                            ),
                            child: child,
                          );
                        },
                        child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(children: [
                              Icon(sportIcon(s.id.substring(6)),
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 7),
                              Expanded(
                                  child: Text(s.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: _compactCards ? 13.5 : 16,
                                          fontWeight: FontWeight.w600))),
                            ])),
                      ),
                    ))
                : Row(
                    children: [
                      Expanded(
                          child: Text(s.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: _compactCards ? 13.5 : 17,
                                  fontWeight: FontWeight.w700,
                                  color:
                                      interfaceColor(context, Colors.white)))),
                      const SizedBox(width: 8),
                      Text('${s.games.length}',
                          style: TextStyle(
                              fontSize: 15,
                              color: interfaceColor(context, Colors.white54))),
                      if (s.id == 'live' && _showLiveAll) ...[
                        const SizedBox(width: 14),
                        SportsChip(
                          focusNode: _chipNode(_liveAllId),
                          label: tr('See all · stats'),
                          icon: Icons.view_list,
                          compact: true,
                          selected: false,
                          onFocus: () {
                            _zone = zoneIndex;
                            precacheLeagueBackdrop(
                                context, s.games.first.league);
                          },
                          onTap: _openLiveList,
                        ),
                      ],
                    ],
                  ),
          ),
          SizedBox(height: headingOnly ? 2 : _sportHeadingGap),
          if (headingOnly)
            const SizedBox.shrink()
          else if (_verticalGames)
            Column(children: [
              for (final g in s.games) _buildGameCard(g, s, preview, zoneIndex),
            ])
          else
            SizedBox(
              height: _rowCardHeight + 6,
              child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (_, event) => _onRowKey(s, event),
                  child: ListView.builder(
                      key: PageStorageKey('sports-row-${s.id}'),
                      controller: _rowScrolls[s.id] ??=
                          SportsScrollController(),
                      scrollDirection: Axis.horizontal,
                      scrollCacheExtent: _tvNavigation
                          ? const ScrollCacheExtent.pixels(48)
                          : null,
                      clipBehavior: Clip.none,
                      itemExtent: _rowCardWidth + 12,
                      itemCount: s.games.length,
                      findChildIndexCallback: (key) {
                        return s.cardIndices[key];
                      },
                      itemBuilder: (context, index) {
                        final g = s.games[index];
                        return _GameCard(
                            fillWidth: _verticalGames,
                            compact: _compactCards,
                            key: ValueKey('card-${_gameKey(g)}'),
                            focusNode: _cardNode(_gameKey(g)),
                            game: g,
                            match: _displayedMatch(g, preview),
                            matching: _pending(g),
                            matchStage: _channelStage,
                            matchError: _channelError,
                            hasCheckedCandidates:
                                _matches.containsKey(_gameKey(g)),
                            hideScores: _hideScores,
                            starred: _follows.involves(g),
                            previewing: preview != null &&
                                _gameKey(preview) == _gameKey(g),
                            onFocus: () {
                              _lockBrowse();
                              _zone = zoneIndex;
                              _lastCardInRow[s.id] = _gameKey(g);
                              _focusedSectionId = s.id;
                              _focusedCardKey = _gameKey(g);
                              _ensureRowVisible(s.id);
                              if (_heroGame != g) {
                                _heroGame = g;
                                _queueListings(g);
                              }
                            },
                            onTap: () => _activateGame(g),
                            onHold: () => _openGame(g));
                      })),
            ),
        ],
      ),
    );
  }
}

/// Keep the actively browsed row mounted if a refresh moves it outside the
/// viewport. Offscreen, unfocused sports remain lazy even while matching.
class _RetainedSportsRow extends StatefulWidget {
  const _RetainedSportsRow({super.key, required this.child});
  final Widget child;
  @override
  State<_RetainedSportsRow> createState() => _RetainedSportsRowState();
}

class _RetainedSportsRowState extends State<_RetainedSportsRow>
    with AutomaticKeepAliveClientMixin {
  bool _focused = false;
  @override
  bool get wantKeepAlive => _focused;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (_focused == focused) return;
        _focused = focused;
        updateKeepAlive();
      },
      child: widget.child,
    );
  }
}

// =================================================================== widgets

String _timeLabel(DateTime utc) => TimeFormat.hm.format(utc.toLocal());

/// What a not-yet-started card shows: the start time — except golf, which
/// ESPN dates at midnight with no tee time; it reads "Oct 15 – 18" (US
/// Eastern dates, see SportsService._tournamentDay).
String _preLabel(SportsGame g) {
  if (isFormulaOne(g)) {
    return '${isF1BuildUp(g, DateTime.now()) ? "Build-up · " : ""}${_timeLabel(g.start)}';
  }
  final end = g.end;
  if (end == null) return _timeLabel(g.start);
  DateTime eastern(DateTime utc) => utc.subtract(const Duration(hours: 4));
  final a = eastern(g.start);
  final b = eastern(end);
  final first = DateFormat.MMMd().format(a);
  if (a.year == b.year && a.month == b.month && a.day == b.day) return first;
  return '$first – ${a.month == b.month ? DateFormat.d().format(b) : DateFormat.MMMd().format(b)}';
}

/// Golf / racing card body: the event's name, then the top two — or,
/// before it starts (or with scores hidden), the session and venue.
class _EventCardBody extends StatelessWidget {
  const _EventCardBody(
      {required this.game, required this.hideScores, this.compact = false});
  final SportsGame game;
  final bool hideScores;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ev = game.event;
    final guide = game.isGuideEvent;
    final dense = sportsLandscape(context);
    final leaders =
        hideScores ? const <SportsEventEntry>[] : (ev?.leaders ?? const []);
    var details = [
      if (ev?.session != null) trSports(ev!.session!),
      if (ev?.venue != null) ev!.venue!,
    ].join(' · ');
    // Golf lists no course; the network is the next useful thing.
    if (guide) {
      details = '${_timeLabel(game.start)} – ${_timeLabel(game.end!)}';
    }
    if (details.isEmpty) details = game.broadcasts.take(2).join(' · ');
    if (game.guideProgrammes.length > 1) {
      details = '$details · ${game.guideProgrammes.length} broadcasts';
    }
    final title = Text(guide ? sportsGuideCardTitle(game.title) : game.title,
        semanticsLabel: guide ? game.title : null,
        key: guide ? ValueKey('guide-coverage-title-${game.id}') : null,
        maxLines: guide ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: guide
                ? (dense
                    ? 12
                    : compact
                        ? 13
                        : 14)
                : (dense ? 13.5 : 15),
            height: guide ? 1.15 : null,
            fontWeight: guide ? FontWeight.w600 : FontWeight.w700,
            color: interfaceColor(context, Colors.white)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (guide)
          Tooltip(
              message: game.title,
              // Hover may reveal the full title; holding the card still opens
              // its channel menu through the parent gesture handler.
              triggerMode: TooltipTriggerMode.manual,
              child: title)
        else
          title,
        SizedBox(height: guide ? 2 : 3),
        if (leaders.isEmpty)
          Text(details,
              maxLines: guide ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: guide ? (dense ? 10 : 11) : (dense ? 11 : 12),
                  height: guide ? 1.1 : null,
                  color: interfaceColor(context, Colors.white60)))
        else
          for (final e in leaders.take(2))
            _EventLeaderLine(
                entry: e,
                fontSize: sportsLandscape(context) ? 11.5 : 12.5,
                flagSize: 13),
      ],
    );
  }
}

class _EventLeaderLine extends StatelessWidget {
  const _EventLeaderLine(
      {required this.entry, required this.fontSize, required this.flagSize});
  final SportsEventEntry entry;
  final double fontSize;
  final double flagSize;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        fontSize: fontSize, color: interfaceColor(context, Colors.white));
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Row(
        children: [
          SizedBox(
            width: fontSize * 2.2,
            child: Text(entry.position,
                style: style.copyWith(
                    color: interfaceColor(context, Colors.white54))),
          ),
          if (entry.flagUrl != null) ...[
            CachedNetworkImage(
              imageUrl: sportsLogoUrl(entry.flagUrl, size: 64) ?? '',
              width: flagSize * 1.4,
              height: flagSize,
              fit: BoxFit.cover,
              memCacheWidth: 64,
              errorWidget: (_, __, ___) => SizedBox(width: flagSize * 1.4),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(fontWeight: FontWeight.w600)),
          ),
          if (entry.value != null)
            Text(entry.value!,
                style: style.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

/// A persistent channel preview. Focus shows a game's details; tapping or
/// pressing OK starts its channel. The player stays mounted as focus moves.
class _Hero extends StatelessWidget {
  const _Hero(
      {super.key,
      this.replays = false,
      this.standings = false,
      this.highlights = false,
      required this.game,
      required this.matches,
      required this.matching,
      required this.hideScores,
      required this.playing,
      this.touch = false,
      this.narrow = false,
      this.sidebar = false,
      this.compact = false,
      this.onVideoTap,
      this.activity});
  final bool replays, standings;
  final bool highlights;
  final SportsGame? game;
  final List<ChannelMatch>? matches;
  final bool matching, hideScores, playing, touch, narrow, sidebar, compact;
  final VoidCallback? onVideoTap;
  final Widget? activity;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final g = game;
        final playingChannel =
            playing ? (context.read<PlaybackService>().currentChannel) : null;
        final channel = playingChannel ?? matches?.firstOrNull?.channel;
        final score = g != null &&
                !hideScores &&
                g.state != GameState.pre &&
                !g.league.isField
            ? '${g.first.score ?? '-'} – ${g.second.score ?? '-'}'
            : null;
        final status = g == null
            ? ''
            : g.state == GameState.pre
                ? _preLabel(g)
                : trSports(g.statusText);
        final videoWidth = sidebar
            ? constraints.maxWidth
            : narrow
                ? MediaQuery.sizeOf(context).width - 24
                : 168.0 * 16 / 9;
        final videoHeight = compact ? 64.0 : videoWidth * 9 / 16;
        final video = PreviewPlayerControls(
          active: playing,
          onFullscreen: onVideoTap,
          child: Container(
            key: const ValueKey('sports-channel-box'),
            width: videoWidth,
            height: videoHeight,
            decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(
                    color: interfaceColor(context, const Color(0xFF303945)))),
            child: Padding(
              padding: const EdgeInsets.all(1),
              // Keep the video at a stable position and keyed by channel.
              // Score/focus refreshes must not recreate its platform view.
              child: playingChannel != null
                  ? VideoPlayerPane(
                      key: ValueKey(playingChannel.id),
                      showEpgBar: false,
                      showControls: false)
                  : Center(
                      child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(
                            channel == null
                                ? Icons.live_tv
                                : Icons.play_circle_outline,
                            color: Colors.white54,
                            size: narrow ? 24 : 32),
                        const SizedBox(height: 5),
                        Text(
                            channel?.name ??
                                (g == null
                                    ? tr('Channel preview')
                                    : matching
                                        ? tr('Finding channel…')
                                        : tr('Choose a channel')),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        if (channel != null && !narrow)
                          Text(tr('Ready to play'),
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                      ]),
                    )),
            ),
          ),
        );
        final guide = playingChannel == null
            ? null
            : context
                .watch<EpgService>()
                .getCurrentProgram(playingChannel.epgId);
        final title = g?.title ??
            guide?.title ??
            playingChannel?.name ??
            (replays
                ? (highlights ? 'Choose a highlight show' : 'Choose a replay')
                : standings
                    ? tr('Channel preview')
                    : tr('Choose a game'));
        final subtitle = g == null
            ? (playingChannel?.name ??
                (replays
                    ? 'Select a programme to preview'
                    : standings
                        ? 'Select a channel in Events or Schedule'
                        : 'Select an event to preview'))
            : [g.league.shortName, status]
                .where((s) => s.isNotEmpty)
                .join(' · ');
        final tournament = g?.event?.title;
        final summary = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!narrow) ...[
              Text(
                  tournament ??
                      g?.league.name ??
                      (playing ? 'NOW PLAYING' : 'CHANNEL PREVIEW'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: interfaceColor(context, Colors.white54),
                      fontWeight: FontWeight.w500,
                      letterSpacing: .3)),
              const SizedBox(height: 6),
            ],
            Text(title,
                key: const ValueKey('sports-preview-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: narrow
                        ? 12.5
                        : sidebar
                            ? (touch ? 14 : 16)
                            : 21,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                    color: interfaceColor(context, const Color(0xFFEAF0F6)))),
            const SizedBox(height: 4),
            Row(children: [
              if (score != null) ...[
                Text(score,
                    style: TextStyle(
                        fontSize: narrow ? 12 : 16,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                        color:
                            interfaceColor(context, const Color(0xFFEAF0F6)))),
                const SizedBox(width: 7),
              ],
              Expanded(
                  child: Text(subtitle,
                      maxLines: narrow ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: narrow ? 10.5 : 12,
                          height: 1.2,
                          color: interfaceColor(context, Colors.white60)))),
            ]),
            if (!narrow && g != null && playingChannel != null) ...[
              const SizedBox(height: 7),
              Text(playingChannel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: interfaceColor(context, Colors.white54))),
            ],
          ],
        );
        if (sidebar) {
          return Column(
              key: const ValueKey('sports-preview'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                    child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        video,
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: summary),
                      ]),
                )),
                if (activity != null)
                  Padding(
                      key: const ValueKey('sports-preview-footer'),
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: activity),
              ]);
        }
        if (narrow) {
          // Reserve the summary row so progress updates cannot move the video
          // or event list. Details remain available without another status strip.
          final summaryHeight = compact
              ? 0.0
              : (MediaQuery.textScalerOf(context).scale(12.5) * 4.2)
                  .clamp(54.0, double.infinity);
          return SizedBox(
            key: const ValueKey('sports-preview'),
            height: videoHeight + summaryHeight,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  video,
                  if (!compact)
                    SizedBox(
                        height: summaryHeight,
                        child: Row(children: [
                          Expanded(child: summary),
                          if (activity != null)
                            Container(
                                width: !standings && !replays
                                    ? (constraints.maxWidth * .48)
                                        .clamp(140.0, 180.0)
                                    : (MediaQuery.sizeOf(context).width < 370
                                        ? 118
                                        : 130),
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.only(left: 8),
                                decoration: BoxDecoration(
                                    border: Border(
                                        left: BorderSide(
                                            color: interfaceColor(context,
                                                const Color(0xFF232B34))))),
                                child: activity),
                        ])),
                ]),
          );
        }
        return SizedBox(
          key: const ValueKey('sports-preview'),
          height: 168,
          child: Row(children: [
            video,
            Expanded(
                child: Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (activity != null)
                      Align(
                          alignment: Alignment.topRight,
                          child: SizedBox(width: 200, child: activity)),
                    Expanded(
                        child: Align(
                            alignment: Alignment.centerLeft, child: summary)),
                  ]),
            )),
          ]),
        );
      });
}

class _GameCard extends StatefulWidget {
  const _GameCard({
    super.key,
    required this.focusNode,
    required this.game,
    required this.match,
    required this.matching,
    required this.matchStage,
    this.matchError,
    this.hasCheckedCandidates = false,
    required this.hideScores,
    required this.starred,
    required this.previewing,
    required this.onFocus,
    required this.onTap,
    required this.onHold,
    this.fillWidth = false,
    this.compact = false,
  });

  final bool fillWidth;
  final bool compact;
  static const double landscapeWidth = 216;
  static const double landscapeHeight = 102;
  static const double compactHeight = 110;
  static const double compactWidth = 236;
  static const double width = 256;
  static const double height = 124;

  final FocusNode focusNode;
  final SportsGame game;
  final ChannelMatch? match;
  final bool matching;
  final ValueListenable<SportsWorkStage?> matchStage;
  final String? matchError;
  final bool hasCheckedCandidates;
  final bool hideScores;

  /// One of My Teams plays.
  final bool starred;

  /// Its channel is playing in the hero.
  final bool previewing;
  final VoidCallback onFocus;
  final VoidCallback onTap;
  final VoidCallback onHold;

  @override
  State<_GameCard> createState() => _GameCardState();
}

class _GameCardState extends State<_GameCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final dense = sportsLandscape(context);
    final scheme = Theme.of(context).colorScheme;
    final frameWidth = _focused ? 2.5 : (widget.previewing ? 1.5 : 1.0);
    final frameInset = frameWidth - 1;
    final channelColor = widget.match == null
        ? interfaceColor(context, Colors.white54)
        : widget.match!.isConfident
            ? scheme.primary
            : interfaceColor(context, const Color(0xFFE7B76A));
    final g = widget.game;
    final live = g.isLive;
    final showScore = g.state != GameState.pre && !widget.hideScores;
    final status = switch (g.state) {
      GameState.pre => _preLabel(g),
      GameState.live =>
        g.statusText.isEmpty ? tr('LIVE') : trSports(g.statusText),
      GameState.post =>
        g.statusText.isEmpty ? tr('Final') : trSports(g.statusText),
    };

    Widget teamLine(SportsTeam t, {required bool leading}) {
      final firstScore = int.tryParse(g.first.score ?? '');
      final secondScore = int.tryParse(g.second.score ?? '');
      final mine = int.tryParse(t.score ?? '');
      final other = identical(t, g.first) ? secondScore : firstScore;
      final winning = g.state == GameState.post &&
          (t.score == 'W' || (mine != null && other != null && mine > other));
      return Row(
        children: [
          SizedBox(
            width: 16,
            child: leading
                ? const SizedBox()
                : Text(g.joiner,
                    style: TextStyle(
                        fontSize: 10,
                        color: interfaceColor(context, Colors.white54))),
          ),
          SportsLogo(
              animate: !context.read<AppPreferences>().isTelevision,
              url: t.logoUrl,
              size: dense
                  ? (g.league.kind == SportsKind.tennis ? 16 : 18)
                  : widget.compact
                      ? (g.league.kind == SportsKind.tennis ? 18 : 20)
                      : 26,
              fallback: t.abbreviation,
              color: t.color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(t.shortName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: dense
                        ? 12.5
                        : widget.compact
                            ? 13
                            : 15,
                    fontWeight: FontWeight.w600,
                    color: g.state == GameState.post && !winning
                        ? interfaceColor(context, Colors.white70)
                        : interfaceColor(context, Colors.white))),
          ),
          if (showScore)
            Text(t.score ?? '',
                style: TextStyle(
                    fontSize: dense
                        ? 14
                        : widget.compact
                            ? (g.league.kind == SportsKind.tennis ? 15 : 16)
                            : 18,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    color: winning || live
                        ? interfaceColor(context, Colors.white)
                        : interfaceColor(context, Colors.white70)))
          else if (t.record != null)
            Text(t.record!,
                style: TextStyle(
                    fontSize: 11,
                    color: interfaceColor(context, Colors.white54))),
        ],
      );
    }

    return Padding(
      padding:
          EdgeInsets.only(right: widget.fillWidth ? 0 : 12, top: 2, bottom: 4),
      // Remote OK: short = watch, hold = channel menu (key path). Mouse/touch
      // long-press opens the menu too; a plain click keeps InkWell's onTap.
      child: HoldToActivate(
        onTap: widget.onTap,
        onHold: widget.onHold,
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(3),
          onTap: () {
            widget.focusNode.requestFocus();
            widget.onTap();
          },
          onFocusChange: (f) {
            setState(() => _focused = f);
            if (f) widget.onFocus();
          },
          child: Container(
            width: widget.fillWidth
                ? double.infinity
                : dense
                    ? _GameCard.landscapeWidth
                    : widget.compact
                        ? _GameCard.compactWidth
                        : _GameCard.width,
            height: dense
                ? _GameCard.landscapeHeight
                : widget.compact
                    ? _GameCard.compactHeight
                    : _GameCard.height,
            // A thicker focus outline must not squeeze/reflow the text.
            padding: EdgeInsets.symmetric(
                horizontal: (dense
                        ? 7
                        : widget.compact
                            ? 8
                            : 10) -
                    frameInset,
                vertical: (dense
                        ? (g.league.kind == SportsKind.tennis ? 2 : 4)
                        : widget.compact
                            ? (g.league.kind == SportsKind.tennis ? 2 : 5)
                            : 6) -
                    frameInset),
            decoration: BoxDecoration(
              // Watching: a light gold tint + thin frame (the
              // "WATCHING" pill is the main cue; a thick frame read
              // like the focused card).
              color: _focused
                  ? null
                  : widget.previewing
                      ? scheme.primary.withValues(alpha: 0.14)
                      : interfaceColor(context, Colors.white)
                          .withValues(alpha: 0.07),
              gradient: _focused ? sportsFocusSheen(scheme) : null,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                  color: _focused
                      ? scheme.primary
                      : widget.previewing
                          ? scheme.primary.withValues(alpha: 0.6)
                          : interfaceColor(context, Colors.white10),
                  width: frameWidth),
              boxShadow: const [],
            ),
            child: DefaultTextStyle.merge(
              style: const TextStyle(height: 1.2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (widget.starred)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child:
                              Icon(Icons.star, size: 13, color: scheme.primary),
                        ),
                      Expanded(
                          flex: 2,
                          child: Text(
                              g.league.kind == SportsKind.tennis
                                  ? '${g.league.shortName} · ${g.event?.session ?? 'Singles'}'
                                  : isFormulaOne(g)
                                      ? 'F1 · ${g.event?.session ?? 'Session'}'
                                      : '${g.league.shortName} · ${leagueDescription(g.league)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: interfaceColor(
                                      context, Colors.white60)))),
                      const SizedBox(width: 5),
                      if (widget.previewing)
                        Icon(Icons.equalizer, size: 13, color: scheme.primary),
                      // Takes the rest of the row (status right-aligned)
                      // and shrinks a long status next to the pill.
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (live && (g.isScheduleOnly || g.isOnAirOnly))
                              Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Icon(Icons.schedule,
                                      size: 12,
                                      color: interfaceColor(
                                          context, const Color(0xFFE2C18C)))),
                            if (live && !g.isScheduleOnly && !g.isOnAirOnly)
                              Container(
                                width: 7,
                                height: 7,
                                margin: const EdgeInsets.only(right: 5),
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: interfaceColor(
                                        context, Colors.redAccent)),
                              ),
                            Flexible(
                              child: Text(status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: live
                                          ? (g.isScheduleOnly || g.isOnAirOnly)
                                              ? interfaceColor(context,
                                                  const Color(0xFFE2C18C))
                                              : interfaceColor(
                                                  context, Colors.redAccent)
                                          : interfaceColor(
                                              context, Colors.white))),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (g.league.kind == SportsKind.tennis && g.event != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Tooltip(
                        message: [
                          g.event!.title,
                          g.event?.session,
                          g.event?.court
                        ]
                            .whereType<String>()
                            .where((s) => s.isNotEmpty)
                            .join(' · '),
                        child: Text(g.event!.title,
                            key: ValueKey('tennis-tournament-${g.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: interfaceColor(context, Colors.white))),
                      ),
                    ),
                  SizedBox(
                      height:
                          dense || g.league.kind == SportsKind.tennis ? 1 : 3),
                  if (g.league.isField)
                    _EventCardBody(
                        game: g,
                        hideScores: widget.hideScores,
                        compact: widget.compact)
                  else ...[
                    teamLine(g.first, leading: true),
                    SizedBox(
                        height: dense || g.league.kind == SportsKind.tennis
                            ? 1
                            : 2),
                    teamLine(g.second, leading: false),
                  ],
                  const Spacer(),
                  Divider(
                      height: 5,
                      thickness: .5,
                      color: scheme.onSurface.withValues(alpha: .09)),
                  Row(
                    children: [
                      Icon(
                          widget.match != null
                              ? (widget.match!.isConfident
                                  ? Icons.live_tv
                                  : Icons.help_outline)
                              : widget.matching
                                  ? Icons.search
                                  : Icons.add_circle_outline,
                          size: 13,
                          color: channelColor),
                      const SizedBox(width: 5),
                      Expanded(
                        child: widget.match == null && widget.matching
                            ? SportsEventMatchStatus(
                                stage: widget.matchStage,
                                error: widget.matchError,
                                hasCandidates: widget.hasCheckedCandidates,
                                color: channelColor)
                            : Text(
                                widget.match == null
                                    ? 'No channel found · Choose'
                                    : '${widget.match!.isConfident ? '' : 'Possible · '}${widget.match!.channel.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w500,
                                    color: widget.match?.isConfident == true
                                        ? scheme.onSurface.withValues(alpha: .8)
                                        : channelColor)),
                      ),
                    ],
                  ),
                  if (widget.match != null)
                    Padding(
                        padding: const EdgeInsets.only(left: 18, top: 1),
                        child: ChannelNowLabel(
                            channel: widget.match!.channel,
                            redundantTitle: g.isGuideEvent ? g.title : null,
                            fontSize: dense
                                ? 9.5
                                : widget.compact
                                    ? 10
                                    : 10.5)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =================================================================== dialogs

enum _PickScope { game, first, second }

class _PickScopeDialog extends StatelessWidget {
  const _PickScopeDialog({required this.game, required this.channel});
  final SportsGame game;
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    Widget choice(
            {bool autofocus = false,
            IconData? icon,
            Widget? leading,
            required String title,
            String? subtitle,
            required VoidCallback onTap}) =>
        ListTile(
            autofocus: autofocus,
            dense: true,
            minTileHeight: 48,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: leading ?? Icon(icon, size: 18),
            onTap: onTap,
            title: Text(title,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            subtitle: subtitle == null
                ? null
                : Text(subtitle, style: const TextStyle(fontSize: 10.5)));
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      scrollable: true,
      title: Text(tr('Remember this channel?'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(channel.name,
                style: TextStyle(
                    color: interfaceColor(context, Colors.white70),
                    fontSize: 12)),
            const SizedBox(height: 6),
            choice(
              autofocus: true,
              icon: Icons.event,
              title: tr('Just this game'),
              subtitle: tr('Best for channels named after one game'),
              onTap: () => Navigator.of(context).pop(_PickScope.game),
            ),
            // Event sports: one "always" choice for the whole series (Sky
            // Sports F1, Golf Channel) — remembering a channel per golfer or
            // fighter would never come up again.
            if (game.league.kind != SportsKind.team)
              choice(
                leading: SportsLogo(
                    url: game.league.logoUrl,
                    size: 24,
                    fallback: game.league.shortName),
                title: tr('Always for {name}', {'name': game.league.name}),
                subtitle:
                    tr('Best for a channel that carries the whole series'),
                onTap: () => Navigator.of(context).pop(_PickScope.first),
              )
            else
              for (final (scope, team) in [
                (_PickScope.first, game.first),
                (_PickScope.second, game.second),
              ])
                choice(
                  leading: SportsLogo(
                      url: team.logoUrl,
                      size: 24,
                      fallback: team.abbreviation,
                      color: team.color),
                  title: tr('Always for the {shortName}',
                      {'shortName': team.shortName}),
                  subtitle:
                      tr('Best for a regular channel, like a regional network'),
                  onTap: () => Navigator.of(context).pop(scope),
                ),
          ],
        ),
      ),
    );
  }
}
