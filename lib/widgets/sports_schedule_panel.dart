import '../models/sports_favourites_filter.dart';
import '../utils/time_format.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/sports.dart';
import '../services/app_preferences.dart';
import '../services/sports_service.dart';
import '../services/sports_follows.dart';
import '../services/sports_channel_matcher.dart' show ChannelMatch;
import '../utils/sports_calendar.dart';
import '../utils/sports_fixture_presentation.dart';
import 'compact_choice_list.dart';
import 'sports_filter_picker.dart';
import 'sports_header_controls.dart';
import 'sports_toolbar_navigation.dart';
import 'sports_details_panel.dart';
import 'sports_fixture_row.dart';
import 'sports_schedule_days.dart';
import 'sports_schedule_calendar.dart';
import 'sports_schedule_display.dart';
import 'tv_text_field_gate.dart';

typedef _ScheduleIndexRow = ({SportsGame game, DateTime day, String text});

/// Retains recent fixtures and bounded calendar counts without hidden polling.
class SportsScheduleBrowseState {
  String? sport, leagueId;
  bool initialized = false;
  bool groupBySport = false;
  SportsFavouritesFilter favouritesFilter = SportsFavouritesFilter.all;
  bool get onlyFavourites => favouritesFilter.isFiltered;
  bool showCompleted = false;
  int calendarDays = 0;
  final summaries = <DateTime, SportsScheduleSummary>{};
  String? summaryScope;
  final _days =
      <String, ({List<SportsGame> games, bool incomplete, DateTime at})>{};
  DateTime? from;
  int days = 7;
  DateTime? selectedDay;
  String query = '';
  double offset = 0;
  ({String league, DateTime from, int days})? _window;
  DateTime? _loadedAt;
  List<SportsGame> _games = const [];
  bool _incomplete = false;
  List<SportsGame>? _indexedGames;
  (String, Duration)? _indexZone;
  List<_ScheduleIndexRow> _index = const [];
  Object? _orderKey;
  List<_ScheduleIndexRow> _orderedIndex = const [];
  Object? _projectionKey;
  List<SportsGame> _visible = const [];
  Map<DateTime, int> _counts = const {};
}

class SportsSchedulePanel extends StatefulWidget {
  const SportsSchedulePanel(
      {super.key,
      required this.browseState,
      required this.entryFocus,
      required this.onFocusToolbar,
      required this.layoutBuilder,
      this.service,
      this.follows,
      this.initialLeague,
      this.overviewLeagues,
      this.favouriteLeagueIds,
      this.favouritesFilter,
      this.onGameDetails,
      this.channelMatchForGame,
      this.onWatchGame,
      this.onLeagueChanged,
      this.onScopeChanged,
      this.onManageLeagues,
      this.onFavouritesChanged,
      this.hideScores = false,
      this.keyboardOpen,
      this.clock});
  final SportsScheduleBrowseState browseState;
  final FocusNode entryFocus;
  final VoidCallback onFocusToolbar;
  final SportsService? service;
  final SportsFollows? follows;
  final SportsLeague? initialLeague;

  /// Enabled competitions only; null retains the single-league detail browser.
  final List<SportsLeague>? overviewLeagues;
  final Set<String>? favouriteLeagueIds;
  final SportsFavouritesFilter? favouritesFilter;
  final ValueChanged<SportsGame>? onGameDetails;

  /// Read already-computed Events results. This must never initiate matching.
  /// Consulted only for mounted rows and again when activating a fixture.
  final ChannelMatch? Function(SportsGame)? channelMatchForGame;
  final void Function(SportsGame, ChannelMatch)? onWatchGame;
  final ValueChanged<SportsLeague>? onLeagueChanged;
  final void Function(String? sport, String? league)? onScopeChanged;
  final Future<void> Function()? onManageLeagues;
  final ValueChanged<SportsFavouritesFilter>? onFavouritesChanged;
  final bool hideScores;
  final bool? keyboardOpen;
  final DateTime Function()? clock;
  final Widget Function(Widget filters, Widget actions, Widget content)
      layoutBuilder;
  @override
  State<SportsSchedulePanel> createState() => _SportsSchedulePanelState();
}

String _scheduleTime(SportsGame game, DateFormat clock) =>
    sportsFixtureHasUnknownTime(game)
        ? 'TBD'
        : clock.format(game.start.toLocal());

class _SportsSchedulePanelState extends State<SportsSchedulePanel> {
  late final _service = widget.service ?? SportsService.instance;
  late final _browse = widget.browseState;
  late final _leagues = [...kSportsLeagues, ...kSportsLeagueBank]
      .where((l) => supportsSportsSchedule(l) && l.id != 'rugby.live')
      .toList();
  late final _leaguesById = {for (final league in _leagues) league.id: league};
  Object? _toolbarMetrics;
  final _toolbarLabelWidths = <String, double>{};
  bool? _clockUses24h;
  late DateFormat _cachedClock;
  DateFormat get _clockFormat {
    if (_clockUses24h != TimeFormat.use24h) {
      _clockUses24h = TimeFormat.use24h;
      _cachedClock = TimeFormat.hm;
    }
    return _cachedClock;
  }

  final _dayFormat = DateFormat('EEEE d MMMM');
  List<SportsGame> _games = const [];
  bool _loading = false, _incomplete = false;
  int _request = 0;
  late final _search = TextEditingController(text: _browse.query);
  final _searchFocus = FocusNode();
  final _leagueFocus = FocusNode(debugLabel: 'schedule-league');
  final _daysEntryFocus = FocusNode(debugLabel: 'schedule-days');
  FocusNode? _lastControlFocus;
  void _focusControls() {
    final node = _lastControlFocus;
    (node != null && sportsFocusAttached(node) ? node : widget.entryFocus)
        .requestFocus();
  }

  void _focusResults() {
    if (_calendar && _calendarKey.currentState != null) {
      _calendarKey.currentState!.focusEntry();
      return;
    }
    final node = _resultsFocus.traversalDescendants
        .where(sportsFocusAttached)
        .firstOrNull;
    if (node != null) {
      node.requestFocus();
      Scrollable.ensureVisible(node.context!);
    }
  }

  void _focusBelowControls(FocusNode node) {
    _lastControlFocus = node;
    if (_searching) {
      _searchFocus.requestFocus();
    } else if (sportsFocusAttached(_daysEntryFocus)) {
      _daysEntryFocus.requestFocus();
    } else {
      _focusResults();
    }
  }

  final _resultsFocus = FocusNode(canRequestFocus: false);
  final _listKey = GlobalKey<CompactChoiceListState>();
  final _calendarKey = GlobalKey<SportsScheduleCalendarState>();
  final _scrollDay = ValueNotifier<DateTime?>(null);
  late final _clockTick = ValueNotifier<DateTime>(_now);
  Timer? _minuteTimer, _entryLoad;
  int _lastNowBoundary = -1;
  bool get _timeOrder => !_overview || !_browse.groupBySport;
  bool get _includesToday =>
      !_from.isAfter(_today) &&
      !_through.isBefore(_today) &&
      (_overview ||
          _browse.selectedDay == null ||
          _browse.selectedDay == _today);
  int get _nowBoundary {
    if (!_timeOrder || !_includesToday || _calendar || _visibleGames.isEmpty) {
      return -1;
    }
    final index = _visibleGames.indexWhere(
        (g) => !sportsFixtureHasUnknownTime(g) && !g.start.isBefore(_now));
    return index < 0 ? _visibleGames.length : index;
  }

  void _activeFixtureChanged(int index) {
    if (index < 0 || index >= _visibleGames.length) return;
    final day = sportsCalendarDay(_visibleGames[index].start.toLocal());
    if (_scrollDay.value == day) return;
    _scrollDay.value = day;
  }

  void _reveal(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _listKey.currentState?.revealIndex(index);
    });
  }

  void _showCompleted() {
    setState(() {
      _browse.showCompleted = !_browse.showCompleted;
      _resultsTouched = false;
      _filterGames();
    });
    if (_timeOrder && _includesToday && _visibleGames.isNotEmpty) {
      final live = _visibleGames.indexWhere((g) => g.isLive);
      final future = _visibleGames.indexWhere(
          (g) => !g.start.isBefore(_now) && !sportsFixtureHasUnknownTime(g));
      _reveal(live >= 0
          ? live
          : future >= 0
              ? future
              : _visibleGames.length - 1);
    }
  }

  void _applyUpdates() {
    final pending = _pendingGames;
    if (pending == null) return;
    final index = _listKey.currentState?.firstVisibleIndex ?? 0;
    final anchor = index < _visibleGames.length ? _visibleGames[index] : null;
    setState(() {
      _games = pending;
      _pendingGames = null;
      _resultsTouched = false;
      _indexGames();
    });
    if (anchor != null) {
      final retained = _visibleGames.indexWhere(
          (g) => g.id == anchor.id && g.league.id == anchor.league.id);
      final next =
          _visibleGames.indexWhere((g) => !g.start.isBefore(anchor.start));
      _reveal(retained >= 0
          ? retained
          : next >= 0
              ? next
              : _visibleGames.length - 1);
    }
    widget.entryFocus.requestFocus();
  }

  Widget _nowMarker() => ValueListenableBuilder<DateTime>(
      valueListenable: _clockTick,
      builder: (context, time, _) => Semantics(
            label: 'Current time ${_clockFormat.format(time)}',
            child: Row(key: const ValueKey('schedule-now-line'), children: [
              const SizedBox(width: 8),
              const Icon(Icons.circle, size: 5, color: Color(0xFFE57373)),
              const SizedBox(width: 6),
              Text('Now · ${_clockFormat.format(time)}',
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFFE57373))),
              const SizedBox(width: 8),
              const Expanded(
                  child: Divider(color: Color(0xFFE57373), thickness: 1)),
            ]),
          ));

  bool _resultsTouched = false;
  List<SportsGame>? _pendingGames;
  late final _scroll = ScrollController(initialScrollOffset: _browse.offset);
  bool _searching = false;
  bool _summaryLoading = false;
  int _summaryRequest = 0;
  bool get _calendar => _browse.calendarDays > 0;
  DateTime get _calendarStart => _browse.calendarDays == 30
      ? DateTime(_from.year, _from.month)
      : sportsCalendarDay(_from, 1 - _from.weekday);
  int get _calendarLength => _browse.calendarDays == 30
      ? DateTime(_from.year, _from.month + 1, 0).day
      : 7;
  List<_ScheduleIndexRow> _indexed = [];
  List<SportsGame> _visibleGames = const [];
  Map<DateTime, int> _dayCounts = {};
  int _followsRevision = 0;

  void _indexGames() {
    final zone = (_now.timeZoneName, _now.timeZoneOffset);
    if (!identical(_browse._indexedGames, _games) ||
        _browse._indexZone != zone) {
      _browse._indexZone = zone;
      _browse._indexedGames = _games;
      final leagueTerms = <String, String>{};
      String terms(SportsLeague league) =>
          leagueTerms.putIfAbsent(league.id, () {
            final sport = league.espnPath.split('/').first;
            return '${sportLabel(sport)} ${shortSportLabel(sport)} ${league.name} ${league.shortName}';
          });
      _browse._index = [
        for (final game in _games)
          (
            game: game,
            day: sportsCalendarDay(game.start.toLocal()),
            text:
                '${game.title} ${game.first.name} ${game.second.name} ${terms(game.league)} ${game.event?.venue ?? ''}'
                    .toLowerCase()
          )
      ];
    }
    _indexed = _browse._index;
    _filterGames();
  }

  String? get _emptyFavouriteSelection =>
      _browse.favouritesFilter.emptySelectionMessage(
          hasLeagues: widget.favouriteLeagueIds?.isNotEmpty == true,
          hasTeams: widget.follows?.isEmpty == false);

  bool _isFavourite(SportsGame game) =>
      (_browse.favouritesFilter.includesLeagues &&
          widget.favouriteLeagueIds?.contains(game.league.id) == true) ||
      (_browse.favouritesFilter.includesTeams &&
          widget.follows?.involves(game) == true);

  void _filterGames() {
    final query = _browse.query.trim().toLowerCase();
    // Retain one immutable projection across tab visits. Every local filter,
    // membership change and new fixture snapshot invalidates it.
    final key = (
      _indexed,
      _overview,
      _browse.sport,
      _browse.selectedDay,
      query,
      _browse.groupBySport,
      _browse.favouritesFilter,
      widget.favouriteLeagueIds,
      _browse.showCompleted,
      widget.follows,
      widget.follows?.revision
    );
    if (_browse._projectionKey == key) {
      _visibleGames = _browse._visible;
      _dayCounts = _browse._counts;
      return;
    }
    _dayCounts = {};
    // Keep one ordered index. Favourites and search change membership only,
    // so repeated filtering does not sort the same fixture snapshot again.
    final orderKey = (_indexed, _timeOrder);
    if (_browse._orderKey != orderKey) {
      _browse._orderKey = orderKey;
      int compare(_ScheduleIndexRow a, _ScheduleIndexRow b) {
        if (!_timeOrder) {
          final sport = sportLabel(a.game.league.espnPath.split('/').first)
              .compareTo(sportLabel(b.game.league.espnPath.split('/').first));
          if (sport != 0) return sport;
          final league =
              a.game.league.shortName.compareTo(b.game.league.shortName);
          if (league != 0) return league;
        }
        final time = a.game.start.compareTo(b.game.start);
        return time != 0
            ? time
            : '${a.game.league.id}:${a.game.id}'
                .compareTo('${b.game.league.id}:${b.game.id}');
      }

      var ordered = true;
      for (var i = 1; i < _indexed.length; i++) {
        if (compare(_indexed[i - 1], _indexed[i]) > 0) {
          ordered = false;
          break;
        }
      }
      // Schedule feeds normally arrive chronologically sorted. Reuse them
      // directly; allocate/sort only when grouping or provider order requires it.
      _browse._orderedIndex =
          ordered ? _indexed : ([..._indexed]..sort(compare));
    }
    final scoped = _browse._orderedIndex.where((row) =>
        (_browse.showCompleted || !sportsFixtureCompleted(row.game)) &&
        (!_overview ||
            _browse.sport == null ||
            row.game.league.espnPath.split('/').first == _browse.sport) &&
        (!_browse.onlyFavourites || _isFavourite(row.game)) &&
        (query.isEmpty || row.text.contains(query)));
    _visibleGames = [];
    for (final row in scoped) {
      _dayCounts.update(row.day, (n) => n + 1, ifAbsent: () => 1);
      if (_browse.selectedDay == null || row.day == _browse.selectedDay) {
        _visibleGames.add(row.game);
      }
    }
    _browse._projectionKey = key;
    _browse._visible = _visibleGames;
    _browse._counts = _dayCounts;
  }

  void _filter({DateTime? day, String? query}) {
    setState(() {
      if (query != null) {
        _browse.query = query;
      } else {
        _browse.selectedDay = day;
      }
      _resultsTouched = false;
      _browse.offset = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _filterGames();
    });
  }

  void _toggleSearch() {
    if (_calendar) _setView(0);
    if (_searching) {
      _search.clear();
      _filter(query: '');
      _searchFocus.unfocus();
    }
    setState(() => _searching = !_searching);
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searching) _searchFocus.requestFocus();
      });
    }
  }

  void _rememberOffset() {
    if (_scroll.hasClients) _browse.offset = _scroll.offset;
  }

  bool get _overview => widget.overviewLeagues != null && _league == null;
  List<SportsLeague> get _overviewLeagues {
    final leagues = widget.overviewLeagues ?? const <SportsLeague>[];
    return widget.favouriteLeagueIds != null &&
            !_browse.onlyFavourites &&
            _browse.sport != null
        ? leagues
            .where((l) => l.espnPath.startsWith('${_browse.sport}/'))
            .toList()
        : leagues;
  }

  String get _dayKey => '${_overviewLeagues.map((l) => l.id).join(',')}|$_from';
  void _acceptGames(List<SportsGame> games) {
    if (listEquals(games, _games)) return;
    // Never insert or reorder fixtures under a remote focus or scrolling finger.
    if (_games.isNotEmpty && (_resultsTouched || _resultsFocus.hasFocus)) {
      _pendingGames = games;
    } else {
      _games = games;
      _indexGames();
    }
  }

  DateTime get _today =>
      sportsCalendarDay(widget.clock?.call() ?? DateTime.now());
  DateTime get _from => _browse.from ?? _today;
  DateTime get _through => sportsCalendarDay(_from, _browse.days - 1);
  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  ({String league, DateTime from, int days}) get _window => (
        league: _overview
            ? _overviewLeagues.map((l) => l.id).join(',')
            : _browse.leagueId ?? '',
        from: _from,
        days: _browse.days
      );
  SportsLeague? get _league =>
      _browse.leagueId == null ? null : _leaguesById[_browse.leagueId];
  @override
  void initState() {
    super.initState();
    _browse.favouritesFilter =
        widget.favouritesFilter ?? _browse.favouritesFilter;
    _followsRevision = widget.follows?.revision ?? 0;
    _browse.from ??= _today;
    if (!_browse.initialized && widget.overviewLeagues != null) {
      _browse.days = 1;
      _browse.sport = null;
      _browse.leagueId = null;
    }
    if (widget.initialLeague != null &&
        (widget.overviewLeagues == null || _browse.leagueId != null) &&
        _leagues.any((league) => league.id == widget.initialLeague!.id)) {
      if (_browse.leagueId != widget.initialLeague!.id) {
        _browse.query = '';
        _browse.selectedDay = null;
        _browse.offset = 0;
      }
      _browse.leagueId = widget.initialLeague!.id;
      _browse.sport = widget.initialLeague!.espnPath.split('/').first;
    }
    _browse.initialized = true;
    if (_browse._window == _window) {
      _games = _browse._games;
      _incomplete = _browse._incomplete;
    }
    _scroll.addListener(_rememberOffset);
    _minuteTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      _clockTick.value = _now;
      final boundary = _nowBoundary;
      if (boundary != _lastNowBoundary) {
        setState(() => _lastNowBoundary = boundary);
      }
    });
    _searching = _browse.query.isNotEmpty;
    _indexGames();
    if (_browse._window == _window) {
      _rememberSummaries(
          _games, _from, _overview ? 1 : _browse.days, _incomplete,
          at: _browse._loadedAt);
    }
    final age =
        _browse._loadedAt == null ? null : _now.difference(_browse._loadedAt!);
    if (((_overview && !_calendar) || _league != null) &&
        (_browse._window != _window ||
            _incomplete ||
            age == null ||
            age.isNegative ||
            age >= const Duration(minutes: 2))) {
      // Cache assembly may cover hundreds of feeds. Present the controls and
      // retained rows first; a tab left before the next event needs no refresh.
      _loading = true;
      final request = _request;
      _entryLoad = Timer(Duration.zero, () {
        _entryLoad = null;
        if (mounted && request == _request) unawaited(_load());
      });
    }
  }

  @override
  void didUpdateWidget(SportsSchedulePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final modeChanged = oldWidget.favouritesFilter != widget.favouritesFilter;
    final localModeChanged = widget.favouritesFilter != null &&
        _browse.favouritesFilter != widget.favouritesFilter;
    if (widget.favouritesFilter != null) {
      _browse.favouritesFilter = widget.favouritesFilter!;
    }
    if (!listEquals(oldWidget.overviewLeagues, widget.overviewLeagues)) {
      final leagues = widget.overviewLeagues;
      if (leagues != null && !modeChanged) {
        if (oldWidget.overviewLeagues?.any((l) => l.id == _browse.leagueId) ==
                true &&
            !leagues.any((l) => l.id == _browse.leagueId)) {
          _browse.leagueId = null;
        }
        if (_browse.leagueId == null &&
            !leagues.any((l) => l.espnPath.startsWith('${_browse.sport}/'))) {
          _browse.sport = null;
        }
      }
      if (_overview && _calendar) {
        // Changing enabled leagues must not start hidden calendar requests.
        _request++;
        _summaryRequest++;
        _loading = false;
        _summaryLoading = false;
        _pendingGames = null;
        final loaded = _browse._window;
        final loadedIds = loaded?.league.split(',').toSet() ?? const <String>{};
        final nextIds = _overviewLeagues.map((league) => league.id).toSet();
        final covered = loaded != null &&
            loaded.from == _from &&
            loaded.days == _browse.days &&
            !_browse._incomplete &&
            _browse._loadedAt != null &&
            nextIds.every(loadedIds.contains);
        if (covered) {
          // A narrower calendar can use the complete snapshot already loaded.
          // Keep its age; changing a filter must not renew the data's TTL.
          _games = _browse._games
              .where((game) => nextIds.contains(game.league.id))
              .toList();
          _browse._games = _games;
          _browse._window = _window;
          _rememberSummaries(_games, _from, 1, false, at: _browse._loadedAt);
        } else {
          _games = const [];
        }
        _indexGames();
      } else if (_overview || !modeChanged) {
        unawaited(_load());
      }
    }
    final revision = widget.follows?.revision ?? 0;
    if (localModeChanged ||
        oldWidget.favouriteLeagueIds != widget.favouriteLeagueIds ||
        oldWidget.follows != widget.follows ||
        revision != _followsRevision) {
      _followsRevision = revision;
      _refreshFavouriteProjection();
    }
  }

  @override
  void dispose() {
    _entryLoad?.cancel();
    _minuteTimer?.cancel();
    _clockTick.dispose();
    _scrollDay.dispose();
    _request++;
    _summaryRequest++;
    _search.dispose();
    _searchFocus.dispose();
    _leagueFocus.dispose();
    _daysEntryFocus.dispose();
    _resultsFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _entryLoad?.cancel();
    _entryLoad = null;
    _summaryRequest++;
    _summaryLoading = false;
    final token = ++_request;
    final league = _league;
    if (league == null && !_overview) return;
    final overview = _overview, dayKey = _dayKey;
    final cached = overview ? _browse._days[dayKey] : null;
    final age = cached == null ? null : _now.difference(cached.at);
    if (cached != null &&
        !cached.incomplete &&
        age != null &&
        !age.isNegative &&
        age < const Duration(minutes: 2)) {
      setState(() {
        _pendingGames = null;
        _browse._window = _window;
        _browse._games = cached.games;
        _browse._loadedAt = cached.at;
        _browse._incomplete = false;
        _games = cached.games;
        _rememberSummaries(_games, _from, 1, false, at: cached.at);
        _indexGames();
        _loading = false;
        _incomplete = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _incomplete = false;
      if (_browse._window != _window) _games = const [];
      _pendingGames = null;
      if (_games.isEmpty) {
        final end = sportsCalendarDay(_through, 1);
        _games = overview
            ? cached?.games ??
                _service.cachedScheduleDay(_overviewLeagues, _from)
            : _service
                .cachedGamesForDay([league!], _from)
                .where((game) =>
                    !game.start.isBefore(_from) && game.start.isBefore(end))
                .toList();
      }
      _indexGames();
      _retainPartial();
    });
    try {
      final result = overview
          ? await _service.scheduleDay(_overviewLeagues, _from,
              shouldContinue: () => mounted && token == _request,
              onProgress: (games) {
                if (mounted && token == _request) {
                  setState(() {
                    _acceptGames(games);
                    _retainPartial();
                  });
                }
              })
          : await _service.scheduleGames(league!, _from, _through,
              shouldContinue: () => mounted && token == _request);
      if (!mounted || token != _request) return;
      setState(() {
        _acceptGames(result.games);
        // The service may assemble a new list containing the same fixtures.
        // Preserve the indexed list identity when no data actually changed.
        final retained =
            listEquals(_games, result.games) ? _games : result.games;
        _rememberSummaries(result.games, _from, _overview ? 1 : _browse.days,
            result.incomplete);
        _incomplete = result.incomplete;
        _loading = false;
        _browse._window = _window;
        _browse._games = retained;
        if (overview) {
          _browse._days.remove(dayKey);
          _browse._days[dayKey] =
              (games: retained, incomplete: result.incomplete, at: _now);
          while (_browse._days.length > 3) {
            _browse._days.remove(_browse._days.keys.first);
          }
        }
        _browse._incomplete = _incomplete;
        _browse._loadedAt = _now;
      });
    } catch (_) {
      if (mounted && token == _request) {
        setState(() {
          _loading = false;
          _incomplete = true;
        });
      }
    }
  }

  void _retainPartial() {
    // Reuse the same list/index on a quick return, without treating a cancelled
    // or unfinished load as fresh. Completion alone supplies a cache timestamp.
    _browse._window = _window;
    _browse._games = _games;
    _browse._loadedAt = null;
    _browse._incomplete = true;
  }

  Future<void> _chooseSport() async {
    final selected = await showSportsFilterPicker(context,
        title: 'Choose sport',
        itemLabel: 'sports',
        description: widget.overviewLeagues == null
            ? null
            : _browse.onlyFavourites
                ? _browse.favouritesFilter.description
                : 'All leagues · narrow by sport',
        selected: _browse.sport ?? '',
        options: [
          ...sportsSportOptions(widget.overviewLeagues ?? _leagues, const {},
              showCounts: false, favouriteOnly: _browse.onlyFavourites),
          if (widget.onManageLeagues != null)
            sportsManageLeaguesOption(
                widget.favouriteLeagueIds?.length ?? _overviewLeagues.length),
        ],
        showSortingControls: false);
    if (!mounted || selected == null) return;
    if (selected == '__manage_leagues__') {
      await widget.onManageLeagues?.call();
      return;
    }
    if (widget.overviewLeagues == null) {
      await _pickLeague(selected.isEmpty ? null : selected);
      return;
    }
    _summaryRequest++;
    _summaryLoading = false;
    final wasOverview = _overview;
    setState(() {
      _browse.sport = selected.isEmpty ? null : selected;
      _browse.leagueId = null;
      _browse.days = 1;
      _browse.calendarDays = 0;
      _browse.selectedDay = null;
      _browse.offset = 0;
      _resultsTouched = false;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _filterGames();
    });
    widget.onScopeChanged?.call(_browse.sport, null);
    if (!wasOverview || _browse._window != _window) await _load();
  }

  Future<void> _chooseLeague() => _pickLeague(_browse.sport);

  Future<void> _pickLeague(String? sport) async {
    final selected = await showSportsFilterPicker(context,
        title: 'Choose league',
        itemLabel: 'leagues',
        description: widget.overviewLeagues == null
            ? null
            : _browse.onlyFavourites
                ? _browse.favouritesFilter.description
                : 'All available leagues',
        selected: _browse.leagueId ?? '__all__',
        showSortingControls: false,
        options: [
          if (widget.overviewLeagues != null)
            SportsFilterOption(
                '__all__',
                sport == null
                    ? 'All leagues'
                    : 'All ${sportLabel(sport)} leagues',
                Icons.public,
                description: sport == null
                    ? 'Across all sports in this view'
                    : 'All ${sportLabel(sport)} leagues in this view'),
          if (widget.overviewLeagues != null && sport != null)
            const SportsFilterOption(
                '__all_sports__', 'All sports', Icons.public,
                description: 'Clear the sport and league filters'),
          if (widget.onManageLeagues != null)
            sportsManageLeaguesOption(
                widget.favouriteLeagueIds?.length ?? _overviewLeagues.length),
          for (final league in widget.overviewLeagues ?? _leagues)
            if (sport == null || league.espnPath.split('/').first == sport)
              SportsFilterOption(league.id, league.name,
                  sportIcon(league.espnPath.split('/').first),
                  logoUrl: league.logoUrl,
                  description: league.region,
                  searchTerms: league.shortName,
                  group: sportLabel(league.espnPath.split('/').first))
        ]);
    if (!mounted || selected == null) return;
    if (selected == _browse.leagueId) return;
    if (selected == '__manage_leagues__') {
      await widget.onManageLeagues?.call();
      return;
    }
    _browse.calendarDays = 0;
    if (selected == '__all__' || selected == '__all_sports__') {
      setState(() {
        _browse.leagueId = null;
        _browse.sport = selected == '__all_sports__' ? null : sport;
        _browse.days = 1;
        _browse.selectedDay = null;
        _browse.offset = 0;
        _resultsTouched = false;
      });
      widget.onScopeChanged?.call(_browse.sport, null);
      await _load();
      return;
    }
    setState(() {
      _browse.query = '';
      _search.clear();
      _browse.selectedDay = null;
      _browse.offset = 0;
      _resultsTouched = false;
      _browse.leagueId = selected;
      _browse.sport = _league?.espnPath.split('/').first;
    });
    widget.onLeagueChanged?.call(_league!);
    widget.onScopeChanged?.call(_browse.sport, _browse.leagueId);
    await _load();
  }

  void _setFavouritesFilter(SportsFavouritesFilter value) {
    if (_browse.favouritesFilter == value) return;
    setState(() {
      _browse.favouritesFilter = value;
      _resultsTouched = false;
      _browse.offset = 0;
      _refreshFavouriteProjection();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    widget.onFavouritesChanged?.call(value);
  }

  void _refreshFavouriteProjection() {
    // A week request belongs to the scope that started it. Do not publish a
    // late response or continue its queue after that scope changes.
    _summaryRequest++;
    _summaryLoading = false;
    _filterGames();
    if (!_loading && _browse._window == _window) {
      _rememberSummaries(
          _games, _from, _overview ? 1 : _browse.days, _incomplete,
          at: _browse._loadedAt);
    }
  }

  String get _summaryScope =>
      '${_overview ? _overviewLeagues.map((l) => l.id).join(',') : _browse.leagueId ?? ''}|${_browse.onlyFavourites ? '${_browse.favouritesFilter.name}:${widget.follows?.revision}:${widget.favouriteLeagueIds?.join(',')}' : 'all'}';

  void _rememberSummaries(
      List<SportsGame> games, DateTime from, int days, bool incomplete,
      {DateTime? at}) {
    if (_browse.summaryScope != _summaryScope) {
      _browse.summaries.clear();
      _browse.summaryScope = _summaryScope;
    }
    final counts = <DateTime, Map<String, int>>{};
    for (final game in games) {
      if (_browse.onlyFavourites && !_isFavourite(game)) continue;
      final day = sportsCalendarDay(game.start.toLocal());
      final sports = counts.putIfAbsent(day, () => {});
      sports.update(game.league.espnPath.split('/').first, (n) => n + 1,
          ifAbsent: () => 1);
    }
    for (var i = 0; i < days; i++) {
      final day = sportsCalendarDay(from, i);
      _browse.summaries.remove(day);
      _browse.summaries[day] = SportsScheduleSummary(counts[day] ?? const {},
          incomplete: incomplete, at: at ?? _now);
    }
    // Calendar history stores small counts, never another month of fixtures.
    while (_browse.summaries.length > 62) {
      _browse.summaries.remove(_browse.summaries.keys.first);
    }
  }

  Future<void> _loadWeekSummaries() async {
    final token = ++_summaryRequest;
    final start = _calendarStart;
    setState(() => _summaryLoading = true);
    for (var i = 0; i < 7; i++) {
      if (!mounted || token != _summaryRequest) return;
      final day = sportsCalendarDay(start, i);
      final cached =
          _browse.summaryScope == _summaryScope ? _browse.summaries[day] : null;
      final age = cached == null ? null : _now.difference(cached.at);
      if (cached != null &&
          !cached.incomplete &&
          age != null &&
          !age.isNegative &&
          age < const Duration(minutes: 2)) {
        continue;
      }
      try {
        final result = await _service.scheduleDay(_overviewLeagues, day,
            shouldContinue: () => mounted && token == _summaryRequest);
        if (!mounted || token != _summaryRequest) return;
        setState(
            () => _rememberSummaries(result.games, day, 1, result.incomplete));
      } catch (_) {
        if (!mounted || token != _summaryRequest) return;
        setState(() => _rememberSummaries(const [], day, 1, true));
      }
    }
    if (mounted && token == _summaryRequest) {
      setState(() => _summaryLoading = false);
    }
  }

  bool _freshSummary(SportsScheduleSummary? summary) {
    if (summary == null || summary.incomplete) return false;
    final age = _now.difference(summary.at);
    return !age.isNegative && age < const Duration(minutes: 2);
  }

  Future<void> _loadMonthSummaries() async {
    if (_summaryLoading || !_overview || _browse.calendarDays != 30) return;
    final token = ++_summaryRequest;
    final start = _calendarStart,
        length = _calendarLength,
        scope = _summaryScope;
    final days = [for (var i = 0; i < length; i++) sportsCalendarDay(start, i)];
    if (_browse.summaryScope == scope &&
        days.every((day) => _freshSummary(_browse.summaries[day]))) {
      return;
    }
    final leagues = List<SportsLeague>.of(_overviewLeagues);
    final counts = <DateTime, Map<String, int>>{};
    var incomplete = false, completed = 0;
    bool active() =>
        mounted &&
        token == _summaryRequest &&
        _calendar &&
        _browse.calendarDays == 30 &&
        _calendarStart == start &&
        _summaryScope == scope;
    void publish() {
      if (_browse.summaryScope != scope) {
        _browse.summaries.clear();
        _browse.summaryScope = scope;
      }
      final partial = incomplete || completed < leagues.length;
      for (final day in days) {
        // Keep an already complete day while other leagues are still loading.
        if (partial && _freshSummary(_browse.summaries[day])) continue;
        _browse.summaries.remove(day);
        _browse.summaries[day] = SportsScheduleSummary(
            Map.unmodifiable(counts[day] ?? const <String, int>{}),
            incomplete: partial,
            at: _now);
      }
      while (_browse.summaries.length > 62) {
        _browse.summaries.remove(_browse.summaries.keys.first);
      }
    }

    setState(() => _summaryLoading = true);
    // Monthly feeds use the separate, bounded schedule cache. Keep only counts
    // here; process one league at a time and yield before starting the next.
    for (final league in leagues) {
      if (!active()) return;
      try {
        final result = await _service.scheduleGames(league, start, days.last,
            shouldContinue: active);
        if (!active()) return;
        incomplete |= result.incomplete;
        for (final game in result.games) {
          if (_browse.onlyFavourites && !_isFavourite(game)) continue;
          final day = sportsCalendarDay(game.start.toLocal());
          if (day.isBefore(start) || day.isAfter(days.last)) continue;
          final bySport = counts.putIfAbsent(day, () => {});
          bySport.update(league.espnPath.split('/').first, (n) => n + 1,
              ifAbsent: () => 1);
        }
      } catch (_) {
        if (!active()) return;
        incomplete = true;
      }
      completed++;
      setState(publish);
      await Future<void>.delayed(Duration.zero);
    }
    if (active()) {
      setState(() {
        publish();
        _summaryLoading = false;
      });
    }
  }

  void _setView(int days) {
    _summaryRequest++;
    setState(() {
      _summaryLoading = false;
      _browse.calendarDays = days;
      _resultsTouched = false;
      _browse.offset = 0;
      if (days > 0) {
        _searching = false;
        _search.clear();
        _browse.query = '';
        if (!_overview) {
          _browse.from = _browse.selectedDay ?? _from;
          _browse.from = _calendarStart;
          _browse.days = _calendarLength;
          _browse.selectedDay = null;
        }
      }
      if (days == 0 && !_overview) _browse.selectedDay ??= _from;
      _filterGames();
    });
    if ((!_overview && _league != null && days > 0) ||
        (_overview && days == 0 && _browse._window != _window)) {
      unawaited(_load());
    }
  }

  void _openCalendarDay(DateTime day) {
    _summaryRequest++;
    setState(() {
      _summaryLoading = false;
      _browse.calendarDays = 0;
      _browse.offset = 0;
      _resultsTouched = false;
      if (_overview) {
        _browse.from = day;
        _browse.selectedDay = null;
      } else {
        _browse.selectedDay = day;
        _filterGames();
      }
    });
    if (_overview) unawaited(_load());
  }

  void _move(int direction) {
    _summaryRequest++;
    if (_overview && _calendar) {
      _request++;
      _loading = false;
      _pendingGames = null;
    }
    setState(() {
      _summaryLoading = false;
      _resultsTouched = false;
      _browse.from = _calendar && _browse.calendarDays == 30
          ? DateTime(_from.year, _from.month + direction)
          : sportsCalendarDay(
              _from,
              direction *
                  (_calendar
                      ? 7
                      : _overview
                          ? 7
                          : _browse.days));
      if (_calendar && !_overview) _browse.days = _calendarLength;
      _browse.selectedDay = null;
      _browse.offset = 0;
    });
    if ((_overview && !_calendar) || _league != null) unawaited(_load());
  }

  Future<void> _chooseDate() async {
    final now = _today;
    final selected = await showSportsChoices<DateTime>(context,
        title: 'Schedule · start date',
        selected: _from,
        choices: [
          SportsChoice(now, 'Today', DateFormat.yMMMd().format(now)),
          SportsChoice(sportsCalendarDay(now, 7), 'Next week',
              DateFormat.yMMMd().format(sportsCalendarDay(now, 7))),
          for (var i = 1; i <= 3; i++)
            SportsChoice(
                DateTime(now.year, now.month + i),
                DateFormat.MMMM().format(DateTime(now.year, now.month + i)),
                'Start of month'),
        ]);
    if (!mounted || selected == null || selected == _from) return;
    _summaryRequest++;
    if (_overview && _calendar) {
      _request++;
      _loading = false;
      _pendingGames = null;
    }
    setState(() {
      _summaryLoading = false;
      _resultsTouched = false;
      _browse.from = selected;
      if (_calendar && !_overview) {
        _browse.from = _calendarStart;
        _browse.days = _calendarLength;
      }
      _browse.selectedDay = null;
      _browse.offset = 0;
    });
    if ((_overview && !_calendar) || _league != null) unawaited(_load());
  }

  Widget _dayStrip(
          {required bool tv, required bool dense, ButtonStyle? iconStyle}) =>
      ValueListenableBuilder<DateTime?>(
          valueListenable: _scrollDay,
          builder: (context, _, __) =>
              _buildDayStrip(tv: tv, dense: dense, iconStyle: iconStyle));

  Widget _buildDayStrip(
      {required bool tv, required bool dense, ButtonStyle? iconStyle}) {
    final days = SportsScheduleDays(
        from: _overview
            ? sportsCalendarDay(_today,
                (sportsCalendarDayOffset(_today, _from) / 7).floor() * 7)
            : _from,
        days: _overview ? 7 : _browse.days,
        compact: tv,
        dense: dense,
        showAll: !_overview && _browse.days > 1,
        showCounts: !_overview,
        today: _today,
        counts: _dayCounts,
        selected: _overview || _browse.days == 1
            ? _from
            : _browse.selectedDay ?? _scrollDay.value,
        onSelected: (day) {
          if (!_overview) {
            _filter(day: day);
            return;
          }
          if (day == null || day == _from) return;
          setState(() {
            _browse.from = day;
            _browse.offset = 0;
            _resultsTouched = false;
          });
          unawaited(_load());
        });
    return SportsToolbarNavigation(
        enabled: tv,
        onUp: _focusControls,
        onDown: (_) => _focusResults(),
        child: Row(children: [
          IconButton(
              key: const ValueKey('schedule-previous'),
              style: iconStyle,
              focusNode: _daysEntryFocus,
              tooltip:
                  _overview ? 'Previous week' : 'Previous ${_browse.days} days',
              onPressed: () => _move(-1),
              icon: const Icon(Icons.chevron_left, size: 20)),
          Expanded(child: days),
          IconButton(
              key: const ValueKey('schedule-next'),
              style: iconStyle,
              tooltip: _overview ? 'Next week' : 'Next ${_browse.days} days',
              onPressed: () => _move(1),
              icon: const Icon(Icons.chevron_right, size: 20)),
        ]));
  }

  void _details(SportsGame game) {
    if (widget.onGameDetails != null) {
      widget.onGameDetails!(game);
      return;
    }
    showSportsGameDetails(context, game, hideScores: widget.hideScores);
  }

  void _activateFixture(SportsGame game) {
    final match = widget.channelMatchForGame?.call(game);
    final watch = widget.onWatchGame;
    if (match != null && watch != null) {
      watch(game, match);
    } else {
      _details(game);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tv = context.read<AppPreferences>().isTelevision;
    final use24h = context.select<AppPreferences, bool>((p) => p.use24h);
    final dense = compactSportsControls(context);
    final controlHeight = sportsScheduleControlHeight(context, television: tv);
    final iconStyle = IconButton.styleFrom(
        minimumSize: Size(40, controlHeight),
        maximumSize: Size(40, controlHeight),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap);
    final league = _league;
    final typing = _searching ||
        (MediaQuery.sizeOf(context).width < 600 &&
            (widget.keyboardOpen ??
                (MediaQuery.viewInsetsOf(context).bottom > 0)));
    final windowArrows = _calendar || (!_overview && _browse.days <= 1);
    final iconCount =
        2 + (_pendingGames == null ? 0 : 1) + (windowArrows ? 2 : 0);
    var toolbarWidth = iconCount * 40.0 + 54 + (_calendar ? 0 : 41);
    final metrics = (
      Theme.of(context).textTheme.labelLarge,
      MediaQuery.textScalerOf(context),
      Directionality.of(context)
    );
    if (_toolbarMetrics != metrics) {
      _toolbarMetrics = metrics;
      _toolbarLabelWidths.clear();
    }
    for (final label in ['Day', 'Week', 'Month', if (!_calendar) 'Display']) {
      toolbarWidth += _toolbarLabelWidths.putIfAbsent(label, () {
        final painter = TextPainter(
            text: TextSpan(
                text: label,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontSize: 11)),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context))
          ..layout();
        final width = painter.width.ceilToDouble();
        painter.dispose();
        return width;
      });
    }
    final filters = Row(children: [
      Expanded(
          flex: 3,
          child: SportsFilterButton(
              key: const ValueKey('schedule-sport'),
              minimumHeight: tv ? 0 : controlHeight,
              caption: 'Sport',
              selected: _browse.sport != null,
              value: sportsPickerSportLabel(context, _browse.sport),
              onTap: _chooseSport)),
      const SizedBox(width: 6),
      Expanded(
          flex: 4,
          child: SportsFilterButton(
              key: const ValueKey('schedule-league'),
              focusNode: _leagueFocus,
              minimumHeight: tv ? 0 : controlHeight,
              caption: 'League',
              value:
                  league?.name ?? (_overview ? 'All leagues' : 'Choose league'),
              selected: league != null,
              onTap: _chooseLeague)),
    ]);
    final calendar = IconButton(
        key: const ValueKey('schedule-date'),
        style: iconStyle,
        tooltip: 'Jump to date',
        onPressed: _chooseDate,
        icon: const Icon(Icons.calendar_today_outlined, size: 18));
    final boundary = _nowBoundary;
    _lastNowBoundary = boundary;
    final rows = [
      for (final (index, game)
          in (_calendar ? const <SportsGame>[] : _visibleGames).indexed)
        CompactChoice(
            id: '${game.league.id}:${game.id}',
            title: game.title,
            markerBefore: index == boundary ? _nowMarker() : null,
            group: _overview
                ? _browse.groupBySport
                    ? '${sportLabel(game.league.espnPath.split('/').first)} · ${game.league.shortName}'
                    : null
                : _dayFormat.format(game.start.toLocal()),
            contentBuilder: (_) {
              final match = widget.onWatchGame == null
                  ? null
                  : widget.channelMatchForGame?.call(game);
              return SportsFixtureRow(
                  game: game,
                  time: _scheduleTime(game, _clockFormat),
                  hideScores: widget.hideScores,
                  use24h: use24h,
                  favourite: widget.follows?.involves(game) ?? false,
                  showLeague: _overview && !_browse.groupBySport,
                  showSport: _overview &&
                      _browse.sport == null &&
                      !_browse.groupBySport,
                  channelName: match?.channel.name,
                  possibleChannel: match != null && !match.isConfident,
                  onDetails: match == null ? null : () => _details(game));
            },
            onHold: widget.onWatchGame == null ? null : () => _details(game),
            onTap: () => _activateFixture(game))
    ];
    return widget.layoutBuilder(
        filters,
        widget.follows != null
            ? SportsFavouritesFilterButton(
                key: const ValueKey('schedule-favourites-only'),
                filter: _browse.favouritesFilter,
                favouriteLeagueCount: widget.favouriteLeagueIds?.length ?? 0,
                favouriteTeamCount: widget.follows?.teams.length ?? 0,
                onChanged: _setFavouritesFilter)
            : const SizedBox.shrink(),
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!typing)
            SportsToolbarNavigation(
                enabled: tv,
                onUp: _leagueFocus.requestFocus,
                onDown: _focusBelowControls,
                child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                            width: constraints.maxWidth
                                .clamp(toolbarWidth, double.infinity),
                            child: Row(children: [
                              if (windowArrows)
                                IconButton(
                                    key: const ValueKey('schedule-previous'),
                                    style: iconStyle,
                                    tooltip: _calendar
                                        ? 'Previous ${_browse.calendarDays == 30 ? 'month' : 'week'}'
                                        : 'Previous ${_browse.days} days',
                                    onPressed: () => _move(-1),
                                    icon: const Icon(Icons.chevron_left,
                                        size: 18)),
                              for (final days in [0, 7, 30])
                                TextButton(
                                    key: ValueKey(
                                        'schedule-range-${days == 0 ? 1 : days}'),
                                    focusNode:
                                        days == 0 ? widget.entryFocus : null,
                                    style: TextButton.styleFrom(
                                        minimumSize: Size(0, controlHeight),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 9),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        foregroundColor:
                                            _browse.calendarDays == days
                                                ? colors.primary
                                                : colors.onSurfaceVariant,
                                        backgroundColor:
                                            _browse.calendarDays == days
                                                ? colors.primary
                                                    .withValues(alpha: .1)
                                                : null,
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(4))),
                                    onPressed: () {
                                      if (_browse.calendarDays != days) {
                                        _setView(days);
                                      }
                                    },
                                    child: Text(
                                        days == 0
                                            ? 'Day'
                                            : days == 7
                                                ? 'Week'
                                                : 'Month',
                                        style: const TextStyle(fontSize: 11))),
                              const Spacer(),
                              if (!_calendar)
                                SportsScheduleDisplay(
                                  height: controlHeight,
                                  canGroup: _overview,
                                  grouped: _browse.groupBySport,
                                  completed: _browse.showCompleted,
                                  onGroup: (value) => setState(() {
                                    _browse.groupBySport = value;
                                    _resultsTouched = false;
                                    _browse.offset = 0;
                                    if (_scroll.hasClients) _scroll.jumpTo(0);
                                    _filterGames();
                                  }),
                                  onCompleted: (value) {
                                    if (_browse.showCompleted != value) {
                                      _showCompleted();
                                    }
                                  },
                                ),
                              if (_pendingGames != null)
                                IconButton(
                                    key: const ValueKey(
                                        'schedule-apply-updates'),
                                    style: iconStyle,
                                    tooltip:
                                        '${_pendingGames!.length} fixtures available · Update list',
                                    icon: const Icon(Icons.update, size: 18),
                                    onPressed: _applyUpdates),
                              calendar,
                              IconButton(
                                  key: const ValueKey('schedule-search-toggle'),
                                  style: iconStyle,
                                  tooltip: 'Search schedule',
                                  icon: const Icon(Icons.search, size: 17),
                                  onPressed: _toggleSearch),
                              if (windowArrows)
                                IconButton(
                                    key: const ValueKey('schedule-next'),
                                    style: iconStyle,
                                    tooltip: _calendar
                                        ? 'Next ${_browse.calendarDays == 30 ? 'month' : 'week'}'
                                        : 'Next ${_browse.days} days',
                                    onPressed: () => _move(1),
                                    icon: const Icon(Icons.chevron_right,
                                        size: 18)),
                            ]))))),
          if (!typing)
            Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
                child: Row(children: [
                  Expanded(
                      child: Text(
                          league == null && !_overview
                              ? 'Pick a sport and league to explore upcoming fixtures'
                              : _calendar
                                  ? '${_browse.calendarDays == 30 ? DateFormat.yMMMM().format(_from) : '${DateFormat('d MMM').format(_calendarStart)} – ${DateFormat('d MMM').format(sportsCalendarDay(_calendarStart, 6))}'} · open a day'
                                  : _loading
                                      ? 'Updating ${_overview ? 'favourite leagues' : league!.source}…'
                                      : _overview
                                          ? '${DateFormat('d MMM').format(_from)} · ${_visibleGames.length} fixtures · local time'
                                          : '${_visibleGames.length} fixtures · local time · ${league!.source}${!supportsSportsScoreboard(league) ? ' · Calendar only' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5, color: colors.onSurfaceVariant))),
                  if (_from != _today && !_calendar)
                    TextButton(
                        key: const ValueKey('schedule-today'),
                        style: TextButton.styleFrom(
                            minimumSize: const Size(0, 24),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(fontSize: 10)),
                        onPressed: () {
                          setState(() {
                            _resultsTouched = false;
                            _browse.from = _today;
                            _browse.selectedDay = null;
                            _browse.offset = 0;
                          });
                          if (_overview || _league != null) unawaited(_load());
                        },
                        child: const Text('Today')),
                ])),
          if (_searching)
            Padding(
                padding: EdgeInsets.fromLTRB(8, 0, 8, dense ? 2 : 6),
                child: TvTextFieldGate(
                    focusNode: _searchFocus,
                    builder: (context, readOnly) => TextField(
                        key: const ValueKey('schedule-search'),
                        controller: _search,
                        focusNode: _searchFocus,
                        readOnly: readOnly,
                        style: const TextStyle(fontSize: 12),
                        onChanged: (q) => _filter(query: q),
                        onSubmitted: (_) => _searchFocus
                            .focusInDirection(TraversalDirection.down),
                        decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Team, event, sport or league',
                            prefixIconConstraints: dense
                                ? BoxConstraints.tightFor(
                                    width: 40, height: controlHeight)
                                : null,
                            suffixIconConstraints: dense
                                ? BoxConstraints.tightFor(
                                    width: 40, height: controlHeight)
                                : null,
                            prefixIcon: const Icon(Icons.search, size: 17),
                            suffixIcon: IconButton(
                                key: const ValueKey('schedule-search-close'),
                                style: iconStyle,
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () {
                                  _search.clear();
                                  _filter(query: '');
                                  setState(() => _searching = false);
                                }),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: dense ? 8 : 10))))),
          if ((_overview || (league != null && _browse.days > 1)) &&
              !typing &&
              !_calendar)
            Padding(
                padding: EdgeInsets.only(bottom: dense ? 2 : 6),
                child: _dayStrip(tv: tv, dense: dense, iconStyle: iconStyle)),
          SizedBox(
              height: 2,
              child: _loading
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null),
          Expanded(
              child: _calendar
                  ? Focus(
                      focusNode: _resultsFocus,
                      canRequestFocus: false,
                      child: SportsScheduleCalendar(
                        key: _calendarKey,
                        onExitUp: _focusControls,
                        from: _calendarStart,
                        days: _calendarLength,
                        today: _today,
                        selected: _browse.selectedDay ?? _from,
                        sport: _browse.sport,
                        summaries: _browse.summaryScope == _summaryScope
                            ? _browse.summaries
                            : const {},
                        onSelected: _openCalendarDay,
                        loading: _summaryLoading || _loading,
                        onLoadWeek: _overview && _browse.calendarDays == 7
                            ? _loadWeekSummaries
                            : null,
                        onLoadMonth: _overview && _browse.calendarDays == 30
                            ? _loadMonthSummaries
                            : null,
                        onStop: _summaryLoading
                            ? () => setState(() {
                                  _summaryRequest++;
                                  _summaryLoading = false;
                                })
                            : null,
                      ))
                  : league == null && !_overview
                      ? Center(
                          child: TextButton.icon(
                              key: const ValueKey('schedule-choose-league'),
                              onPressed: _chooseSport,
                              icon: const Icon(Icons.event_note),
                              label: const Text('Find a schedule')))
                      : rows.isEmpty
                          ? Center(
                              child: SingleChildScrollView(
                                  child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                                _loading
                                                    ? Icons.event_note
                                                    : Icons.event_available,
                                                size: 26,
                                                color: colors.onSurfaceVariant),
                                            const SizedBox(height: 10),
                                            Text(
                                                _loading
                                                    ? 'Loading schedule…'
                                                    : _incomplete
                                                        ? 'Schedule unavailable for this window'
                                                        : _emptyFavouriteSelection ??
                                                            (_games.isNotEmpty
                                                                ? 'No fixtures match these filters'
                                                                : 'No fixtures published for these dates'),
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    color: colors
                                                        .onSurfaceVariant)),
                                            if (!_loading) ...[
                                              const SizedBox(height: 12),
                                              TextButton.icon(
                                                  style: sportsPopupButtonStyle(
                                                      context),
                                                  onPressed: _incomplete
                                                      ? _load
                                                      : _emptyFavouriteSelection !=
                                                              null
                                                          ? () => _setFavouritesFilter(
                                                              SportsFavouritesFilter
                                                                  .all)
                                                          : _games.isNotEmpty
                                                              ? () {
                                                                  _search
                                                                      .clear();
                                                                  _browse.showCompleted =
                                                                      true;
                                                                  _browse.favouritesFilter =
                                                                      SportsFavouritesFilter
                                                                          .all;
                                                                  widget
                                                                      .onFavouritesChanged
                                                                      ?.call(SportsFavouritesFilter
                                                                          .all);
                                                                  _filter(
                                                                      query:
                                                                          '');
                                                                  if (_overview) {
                                                                    _browse.sport =
                                                                        null;
                                                                  }
                                                                  _filter(
                                                                      day:
                                                                          null);
                                                                }
                                                              : () => _move(1),
                                                  icon: Icon(
                                                      _incomplete
                                                          ? Icons.refresh
                                                          : Icons.chevron_right,
                                                      size: 16),
                                                  label: Text(_incomplete
                                                      ? 'Try again'
                                                      : _games.isNotEmpty ||
                                                              _emptyFavouriteSelection !=
                                                                  null
                                                          ? 'Show all fixtures'
                                                          : 'Check the next ${_browse.days} days')),
                                            ],
                                          ]))))
                          : Listener(
                              onPointerDown: (_) => _resultsTouched = true,
                              child: Focus(
                                  focusNode: _resultsFocus,
                                  canRequestFocus: false,
                                  onKeyEvent: (_, event) {
                                    if (event is KeyDownEvent &&
                                        event.logicalKey ==
                                            LogicalKeyboardKey.arrowLeft) {
                                      (_searching
                                              ? _searchFocus
                                              : widget.entryFocus)
                                          .requestFocus();
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: CompactChoiceList(
                                      key: _listKey,
                                      onActiveIndexChanged:
                                          _activeFixtureChanged,
                                      trailingMarker: boundary == rows.length
                                          ? _nowMarker()
                                          : null,
                                      onExitUp: () => (_searching
                                              ? _searchFocus
                                              : sportsFocusAttached(
                                                      _daysEntryFocus)
                                                  ? _daysEntryFocus
                                                  : widget.entryFocus)
                                          .requestFocus(),
                                      // Keep a small lookahead for remote steps
                                      // without mounting several rich rows early.
                                      cacheExtent: tv ? 28 : null,
                                      controller: _scroll,
                                      resetScrollKey: (
                                        league?.id,
                                        _from,
                                        _browse.days,
                                        _browse.selectedDay,
                                        _browse.query,
                                        _browse.groupBySport
                                      ),
                                      autofocus: false,
                                      polished: true,
                                      striped: true,
                                      showNavigation: tv,
                                      // Reserve one compact channel line so
                                      // incoming matches never move focused rows.
                                      rowHeight: ((dense ? 52 : 56) +
                                              (widget.onWatchGame == null
                                                  ? 0
                                                  : 12)) *
                                          MediaQuery.textScalerOf(context)
                                              .scale(12) /
                                          12,
                                      choices: rows)))),
          if (_incomplete && _games.isNotEmpty)
            Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(children: [
                  const Icon(Icons.info_outline, size: 15),
                  const SizedBox(width: 6),
                  const Expanded(
                      child: Text('Partial schedule',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11))),
                  TextButton(
                      style: sportsPopupButtonStyle(context),
                      onPressed: _load,
                      child: const Text('Retry')),
                ])),
        ]));
  }
}
