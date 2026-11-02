import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import '../widgets/sports_header_controls.dart';
import '../models/sports.dart';
import '../models/sports_details.dart';
import '../services/sports_follows.dart';
import '../services/sports_details_service.dart';
import '../services/storage_service.dart';
import '../services/sports_standings_service.dart';
import '../utils/sports_presentation.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/sports_panel.dart';
import '../utils/guarded_dialog.dart';
import '../widgets/sports_details_panel.dart';
import '../widgets/sports_filter_picker.dart';
import '../widgets/standings_team_tile.dart';
import '../widgets/sports_favourite_tile.dart';
import '../widgets/tv_text_field_gate.dart';

final sportsStandingsLeagues = [...kSportsLeagues, ...kSportsLeagueBank]
    .where((l) =>
        (['ESPN', 'K League', 'EASL', 'NPB', 'KBO', 'ABL', 'B.League']
                .contains(l.source) ||
            const {'racing.motogp', 'racing.moto2', 'racing.moto3'}
                .contains(l.id)) &&
        l.id != 'rugby.live' &&
        (l.kind == SportsKind.team || l.hasStandings))
    .toList(growable: false);
String _sport(SportsLeague league) => league.espnPath.split('/').first;
String _directoryMessage(String leagueId) => switch (leagueId) {
      'rugby.289234' ||
      'fifa.friendly' ||
      'fifa.friendly.w' =>
        'International fixtures have no single league table · select teams to follow',
      'rugby.268565' =>
        'Tour fixtures have no league table · select teams to follow',
      'uefa.champions_qual' ||
      'uefa.super_cup' ||
      'eng.fa' ||
      'eng.league_cup' ||
      'ger.dfb_pokal' ||
      'esp.copa_del_rey' ||
      'ita.coppa_italia' ||
      'esp.super_cup' ||
      'ita.super_cup' ||
      'fra.coupe_de_france' ||
      'concacaf.champions' ||
      'usa.open' ||
      'ned.cup' ||
      'eng.w.fa' ||
      'ksa.kings.cup' ||
      'sco.tennents' =>
        'Knockout competition · no league table · select teams to follow',
      _ => 'Team directory · standings unavailable · select teams to follow',
    };
final _sports = sportsStandingsLeagues.map(_sport).toSet().toList()
  ..sort((a, b) => sportLabel(a).compareTo(sportLabel(b)));

/// Optional browsing: selector changes are local until a league is confirmed.
/// Images come from the loaded response, never from per-team metadata requests.
class SportsTeamsScreen extends StatefulWidget {
  const SportsTeamsScreen(
      {super.key,
      required this.follows,
      this.initialLeague,
      this.favorites = false,
      this.service,
      this.detailsService,
      this.embedded = false,
      this.panel = false,
      this.browseState,
      this.entryFocusNode,
      this.searchFocusNode,
      this.layoutBuilder,
      this.keyboardOpen,
      this.onTeamDetails,
      this.onLeagueChanged,
      this.onFocusToolbar});
  final SportsFollows follows;
  final SportsLeague? initialLeague;
  final bool favorites;
  final ValueChanged<SportsLeague>? onLeagueChanged;
  final SportsStandingsService? service;
  final SportsDetailsService? detailsService;
  final bool embedded, panel;
  final SportsStandingsBrowseState? browseState;
  final FocusNode? entryFocusNode, searchFocusNode;
  final Widget Function(Widget filters, Widget actions, Widget content)?
      layoutBuilder;
  final bool? keyboardOpen;
  final VoidCallback? onFocusToolbar;
  final void Function(SportsLeague league, StandingTeam row)? onTeamDetails;
  @override
  State<SportsTeamsScreen> createState() => _SportsTeamsScreenState();
}

typedef _BrowsePosition = ({
  String query,
  String? group,
  bool onlyFavourites,
  double offset
});

/// Retains only browsing choices while the pane is closed. No hidden widget
/// tree, scroll layout, image listeners or polling is kept alive.
class SportsStandingsBrowseState {
  String? _leagueId;
  final _positions = <String, _BrowsePosition>{};
}

class _SportsTeamsScreenState extends State<SportsTeamsScreen> {
  late final _service = widget.service ?? SportsStandingsService.instance;
  late SportsLeague _league = sportsStandingsLeagues
          .where((l) =>
              l.id ==
              (widget.initialLeague?.id ??
                  widget.browseState?._leagueId ??
                  _service.lastLeagueId))
          .firstOrNull ??
      sportsStandingsLeagues.first;
  LeagueStandings? _data;
  bool _loading = false, _onlyFavourites = false, _navigating = false;
  bool _openingLeague = false;
  int _followsRevision = 0;
  Timer? _favouriteFocusTimer;
  final _favouriteSelection = ValueNotifier<FollowedTeam?>(null);
  final _favouriteDetailsRevision = ValueNotifier<int>(0);
  late final _favouriteChanges =
      Listenable.merge([_favouriteSelection, _favouriteDetailsRevision]);
  FollowedTeam? get _selectedFavourite => _favouriteSelection.value;
  FollowedTeam? _pendingFavourite;
  final _favouriteRows = <String, StandingTeam>{};
  bool _resolvingFavourites = false, _favouriteDetailsLoading = false;
  FollowedTeam? _detailsFavourite;
  SportsDetails? _favouriteDetails;
  late final _detailsService =
      widget.detailsService ?? SportsDetailsService.instance;

  void _selectFavourite(FollowedTeam entry) {
    _favouriteSelection.value = entry;
    unawaited(_loadFavouriteDetails());
  }

  // Rapid remote movement keeps only the latest target behind one request.
  // Removed/closed selections cannot update the visible pane or enqueue work.
  Future<void> _loadFavouriteDetails() async {
    if (_favouriteDetailsLoading) return;
    _favouriteDetailsLoading = true;
    try {
      while (mounted) {
        final entry = _selectedFavourite;
        if (entry == null ||
            entry == _detailsFavourite ||
            !widget.follows.isFollowed(entry.leagueId, entry.teamId)) {
          return;
        }
        final league = sportsLeagueById(entry.leagueId);
        if (league == null) return;
        if (league.source != 'ESPN' && !_favouriteRows.containsKey(entry.key)) {
          final standings =
              await _service.load(league, rememberSelection: false);
          if (!mounted) return;
          final rows = standings.tables.expand((t) => t.rows);
          for (final row in rows) {
            if (widget.follows.isFollowed(league.id, row.team.id)) {
              _favouriteRows[FollowedTeam(league.id, row.team.id).key] = row;
            }
          }
          await widget.follows
              .rememberTeams(league.id, rows.map((r) => r.team))
              .catchError((Object _) {});
          if (!mounted) return;
          if (entry != _selectedFavourite) continue;
        }
        final data =
            await _detailsService.team(league, _favouriteRow(entry).team);
        if (!mounted) return;
        await _rememberFavouriteName(entry, data);
        if (!mounted) return;
        if (entry == _selectedFavourite) {
          _detailsFavourite = entry;
          _favouriteDetails = data;
          _favouriteDetailsRevision.value++;
          return;
        }
      }
    } finally {
      _favouriteDetailsLoading = false;
    }
  }

  Future<void> _rememberFavouriteName(
      FollowedTeam entry, SportsDetails data) async {
    if (widget.follows.nameOf(entry) != null ||
        data.failed ||
        data.unsupported ||
        data.title.isEmpty ||
        data.title == _favouriteRow(entry).team.name) {
      return;
    }
    await widget.follows.rememberTeams(entry.leagueId, [
      SportsTeam(
          id: entry.teamId,
          name: data.title,
          shortName: data.title,
          abbreviation: '',
          logoUrl: widget.follows.logoOf(entry))
    ]).catchError((Object _) {});
    if (mounted) setState(() {});
  }

  // Older follows stored IDs only. Resolve one league at a time while this
  // screen is open, and persist identities without altering follow order.
  Future<void> _resolveFavourites({bool refresh = false}) async {
    if (_resolvingFavourites) return;
    _resolvingFavourites = true;
    try {
      final leagues = widget.follows.teams
          .where((t) => widget.follows.nameOf(t) == null)
          .map((t) => t.leagueId)
          .toSet();
      for (final id in leagues) {
        if (!mounted) return;
        final league = sportsLeagueById(id);
        if (league == null) continue;
        final data = await _service.load(league,
            refresh: refresh, rememberSelection: false);
        if (!mounted) return;
        final rows = data.tables.expand((t) => t.rows);
        for (final row in rows) {
          if (widget.follows.isFollowed(id, row.team.id)) {
            _favouriteRows[FollowedTeam(id, row.team.id).key] = row;
          }
        }
        await widget.follows.rememberTeams(id, rows.map((r) => r.team));
        if (!mounted) return;
        setState(() {});
        // A club can still be followed after relegation or elimination. The
        // league directory supplies identity only, never a fabricated rank.
        if (!data.failed &&
            !data.directory &&
            league.source == 'ESPN' &&
            league.kind == SportsKind.team &&
            widget.follows.teams.any(
                (t) => t.leagueId == id && widget.follows.nameOf(t) == null)) {
          final directory =
              await _service.teamDirectory(league, refresh: refresh);
          if (!mounted) return;
          final directoryRows = directory.tables.expand((t) => t.rows);
          for (final row in directoryRows) {
            if (widget.follows.isFollowed(id, row.team.id)) {
              _favouriteRows.putIfAbsent(
                  FollowedTeam(id, row.team.id).key, () => row);
            }
          }
          await widget.follows
              .rememberTeams(id, directoryRows.map((r) => r.team));
          if (mounted) setState(() {});
        }
      }
    } catch (error) {
      debugPrint('Favourite identity refresh failed: ${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _resolvingFavourites = false);
    }
  }

  StandingTeam _favouriteRow(FollowedTeam entry) =>
      _favouriteRows[entry.key] ??
      StandingTeam(
          SportsTeam(
              id: entry.teamId,
              name: widget.follows.nameOf(entry) ?? 'Team ${entry.teamId}',
              shortName: widget.follows.nameOf(entry) ?? '',
              abbreviation: '',
              logoUrl: widget.follows.logoOf(entry)),
          const {},
          null);

  void _focusFavourite(FollowedTeam entry) {
    _favouriteFocusTimer?.cancel();
    if (_selectedFavourite == entry) return;
    _pendingFavourite = entry;
    _favouriteFocusTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent != false &&
          widget.follows.isFollowed(entry.leagueId, entry.teamId)) {
        _selectFavourite(entry);
      }
    });
  }

  void _openFavourite(FollowedTeam entry, {required bool wide}) {
    _favouriteFocusTimer?.cancel();
    final league = sportsLeagueById(entry.leagueId);
    if (league == null) return;
    if (wide) {
      _selectFavourite(entry);
    } else {
      showSportsTeamDetails(context, league, _favouriteRow(entry),
          service: widget.detailsService, onLoaded: (data) {
        unawaited(_rememberFavouriteName(entry, data));
      });
    }
  }

  int _generation = 0, _matches = 0;
  String? _group, _favouriteSport;
  String? _driversGroup, _constructorsGroup;
  String _allGroupsLabel = 'All groups', _chooseGroupLabel = 'Choose group';
  final _statsByGroup = <String, Set<String>>{};
  final _searchLabels = <StandingTeam, String>{};
  Set<String> _allStats = const {};
  final _saving = <String>{};
  final _search = TextEditingController();
  late final _searchFocus =
      widget.searchFocusNode ?? FocusNode(debugLabel: 'standings-search');
  late final _leagueFocus =
      widget.entryFocusNode ?? FocusNode(debugLabel: 'standings-league');
  final _sportFocus = FocusNode(debugLabel: 'standings-sport');
  double _scrollOffset = 0;
  final _scroll = ScrollController();
  late final _positions =
      widget.browseState?._positions ?? <String, _BrowsePosition>{};
  List<({String key, String? heading, StandingTeam? row})> _rows = [];
  final _rowIndices = <String, int>{};
  Set<String> _availableStats = const {};
  String _query = '';
  bool get _keyboardOpen =>
      widget.keyboardOpen ?? MediaQuery.viewInsetsOf(context).bottom > 0;
  bool get _individual => _league.kind != SportsKind.team;
  bool get _racingGroups => _driversGroup != null && _constructorsGroup != null;
  bool get _constructors => _racingGroups && _group == _constructorsGroup;
  bool get _riders => const {'racing.motogp', 'racing.moto2', 'racing.moto3'}
      .contains(_league.id);
  String get _entryName => _constructors
      ? 'constructors'
      : _sport(_league) == 'racing'
          ? (_riders ? 'riders' : 'drivers')
          : _individual
              ? 'competitors'
              : 'teams';
  String get _columnName => _constructors
      ? 'Constructor'
      : _sport(_league) == 'racing'
          ? (_riders ? 'Rider' : 'Driver')
          : _individual
              ? 'Competitor'
              : 'Team';
  @override
  void initState() {
    super.initState();
    _followsRevision = widget.follows.revision;
    _scroll.addListener(() => _scrollOffset = _scroll.offset);
    if (widget.favorites) unawaited(_resolveFavourites());
    if (!widget.favorites) {
      final saved = _positions[_league.id];
      if (saved != null) {
        _search.text = saved.query;
        _query = saved.query.trim().toLowerCase();
        _group = saved.group;
        _onlyFavourites = saved.onlyFavourites;
      }
      unawaited(_load(restoreOffset: saved?.offset));
    }
  }

  @override
  void didUpdateWidget(SportsTeamsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.follows != widget.follows ||
        _followsRevision != widget.follows.revision) {
      _followsRevision = widget.follows.revision;
      _filter();
    }
  }

  @override
  void dispose() {
    if (widget.browseState case final state?) {
      state._leagueId = _league.id;
      _positions[_league.id] = (
        query: _search.text,
        group: _group,
        onlyFavourites: _onlyFavourites,
        offset: _scrollOffset
      );
    }
    _favouriteFocusTimer?.cancel();
    _favouriteSelection.dispose();
    _favouriteDetailsRevision.dispose();
    _search.dispose();
    if (widget.searchFocusNode == null) _searchFocus.dispose();
    if (widget.entryFocusNode == null) _leagueFocus.dispose();
    _sportFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false, double? restoreOffset}) async {
    final token = ++_generation, league = _league;
    setState(() => _loading = true);
    final data = await _service.load(league, refresh: refresh);
    if (!mounted || token != _generation) return;
    setState(() {
      _data = data;
      _loading = false;
      _statsByGroup.clear();
      _searchLabels.clear();
      for (final table in data.tables) {
        final stats = _statsByGroup[table.name] ??= {};
        for (final row in table.rows) {
          stats.addAll(row.stats.keys);
          _searchLabels[row] =
              '${row.team.name} ${row.team.shortName} ${row.team.abbreviation} ${row.nameAliases.join(' ')}'
                  .toLowerCase();
        }
      }
      _allStats = _statsByGroup.values.expand((keys) => keys).toSet();
      _driversGroup = _constructorsGroup = null;
      if (_league.id == 'racing.f1') {
        _driversGroup = data.tables
            .where((t) => t.name.toLowerCase().contains('driver'))
            .firstOrNull
            ?.name;
        _constructorsGroup = data.tables
            .where((t) => t.name.toLowerCase().contains('constructor'))
            .firstOrNull
            ?.name;
      }
      final names = data.tables.map((t) => t.name.toLowerCase());
      final kind = names.isNotEmpty &&
              names.every((n) => n.contains('conference'))
          ? 'conference'
          : names.isNotEmpty && names.every((n) => n.contains('division'))
              ? 'division'
              : names.isNotEmpty && names.every((n) => n.startsWith('pool '))
                  ? 'pool'
                  : 'group';
      _allGroupsLabel = 'All ${kind}s';
      _chooseGroupLabel = 'Choose $kind';
      if (_group != null && !data.tables.any((t) => t.name == _group)) {
        _group = null;
      }
      if (_racingGroups) _group ??= _driversGroup;
      _filter();
    });
    if (restoreOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && token == _generation && _scroll.hasClients) {
          _scroll
              .jumpTo(restoreOffset.clamp(0, _scroll.position.maxScrollExtent));
        }
      });
    }
    try {
      await widget.follows.rememberTeams(
          league.id, data.tables.expand((t) => t.rows.map((r) => r.team)));
    } catch (_) {}
  }

  void _filter() {
    _availableStats =
        _group == null ? _allStats : _statsByGroup[_group] ?? const {};
    final terms =
        _query.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    _rows = [];
    _matches = 0;
    _rowIndices.clear();
    for (final (index, table) in (_data?.tables ?? <StandingTable>[]).indexed) {
      if (_group != null && table.name != _group) continue;
      final matches = table.rows.where((r) {
        final label = _searchLabels[r] ?? '';
        return terms.every(label.contains) &&
            (!_onlyFavourites ||
                widget.follows.isFollowed(_league.id, r.team.id));
      }).toList();
      if (matches.isEmpty) continue;
      if (_group == null && (_data?.tables.length ?? 0) > 1) {
        _rows.add((key: 'heading-$index', heading: table.name, row: null));
      }
      for (final row in matches) {
        _rows.add((key: '$index|${row.team.id}', heading: null, row: row));
      }
      _matches += matches.length;
    }
    for (var i = 0; i < _rows.length; i++) {
      _rowIndices[_rows[i].key] = i;
    }
  }

  void _changeFilter(VoidCallback change) {
    setState(() {
      change();
      _filter();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _clearFilters() => _changeFilter(() {
        _query = '';
        _search.clear();
        _group = _racingGroups ? (_group ?? _driversGroup) : null;
        _onlyFavourites = false;
        _favouriteSport = null;
      });

  Future<SportsLeague?> _chooseLeague({String? sport}) async {
    final id = await showSportsFilterPicker(context,
        title: sport == null ? 'Choose league' : '${sportLabel(sport)} leagues',
        selected:
            widget.favorites ? (widget.initialLeague?.id ?? '') : _league.id,
        initialGroup: widget.favorites && _favouriteSport != null
            ? sportLabel(_favouriteSport!)
            : null,
        topFirst: true,
        showSortingControls: sport == null,
        options: [
          for (final l in sportsStandingsLeagues)
            if (sport == null || _sport(l) == sport)
              SportsFilterOption(l.id, l.name, sportIcon(_sport(l)),
                  group: sport == null ? sportLabel(_sport(l)) : null,
                  description: leagueDescription(l),
                  priority: leagueDisplayPriority(l))
        ]);
    return id == null ? null : sportsLeagueById(id);
  }

  Future<void> _pick({bool sportFirst = false}) async {
    if (_navigating) return;
    _navigating = true;
    try {
      String? sport = widget.favorites ? null : _sport(_league);
      if (sportFirst) {
        sport = await showSportsFilterPicker(context,
            title: 'Choose sport',
            selected: sport ?? '',
            options: [
              for (final s in _sports)
                SportsFilterOption(s, sportLabel(s), sportIcon(s))
            ]);
        if (!mounted || sport == null) return;
      }
      final league = await _chooseLeague(sport: sport);
      if (!mounted || league == null) return;
      if (widget.favorites) {
        await _openLeague(league);
      } else if (_league.id != league.id) {
        _positions.remove(_league.id);
        _positions[_league.id] = (
          query: _search.text,
          group: _group,
          onlyFavourites: _onlyFavourites,
          offset: _scroll.hasClients ? _scroll.offset : 0
        );
        while (_positions.length > 12) {
          _positions.remove(_positions.keys.first);
        }
        final previous = _positions[league.id];
        setState(() {
          _league = league;
          _data = null;
          _driversGroup = _constructorsGroup = null;
          _rows = [];
          _rowIndices.clear();
          _search.text = previous?.query ?? '';
          _query = _search.text.trim().toLowerCase();
          _group = previous?.group;
          _onlyFavourites = previous?.onlyFavourites ?? false;
        });
        widget.onLeagueChanged?.call(league);
        if (_scroll.hasClients) _scroll.jumpTo(0);
        unawaited(_load(restoreOffset: previous?.offset));
      }
    } finally {
      _navigating = false;
    }
  }

  Future<void> _openLeague(SportsLeague league) async {
    if (_openingLeague) return;
    _openingLeague = true;
    try {
      await showSportsPanel<void>(
          context: context,
          builder: (_) => SportsTeamsScreen(
              follows: widget.follows,
              panel: true,
              initialLeague: league,
              service: _service));
      if (mounted) {
        setState(() {});
        unawaited(_resolveFavourites());
      }
    } finally {
      _openingLeague = false;
    }
  }

  Future<void> _pickGroup() async {
    final groups = _data?.tables.map((t) => t.name).toSet() ?? <String>{};
    final selected = await showSportsFilterPicker(context,
        title: _chooseGroupLabel,
        selected: _group ?? '',
        options: [
          SportsFilterOption('', _allGroupsLabel, Icons.view_list),
          for (final name in groups)
            SportsFilterOption(name, name, Icons.table_chart_outlined),
        ]);
    if (mounted && selected != null) {
      _changeFilter(() => _group = selected.isEmpty ? null : selected);
    }
  }

  Future<void> _pickFavouriteSport() async {
    final sports = {
      for (final t in widget.follows.teams)
        if (sportsLeagueById(t.leagueId) case final league?) _sport(league)
    };
    final selected = await showSportsFilterPicker(context,
        title: 'Filter favourites',
        selected: _favouriteSport ?? '',
        options: [
          const SportsFilterOption('', 'All sports', Icons.sports),
          for (final sport in _sports.where(sports.contains))
            SportsFilterOption(sport, sportLabel(sport), sportIcon(sport)),
        ]);
    if (mounted && selected != null) {
      _changeFilter(() => _favouriteSport = selected.isEmpty ? null : selected);
    }
  }

  Future<void> _toggle(String league, SportsTeam team) async {
    final key = FollowedTeam(league, team.id);
    if (!_saving.add(key.key)) return;
    final removing = widget.follows.isFollowed(league, team.id);
    final position = widget.follows.teams.indexOf(key);
    final savedName = widget.follows.nameOf(key);
    final focused = FocusManager.instance.primaryFocus;
    setState(() {});
    try {
      if (removing) {
        await widget.follows.unfollow(league, team.id);
        // Move before removing the focused row; keep the user's current focus
        // if they navigated elsewhere while the save was in flight.
        if (mounted &&
            (widget.favorites || _onlyFavourites) &&
            focused?.hasFocus == true) {
          focused!.nextFocus();
        }
      } else {
        await widget.follows
            .follow(league, team.id, name: team.name, logoUrl: team.logoUrl);
      }
      if (mounted && widget.favorites && removing) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(
            content: Text('Removed ${team.name}'),
            action: SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  try {
                    await widget.follows.follow(league, team.id,
                        name: widget.favorites ? savedName : team.name,
                        logoUrl: team.logoUrl,
                        atIndex: position);
                  } catch (_) {
                    if (mounted) _saveError();
                  }
                  if (mounted) setState(() {});
                })));
      }
    } catch (_) {
      if (mounted) _saveError();
    } finally {
      _saving.remove(key.key);
      if (mounted) {
        setState(() {
          _filter();
        });
      }
    }
  }

  void _saveError() =>
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save favourite. Please try again.')));

  bool get _television => context.read<AppPreferences?>()?.isTelevision == true;

  bool get _compactTvControls =>
      _television && MediaQuery.textScalerOf(context).scale(13) <= 17;

  bool get _compactBrowseControls =>
      _compactTvControls || compactSportsControls(context);
  double get _browseControlHeight =>
      _compactTvControls ? 34 : sportsTouchControlHeight(context);

  Widget _searchField({bool compact = false, bool inline = false}) => Padding(
      padding:
          inline ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: TvTextFieldGate(
          focusNode: _searchFocus,
          builder: (context, readOnly) => TextField(
                key: const ValueKey('standings-search'),
                controller: _search,
                focusNode: _searchFocus,
                readOnly: readOnly,
                style: compact ? const TextStyle(fontSize: 12) : null,
                decoration: InputDecoration(
                    filled: inline,
                    fillColor: inline
                        ? Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: .25)
                        : null,
                    enabledBorder: inline
                        ? OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: .35)))
                        : null,
                    focusedBorder: inline
                        ? OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary))
                        : null,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: compact
                            ? (_compactTvControls
                                ? 6
                                : compactSportsControls(context)
                                    ? 8
                                    : 14)
                            : 13),
                    prefixIconConstraints: compact
                        ? BoxConstraints(
                            minWidth: _browseControlHeight,
                            minHeight: _browseControlHeight)
                        : null,
                    suffixIconConstraints: compact && _compactBrowseControls
                        ? BoxConstraints.tightFor(
                            width: _browseControlHeight,
                            height: _browseControlHeight)
                        : null,
                    hintText: inline
                        ? widget.favorites
                            ? 'Search favourites'
                            : 'Search $_entryName'
                        : null,
                    labelText: inline
                        ? null
                        : widget.favorites
                            ? 'Search favourites'
                            : 'Search $_entryName',
                    prefixIcon: Icon(Icons.search, size: compact ? 18 : 24),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            padding: compact && _compactBrowseControls
                                ? EdgeInsets.zero
                                : null,
                            style: compact && _compactBrowseControls
                                ? IconButton.styleFrom(
                                    minimumSize: Size(_browseControlHeight,
                                        _browseControlHeight),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap)
                                : null,
                            icon: Icon(Icons.clear, size: compact ? 18 : 24),
                            onPressed: () => _changeFilter(() {
                                  _search.clear();
                                  _query = '';
                                }))),
                onChanged: (text) =>
                    _changeFilter(() => _query = text.trim().toLowerCase()),
              )));
  Widget _empty(String title, {bool clear = false}) => Center(
      child: SingleChildScrollView(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(title, textAlign: TextAlign.center),
                if (clear)
                  TextButton(
                      onPressed: _clearFilters,
                      child: const Text('Clear filters')),
                if (_data?.failed == true && !clear)
                  TextButton(
                      onPressed: _loading ? null : () => _load(refresh: true),
                      child: const Text('Retry')),
              ]))));

  Widget _favorites({required bool wide}) {
    final terms =
        _query.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final teams = widget.follows.teams.where((t) {
      final league = sportsLeagueById(t.leagueId);
      final label =
          '${widget.follows.nameOf(t) ?? t.teamId} ${league?.name ?? ''} ${league?.shortName ?? ''}'
              .toLowerCase();
      return terms.every(label.contains) &&
          (_favouriteSport == null ||
              league != null && _sport(league) == _favouriteSport);
    }).toList();
    final indices = {for (var i = 0; i < teams.length; i++) teams[i].key: i};
    return Column(children: [
      if (!_keyboardOpen)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(children: [
              Expanded(
                  child: TextButton.icon(
                      key: const ValueKey('add-team'),
                      style: sportsPopupButtonStyle(context).copyWith(
                          backgroundColor: WidgetStatePropertyAll(
                              Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: .10))),
                      autofocus: true,
                      onPressed: _pick,
                      icon: const Icon(Icons.add, size: 17),
                      label: const Text('Add favourite',
                          style: TextStyle(fontSize: 11.5)))),
              const SizedBox(width: 6),
              Expanded(
                  child: SportsFilterButton(
                      key: const ValueKey('favourites-sport'),
                      caption: 'Sport',
                      value: _favouriteSport == null
                          ? 'All sports'
                          : sportLabel(_favouriteSport!),
                      onTap: _pickFavouriteSport)),
              if (widget.follows.teams
                  .any((t) => widget.follows.nameOf(t) == null))
                IconButton(
                    tooltip: _resolvingFavourites
                        ? 'Loading team names'
                        : 'Retry team names',
                    onPressed: _resolvingFavourites
                        ? null
                        : () {
                            setState(() {});
                            unawaited(_resolveFavourites(refresh: true));
                          },
                    icon: _resolvingFavourites
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 18)),
            ])),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: _searchField(compact: true, inline: true)),
      if (!_keyboardOpen)
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 5),
            child: Row(children: [
              Expanded(
                  child: Text(
                      teams.length == widget.follows.teams.length
                          ? '${teams.length} saved'
                          : '${teams.length} of ${widget.follows.teams.length} shown',
                      style: TextStyle(
                          fontSize: 10.5,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant))),
              if (_television)
                Text('OK: details · →: remove',
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ])),
      Expanded(
          child: teams.isEmpty
              ? _empty(
                  widget.follows.isEmpty
                      ? 'Add a team or athlete to follow them in Sports.'
                      : 'No favourites match these filters.',
                  clear: !widget.follows.isEmpty)
              : ListView.builder(
                  scrollCacheExtent: const ScrollCacheExtent.pixels(100),
                  controller: _scroll,
                  findChildIndexCallback: (key) =>
                      key is ObjectKey && key.value is FollowedTeam
                          ? indices[(key.value as FollowedTeam).key]
                          : null,
                  itemCount: teams.length,
                  itemBuilder: (context, index) {
                    final entry = teams[index],
                        league = sportsLeagueById(teams[index].leagueId);
                    final name =
                        widget.follows.nameOf(entry) ?? 'Team ${entry.teamId}';
                    final logo = widget.follows.logoOf(entry);
                    return SportsFavouriteTile(
                      key: ObjectKey(entry),
                      entry: entry,
                      striped: index.isOdd,
                      name: name,
                      league: league?.name ?? entry.leagueId,
                      logo: logo,
                      selection: _favouriteSelection,
                      onFocusChange: (focused) {
                        if (wide && focused) _focusFavourite(entry);
                        if (!focused && _pendingFavourite == entry) {
                          _favouriteFocusTimer?.cancel();
                        }
                      },
                      onTap: league == null
                          ? null
                          : () => _openFavourite(entry, wide: wide),
                      onRemove: () => _toggle(
                          entry.leagueId,
                          SportsTeam(
                              id: entry.teamId,
                              name: name,
                              shortName: name,
                              abbreviation: '',
                              logoUrl: logo)),
                    );
                  })),
    ]);
  }

  Widget _headerFilters() => Row(children: [
        Expanded(
            flex: 2,
            child: SportsFilterButton(
                key: const ValueKey('standings-sport'),
                caption: 'Sport',
                minimumHeight:
                    _television ? 0 : sportsTouchControlHeight(context),
                value: compactSportsPortrait(context)
                    ? shortSportLabel(_sport(_league))
                    : sportLabel(_sport(_league)),
                focusNode: _sportFocus,
                onTap: () => _pick(sportFirst: true))),
        const SizedBox(width: 6),
        Expanded(
            flex: 3,
            child: SportsFilterButton(
                key: const ValueKey('standings-league'),
                caption: 'League',
                minimumHeight:
                    _television ? 0 : sportsTouchControlHeight(context),
                value: compactSportsPortrait(context)
                    ? _league.shortName
                    : _league.name,
                focusNode: _leagueFocus,
                onTap: _pick)),
      ]);

  Widget _compactControls(double width, {required bool hasGroups}) {
    final colors = Theme.of(context).colorScheme;
    final singleRow =
        width >= 500 && MediaQuery.textScalerOf(context).scale(14) <= 18;
    final data = _data;
    final status = data == null ? 'Loading standings…' : _status(data);
    final favourite = IconButton(
        key: const ValueKey('standings-favourites-only'),
        tooltip: _onlyFavourites ? 'Show all $_entryName' : 'Favourites only',
        style: _compactBrowseControls
            ? IconButton.styleFrom(
                minimumSize: Size(_browseControlHeight, _browseControlHeight),
                maximumSize: Size(_browseControlHeight, _browseControlHeight),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap)
            : null,
        isSelected: _onlyFavourites,
        visualDensity:
            _television ? VisualDensity.compact : VisualDensity.standard,
        color: _onlyFavourites ? colors.primary : colors.onSurfaceVariant,
        onPressed: () =>
            _changeFilter(() => _onlyFavourites = !_onlyFavourites),
        icon: const Icon(Icons.star_border, size: 19),
        selectedIcon: const Icon(Icons.star, size: 19));
    final group = TextButton.icon(
        key: const ValueKey('standings-group'),
        style: TextButton.styleFrom(
            minimumSize: Size(0, _browseControlHeight),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: _compactBrowseControls
                ? MaterialTapTargetSize.shrinkWrap
                : null,
            foregroundColor:
                _group == null ? colors.onSurfaceVariant : colors.primary,
            animationDuration: Duration.zero),
        onPressed: _pickGroup,
        icon: const Icon(Icons.filter_list, size: 16),
        label: Text(_group ?? _allGroupsLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12)));
    return Padding(
        padding: EdgeInsets.fromLTRB(
            widget.layoutBuilder == null ? 10 : 0,
            compactSportsControls(context) ? 2 : 6,
            widget.layoutBuilder == null ? 10 : 0,
            4),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: singleRow && _compactTvControls
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 230),
                            child: _searchField(compact: true, inline: true)))
                    : _searchField(compact: true, inline: true)),
            if (singleRow &&
                !_keyboardOpen &&
                (_racingGroups || hasGroups)) ...[
              const SizedBox(width: 6),
              SizedBox(
                  width: _racingGroups ? 188 : 150,
                  child: _racingGroups ? _racingSelector() : group),
            ],
            if (!_keyboardOpen) favourite,
          ]),
          if (!singleRow && !_keyboardOpen && (_racingGroups || hasGroups))
            _racingGroups
                ? _racingSelector()
                : Align(alignment: Alignment.centerLeft, child: group),
          if (!_keyboardOpen)
            Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Tooltip(
                    message: '$_matches $_entryName · $status',
                    child: Text('$_matches $_entryName · $status',
                        key: const ValueKey('standings-status'),
                        maxLines:
                            singleRow || compactSportsControls(context) ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.3,
                            color: data?.failed == true
                                ? colors.error
                                : colors.onSurfaceVariant)))),
        ]));
  }

  String _status(LeagueStandings data) => data.failed
      ? (data.hasRows
          ? 'Refresh failed · showing saved data'
          : 'Could not load standings')
      : data.directory
          ? _directoryMessage(_league.id)
          : data.rankings
              ? '${data.rankingTitle ?? 'Rankings'} · ${data.sourceName ?? 'Official rankings'}${data.updatedAt == null ? '' : ' · ${DateFormat.yMMMd().format(data.updatedAt!)}'}'
              : data.previousSeason == true
                  ? 'Previous season: ${data.season} · current table unavailable${data.sourceName == null ? '' : ' · ${data.sourceName}'}'
                  : '${data.season != null ? 'Season ${data.season}' : data.updatedAt != null ? 'As of ${DateFormat.yMMMd().format(data.updatedAt!)}' : 'Season not supplied'}${data.sourceName == null ? '' : ' · ${data.sourceName}'}';

  Widget _racingSelector() => SegmentedButton<String>(
        showSelectedIcon: false,
        style: ButtonStyle(
            animationDuration: Duration.zero,
            visualDensity: _compactTvControls
                ? const VisualDensity(vertical: -1.5)
                : VisualDensity.standard,
            minimumSize: WidgetStatePropertyAll(Size(0, _browseControlHeight)),
            tapTargetSize: _compactBrowseControls
                ? MaterialTapTargetSize.shrinkWrap
                : null,
            padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 8)),
            shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
            textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 11.5))),
        segments: [
          ButtonSegment(
              value: _driversGroup!,
              label: const Text('Drivers',
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          ButtonSegment(
              value: _constructorsGroup!,
              label: const Text('Constructors',
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        selected: {_group ?? _driversGroup!},
        onSelectionChanged: (value) =>
            _changeFilter(() => _group = value.single),
      );

  Widget _browse(double width) {
    final data = _data;
    final groups = data?.tables.map((t) => t.name).toSet() ?? <String>{};
    return Column(children: [
      if (widget.layoutBuilder == null && !_keyboardOpen)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _headerFilters()),
      _compactControls(width, hasGroups: groups.length > 1),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(
          child: _rows.isEmpty
              ? _empty(
                  _loading
                      ? 'Loading standings…'
                      : _query.isNotEmpty || _onlyFavourites || _group != null
                          ? 'No matches. Try another group or clear the filters.'
                          : data?.failed == true
                              ? 'This league could not be loaded. You can retry or choose another league.'
                              : 'No standings are available for this league.',
                  clear: !_loading &&
                      (_query.isNotEmpty || _onlyFavourites || _group != null))
              : LayoutBuilder(builder: (context, constraints) {
                  final columnWidth = 46 *
                      (MediaQuery.textScalerOf(context).scale(14) / 14)
                          .clamp(1.0, 2.0);
                  final columns = visibleStandingsColumns(
                      _availableStats, constraints.maxWidth,
                      sport: _sport(_league),
                      leagueId: _league.id,
                      rankings: data!.rankings,
                      columnWidth: columnWidth);
                  return Column(children: [
                    if (!data.directory &&
                        constraints.maxHeight >=
                            MediaQuery.textScalerOf(context).scale(100))
                      StandingsTableHeader(
                          columns: columns,
                          columnWidth: columnWidth,
                          label: _columnName),
                    Expanded(
                        child: Focus(
                            canRequestFocus: false,
                            onKeyEvent: (_, event) {
                              if ((event is KeyDownEvent ||
                                      event is KeyRepeatEvent) &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.arrowUp) {
                                final tile = FocusManager
                                    .instance.primaryFocus?.context
                                    ?.findAncestorWidgetOfExactType<
                                        StandingsTeamTile>();
                                final first = _rows
                                    .where((item) => item.row != null)
                                    .firstOrNull
                                    ?.row;
                                if (tile != null &&
                                    identical(tile.row, first)) {
                                  _searchFocus.requestFocus();
                                  return KeyEventResult.handled;
                                }
                              }
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.arrowLeft &&
                                  FocusManager.instance.primaryFocus?.context
                                          ?.findAncestorWidgetOfExactType<
                                              IconButton>() ==
                                      null) {
                                _searchFocus.requestFocus();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: CallbackShortcuts(
                                bindings: {
                                  const SingleActivator(
                                          LogicalKeyboardKey.contextMenu):
                                      _leagueFocus.requestFocus,
                                  const SingleActivator(
                                      LogicalKeyboardKey.home): () {
                                    _scroll.jumpTo(0);
                                    _leagueFocus.requestFocus();
                                  }
                                },
                                child: ListView.builder(
                                    padding: EdgeInsets.zero,
                                    controller: _scroll,
                                    scrollCacheExtent: _television
                                        ? const ScrollCacheExtent.pixels(48)
                                        : null,
                                    itemCount: _rows.length,
                                    findChildIndexCallback: (key) =>
                                        key is ValueKey<String>
                                            ? _rowIndices[key.value]
                                            : null,
                                    itemBuilder: (context, index) {
                                      final item = _rows[index],
                                          row = _rows[index].row;
                                      if (row == null) {
                                        return Padding(
                                            key: ValueKey(item.key),
                                            padding: const EdgeInsets.fromLTRB(
                                                12, 7, 12, 3),
                                            child: Row(children: [
                                              Flexible(
                                                  child: Text(item.heading!,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .labelSmall
                                                          ?.copyWith(
                                                              color: Theme.of(
                                                                      context)
                                                                  .colorScheme
                                                                  .onSurfaceVariant))),
                                              const SizedBox(width: 12),
                                              const Expanded(
                                                  child: Divider(height: 1)),
                                            ]));
                                      }
                                      return StandingsTeamTile(
                                          key: ValueKey(item.key),
                                          row: row,
                                          alternate: index.isOdd,
                                          logoFallback: _racingGroups &&
                                                  _group == _constructorsGroup
                                              ? row.team.name
                                              : null,
                                          columns: columns,
                                          columnWidth: columnWidth,
                                          directory: data.directory,
                                          followed: widget.follows.isFollowed(
                                              _league.id, row.team.id),
                                          onToggle: () =>
                                              _toggle(_league.id, row.team),
                                          onDetails: () {
                                            if (_league.kind !=
                                                SportsKind.team) {
                                              showStandingRecord(context, row,
                                                  sport: _sport(_league),
                                                  rankings: data.rankings,
                                                  rankingTitle:
                                                      data.rankingTitle);
                                            } else if (widget.onTeamDetails !=
                                                null) {
                                              widget.onTeamDetails!(
                                                  _league, row);
                                            } else {
                                              showSportsTeamDetails(
                                                  context, _league, row);
                                            }
                                          });
                                    })))),
                  ]);
                })),
    ]);
  }

  List<Widget> _actions() => [
        if (widget.layoutBuilder == null)
          IconButton(
              constraints: _television && widget.layoutBuilder != null
                  ? const BoxConstraints.tightFor(width: 34, height: 34)
                  : null,
              padding: _television && widget.layoutBuilder != null
                  ? EdgeInsets.zero
                  : null,
              iconSize: 20,
              tooltip: 'Sports favourites',
              icon: const Icon(Icons.star_border),
              onPressed: () async {
                if (_navigating) return;
                _navigating = true;
                try {
                  await showSportsPanel<void>(
                      context: context,
                      besidePreview: true,
                      builder: (_) => SportsTeamsScreen(
                          follows: widget.follows,
                          favorites: true,
                          panel: true,
                          service: _service));
                  if (mounted) setState(() => _filter());
                } finally {
                  _navigating = false;
                }
              }),
        IconButton(
            constraints: _television && widget.layoutBuilder != null
                ? const BoxConstraints.tightFor(width: 34, height: 34)
                : null,
            padding: _television && widget.layoutBuilder != null
                ? EdgeInsets.zero
                : null,
            iconSize: 20,
            style: _television && widget.layoutBuilder != null
                ? IconButton.styleFrom(
                    minimumSize: const Size(34, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap)
                : null,
            tooltip: 'Refresh standings',
            onPressed: _loading ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh)),
      ];

  Widget _favouriteDetailPane() {
    final selected = _selectedFavourite;
    final league =
        selected == null ? null : sportsLeagueById(selected.leagueId);
    if (selected == null ||
        league == null ||
        !widget.follows.isFollowed(selected.leagueId, selected.teamId)) {
      return const Center(
          child: Text('Select a favourite to see team details.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12)));
    }
    final row = _favouriteRow(selected);
    if (_detailsFavourite != selected) {
      return Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SportsPopupHeader(
                title: row.team.name,
                description: league.name,
                showClose: false),
            const LinearProgressIndicator(minHeight: 2),
            const Expanded(
                child: Center(
                    child: Text('Loading team details…',
                        style: TextStyle(fontSize: 12)))),
          ]));
    }
    return SportsDetailsPanel(
        key: ValueKey('favourite-details:${selected.key}'),
        embedded: true,
        initialData: _favouriteDetails,
        league: league,
        team: row.team,
        standing: row,
        service: widget.detailsService,
        hideScores:
            context.read<StorageService?>()?.getSportsHideScores() ?? false);
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.favorites
        ? LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth >= 700;
            final list = _favorites(wide: wide);
            if (!wide) return list;
            return Row(children: [
              Expanded(
                  flex: 5,
                  child: RepaintBoundary(
                      child: ListenableBuilder(
                          listenable: _favouriteChanges,
                          builder: (context, _) => _favouriteDetailPane()))),
              const VerticalDivider(width: 1),
              Expanded(flex: 4, child: list),
            ]);
          })
        : LayoutBuilder(
            builder: (context, constraints) => _browse(constraints.maxWidth));
    if (widget.embedded || widget.layoutBuilder != null) {
      content = Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.arrowUp &&
                (widget.layoutBuilder != null
                    ? _searchFocus.hasFocus
                    : (_leagueFocus.hasFocus || _sportFocus.hasFocus)) &&
                widget.onFocusToolbar != null) {
              if (widget.layoutBuilder != null) {
                _leagueFocus.requestFocus();
              } else {
                widget.onFocusToolbar!();
              }
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: content);
      if (widget.layoutBuilder case final builder?) {
        return builder(_headerFilters(),
            Row(mainAxisSize: MainAxisSize.min, children: _actions()), content);
      }
      return content;
    }
    if (widget.panel) {
      return Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 2),
            child: Row(children: [
              Expanded(
                  child: SportsPopupHeader(
                      title:
                          widget.favorites ? 'Sports favourites' : 'Standings',
                      description: widget.favorites
                          ? 'Teams and athletes you follow'
                          : null,
                      showClose: false)),
              if (!widget.favorites) ..._actions(),
              IconButton(
                  tooltip: 'Close',
                  onPressed: () => popRouteIfCurrent(context),
                  icon: const Icon(Icons.close, size: 18)),
            ])),
        Expanded(child: content),
      ]);
    }
    return SettingsScaffold(
        title: widget.favorites ? 'Sports favourites' : 'Standings',
        actions: widget.favorites ? null : _actions(),
        body: content);
  }
}
