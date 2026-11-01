import '../utils/guarded_dialog.dart';
import '../utils/interface_colors.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'sports_header_controls.dart';
import 'compact_choice_list.dart';
import 'tv_text_field_gate.dart';
import '../models/sports.dart';
import '../utils/sports_presentation.dart';

typedef SportsFilterCounts = Map<String, ({int live, int upcoming})>;

/// Build from the enabled catalogue, so empty or still-loading competitions
/// remain selectable. Counts describe availability, not catalogue membership.
List<SportsFilterOption> sportsSportOptions(
    List<SportsLeague> leagues, SportsFilterCounts counts) {
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
          currentLabel: (sport.isEmpty && guideSports.isNotEmpty) ||
                  (guideSports.contains(sport) && scoredSports.contains(sport))
              ? 'live / on air'
              : guideSports.contains(sport)
                  ? 'on air'
                  : 'live',
          live: counts[sport]?.live ?? 0,
          upcoming: counts[sport]?.upcoming ?? 0),
  ];
}

List<SportsFilterOption> sportsLeagueOptions(
        List<SportsLeague> leagues, SportsFilterCounts counts,
        {String? sport, required int enabledCount}) =>
    [
      const SportsFilterOption('', 'All enabled leagues', Icons.list),
      SportsFilterOption(
          '__manage_leagues__', 'Choose enabled leagues', Icons.tune,
          description: '$enabledCount enabled · Turn leagues on or off'),
      for (final league in leagues)
        if (sport == null || league.espnPath.split('/').first == sport)
          SportsFilterOption(league.id, league.name,
              sportIcon(league.espnPath.split('/').first),
              description: leagueDescription(league),
              priority: leagueDisplayPriority(league),
              group: sportLabel(league.espnPath.split('/').first),
              currentLabel:
                  league.source == 'Channel guide' ? 'on air' : 'live',
              live: counts[league.id]?.live ?? 0,
              upcoming: counts[league.id]?.upcoming ?? 0),
    ];

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
      'sumo' || 'taekwondo' => Icons.sports_martial_arts,
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
      {this.live,
      this.upcoming,
      this.group,
      this.description,
      this.priority = 10,
      this.currentLabel = 'live'});
  final String id;
  final String label;
  final IconData icon;
  final int? live;
  final int? upcoming;
  final String? group, description;
  final int priority;
  final String currentLabel;
}

Future<String?> showSportsFilterPicker(
  BuildContext context, {
  required String title,
  required String selected,
  required List<SportsFilterOption> options,
  bool topFirst = false,
}) =>
    showGuardedDialog<String>(
        context: context,
        builder: (_) => _FilterPicker(
            title: title,
            selected: selected,
            options: options,
            topFirst: topFirst));

class _FilterPicker extends StatefulWidget {
  const _FilterPicker(
      {required this.title,
      required this.selected,
      required this.options,
      required this.topFirst});
  final String title;
  final String selected;
  final List<SportsFilterOption> options;
  final bool topFirst;
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
    // Keep All pinned and each sport contiguous, even when groups move.
    if (a.id.isEmpty != b.id.isEmpty) return a.id.isEmpty ? -1 : 1;
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
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  late SportsPickerSort _sort =
      widget.topFirst ? SportsPickerSort.top : SportsPickerSort.name;
  @override
  Widget build(BuildContext context) {
    final options = sortSportsOptions(
        widget.options.where((o) =>
            '${o.label} ${o.description ?? ''} ${o.group ?? ''}'
                .toLowerCase()
                .contains(_query)),
        _sort);
    // Keep the frame steady while searching. Only list contents change.
    final groups =
        widget.options.map((o) => o.group).whereType<String>().toSet().length;
    final media = MediaQuery.of(context);
    final portrait = compactSportsPortrait(context);
    final rowHeight = (portrait ? 44.0 : 48.0) *
        math.max(1.0, media.textScaler.scale(12) / 12);
    final available = math.max(
        0.0,
        media.size.height -
            media.viewInsets.bottom -
            media.padding.vertical -
            48);
    final maxHeight =
        math.min(620.0, math.min(media.size.height * .78, available));
    final height = math.min(
        124.0 + widget.options.length * rowHeight + groups * 24, maxHeight);
    final short = height < 220;
    return Dialog(
      backgroundColor: sportsPopupBackground(context),
      surfaceTintColor: Colors.transparent,
      shape: sportsPopupShape(context),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: 460,
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SportsPopupHeader(title: widget.title),
            FocusNodeOwner(
                builder: (context, node) => TvTextFieldGate(
                    focusNode: node,
                    builder: (context, readOnly) => TextField(
                          controller: _search,
                          focusNode: node,
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
                              hintText: 'Search names or descriptions',
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
                                          color: interfaceColor(context,
                                              const Color(0xFF9AA7B6))),
                                      onPressed: () {
                                        _search.clear();
                                        setState(() => _query = '');
                                        node.requestFocus();
                                      }),
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
                          onChanged: (query) => setState(
                              () => _query = query.trim().toLowerCase()),
                        ))),
            const SizedBox(height: 4),
            if (!short)
              SizedBox(
                  height: 34,
                  child: Row(children: [
                    Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: Text('Sort',
                            style: TextStyle(
                                fontSize: 10.5,
                                color:
                                    interfaceColor(context, Colors.white54)))),
                    for (final sort in [
                      if (widget.topFirst) SportsPickerSort.top,
                      SportsPickerSort.live,
                      SportsPickerSort.upcoming,
                      SportsPickerSort.name
                    ])
                      Expanded(
                          child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: TextButton(
                                key: ValueKey('sports-sort-${sort.name}'),
                                style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    minimumSize: const Size(0, 30),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(3)),
                                    backgroundColor: _sort == sort
                                        ? Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: .14)
                                        : null,
                                    foregroundColor: _sort == sort
                                        ? Theme.of(context).colorScheme.primary
                                        : interfaceColor(
                                            context, Colors.white60),
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(fontSize: 11.5)),
                                onPressed: () => setState(() => _sort = sort),
                                child: Text(switch (sort) {
                                  SportsPickerSort.top => 'Top leagues',
                                  SportsPickerSort.live => 'Live',
                                  SportsPickerSort.upcoming => 'Upcoming',
                                  SportsPickerSort.name => 'A–Z',
                                }),
                              ))),
                  ])),
            const SizedBox(height: 4),
            Expanded(
                child: options.isEmpty
                    ? short
                        ? const Center(child: Text('No matches'))
                        : Center(
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.search_off_rounded,
                                          size: 22,
                                          color: interfaceColor(context,
                                              const Color(0xFF788697))),
                                      const SizedBox(height: 8),
                                      const Text('No matches',
                                          style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 4),
                                      Text(
                                          'Try a sport, league or competition name.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: interfaceColor(context,
                                                  const Color(0xFF98A6B6)))),
                                    ])))
                    : CompactChoiceList(
                        // Filtering does not autofocus a new choice over the keyboard.
                        resetScrollKey: (_sort, _query),
                        rowHeight: rowHeight,
                        polished: true,
                        selected: widget.selected,
                        choices: [
                          for (final option in options)
                            CompactChoice(
                              id: option.id,
                              title: option.label,
                              subtitle: option.description,
                              group: option.group,
                              leading: Icon(option.icon,
                                  size: 17,
                                  color: interfaceColor(
                                      context, const Color(0xFF9EACBC))),
                              trailing: option.live == null
                                  ? null
                                  : SportsCounts(
                                      compact: true,
                                      live: option.live!,
                                      currentLabel: option.currentLabel,
                                      upcoming: option.upcoming ?? 0),
                              onTap: () =>
                                  popRouteIfCurrent(context, option.id),
                            )
                        ],
                      )),
          ]),
        ),
      ),
    );
  }
}
