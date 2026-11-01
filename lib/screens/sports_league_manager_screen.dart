import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/sports.dart';
import '../services/storage_service.dart';
import '../services/sports_service.dart';
import '../utils/constants.dart';
import '../utils/tv_theme.dart';
import '../utils/sports_presentation.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/section_label.dart';
import '../widgets/settings_scaffold.dart';
import '../widgets/sports_widgets.dart';
import '../widgets/tv_menu_tile.dart';
import '../l10n/l10n.dart';

/// Every supported league is available here. Selection controls which feeds
/// are searched; there is no separate catalogue subscription or add step.
/// Saves on every change and returns true when the selection changed.
class SportsLeagueManagerScreen extends StatefulWidget {
  const SportsLeagueManagerScreen({super.key});

  @override
  State<SportsLeagueManagerScreen> createState() =>
      _SportsLeagueManagerScreenState();
}

class _SportsLeagueManagerScreenState extends State<SportsLeagueManagerScreen> {
  late final StorageService _storage = context.read<StorageService>();

  /// Shown league ids, in the Sports tab's chip order.
  late List<String> _shown;

  /// The favourite league id, or null.
  late String? _favorite = _storage.getSportsFavoriteLeague();
  bool _changed = false;
  bool _savingAll = false;

  List<String> get _availableIds => {
        for (final league in [...kSportsLeagues, ...kSportsLeagueBank])
          league.id,
      }.toList();
  bool get _allEnabled => _availableIds.every(_shown.contains);

  Future<void> _enableAll() async {
    if (_savingAll || _allEnabled) return;
    setState(() {
      _savingAll = true;
      _shown = {..._shown, ..._availableIds}.toList();
    });
    try {
      await _save();
    } finally {
      if (mounted) {
        setState(() => _savingAll = false);
        if (_leagues.isNotEmpty) _focusLater(_leagues.first.id);
      }
    }
  }

  final _allFocus = FocusNode(debugLabel: 'leagues-enable-all');
  final Map<String, FocusNode> _nodes = {};

  FocusNode _node(String id) => _nodes.putIfAbsent(id, FocusNode.new);

  @override
  void initState() {
    super.initState();
    _shown = savedSportsLeagues(_storage).map((l) => l.id).toList();
  }

  @override
  void dispose() {
    _allFocus.dispose();
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  String _groupOf(SportsLeague league) {
    if (league.region != null) return league.region!;
    final parts = league.espnPath.split('/');
    if (parts.first == 'soccer') {
      return switch (parts.last.split('.').first) {
        'eng' => 'England',
        'esp' => 'Spain',
        'ger' => 'Germany',
        'ita' => 'Italy',
        'fra' => 'France',
        'usa' => 'Americas',
        'uefa' => 'Europe',
        _ => 'World',
      };
    }
    return switch (parts.first) {
      'football' => 'American football',
      'basketball' => 'Basketball',
      'baseball' => 'Baseball',
      'hockey' => 'Hockey',
      'rugby' => 'Rugby',
      'mma' || 'boxing' => 'Fighting',
      'poker' => 'Poker',
      _ => 'Other',
    };
  }

  List<SportsLeague> get _leagues {
    final groups = <String, List<SportsLeague>>{};
    final leagues = [...kSportsLeagues, ...kSportsLeagueBank];
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

  Future<void> _save() async {
    _changed = true;
    // A disabled league cannot remain the favourite.
    if (_favorite != null && !_shown.contains(_favorite)) _favorite = null;
    await _storage.setSportsLeagues(_shown);
    await _storage.setHiddenGuideLeagues([
      for (final l in kAutomaticSportsLeagues)
        if (!_shown.contains(l.id)) l.id,
    ]);
    await _storage.setSportsFavoriteLeague(_favorite);
    await _storage.setSportsAllLeagues(_allEnabled);
  }

  /// Hold OK to change the favourite without changing the catalogue.
  Future<void> _openMenu(SportsLeague l) async {
    final favorite = _favorite == l.id;
    final action = await showDialog<String>(
      context: context,
      // Opened by a hold: drop the held OK's repeats.
      builder: (context) => SwallowHeldActivate(
        child: AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          title: Text(l.name),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TvMenuTile(
                  autofocus: true,
                  icon: favorite ? Icons.star_outline : Icons.star,
                  title: favorite
                      ? tr('Remove from favourite')
                      : tr('Make favourite league'),
                  subtitle: favorite
                      ? null
                      : tr(
                          '{tab} opens on it and its games come first in Live now',
                          {'tab': AppConstants.sportsTabName}),
                  onTap: () => Navigator.of(context).pop('favorite'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'favorite') {
      setState(() {
        _favorite = favorite ? null : l.id;
        // The favourite is always shown.
        if (!favorite && !_shown.contains(l.id)) _shown.add(l.id);
      });
      await _save();
    }
  }

  void _toggleShown(SportsLeague l) {
    if (_shown.contains(l.id)) {
      // The Sports tab needs at least one league.
      if (_shown.length == 1) return;
      setState(() => _shown.remove(l.id));
    } else {
      setState(() => _shown.add(l.id));
    }
    _save();
  }

  void _focusLater(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _nodes[id];
      if (node?.context == null) return;
      node!.requestFocus();
      Scrollable.ensureVisible(node.context!, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final yours = _leagues;
    final rows = <Widget>[
      for (final (i, league) in yours.indexed) ...[
        if (i == 0 || _groupOf(yours[i - 1]) != _groupOf(league))
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
            child: SectionLabel(tr(_groupOf(league))),
          ),
        _leagueTile(league, autofocus: i == 0),
      ],
    ];
    final body = ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, index) => rows[index],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                !_allEnabled &&
                yours.isNotEmpty &&
                _node(yours.first.id).hasFocus) {
              _allFocus.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                _allFocus.hasFocus &&
                yours.isNotEmpty) {
              _node(yours.first.id).requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SportsScreenFrame(
            child: withTvThemeIfNeeded(
              context,
              (context) => Stack(
                children: [
                  const Positioned.fill(child: SettingsGradientBackground()),
                  Scaffold(
                    backgroundColor: Colors.transparent,
                    body: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 44,
                              child: Row(
                                children: [
                                  const SportsBackButton(),
                                  Text(tr('Leagues'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(
                                              fontWeight: FontWeight.w800)),
                                ],
                              ),
                            ),
                            Wrap(
                              spacing: 16,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                    '${_shown.length} of ${_availableIds.length} enabled · Select leagues to include',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontSize: 12)),
                                OutlinedButton.icon(
                                  key: const ValueKey('enable-all-leagues'),
                                  focusNode: _allFocus,
                                  onPressed: _savingAll || _allEnabled
                                      ? null
                                      : _enableAll,
                                  icon: const Icon(Icons.done_all, size: 18),
                                  label: Text(_allEnabled
                                      ? 'All leagues enabled'
                                      : 'Enable all leagues'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Expanded(child: body),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )),
    );
  }

  Widget _leagueTile(SportsLeague l, {required bool autofocus}) {
    final shown = _shown.contains(l.id);
    final scheme = Theme.of(context).colorScheme;
    final favorite = _favorite == l.id;
    final subtitle = [
      if (favorite) tr('Favourite league'),
      if (l.source == 'Channel guide')
        tr('From your TV guide · no separate score feed'),
    ].join(' · ');
    return HoldToActivate(
      key: ValueKey('league:${l.id}'),
      onTap: () => _toggleShown(l),
      onHold: () => _openMenu(l),
      child: TvMenuTile(
        focusNode: _node(l.id),
        autofocus: autofocus,
        leading: SportsLogo(url: l.logoUrl, size: 36, fallback: l.shortName),
        title: l.name,
        subtitle: subtitle.isEmpty ? null : subtitle,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (favorite)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.star, color: scheme.primary),
            ),
          Icon(shown ? Icons.check_circle : Icons.radio_button_unchecked,
              color: shown
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.35)),
        ]),
        onTap: () => _toggleShown(l),
      ),
    );
  }
}
