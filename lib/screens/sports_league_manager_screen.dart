import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/sports.dart';
import '../services/storage_service.dart';
import '../services/sports_service.dart';
import '../utils/constants.dart';
import '../utils/guarded_dialog.dart';
import '../utils/tv_theme.dart';
import '../utils/sports_presentation.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/sports_widgets.dart';
import '../widgets/sports_header_controls.dart';
import '../widgets/sports_filter_picker.dart' show sportLabel;
import '../widgets/compact_choice_list.dart';
import '../widgets/tv_text_field_gate.dart';

/// Local catalogue controls. Each completed edit saves without leaving the list.
class SportsLeagueManagerScreen extends StatefulWidget {
  const SportsLeagueManagerScreen({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<SportsLeagueManagerScreen> createState() =>
      _SportsLeagueManagerScreenState();
}

class _SportsLeagueManagerScreenState extends State<SportsLeagueManagerScreen> {
  late final StorageService _storage = context.read<StorageService>();
  late Set<String> _shown;
  late String? _favorite = _storage.getSportsFavoriteLeague();
  bool _changed = false, _saving = false;
  Future<void>? _pendingSave;
  bool _closing = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'leagues-search');
  final _closeFocus = FocusNode(debugLabel: 'leagues-close');
  final _allFocus = FocusNode(debugLabel: 'leagues-enable-all');
  final _scroll = ScrollController();
  String _query = '', _state = 'all';
  String? _sport;
  late List<SportsLeague> _visibleLeagues;
  late final _searchText = {
    for (final l in _leagues)
      l.id:
          '${l.name} ${l.shortName} ${leagueDescription(l)} ${l.region ?? ''} ${_groupOf(l)}'
              .toLowerCase()
  };
  static final _availableIds = {
    for (final l in [...kSportsLeagues, ...kSportsLeagueBank]) l.id
  };
  bool get _allEnabled => _availableIds.every(_shown.contains);

  void _filter() {
    final terms =
        _query.toLowerCase().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    _visibleLeagues = _leagues
        .where((l) =>
            (_sport == null || _sportOf(l) == _sport) &&
            (_state == 'all' ||
                (_state == 'enabled') == _shown.contains(l.id)) &&
            terms.every(_searchText[l.id]!.contains))
        .toList();
  }

  void _changeFilter(VoidCallback change) {
    setState(() {
      change();
      _filter();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void initState() {
    super.initState();
    _shown = savedSportsLeagues(_storage).map((l) => l.id).toSet();
    _filter();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _closeFocus.dispose();
    _allFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _sportOf(SportsLeague league) => league.espnPath.split('/').first;
  String _groupOf(SportsLeague league) => sportLabel(_sportOf(league));

  late final List<SportsLeague> _leagues = _orderedLeagues();

  List<SportsLeague> _orderedLeagues() {
    final groups = <String, List<SportsLeague>>{};
    final leagues = {
      for (final l in [...kSportsLeagues, ...kSportsLeagueBank]) l.id: l
    }.values.toList();
    final order = {for (final (i, league) in leagues.indexed) league.id: i};
    for (final league in leagues) {
      (groups[_groupOf(league)] ??= []).add(league);
    }
    for (final group in groups.values) {
      group.sort((a, b) {
        final priority =
            leagueDisplayPriority(a).compareTo(leagueDisplayPriority(b));
        return priority != 0 ? priority : order[a.id]!.compareTo(order[b.id]!);
      });
    }
    return groups.values.expand((group) => group).toList();
  }

  Future<void> _persist(Set<String> shown, String? favorite) async {
    await _storage.setSportsLeagues(shown.toList());
    await _storage.setHiddenGuideLeagues([
      for (final l in kAutomaticSportsLeagues)
        if (!shown.contains(l.id)) l.id,
    ]);
    await _storage.setSportsFavoriteLeague(favorite);
    await _storage.setSportsAllLeagues(_availableIds.every(shown.contains));
  }

  Future<void> _apply(Set<String> next, String? favorite) async {
    if (_saving ||
        _closing ||
        (next.length == _shown.length &&
            next.containsAll(_shown) &&
            favorite == _favorite)) {
      return;
    }
    if (next.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Keep at least one league enabled.')));
      return;
    }
    final previous = Set<String>.of(_shown), previousFavorite = _favorite;
    setState(() {
      _saving = true;
      _shown = next;
      _favorite = favorite;
      _filter();
    });
    final complete = Completer<void>();
    _pendingSave = complete.future;
    try {
      await _persist(next, favorite);
      _changed = true;
    } catch (_) {
      // Restore both the local view and any preference writes completed before failure.
      try {
        await _persist(previous, previousFavorite);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _shown = previous;
          _favorite = previousFavorite;
          _filter();
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save leagues. Please try again.')));
      }
    } finally {
      _pendingSave = null;
      if (mounted) setState(() => _saving = false);
      complete.complete();
    }
  }

  void _toggle(SportsLeague league) {
    final next = Set<String>.of(_shown);
    if (!next.remove(league.id)) next.add(league.id);
    _apply(next, next.contains(_favorite) ? _favorite : null);
  }

  void _bulk(bool enable) {
    final ids = _visibleLeagues.map((l) => l.id).toSet();
    final next = enable ? {..._shown, ...ids} : _shown.difference(ids);
    _apply(next, next.contains(_favorite) ? _favorite : null);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _pendingSave;
    } catch (_) {}
    // Allow rollback/finalisation to complete before returning to Sports.
    if (mounted) popRouteIfCurrent(context, _changed);
  }

  Future<void> _chooseSport() async {
    final sports = _leagues.map(_sportOf).toSet().toList()
      ..sort((a, b) => sportLabel(a).compareTo(sportLabel(b)));
    final result = await showSportsChoices<String>(context,
        title: 'Filter by sport',
        selected: _sport ?? '',
        choices: [
          const SportsChoice('', 'All sports', ''),
          for (final sport in sports)
            SportsChoice(sport, sportLabel(sport),
                '${_leagues.where((l) => _sportOf(l) == sport).length} leagues'),
        ]);
    if (mounted && result != null) {
      _changeFilter(() => _sport = result.isEmpty ? null : result);
    }
  }

  Future<void> _chooseState() async {
    final result = await showSportsChoices<String>(context,
        title: 'Show leagues',
        selected: _state,
        choices: const [
          SportsChoice('all', 'All leagues', ''),
          SportsChoice('enabled', 'Enabled only', ''),
          SportsChoice('disabled', 'Disabled only', ''),
        ]);
    if (mounted && result != null) _changeFilter(() => _state = result);
  }

  Future<void> _openMenu(SportsLeague league) async {
    final favorite = _favorite == league.id;
    final action = await showSportsChoices<String>(context,
        title: league.name,
        selected: '',
        showSelection: false,
        choices: [
          SportsChoice(
              'favorite',
              favorite ? 'Remove from favourite' : 'Make favourite league',
              favorite
                  ? ''
                  : '${AppConstants.sportsTabName} opens on it and its games come first in Live now',
              icon: favorite ? Icons.star_outline : Icons.star),
        ]);
    if (mounted && action == 'favorite') {
      await _apply({..._shown, league.id}, favorite ? null : league.id);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: widget.embedded
            ? withTvThemeIfNeeded(context, _content)
            : SportsScreenFrame(
                child: withTvThemeIfNeeded(
                    context,
                    (context) => Stack(children: [
                          const Positioned.fill(
                              child: SettingsGradientBackground()),
                          Scaffold(
                              backgroundColor: Colors.transparent,
                              body: SafeArea(child: _content(context))),
                        ]))),
      );

  Widget _content(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shownCount =
        _visibleLeagues.where((l) => _shown.contains(l.id)).length;
    final choices = [
      for (final l in _visibleLeagues)
        CompactChoice(
          id: l.id,
          title: l.name,
          group: _groupOf(l),
          subtitle: [
            if (_favorite == l.id) 'Favourite',
            if (l.region != null) l.region!,
            if (l.source == 'Channel guide') 'TV guide'
          ].join(' · '),
          leading: SportsLogo(
              url: l.logoUrl, size: 24, fallback: l.shortName, animate: false),
          trailing: Icon(
              _shown.contains(l.id)
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 18,
              color: _shown.contains(l.id)
                  ? colors.primary
                  : colors.onSurfaceVariant),
          onTap: () => _toggle(l),
          onHold: () => _openMenu(l),
        )
    ];
    return Padding(
        padding: EdgeInsets.fromLTRB(
            widget.embedded ? 10 : 16, 4, widget.embedded ? 10 : 16, 8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
              height: 40,
              child: Row(children: [
                const Expanded(
                    child: Text('Enabled leagues',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600))),
                IconButton(
                    key: const ValueKey('close-leagues'),
                    focusNode: _closeFocus,
                    tooltip: 'Close',
                    onPressed: _close,
                    icon: const Icon(Icons.close, size: 20)),
              ])),
          Row(children: [
            Expanded(
                child: SportsFilterButton(
                    key: const ValueKey('league-manager-sport'),
                    caption: 'Sport',
                    value: _sport == null ? 'All sports' : sportLabel(_sport!),
                    onTap: _chooseSport)),
            const SizedBox(width: 6),
            Expanded(
                child: SportsFilterButton(
                    key: const ValueKey('league-manager-state'),
                    caption: 'Show',
                    value: switch (_state) {
                      'enabled' => 'Enabled only',
                      'disabled' => 'Disabled only',
                      _ => 'All leagues'
                    },
                    onTap: _chooseState)),
          ]),
          const SizedBox(height: 6),
          TvTextFieldGate(
              focusNode: _searchFocus,
              builder: (context, readOnly) => TextField(
                    key: const ValueKey('league-manager-search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    readOnly: readOnly,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search leagues or countries',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.clear, size: 17),
                                onPressed: () {
                                  _search.clear();
                                  _changeFilter(() => _query = '');
                                  _searchFocus.requestFocus();
                                })),
                    onChanged: (query) => _changeFilter(() => _query = query),
                  )),
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Wrap(spacing: 6, runSpacing: 2, children: [
                OutlinedButton(
                    key: const ValueKey('enable-visible-leagues'),
                    style: sportsPopupButtonStyle(context),
                    onPressed: _saving || shownCount == choices.length
                        ? null
                        : () => _bulk(true),
                    child: const Text('Enable shown')),
                OutlinedButton(
                    key: const ValueKey('disable-visible-leagues'),
                    style: sportsPopupButtonStyle(context),
                    onPressed:
                        _saving || shownCount == 0 ? null : () => _bulk(false),
                    child: const Text('Disable shown')),
                OutlinedButton(
                    key: const ValueKey('enable-all-leagues'),
                    focusNode: _allFocus,
                    style: sportsPopupButtonStyle(context),
                    onPressed: _saving || _allEnabled
                        ? null
                        : () =>
                            _apply({..._shown, ..._availableIds}, _favorite),
                    child: Text(_allEnabled
                        ? 'All leagues enabled'
                        : 'Enable all leagues')),
              ])),
          Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                  '${choices.length} shown · ${_shown.length} enabled · ${_saving ? 'Saving…' : 'Saved automatically'}',
                  style:
                      TextStyle(fontSize: 10, color: colors.onSurfaceVariant))),
          Expanded(
              child: choices.isEmpty
                  ? const Center(
                      child: Text('No matching leagues',
                          style: TextStyle(fontSize: 12)))
                  : CompactChoiceList(
                      controller: _scroll,
                      autofocus: !_searchFocus.hasFocus,
                      choices: choices,
                      polished: true,
                      striped: true,
                      showNavigation: true,
                      rowHeight: 48 *
                          (MediaQuery.textScalerOf(context).scale(12) / 12)
                              .clamp(1.0, 2.5),
                      resetScrollKey: (_sport, _state, _query),
                      onExitUp: _searchFocus.requestFocus,
                    )),
          const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                  'OK: enable / disable · Hold OK: favourite · →: page controls',
                  style: TextStyle(fontSize: 10))),
        ]));
  }
}
