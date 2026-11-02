import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import '../widgets/sports_header_controls.dart';
import '../models/sports.dart';
import '../services/sports_follows.dart';
import '../services/sports_standings_service.dart';
import '../utils/sports_presentation.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/sports_panel.dart';
import '../widgets/sports_details_panel.dart';
import '../widgets/sports_filter_picker.dart';
import '../widgets/sports_widgets.dart';
import '../widgets/standings_team_tile.dart';
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
    _scroll.addListener(() => _scrollOffset = _scroll.offset);
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
        selected: _league.id,
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
      if (mounted) setState(() {});
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
                        name: team.name,
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
      _compactTvControls || compactSportsPortrait(context);
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
                                : compactSportsPortrait(context)
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
                    hintText: inline ? 'Search $_entryName' : null,
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

  Widget _favorites() {
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
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Expanded(
                  child: FilledButton.icon(
                      key: const ValueKey('add-team'),
                      autofocus: true,
                      onPressed: _pick,
                      icon: const Icon(Icons.add),
                      label: const Text('Add favourite'))),
              const SizedBox(width: 8),
              IconButton(
                  tooltip: _favouriteSport == null
                      ? 'Filter by sport'
                      : sportLabel(_favouriteSport!),
                  isSelected: _favouriteSport != null,
                  onPressed: _pickFavouriteSport,
                  icon: const Icon(Icons.filter_list)),
            ])),
      _searchField(),
      Expanded(
          child: teams.isEmpty
              ? _empty(
                  widget.follows.isEmpty
                      ? 'Add a team or athlete to follow them in Sports.'
                      : 'No favourites match these filters.',
                  clear: !widget.follows.isEmpty)
              : ListView.builder(
                  controller: _scroll,
                  findChildIndexCallback: (key) =>
                      key is ValueKey<String> ? indices[key.value] : null,
                  itemCount: teams.length,
                  itemBuilder: (context, index) {
                    final entry = teams[index],
                        league = sportsLeagueById(teams[index].leagueId);
                    final name =
                        widget.follows.nameOf(entry) ?? 'Team ${entry.teamId}';
                    final logo = widget.follows.logoOf(entry);
                    return ListTile(
                      key: ValueKey(entry.key),
                      leading: SportsLogo(
                          url: logo, size: 36, fallback: name, animate: false),
                      title: Text(name,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(league?.name ?? entry.leagueId),
                      onTap: league == null ? null : () => _openLeague(league),
                      trailing: IconButton(
                          tooltip: 'Remove favourite',
                          icon: const Icon(Icons.star),
                          onPressed: () => _toggle(
                              entry.leagueId,
                              SportsTeam(
                                  id: entry.teamId,
                                  name: name,
                                  shortName: name,
                                  abbreviation: '',
                                  logoUrl: logo))),
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
            compactSportsPortrait(context) ? 2 : 6,
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
                            singleRow || compactSportsPortrait(context) ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.3,
                            color: data?.failed == true
                                ? colors.error
                                : colors.onSurfaceVariant)))),
        ]));
  }

  Widget _selectors() {
    final colors = Theme.of(context).colorScheme;
    final style = OutlinedButton.styleFrom(
      foregroundColor: colors.onSurface,
      backgroundColor: colors.surfaceContainerHighest.withValues(alpha: .35),
      side: BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      minimumSize: const Size(0, 40),
      animationDuration: Duration.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Expanded(
              flex: 2,
              child: OutlinedButton(
                  key: const ValueKey('standings-sport'),
                  focusNode: _sportFocus,
                  style: style,
                  onPressed: () => _pick(sportFirst: true),
                  child: Row(children: [
                    Icon(sportIcon(_sport(_league)), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(sportLabel(_sport(_league)),
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const Icon(Icons.expand_more, size: 18),
                  ]))),
          const SizedBox(width: 8),
          Expanded(
              flex: 4,
              child: OutlinedButton(
                  key: const ValueKey('standings-league'),
                  focusNode: _leagueFocus,
                  style: style,
                  onPressed: _pick,
                  child: Row(children: [
                    Expanded(
                        child: Text(_league.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600))),
                    const SizedBox(width: 4),
                    const Icon(Icons.expand_more, size: 18),
                  ]))),
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

  Widget _utilities({required bool wide, required bool hasGroups}) {
    final data = _data;
    final colors = Theme.of(context).colorScheme;
    final count =
        '$_matches ${data?.rankings == true ? 'available teams' : _entryName}';
    final status = data == null ? count : _status(data);
    final metadata = Tooltip(
        message: '$count · $status',
        child: Text(status,
            key: const ValueKey('standings-status'),
            maxLines: wide ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: data?.failed == true
                    ? colors.error
                    : colors.onSurfaceVariant)));
    final favourite = FilterChip(
        key: const ValueKey('standings-favourites-only'),
        label: const Text('Favourites'),
        avatar: const Icon(Icons.star_border, size: 18),
        selected: _onlyFavourites,
        onSelected: (v) => _changeFilter(() => _onlyFavourites = v));
    final group = TextButton.icon(
        key: const ValueKey('standings-group'),
        style: TextButton.styleFrom(
            foregroundColor:
                _group == null ? colors.onSurfaceVariant : colors.primary,
            animationDuration: Duration.zero),
        onPressed: _pickGroup,
        icon: const Icon(Icons.filter_list, size: 18),
        label: Text(_group ?? _allGroupsLabel,
            maxLines: 1, overflow: TextOverflow.ellipsis));
    return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: wide
            ? Row(children: [
                Expanded(child: metadata),
                const SizedBox(width: 12),
                if (_racingGroups) ...[
                  SizedBox(width: 246, child: _racingSelector()),
                  const SizedBox(width: 12),
                ] else if (hasGroups) ...[
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 210),
                      child: group),
                  const SizedBox(width: 8),
                ],
                favourite,
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_racingGroups) _racingSelector(),
                Row(children: [
                  Expanded(
                      child: hasGroups && !_racingGroups
                          ? group
                          : Text(count,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall)),
                  const SizedBox(width: 8),
                  favourite,
                ]),
                if (data != null) metadata,
              ]));
  }

  Widget _browse(double width) {
    final data = _data;
    final groups = data?.tables.map((t) => t.name).toSet() ?? <String>{};
    final wide = width >= 900 &&
        MediaQuery.textScalerOf(context).scale(14) <= 18 &&
        !_keyboardOpen;
    return Column(children: [
      if (widget.layoutBuilder != null)
        _compactControls(width, hasGroups: groups.length > 1)
      else if (wide)
        Row(children: [
          Expanded(flex: 2, child: _selectors()),
          Expanded(child: _searchField(compact: true)),
          if (widget.embedded) ..._actions(),
        ])
      else ...[
        if (!_keyboardOpen) _selectors(),
        if (widget.embedded && !_keyboardOpen)
          Row(children: [
            Expanded(child: _searchField(compact: true)),
            ..._actions()
          ])
        else
          _searchField(),
      ],
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      if (!_keyboardOpen && widget.layoutBuilder == null)
        _utilities(
            wide: wide ||
                (widget.embedded &&
                    width >= 500 &&
                    MediaQuery.textScalerOf(context).scale(14) <= 18),
            hasGroups: groups.length > 1),
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
                        child: CallbackShortcuts(
                            bindings: {
                          const SingleActivator(LogicalKeyboardKey.contextMenu):
                              _leagueFocus.requestFocus,
                          const SingleActivator(LogicalKeyboardKey.home): () {
                            _scroll.jumpTo(0);
                            _leagueFocus.requestFocus();
                          }
                        },
                            child: ListView.builder(
                                padding: EdgeInsets.zero,
                                controller: _scroll,
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
                                      followed: widget.follows
                                          .isFollowed(_league.id, row.team.id),
                                      onToggle: () =>
                                          _toggle(_league.id, row.team),
                                      onDetails: () {
                                        if (_league.kind != SportsKind.team) {
                                          showStandingRecord(context, row,
                                              sport: _sport(_league),
                                              rankings: data.rankings,
                                              rankingTitle: data.rankingTitle);
                                        } else if (widget.onTeamDetails !=
                                            null) {
                                          widget.onTeamDetails!(_league, row);
                                        } else {
                                          showSportsTeamDetails(
                                              context, _league, row);
                                        }
                                      });
                                }))),
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

  @override
  Widget build(BuildContext context) {
    Widget content = widget.favorites
        ? _favorites()
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
              widget.onFocusToolbar!();
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
        SizedBox(
            height: 48,
            child: Row(children: [
              const SizedBox(width: 16),
              Expanded(
                  child: Text(
                      widget.favorites ? 'Sports favourites' : 'Standings',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium)),
              if (!widget.favorites) ..._actions(),
              IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close)),
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
