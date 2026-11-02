import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/sports.dart';
import '../models/sports_details.dart';
import '../services/app_preferences.dart';
import '../services/sports_details_service.dart';
import '../services/sports_service.dart';
import '../services/sports_standings_service.dart';
import '../services/storage_service.dart';
import '../utils/sports_calendar.dart';
import '../utils/sports_fixture_presentation.dart';
import '../utils/sports_detail_presentation.dart';
import '../utils/time_format.dart';
import 'compact_choice_list.dart';
import 'sports_header_controls.dart';
import 'sports_panel.dart';
import 'standings_team_tile.dart';
import 'sports_detail_views.dart';
import 'sports_widgets.dart';

Future<void> showSportsGameDetails(BuildContext context, SportsGame game,
        {bool hideScores = false, SportsDetailsService? service}) =>
    showSportsPanel<void>(
        context: context,
        besidePreview: true,
        builder: (_) => SportsDetailsPanel(
            league: game.league,
            game: game,
            hideScores: hideScores,
            service: service));

Future<void> showSportsTeamDetails(
        BuildContext context, SportsLeague league, StandingTeam row,
        {SportsDetailsService? service,
        ValueChanged<SportsDetails>? onLoaded}) =>
    showSportsPanel<void>(
        context: context,
        besidePreview: true,
        builder: (_) => SportsDetailsPanel(
            league: league,
            team: row.team,
            standing: row,
            service: service,
            onLoaded: onLoaded,
            hideScores:
                context.read<StorageService?>()?.getSportsHideScores() ??
                    false));

/// A single optional request belongs to this panel, never to a card build or
/// focus change. The existing preview and browsing position remain mounted.
class SportsDetailsPanel extends StatefulWidget {
  const SportsDetailsPanel(
      {super.key,
      required this.league,
      this.game,
      this.team,
      this.standing,
      this.service,
      this.scores,
      this.hideScores = false,
      this.embedded = false,
      this.initialData,
      this.onLoaded})
      : assert(game != null || team != null);
  final SportsLeague league;
  final SportsGame? game;
  final SportsTeam? team;
  final StandingTeam? standing;
  final SportsDetailsService? service;
  final SportsDetails? initialData;
  final ValueChanged<SportsDetails>? onLoaded;
  final SportsService? scores;
  final bool hideScores;
  final bool embedded;
  @override
  State<SportsDetailsPanel> createState() => _SportsDetailsPanelState();
}

class _SportsDetailsPanelState extends State<SportsDetailsPanel> {
  late final _service = widget.service ?? SportsDetailsService.instance;
  late bool _revealed = widget.game == null || !widget.hideScores;
  SportsDetails? _data;
  bool _loading = false, _fixturesLoading = false, _incomplete = false;
  List<SportsGame>? _fixtures;
  String _section = 'overview';
  int _generation = 0, _fixtureGeneration = 0;
  final _sectionFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    _data = widget.initialData;
    if (_revealed && _data == null) unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _fixtureGeneration++;
    _sectionFocus.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    final token = ++_generation;
    setState(() => _loading = true);
    final result = widget.game != null
        ? await _service.game(widget.game!, refresh: refresh)
        : await _service.team(widget.league, widget.team!, refresh: refresh);
    if (!mounted || token != _generation) return;
    setState(() {
      final index = int.tryParse(_section);
      if (index != null) {
        final old = _data?.sections;
        final title =
            old != null && index < old.length ? old[index].title : null;
        final replacement =
            result.sections.indexWhere((section) => section.title == title);
        _section = replacement < 0 ? 'overview' : '$replacement';
      }
      _data = result;
      _loading = false;
    });
    widget.onLoaded?.call(result);
  }

  Future<void> _chooseSection({bool? players}) async {
    final selected = await showSportsChoices<String>(context,
        title: players == null
            ? 'Explore details'
            : players
                ? 'Choose team / group'
                : 'Choose statistics',
        selected: _section,
        choices: [
          if (players == null)
            const SportsChoice('overview', 'Summary', '',
                key: ValueKey('detail-section-overview'),
                icon: Icons.info_outline),
          for (final (i, section)
              in (_data?.sections ?? <SportsDetailSection>[]).indexed)
            if (players == null ||
                (sportsPlayerSection(section) == players &&
                    section.kind != SportsDetailKind.information))
              SportsChoice(
                  '$i',
                  section.title,
                  sportsPlayerSection(section)
                      ? '${section.rows.length} players'
                      : section.kind == SportsDetailKind.periods
                          ? 'Scores by period'
                          : '${section.rows.length} statistics',
                  key: ValueKey('detail-section-$i'),
                  icon: Icons.table_chart_outlined),
          if (players == null &&
              widget.team != null &&
              supportsSportsScoreboard(widget.league))
            const SportsChoice('fixtures', 'Upcoming fixtures', 'Next 30 days',
                key: ValueKey('detail-section-fixtures'),
                icon: Icons.calendar_today_outlined),
        ]);
    if (!mounted || selected == null) return;
    _selectSection(selected);
  }

  void _selectSection(String selected) {
    setState(() {
      if (_section == 'fixtures' && selected != 'fixtures') {
        _fixtureGeneration++;
        _fixturesLoading = false;
      }
      _section = selected;
    });
    if (selected == 'fixtures' && _fixtures == null) unawaited(_loadFixtures());
  }

  Future<void> _loadFixtures() async {
    if (_fixturesLoading) return;
    final token = ++_fixtureGeneration;
    setState(() => _fixturesLoading = true);
    final today = sportsCalendarDay(DateTime.now());
    try {
      final result = await (widget.scores ?? SportsService.instance)
          .scheduleGames(widget.league, today, sportsCalendarDay(today, 29),
              shouldContinue: () =>
                  mounted &&
                  token == _fixtureGeneration &&
                  _section == 'fixtures');
      if (!mounted || token != _fixtureGeneration) return;
      setState(() {
        _fixtures = result.games
            .where((g) =>
                g.home.id == widget.team!.id || g.away.id == widget.team!.id)
            .toList();
        _incomplete = result.incomplete;
      });
    } catch (_) {
      if (mounted && token == _fixtureGeneration) {
        setState(() {
          _fixtures = [];
          _incomplete = true;
        });
      }
    } finally {
      if (mounted && token == _fixtureGeneration) {
        setState(() => _fixturesLoading = false);
      }
    }
  }

  String get _title => widget.game?.title ?? _data?.title ?? widget.team!.name;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tv = context.read<AppPreferences>().isTelevision;
    context.select<AppPreferences, bool>((p) => p.use24h);
    final sectionIndex = int.tryParse(_section);
    final sections = _data?.sections ?? const <SportsDetailSection>[];
    final selected = sectionIndex != null &&
            sectionIndex >= 0 &&
            sectionIndex < sections.length
        ? sections[sectionIndex]
        : null;
    final comparisonIndex =
        sections.indexWhere((s) => s.kind == SportsDetailKind.comparison);
    final statisticsIndex = comparisonIndex >= 0
        ? comparisonIndex
        : sections.indexWhere((s) =>
            !sportsPlayerSection(s) && s.kind != SportsDetailKind.information);
    final hasRelatedSections = selected != null &&
        sections
            .where((s) =>
                selected.kind == SportsDetailKind.information ||
                (s.kind != SportsDetailKind.information &&
                    sportsPlayerSection(s) == sportsPlayerSection(selected)))
            .skip(1)
            .isNotEmpty;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final navigation = <Widget>[
      SportsOptionButton(
          label: 'Summary',
          selected: _section == 'overview',
          onPressed: () => _selectSection('overview')),
      if (statisticsIndex >= 0) ...[
        const SizedBox(width: 4),
        SportsOptionButton(
            label: widget.team == null
                ? sportsDetailProfile(widget.league).statistics
                : sections[statisticsIndex].kind == SportsDetailKind.record
                    ? 'Record'
                    : 'Statistics',
            selected: selected != null &&
                !sportsPlayerSection(selected) &&
                selected.kind != SportsDetailKind.information,
            onPressed: () => _selectSection('$statisticsIndex')),
      ],
      if (sections.any(sportsPlayerSection)) ...[
        const SizedBox(width: 4),
        SportsOptionButton(
            label: widget.team != null
                ? 'Roster'
                : sportsDetailProfile(widget.league).players,
            selected: selected != null && sportsPlayerSection(selected),
            onPressed: () =>
                _selectSection('${sections.indexWhere(sportsPlayerSection)}')),
      ],
      if (widget.team != null && supportsSportsScoreboard(widget.league)) ...[
        const SizedBox(width: 4),
        SportsOptionButton(
            label: 'Fixtures',
            selected: _section == 'fixtures',
            onPressed: () => _selectSection('fixtures')),
      ],
    ];
    final controls = <Widget>[
      IconButton(
          key: const ValueKey('sports-detail-section'),
          focusNode: _sectionFocus,
          tooltip: 'All detail sections',
          onPressed: _chooseSection,
          icon: const Icon(Icons.tune, size: 17)),
      IconButton(
          key: const ValueKey('sports-detail-refresh'),
          tooltip: 'Refresh details',
          onPressed: _loading || _fixturesLoading
              ? null
              : () => _section == 'fixtures'
                  ? _loadFixtures()
                  : _load(refresh: true),
          icon: const Icon(Icons.refresh, size: 17)),
    ];
    return Padding(
      padding: EdgeInsets.all(compactSportsControls(context) ? 8 : 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (widget.team case final team?) ...[
            Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 6),
                child: SportsLogo(
                    url: team.logoUrl,
                    size: 36,
                    fallback: team.abbreviation.isEmpty
                        ? team.name
                        : team.abbreviation,
                    animate: false)),
          ],
          Expanded(
              child: SportsPopupHeader(
                  title: _title,
                  description: widget.league.name,
                  showClose: !widget.embedded)),
        ]),
        if (!_revealed)
          Expanded(
              child: Center(
                  child: TextButton.icon(
                      key: const ValueKey('sports-reveal-details'),
                      onPressed: () {
                        setState(() => _revealed = true);
                        unawaited(_load());
                      },
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('Show game details and scores'))))
        else ...[
          if (compact)
            Wrap(
                spacing: 4,
                runSpacing: 4,
                children:
                    navigation.where((widget) => widget is! SizedBox).toList())
          else
            Row(children: [
              Expanded(
                  child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: navigation))),
              ...controls
            ]),
          if (selected != null && hasRelatedSections)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SportsFilterButton(
                    caption:
                        sportsPlayerSection(selected) ? 'Team / group' : 'View',
                    value: selected.title,
                    minimumHeight: tv ? 34 : sportsTouchControlHeight(context),
                    onTap: () => _chooseSection(
                        players: selected.kind == SportsDetailKind.information
                            ? null
                            : sportsPlayerSection(selected)))),
          SizedBox(
              height: 4,
              child: _loading || _fixturesLoading
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null),
          if (_data?.message case final message?)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(
                      child: Text(message,
                          style: TextStyle(
                              fontSize: 11, color: colors.onSurfaceVariant))),
                  if (_data?.failed == true) ...[
                    const SizedBox(width: 6),
                    TextButton(
                        style: sportsPopupButtonStyle(context),
                        onPressed: _loading ? null : () => _load(refresh: true),
                        child: const Text('Retry')),
                  ],
                ])),
          Expanded(
              child: _section == 'fixtures'
                  ? _fixtureList()
                  : selected != null
                      ? SportsDetailTable(
                          key: ValueKey(selected.title), section: selected)
                      : _overview(sections)),
          Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Row(children: [
                Expanded(
                    child: Text(
                        _data == null
                            ? 'Details load only while opened'
                            : _data!.unsupported
                                ? '${_data!.source} · overview only'
                                : _data!.failed && !_data!.stale
                                    ? '${_data!.source} · unavailable'
                                    : '${_data!.source} · ${_data!.stale ? 'Saved' : 'Loaded'} ${TimeFormat.hm.format(_data!.fetchedAt.toLocal())}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10, color: colors.onSurfaceVariant))),
                if (compact) ...controls,
              ])),
        ],
      ]),
    );
  }

  Widget _overview(List<SportsDetailSection> sections) => SportsDetailSummary(
      league: widget.league,
      game: widget.game,
      team: widget.team,
      standing: widget.standing,
      data: _data,
      sections: sections,
      onSection: (index) => _selectSection('$index'),
      onRecord: widget.standing == null ||
              (widget.standing!.stats.isEmpty &&
                  widget.standing!.position == null)
          ? null
          : () => showStandingRecord(context, widget.standing!,
              sport: widget.league.espnPath.split('/').first),
      onFixtures: widget.team != null && supportsSportsScoreboard(widget.league)
          ? () => _selectSection('fixtures')
          : null);

  Widget _fixtureList() {
    if (_fixturesLoading && _fixtures == null) {
      return const Center(child: Text('Loading fixtures…'));
    }
    final games = _fixtures ?? const <SportsGame>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_incomplete)
        const Padding(
            padding: EdgeInsets.all(6),
            child: Text('Some fixtures may be unavailable. Refresh to retry.',
                style: TextStyle(fontSize: 11))),
      Expanded(
          child: games.isEmpty
              ? const Center(
                  child: Text('No published fixtures in the next 30 days',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12)))
              : CompactChoiceList(polished: true, striped: true, choices: [
                  for (final game in games)
                    CompactChoice(
                        id: 'team-fixture-${game.id}',
                        title: game.title,
                        subtitle:
                            '${DateFormat('EEE d MMM').format(game.start.toLocal())} · ${sportsFixtureHasUnknownTime(game) ? 'TBD' : TimeFormat.hm.format(game.start.toLocal())}',
                        onTap: () => showSportsGameDetails(context, game,
                            hideScores: widget.hideScores,
                            service: widget.service))
                ])),
    ]);
  }
}
