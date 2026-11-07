import '../models/sports_favourites_filter.dart';
import '../utils/guarded_dialog.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import '../utils/interface_colors.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sports_header_controls.dart';
import 'sports_widgets.dart' show SportsLogo;
import 'compact_choice_list.dart';
import 'tv_text_field_gate.dart';
import '../models/sports.dart';
import '../utils/sports_presentation.dart';

typedef SportsFilterCounts = Map<String, ({int live, int upcoming})>;

const sportsManageLeaguesLabel = 'Manage favourite leagues';

/// Uses the same labelled dropdown as Sport/League; opening it does no work.
class SportsFavouritesFilterButton extends StatelessWidget {
  const SportsFavouritesFilterButton(
      {super.key,
      required this.filter,
      required this.onChanged,
      this.favouriteLeagueCount,
      this.favouriteTeamCount,
      this.focusNode});
  final SportsFavouritesFilter filter;
  final ValueChanged<SportsFavouritesFilter> onChanged;
  final FocusNode? focusNode;
  final int? favouriteLeagueCount, favouriteTeamCount;

  String _description(SportsFavouritesFilter option) {
    if (favouriteLeagueCount == null || favouriteTeamCount == null) {
      return option.description;
    }
    final empty = option.emptySelectionMessage(
        hasLeagues: favouriteLeagueCount! > 0,
        hasTeams: favouriteTeamCount! > 0);
    if (empty != null) return empty;
    return switch (option) {
      SportsFavouritesFilter.leagues =>
        '$favouriteLeagueCount saved · includes the whole league',
      SportsFavouritesFilter.teams =>
        '$favouriteTeamCount saved · only these teams & athletes, in any league',
      _ => option.description,
    };
  }

  Future<void> _choose(BuildContext context) async {
    final selected = await showSportsChoices<SportsFavouritesFilter>(context,
        title: 'Show results',
        description: 'Sport, league and date filters still apply.',
        selected: filter,
        choices: [
          for (final option in SportsFavouritesFilter.values)
            SportsChoice(option, option.label, _description(option),
                key: ValueKey('sports-favourites-${option.name}'),
                icon: switch (option) {
                  SportsFavouritesFilter.all => Icons.list_rounded,
                  SportsFavouritesFilter.favourites => Icons.star_rounded,
                  SportsFavouritesFilter.leagues => Icons.emoji_events_outlined,
                  SportsFavouritesFilter.teams => Icons.groups_outlined,
                }),
        ]);
    if (context.mounted && selected != null && selected != filter) {
      onChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
      width: 88,
      child: Semantics(
          label: 'Show results: ${filter.label}',
          hint: 'Choose all results or a favourites filter',
          child: SportsFilterButton(
              caption: filter == SportsFavouritesFilter.leagues ||
                      filter == SportsFavouritesFilter.teams
                  ? 'Favourites'
                  : 'Show',
              value: filter.shortLabel,
              tooltip: 'Show: ${filter.label} · change result filter',
              selected: filter.isFiltered,
              focusNode: focusNode,
              onTap: () => _choose(context))));
}

/// Build from the enabled catalogue, so empty or still-loading competitions
/// remain selectable. Counts describe availability, not catalogue membership.
List<SportsFilterOption> sportsSportOptions(
    List<SportsLeague> leagues, SportsFilterCounts counts,
    {bool showCounts = true, bool favouriteOnly = true}) {
  final sports = leagues
      .map((l) => l.espnPath.split('/').first)
      .toSet()
      .toList()
    ..sort((a, b) => sportLabel(a).compareTo(sportLabel(b)));
  final guideSports = {
    for (final l in leagues)
      if (l.source == 'Channel guide') l.espnPath.split('/').first,
  };
  final scoredSports = {
    for (final l in leagues)
      if (l.source != 'Channel guide') l.espnPath.split('/').first,
  };
  return [
    for (final sport in ['', ...sports])
      SportsFilterOption(sport,
          sport.isEmpty ? 'All sports' : sportLabel(sport), sportIcon(sport),
          description: sport.isEmpty
              ? favouriteOnly
                  ? 'Across your favourites · clear sport & league filters'
                  : 'All available sports'
              : null,
          currentLabel: (sport.isEmpty && guideSports.isNotEmpty) ||
                  (guideSports.contains(sport) && scoredSports.contains(sport))
              ? 'live / on air'
              : guideSports.contains(sport)
                  ? 'on air'
                  : 'live',
          live: showCounts ? counts[sport]?.live ?? 0 : null,
          upcoming: showCounts ? counts[sport]?.upcoming ?? 0 : null),
  ];
}

List<SportsFilterOption> sportsLeagueOptions(
        List<SportsLeague> leagues, SportsFilterCounts counts,
        {String? sport,
        required int favouriteCount,
        bool favouritesOnly = true}) =>
    [
      SportsFilterOption(
          '',
          sport == null ? 'All leagues' : 'All ${sportLabel(sport)} leagues',
          Icons.list,
          description: sport == null
              ? favouritesOnly
                  ? 'Across your favourites'
                  : 'Across all sports'
              : favouritesOnly
                  ? 'Your favourites in ${sportLabel(sport)}'
                  : 'All ${sportLabel(sport)} leagues'),
      if (sport != null)
        const SportsFilterOption('__all_sports__', 'All sports', Icons.public,
            description: 'Clear the sport and league filters'),
      sportsManageLeaguesOption(favouriteCount),
      for (final league in leagues)
        if (sport == null || league.espnPath.split('/').first == sport)
          SportsFilterOption(league.id, league.name,
              sportIcon(league.espnPath.split('/').first),
              logoUrl: league.logoUrl,
              description: leagueDescription(league),
              searchTerms: '${league.shortName} ${league.region ?? ''}',
              priority: leagueDisplayPriority(league),
              group: sportLabel(league.espnPath.split('/').first),
              currentLabel:
                  league.source == 'Channel guide' ? 'on air' : 'live',
              live: counts[league.id]?.live ?? 0,
              upcoming: counts[league.id]?.upcoming ?? 0),
    ];

SportsFilterOption sportsManageLeaguesOption(int favouriteCount) =>
    SportsFilterOption(
        '__manage_leagues__', sportsManageLeaguesLabel, Icons.tune,
        description: '$favouriteCount saved · choose your favourite leagues');

String shortSportLabel(String sport) => switch (sport) {
      'soccer' => 'Soccer',
      'football' => 'US football',
      'australian-football' => 'Aussie rules',
      _ => sportLabel(sport),
    };

String sportsPickerSportLabel(BuildContext context, String? sport) =>
    sport == null
        ? 'All sports'
        : compactSportsPortrait(context)
            ? shortSportLabel(sport)
            : sportLabel(sport);

String sportLabel(String sport) => switch (sport) {
      'australian-football' => 'Aussie rules',
      'football' => 'American football',
      'mma' => 'MMA & Muay Thai',
      'soccer' => 'Football / Soccer',
      'horse-racing' => 'Horse racing',
      'field-hockey' => 'Field hockey',
      'table-tennis' => 'Table tennis',
      'action-sports' => 'Action sports',
      'billiards' => 'Snooker & pool',
      'skating' => 'Ice skating',
      _ => sport.isEmpty
          ? sport
          : '${sport[0].toUpperCase()}${sport.substring(1)}',
    };

IconData sportIcon(String sport) => switch (sport) {
      'basketball' => Icons.sports_basketball,
      'baseball' => Icons.sports_baseball,
      'soccer' => Icons.sports_soccer,
      'football' || 'australian-football' || 'rugby' => Icons.sports_football,
      'hockey' => Icons.sports_hockey,
      'tennis' || 'padel' || 'pickleball' => Icons.sports_tennis,
      'golf' => Icons.sports_golf,
      'mma' => Icons.sports_mma,
      'racing' => Icons.sports_motorsports,
      'horse-racing' => Icons.flag_outlined,
      'rodeo' => Icons.sports,
      'volleyball' => Icons.sports_volleyball,
      'poker' => Icons.casino_outlined,
      'cricket' => Icons.sports_cricket,
      'netball' => Icons.sports_basketball,
      'handball' => Icons.sports_handball,
      'cycling' => Icons.directions_bike,
      'field-hockey' => Icons.sports_hockey,
      'darts' => Icons.track_changes,
      'esports' => Icons.sports_esports,
      'action-sports' => Icons.skateboarding,
      'billiards' => Icons.circle_outlined,
      'sumo' || 'taekwondo' || 'sambo' => Icons.sports_martial_arts,
      'sailing' => Icons.sailing_outlined,
      'triathlon' => Icons.directions_run,
      'gymnastics' => Icons.sports_gymnastics,
      'climbing' => Icons.terrain,
      'wrestling' => Icons.sports_martial_arts,
      'skating' => Icons.ice_skating,
      'skiing' => Icons.downhill_skiing,
      _ => Icons.sports,
    };

class SportsFilterOption {
  const SportsFilterOption(this.id, this.label, this.icon,
      {this.logoUrl,
      this.live,
      this.upcoming,
      this.group,
      this.description,
      this.searchTerms = '',
      this.priority = 10,
      this.currentLabel = 'live'});
  final String id;
  final String label;
  final IconData icon;
  final int? live;
  final int? upcoming;
  final String? group, description, logoUrl;
  final String searchTerms;
  final int priority;
  final String currentLabel;
  bool get isManagement => id == '__manage_leagues__';
  bool get isScope => id.isEmpty || id == '__all__' || id == '__all_sports__';
}

Future<String?> showSportsFilterPicker(
  BuildContext context, {
  required String title,
  required String selected,
  required List<SportsFilterOption> options,
  String? description,
  String itemLabel = 'choices',
  bool topFirst = false,
  bool showSortingControls = true,
  String? initialGroup,
}) =>
    showSportsDialog<String>(
        context: context,
        builder: (_) => _FilterPicker(
            title: title,
            description: description,
            itemLabel: itemLabel,
            selected: selected,
            options: options,
            topFirst: topFirst,
            showSortingControls: showSortingControls,
            initialGroup: initialGroup));

class _FilterPicker extends StatefulWidget {
  const _FilterPicker(
      {required this.title,
      this.description,
      required this.itemLabel,
      required this.selected,
      required this.options,
      required this.topFirst,
      required this.showSortingControls,
      this.initialGroup});
  final String title;
  final String? description;
  final String itemLabel;
  final String selected;
  final List<SportsFilterOption> options;
  final bool topFirst, showSortingControls;
  final String? initialGroup;
  @override
  State<_FilterPicker> createState() => _FilterPickerState();
}

enum SportsPickerSort { top, live, upcoming, name }

List<SportsFilterOption> sortSportsOptions(
    Iterable<SportsFilterOption> options, SportsPickerSort sort) {
  final result = options.toList();
  // Count each group once, outside the comparator. Otherwise inactive sports
  // stay above busy ones in Live/Upcoming and the sort appears to do nothing.
  final groupCounts = <String, int>{};
  if (sort == SportsPickerSort.live || sort == SportsPickerSort.upcoming) {
    for (final option in result) {
      if (option.id.isEmpty) continue;
      final group = option.group ?? '';
      final count = sort == SportsPickerSort.live
          ? option.live ?? 0
          : option.upcoming ?? 0;
      groupCounts[group] = (groupCounts[group] ?? 0) + count;
    }
  }
  result.sort((a, b) {
    // Scope and configuration actions stay discoverable under every sort.
    int scopeRank(String id) => switch (id) {
          '' || '__all__' => 0,
          '__all_sports__' => 1,
          '__manage_leagues__' => 2,
          _ => 3,
        };
    final scope = scopeRank(a.id).compareTo(scopeRank(b.id));
    if (scope != 0) return scope;
    final aGroup = a.group ?? '', bGroup = b.group ?? '';
    if (aGroup != bGroup) {
      final activity =
          (groupCounts[bGroup] ?? 0).compareTo(groupCounts[aGroup] ?? 0);
      if (activity != 0) return activity;
      return aGroup.compareTo(bGroup);
    }
    final order = switch (sort) {
      SportsPickerSort.top => a.priority.compareTo(b.priority),
      SportsPickerSort.live => (b.live ?? 0).compareTo(a.live ?? 0),
      SportsPickerSort.upcoming => (b.upcoming ?? 0).compareTo(a.upcoming ?? 0),
      SportsPickerSort.name =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    };
    if (order != 0) return order;
    if (sort != SportsPickerSort.name) {
      final priority = a.priority.compareTo(b.priority);
      if (priority != 0) return priority;
    }
    final name = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    return name != 0 ? name : a.id.compareTo(b.id);
  });
  return result;
}

class SportsCounts extends StatelessWidget {
  const SportsCounts(
      {super.key,
      required this.live,
      required this.upcoming,
      this.compact = false,
      this.currentLabel = 'live'});
  final int live, upcoming;
  final bool compact;
  final String currentLabel;

  Widget _badge(BuildContext context, int count, String label, Color accent) =>
      Tooltip(
          message: '$count $label',
          child: Container(
              constraints: compact ? const BoxConstraints(minWidth: 35) : null,
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 4 : 5, vertical: 3),
              decoration: BoxDecoration(
                  color: count > 0
                      ? accent.withValues(alpha: .10)
                      : interfaceColor(context, const Color(0xFF202832)),
                  borderRadius: BorderRadius.circular(2)),
              child: compact
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                          Icon(
                              label == 'live'
                                  ? Icons.circle
                                  : Icons.schedule_rounded,
                              size: label == 'live' ? 5 : 10,
                              color: count > 0
                                  ? accent
                                  : interfaceColor(
                                      context, const Color(0xFF647181))),
                          const SizedBox(width: 4),
                          Text('$count',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: count > 0
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: count > 0
                                      ? accent
                                      : interfaceColor(
                                          context, const Color(0xFF647181)))),
                        ])
                  : Text('$count $label',
                      style: TextStyle(
                          fontSize: 10.5,
                          color: count > 0
                              ? accent
                              : interfaceColor(context, Colors.white38),
                          fontWeight:
                              count > 0 ? FontWeight.w600 : FontWeight.w400))));

  @override
  Widget build(BuildContext context) => Semantics(
      label: '$live $currentLabel, $upcoming upcoming',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _badge(
            context,
            live,
            currentLabel,
            currentLabel == 'live'
                ? interfaceColor(context, const Color(0xFFFF8585))
                : interfaceColor(context, const Color(0xFFE0BC79))),
        const SizedBox(width: 4),
        _badge(context, upcoming, 'upcoming',
            interfaceColor(context, const Color(0xFF90CAF9))),
      ]));
}

class _FilterPickerState extends State<_FilterPicker> {
  String _query = '';
  bool _changed = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'sports-picker-search');
  final _manageFocus = FocusNode(debugLabel: 'sports-picker-manage');
  final _groupFocus = FocusNode(debugLabel: 'sports-picker-group');
  final _sortFocus = FocusNode(debugLabel: 'sports-picker-sort');
  final _list = GlobalKey<CompactChoiceListState>();
  int _activeIndex = 0;
  late final _management =
      widget.options.where((o) => o.isManagement).firstOrNull;
  late final _catalogue = widget.options.where((o) => !o.isManagement).toList();
  late final _totalCount = _catalogue.where((o) => !o.isScope).length;
  late final _catalogueHeading = _catalogue.any((o) => o.isScope)
      ? switch (widget.itemLabel) {
          'sports' => 'Sports',
          'leagues' => 'Leagues',
          _ => null,
        }
      : null;
  late String? _group = widget.initialGroup;
  late SportsPickerSort _sort =
      widget.topFirst ? SportsPickerSort.top : SportsPickerSort.name;
  final _sorted = <SportsPickerSort, List<SportsFilterOption>>{};
  late final _labels = {
    for (final o in widget.options)
      o.id:
          '${o.label} ${o.description ?? ''} ${o.group ?? ''} ${o.searchTerms}'
              .toLowerCase()
  };
  late final _groupIcons = {
    for (final option in widget.options)
      if (option.group != null) option.group!: option.icon,
  };
  late final _groups = _groupIcons.keys.toList()..sort();
  late final _hasCounts =
      widget.options.any((o) => o.live != null || o.upcoming != null);
  List<SportsFilterOption> _options = const [];
  @override
  void initState() {
    super.initState();
    _filter();
  }

  void _filter() {
    final terms =
        _query.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final sorted =
        _sorted.putIfAbsent(_sort, () => sortSportsOptions(_catalogue, _sort));
    _options = sorted
        .where((o) =>
            (_group == null || o.group == null || o.group == _group) &&
            terms.every(_labels[o.id]!.contains))
        .toList();
  }

  void _change(VoidCallback action) => setState(() {
        _changed = true;
        action();
        _filter();
      });

  void _clearSearch() {
    _search.clear();
    _change(() => _query = '');
    _searchFocus.requestFocus();
  }

  void _returnToResults() {
    if (_options.isEmpty) {
      _searchFocus.requestFocus();
    } else {
      _list.currentState?.revealIndex(
          _activeIndex.clamp(0, _options.length - 1),
          requestFocus: true);
    }
  }

  String _sortLabel(SportsPickerSort sort) => switch (sort) {
        SportsPickerSort.top => 'Top leagues',
        SportsPickerSort.live => 'Live',
        SportsPickerSort.upcoming => 'Upcoming',
        SportsPickerSort.name => 'A–Z',
      };

  Future<void> _chooseGroup() async {
    final group = await showSportsFilterPicker(context,
        title: 'Filter by sport',
        itemLabel: 'sports',
        selected: _group ?? '',
        showSortingControls: false,
        options: [
          const SportsFilterOption('', 'All sports', Icons.public),
          for (final group in _groups)
            SportsFilterOption(group, group, _groupIcons[group]!),
        ]);
    if (mounted && group != null) {
      _change(() => _group = group.isEmpty ? null : group);
    }
  }

  Future<void> _chooseSort() async {
    final sort = await showSportsChoices<SportsPickerSort>(context,
        title: 'Sort by',
        selected: _sort,
        choices: [
          for (final sort in [
            if (widget.topFirst) SportsPickerSort.top,
            if (_hasCounts) SportsPickerSort.live,
            if (_hasCounts) SportsPickerSort.upcoming,
            SportsPickerSort.name,
          ])
            SportsChoice(sort, _sortLabel(sort), '',
                key: ValueKey('sports-sort-${sort.name}')),
        ]);
    if (mounted && sort != null) _change(() => _sort = sort);
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _manageFocus.dispose();
    _groupFocus.dispose();
    _sortFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    // Keep the frame steady while searching. Only list contents change.
    final groups = _groups.length;
    final television = context.read<AppPreferences?>()?.isTelevision == true;
    final sortControl =
        widget.showSortingControls && (_hasCounts || widget.topFirst);
    final media = MediaQuery.of(context);
    final compact = compactSportsControls(context);
    final management = _management;
    final reserveManagement =
        management != null && media.viewInsets.bottom == 0;
    final resultCount = options.where((o) => !o.isScope).length;
    final scopeHeading =
        options.any((o) => o.isScope) ? _catalogueHeading : null;
    final rowHeight = (television
            ? 40.0
            : compact
                ? 44.0
                : 48.0) *
        math.max(1.0, media.textScaler.scale(12) / 12);
    final available = math.max(
        0.0,
        media.size.height -
            media.viewInsets.bottom -
            media.padding.vertical -
            48);
    final maxHeight =
        math.min(620.0, math.min(media.size.height * .78, available));
    final textScale = math.max(1.0, media.textScaler.scale(12) / 12);
    // Include the header, search, status and insets so short lists do not
    // needlessly clip their last row below the viewport.
    final height = math.min(
        (groups > 1 || sortControl ? 150.0 : 114.0) * textScale +
            (widget.description == null ? 0 : 21 * textScale) +
            _catalogue.length * rowHeight +
            (reserveManagement ? 52 * textScale : 0) +
            (_catalogueHeading != null && groups == 0 ? 24 * textScale : 0) +
            groups * 24 * textScale,
        maxHeight);
    return Dialog(
      alignment: Alignment.center,
      backgroundColor: sportsPopupBackground(context),
      surfaceTintColor: Colors.transparent,
      shape: sportsPopupShape(context),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: 460,
        height: height,
        child: LayoutBuilder(builder: (context, constraints) {
          // Dialog insets animate independently of MediaQuery. Use the actual
          // space during keyboard transitions before restoring extra controls.
          final short = constraints.maxHeight <
              (reserveManagement ? 272 : 220) * textScale;
          final managementHeight = short
              ? math.max(36.0, media.textScaler.scale(12) * 1.2 + 8)
              : 42 * textScale;
          final showManagement = management != null &&
              reserveManagement &&
              constraints.maxHeight >= 88 * textScale + managementHeight + 21;
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SportsPopupHeader(
                  title: widget.title,
                  description: short ? null : widget.description),
              TvTextFieldGate(
                  focusNode: _searchFocus,
                  builder: (context, readOnly) => TextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        readOnly: readOnly,
                        style: const TextStyle(fontSize: 12.5),
                        decoration: InputDecoration(
                            prefixIcon: Icon(Icons.search_rounded,
                                size: 17,
                                color: interfaceColor(
                                    context, const Color(0xFF8795A5))),
                            prefixIconConstraints:
                                const BoxConstraints.tightFor(
                                    width: 32, height: 32),
                            hintText: _group == null
                                ? switch (widget.itemLabel) {
                                    'sports' => 'Search sports',
                                    'leagues' => 'Search leagues or countries',
                                    _ => 'Search names or descriptions',
                                  }
                                : 'Search $_group',
                            suffixIconConstraints:
                                const BoxConstraints.tightFor(
                                    width: 32, height: 32),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    padding: EdgeInsets.zero,
                                    icon: Icon(Icons.close_rounded,
                                        size: 15,
                                        color: interfaceColor(
                                            context, const Color(0xFF9AA7B6))),
                                    onPressed: _clearSearch),
                            hintStyle: TextStyle(
                                fontSize: 11.5,
                                color: interfaceColor(
                                    context, const Color(0xFF8795A5))),
                            filled: true,
                            fillColor: interfaceColor(
                                context, const Color(0xFF111923)),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(3),
                                borderSide: BorderSide.none),
                            enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(3),
                                borderSide: BorderSide.none),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 7)),
                        onChanged: (query) =>
                            _change(() => _query = query.trim().toLowerCase()),
                      )),
              const SizedBox(height: 4),
              if (!short && (_groups.length > 1 || sortControl))
                Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(children: [
                      if (_groups.length > 1)
                        Expanded(
                            child: SportsFilterButton(
                                key: const ValueKey('sports-picker-group'),
                                focusNode: _groupFocus,
                                caption: 'Sport',
                                value: _group ?? 'All sports',
                                onTap: _chooseGroup)),
                      if (_groups.length > 1 && sortControl)
                        const SizedBox(width: 6),
                      if (sortControl)
                        Expanded(
                            child: SportsFilterButton(
                                key: const ValueKey('sports-picker-sort'),
                                focusNode: _sortFocus,
                                caption: 'Sort',
                                value: _sortLabel(_sort),
                                onTap: _chooseSort)),
                    ])),
              if (!short && !(television && options.length > 30))
                Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 3),
                    child: Text(
                        '${resultCount == _totalCount ? resultCount : '$resultCount of $_totalCount'} ${widget.itemLabel}',
                        style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
              Expanded(
                  child: options.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                              child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text('No matches',
                                            style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600)),
                                        if (_group != null)
                                          TextButton(
                                              onPressed: () =>
                                                  _change(() => _group = null),
                                              child: const Text(
                                                  'Search all sports')),
                                        if (_query.isNotEmpty)
                                          TextButton(
                                              onPressed: _clearSearch,
                                              child: const Text('Clear search'))
                                        else if (_group == null && !short)
                                          const Text(
                                              'Try a different name or description.',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(fontSize: 11)),
                                      ]))))
                      : CallbackShortcuts(
                          bindings: {
                              if (showManagement)
                                const SingleActivator(
                                        LogicalKeyboardKey.arrowLeft):
                                    _manageFocus.requestFocus,
                            },
                          child: CompactChoiceList(
                            key: _list,
                            onExitDown: showManagement
                                ? _manageFocus.requestFocus
                                : null,
                            onExitUp: !short && sortControl
                                ? _sortFocus.requestFocus
                                : !short && _groups.length > 1
                                    ? _groupFocus.requestFocus
                                    : _searchFocus.requestFocus,
                            onActiveIndexChanged: (index) =>
                                _activeIndex = index,
                            cacheExtent: television ? 48 : null,
                            // Filtering does not autofocus a new choice over the keyboard.
                            resetScrollKey: (_sort, _query, _group),
                            autofocus: !_changed,
                            rowHeight: rowHeight,
                            polished: true,
                            striped: true,
                            showNavigation: television && !short,
                            selected: widget.selected,
                            choices: [
                              for (final option in options)
                                CompactChoice(
                                  id: option.id,
                                  title: option.label,
                                  subtitle: option.description,
                                  group: option.isScope
                                      ? null
                                      : option.group ?? scopeHeading,
                                  leading: option.logoUrl != null
                                      ? SportsLogo(
                                          url: option.logoUrl,
                                          size: 22,
                                          fallback: option.label,
                                          animate: false)
                                      : Icon(option.icon,
                                          size: 17,
                                          color: interfaceColor(context,
                                              const Color(0xFF9EACBC))),
                                  trailing: (option.live ?? 0) == 0 &&
                                          (option.upcoming ?? 0) == 0
                                      ? null
                                      : SportsCounts(
                                          compact: true,
                                          live: option.live ?? 0,
                                          currentLabel: option.currentLabel,
                                          upcoming: option.upcoming ?? 0),
                                  onTap: () =>
                                      popRouteIfCurrent(context, option.id),
                                )
                            ],
                          ))),
              if (showManagement) ...[
                const Divider(height: 9),
                CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.arrowUp):
                          _returnToResults,
                      const SingleActivator(LogicalKeyboardKey.arrowRight):
                          _returnToResults,
                    },
                    child: Tooltip(
                        message: television
                            ? '${management.label} · Left from results'
                            : management.label,
                        child: TextButton(
                            key: ValueKey(management.id),
                            focusNode: _manageFocus,
                            style: TextButton.styleFrom(
                                minimumSize: Size(0, managementHeight),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap),
                            onPressed: () =>
                                popRouteIfCurrent(context, management.id),
                            child: Row(children: [
                              Icon(management.icon, size: 17),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(management.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500)),
                                    if (!short &&
                                        management.description != null)
                                      Text(management.description!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant)),
                                  ])),
                              if (television)
                                const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.keyboard_arrow_left, size: 17),
                                      Text('Left',
                                          style: TextStyle(fontSize: 10)),
                                    ])
                              else
                                const Icon(Icons.chevron_right, size: 17),
                            ])))),
              ],
            ]),
          );
        }),
      ),
    );
  }
}
