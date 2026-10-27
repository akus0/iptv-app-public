import '../utils/interface_colors.dart';
import 'sports_header_controls.dart';
import 'sports_toolbar_navigation.dart';
import 'sports_hub_layout.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ScrollCacheExtent, RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../services/epg_service.dart';
import '../services/app_preferences.dart';
import '../services/playlist_manager.dart';
import '../services/sports_replay_service.dart';
import '../services/replay_schedule_service.dart';
import '../utils/replay_event_date.dart';
import '../utils/replay_browse_index.dart';
import '../utils/replay_presentation.dart';
import 'hold_to_activate.dart';
import 'cached_channel_logo.dart';
import 'sports_filter_picker.dart';
import 'sports_refresh_control.dart';
import 'sports_activity_status.dart';
import 'tv_text_field_gate.dart';

class SportsReplaysPanel extends StatefulWidget {
  const SportsReplaysPanel(
      {super.key,
      required this.onPlay,
      required this.active,
      this.playingId,
      this.highlights = false,
      this.service,
      this.dateService,
      this.onFocusToolbar,
      this.headerBuilder,
      this.layoutBuilder});
  final Future<void> Function(Channel) onPlay;
  final bool active;
  final bool highlights;
  final String? playingId;
  final VoidCallback? onFocusToolbar;
  final SportsReplayService? service;
  final ReplayScheduleService? dateService;

  /// Places the controls above the shared preview without lifting scan state
  /// into the whole sports screen. The preview keeps its identity across tabs.
  final Widget Function(Widget filters, Widget activity, Widget actions)?
      headerBuilder;
  final Widget Function(
          Widget filters, Widget activity, Widget actions, Widget content)?
      layoutBuilder;
  @override
  State<SportsReplaysPanel> createState() => SportsReplaysPanelState();
}

enum _ReplaySort { popular, recent, started, ending }

class SportsReplaysPanelState extends State<SportsReplaysPanel> {
  late final EpgService _epg;
  late final PlaylistManager _playlist;
  late final SportsReplayService _service;
  late final ReplayScheduleService _dateService;
  ReplaySnapshot? _snapshot;
  ReplaySnapshot? _sourceSnapshot;
  String get _programmes => widget.highlights ? 'highlights' : 'replays';
  List<Channel> _channels = [];
  int _playlistRevision = -1;
  bool _loading = false;
  Future<bool>? _refreshTask;
  bool _refreshPending = false, _forcePending = false;
  String? _error;
  String? _sport;
  _ReplaySort _sort = _ReplaySort.popular;
  final _pullActivity = ValueNotifier<String?>(null);
  bool _searching = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  List<String> _searchTerms = [];
  final _searchIndex = <String, String>{};
  final _priorities = <String, int>{};
  final _leagueInitials = <String, String?>{};
  ReplayDateRange _range = ReplayDateRange.all;
  bool _includeLikely = false;
  bool _checkingDates = false;
  int _request = 0;
  Timer? _timer;
  Timer? _debounce;
  final _scroll = ScrollController();
  final _sportFocus = FocusNode();
  final _sortFocus = FocusNode();
  final _dateFocus = FocusNode();
  final _refreshFocus = FocusNode(debugLabel: 'replays-refresh');
  List<SportsReplay> _navigationEvents = const [];
  String? _lastFocusedEvent;
  bool get _tvNavigation => context.read<AppPreferences>().isTelevision;

  void focusRefresh() => _refreshFocus.requestFocus();

  void focusContent() {
    if (_navigationEvents.isEmpty) {
      focusRefresh();
      return;
    }
    final index =
        _navigationEvents.indexWhere((e) => e.id == _lastFocusedEvent);
    final target = index < 0 ? 0 : index;
    _step(_navigationEvents, target, 0);
  }

  void _focusToolbar() {
    if (widget.onFocusToolbar case final focus?) {
      focus();
    } else {
      _sportFocus.requestFocus();
    }
  }

  final _nodes = <String, FocusNode>{};

  @override
  void initState() {
    super.initState();
    _epg = context.read<EpgService>();
    _playlist = context.read<PlaylistManager>();
    _service = widget.service ?? SportsReplayService.shared(_epg);
    _dateService = widget.dateService ?? ReplayScheduleService.instance;
    _epg.addListener(_changed);
    _epg.guideRowsLoaded.addListener(_changed);
    _playlist.addListener(_changed);
    unawaited(refresh());
  }

  @override
  void didUpdateWidget(SportsReplaysPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _timer?.cancel();
      _debounce?.cancel();
      if (widget.active) unawaited(refresh());
    }
  }

  void _changed() {
    if (!widget.active) return;
    _debounce?.cancel();
    if (_loading) {
      // Retain one follow-up, regardless of how many guide batches arrive.
      unawaited(refresh());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () => refresh());
  }

  Future<bool> refresh({bool force = false}) {
    if (!mounted || !widget.active) return Future.value(false);
    _refreshPending = true;
    _forcePending |= force;
    return _refreshTask ??= _drainRefresh().whenComplete(() {
      _refreshTask = null;
    });
  }

  Future<bool> _drainRefresh() async {
    var success = false;
    while (mounted && widget.active && _refreshPending) {
      final force = _forcePending;
      _refreshPending = false;
      _forcePending = false;
      success = await _refreshOnce(force: force);
    }
    return success;
  }

  Future<bool> _refreshOnce({required bool force}) async {
    final request = ++_request;
    _timer?.cancel();
    _debounce?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    var success = false;
    try {
      // Observe the normal catalogue restore only. In particular, a replay
      // refresh must never trigger a provider fetch if its cache is missing.
      await _playlist.whenRestored;
      if (!mounted || request != _request) return false;
      if (_playlistRevision != _playlist.liveRevision) {
        _channels = _playlist.visibleLiveChannels;
        _playlistRevision = _playlist.liveRevision;
      }
      final source = await _service.load(_channels,
          revision: (identityHashCode(_playlist), _playlistRevision),
          force: force);
      if (!mounted || request != _request) return false;
      if (_playlistRevision != _playlist.liveRevision) {
        // A removed/hidden channel must not return from an older scan.
        _refreshPending = true;
        return false;
      }
      final result = identical(_sourceSnapshot, source) && _snapshot != null
          ? _snapshot!
          : widget.highlights
              ? ReplaySnapshot(source.highlights, source.channelsWithGuide)
              : source;
      _sourceSnapshot = source;
      if (!identical(_snapshot, result)) {
        _searchIndex.clear();
        _priorities.clear();
        _leagueInitials.clear();
        for (final event in result.events) {
          _leagueInitials[event.id] =
              replayLeagueInitials(event.sport, event.title);
          _priorities[event.id] = replayLeaguePriority(event.sport, event.title,
              event.broadcasts.first.programme.description);
          final parts = replayTitleParts(event.title, event.sport,
              highlights: widget.highlights,
              description: event.broadcasts.first.programme.description);
          _searchIndex[event.id] = replaySearchText([
            event.title,
            parts.title,
            parts.competition,
            sportLabel(event.sport),
            for (final b in event.broadcasts)
              '${b.channel.name} ${b.channel.group}',
          ].join(' '));
        }
      }
      setState(() => _snapshot = result);
      if (!widget.highlights) _enrichDates(result, request);
      final keep = result.events.map((e) => e.id).toSet();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || request != _request) return;
        for (final id in _nodes.keys.toList()) {
          if (!keep.contains(id)) {
            final node = _nodes.remove(id)!;
            if (node.hasFocus) _sportFocus.requestFocus();
            node.dispose();
          }
        }
      });
      success = true;
    } catch (_) {
      if (mounted && request == _request) {
        setState(
            () => _error = 'Couldn’t read the guide. Tap refresh to retry.');
      }
    } finally {
      if (mounted && request == _request) {
        setState(() => _loading = false);
        _scheduleTick();
      }
    }
    return success;
  }

  ReplayEventDate? _date(SportsReplay event) =>
      widget.highlights ? null : event.eventDate ?? _dateService.known(event);

  void _enrichDates(ReplaySnapshot snapshot, int request) {
    if (_checkingDates) return;
    _checkingDates = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool cancelled() => !mounted || !widget.active || request != _request;
      try {
        await _dateService.enrich(snapshot.events, cancelled: cancelled,
            onUpdate: () {
          if (!cancelled()) setState(() {});
        });
      } catch (_) {
        // Optional dates must never interrupt the local guide or its controls.
      } finally {
        if (mounted) {
          setState(() => _checkingDates = false);
          if (widget.active && request != _request && _snapshot != null) {
            _enrichDates(_snapshot!, _request);
          }
        }
      }
    });
  }

  void _scheduleTick() {
    if (!widget.active) return;
    final now = DateTime.now();
    var delay = const Duration(seconds: 30);
    for (final event in _snapshot?.events ?? const <SportsReplay>[]) {
      for (final b in event.broadcasts) {
        final remaining = b.programme.stop.difference(now);
        if (remaining > Duration.zero && remaining < delay) delay = remaining;
      }
    }
    _timer = Timer(delay, () => refresh());
  }

  @override
  void dispose() {
    _request++;
    _timer?.cancel();
    _debounce?.cancel();
    _epg.removeListener(_changed);
    _epg.guideRowsLoaded.removeListener(_changed);
    _playlist.removeListener(_changed);
    _pullActivity.dispose();
    _scroll.dispose();
    _sportFocus.dispose();
    _sortFocus.dispose();
    _dateFocus.dispose();
    _refreshFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  final _browseIndex = ReplayBrowseIndex();

  bool _matchesFilters(SportsReplay event, DateTime now) =>
      (_sport == null || event.sport == _sport) &&
      (_includeLikely || event.evidence != ReplayEvidence.likely) &&
      _matchesSearch(event) &&
      replayDateInRange(event.eventDate, _range, now);

  bool _matchesSearch(SportsReplay event) => _searchTerms
      .every((term) => (_searchIndex[event.id] ?? '').contains(term));

  void _searchChanged(String value) {
    setState(() => _searchTerms =
        replaySearchText(value).split(' ').where((s) => s.isNotEmpty).toList());
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchTerms = [];
        _searchController.clear();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_searching) {
        _searchFocus.requestFocus();
      } else {
        _sportFocus.requestFocus();
      }
    });
  }

  Future<void> _chooseSport() async {
    final counts = <String, int>{};
    for (final event in _snapshot?.events ?? const <SportsReplay>[]) {
      if (!_includeLikely && event.evidence == ReplayEvidence.likely) continue;
      if (!_matchesSearch(event)) continue;
      if (!replayDateInRange(event.eventDate, _range, DateTime.now()) ||
          !event.broadcasts
              .any((b) => b.programme.isNowPlaying(DateTime.now()))) {
        continue;
      }
      counts.update(event.sport, (n) => n + 1, ifAbsent: () => 1);
    }
    final sports = counts.keys.toList()
      ..sort((a, b) => sportLabel(a).compareTo(sportLabel(b)));
    final choice = await showSportsChoices(context,
        title: widget.highlights ? 'Highlight sport' : 'Replay sport',
        selected: _sport ?? '',
        choices: [
          for (final sport in ['', ...sports])
            SportsChoice(
                sport,
                sport.isEmpty ? 'All sports' : sportLabel(sport),
                '${sport.isEmpty ? counts.values.fold(0, (a, b) => a + b) : counts[sport]} programmes on air',
                icon: sport.isEmpty ? Icons.sports : sportIcon(sport))
        ]);
    if (choice == null || !mounted) return;
    setState(() => _sport = choice.isEmpty ? null : choice);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  String get _sortLabel => switch (_sort) {
        _ReplaySort.popular => 'Top leagues',
        _ReplaySort.recent => 'Recent events',
        _ReplaySort.started => 'Just started',
        _ReplaySort.ending => 'Ending soon',
      };

  Future<void> _chooseSort() async {
    final choice = await showSportsChoices(context,
        title: 'Sort $_programmes',
        selected: _sort,
        description: 'Order within each sport',
        choices: [
          SportsChoice(
              _ReplaySort.popular,
              'Top leagues',
              widget.highlights
                  ? 'Leading competitions first within each sport.'
                  : 'Leading competitions first, then newest event dates.',
              icon: Icons.emoji_events_outlined),
          if (!widget.highlights)
            const SportsChoice(_ReplaySort.recent, 'Recent events',
                'Newest event dates first. Unknown dates stay at the end.',
                icon: Icons.history),
          const SportsChoice(_ReplaySort.started, 'Just started',
              'Programmes that began airing most recently.',
              icon: Icons.play_circle_outline),
          const SportsChoice(_ReplaySort.ending, 'Ending soon',
              'Catch programmes before their current airing finishes.',
              icon: Icons.hourglass_bottom),
        ]);
    if (choice == null || !mounted) return;
    setState(() => _sort = choice);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _chooseDate() async {
    final now = DateTime.now();
    final candidates = _snapshot?.events
            .where((e) =>
                (_sport == null || e.sport == _sport) &&
                (_includeLikely || e.evidence != ReplayEvidence.likely) &&
                _matchesSearch(e) &&
                e.broadcasts.any((b) => b.programme.isNowPlaying(now)))
            .toList() ??
        <SportsReplay>[];
    final choice = await showSportsChoices(context,
        title: 'Replay event date',
        selected: _range,
        description:
            'The date the event took place, not when this replay is airing. Recent means the past 4 weeks.',
        choices: [
          for (final range in ReplayDateRange.values)
            SportsChoice(
                range,
                _rangeLabel(range),
                '${candidates.where((e) => replayDateInRange(e.eventDate, range, now)).length} programmes · ${switch (range) {
                  ReplayDateRange.all => 'Every event date',
                  ReplayDateRange.recent => 'Events from the past 4 weeks',
                  ReplayDateRange.older => 'Events more than 4 weeks ago',
                  ReplayDateRange.unknown => 'Dates not yet verified',
                }}',
                icon: Icons.calendar_today_outlined)
        ]);
    if (choice == null || !mounted) return;
    setState(() => _range = choice);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _play(ReplayBroadcast broadcast) async {
    // A programme may finish while its details dialog is open. Never tune
    // an expired slot under the promise that this replay is still on.
    final current = _epg.getCurrentProgram(broadcast.channel.epgId);
    if (!broadcast.programme.isNowPlaying(DateTime.now()) ||
        current == null ||
        (!widget.highlights && isLiveSportsProgramme(current)) ||
        current.stop != broadcast.programme.stop ||
        current.description != broadcast.programme.description ||
        current.title != broadcast.programme.title ||
        current.start != broadcast.programme.start) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('This guide slot has changed. Refreshing $_programmes…')));
      }
      unawaited(refresh(force: true));
      return;
    }
    await widget.onPlay(broadcast.channel);
  }

  Future<void> _details(SportsReplay event) async {
    final programme = event.broadcasts.first.programme;
    final parts = replayTitleParts(event.title, event.sport,
        highlights: widget.highlights, description: programme.description);
    final broadcasts = event.broadcasts
        .where((b) => b.programme.isNowPlaying(DateTime.now()))
        .toList();
    final choice = await showDialog<ReplayBroadcast>(
        context: context,
        builder: (context) => SwallowHeldActivate(
                child: AlertDialog(
              backgroundColor: interfaceColor(context, const Color(0xFF20262E)),
              titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
              contentPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(parts.competition,
                        style: TextStyle(
                            fontSize: 11,
                            color: interfaceColor(context, Colors.white54))),
                    const SizedBox(height: 5),
                    Text(parts.title,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                  ]),
              content: SizedBox(
                  width: 620,
                  child: ListView(shrinkWrap: true, children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!widget.highlights)
                                _ReplayDateLine(
                                    date: _date(event), now: DateTime.now()),
                              const SizedBox(height: 7),
                              Text(event.reason,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: interfaceColor(
                                          context, Colors.white54))),
                              if ((programme.description ?? '').isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(
                                    replaySynopsisForDisplay(
                                        programme.description!),
                                    style: TextStyle(
                                        fontSize: 12,
                                        height: 1.4,
                                        color: interfaceColor(
                                            context, Colors.white70))),
                              ],
                            ])),
                    Divider(
                        height: 12,
                        color: interfaceColor(context, Colors.white10)),
                    Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                        child: Text(
                            'ON NOW · ${broadcasts.length} ${broadcasts.length == 1 ? 'CHANNEL' : 'CHANNELS'}',
                            style: TextStyle(
                                fontSize: 10,
                                letterSpacing: .6,
                                color:
                                    interfaceColor(context, Colors.white54)))),
                    for (final b in broadcasts)
                      Padding(
                          padding: const EdgeInsets.fromLTRB(2, 3, 2, 3),
                          child: Material(
                              color: interfaceColor(
                                  context, const Color(0xFF262F3A)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(5),
                                  side: BorderSide(
                                      color: b.channel.id == widget.playingId
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: .6)
                                          : interfaceColor(context, Colors.white)
                                              .withValues(alpha: .10))),
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  autofocus: b == broadcasts.first,
                                  selected: b.channel.id == widget.playingId,
                                  leading: CachedChannelLogo(
                                      url: b.channel.logoUrl,
                                      size: 26,
                                      icon: b.channel.id == widget.playingId
                                          ? Icons.equalizer
                                          : Icons.tv),
                                  trailing: const Icon(Icons.play_arrow_rounded,
                                      size: 20),
                                  title: Text(b.channel.name,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(_airing(b),
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: interfaceColor(
                                                    context, Colors.white70))),
                                        const SizedBox(height: 3),
                                        Text(b.channel.group,
                                            style: TextStyle(
                                                fontSize: 10.5,
                                                color: interfaceColor(
                                                    context, Colors.white38))),
                                      ])),
                                  onTap: () => Navigator.pop(context, b)))),
                    Divider(
                        height: 12,
                        color: interfaceColor(context, Colors.white10)),
                    ExpansionTile(
                        dense: true,
                        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                        title: Text(
                            widget.highlights
                                ? 'Original guide'
                                : 'Original guide & date source',
                            style: TextStyle(
                                fontSize: 11,
                                color:
                                    interfaceColor(context, Colors.white54))),
                        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!widget.highlights)
                            Text(
                                _date(event)?.source ??
                                    'No reliable original event date is supplied.',
                                style: TextStyle(
                                    fontSize: 11,
                                    height: 1.4,
                                    color: interfaceColor(
                                        context, Colors.white60))),
                          const SizedBox(height: 6),
                          Text(programme.title,
                              style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      interfaceColor(context, Colors.white60))),
                          if ((programme.description ?? '').isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(programme.description!,
                                style: TextStyle(
                                    fontSize: 11,
                                    height: 1.4,
                                    color: interfaceColor(
                                        context, Colors.white54))),
                          ],
                        ]),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'))
              ],
            )));
    if (choice != null && mounted) await _play(choice);
  }

  Future<void> _browseChannels() async {
    final channels = _snapshot?.unscheduled ?? const <ReplayChannel>[];
    final choice = await showDialog<Channel>(
        context: context,
        builder: (context) => AlertDialog(
              backgroundColor: interfaceColor(context, const Color(0xFF20262E)),
              titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
              contentPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              title: const Text('Replay channels',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              content: SizedBox(
                  width: 620,
                  height: MediaQuery.sizeOf(context).height * .58,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                            padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
                            child: Text(
                                'These channels are labelled for replays, but the guide has no current event details. Tap to try a channel; availability is unverified.',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    height: 1.35,
                                    color: interfaceColor(
                                        context, Colors.white60)))),
                        Expanded(
                            child: ListView.builder(
                                itemCount: channels.length,
                                itemBuilder: (context, i) {
                                  final entry = channels[i];
                                  return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (i == 0 ||
                                            channels[i - 1].sport !=
                                                entry.sport)
                                          Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      8, 8, 8, 3),
                                              child: Text(
                                                  sportLabel(entry.sport),
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .primary))),
                                        ListTile(
                                            dense: true,
                                            visualDensity:
                                                VisualDensity.compact,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 8),
                                            autofocus: i == 0,
                                            leading: Icon(
                                                entry.channel.id == widget.playingId
                                                    ? Icons.equalizer
                                                    : Icons.play_arrow_rounded,
                                                size: 18),
                                            title: Text(entry.channel.name,
                                                style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                            subtitle: Text(entry.channel.group,
                                                style: TextStyle(
                                                    fontSize: 10.5,
                                                    color: interfaceColor(
                                                        context,
                                                        Colors.white54))),
                                            onTap: () => Navigator.pop(
                                                context, entry.channel)),
                                      ]);
                                })),
                      ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'))
              ],
            ));
    if (choice == null || !mounted) return;
    final current = _epg.getCurrentProgram(choice.epgId);
    if (isUnscheduledReplayChannel(choice, current)) {
      await widget.onPlay(choice);
    } else if (current != null &&
        classifySportsReplay(current, channel: choice) != null) {
      await _play(ReplayBroadcast(choice, current));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('This channel’s guide has changed. Refreshing replays…')));
      unawaited(refresh(force: true));
    }
  }

  void _revealCard(BuildContext context) {
    final position = Scrollable.maybeOf(context)?.position;
    final box = context.findRenderObject();
    if (position == null || box is! RenderBox) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final heading = (MediaQuery.textScalerOf(context).scale(13) + 16)
        .clamp(30.0, double.infinity);
    // Measure in viewport coordinates: grouped pinned slivers adjust paint
    // offsets, so a generic reveal offset can scroll an already-visible card.
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottom = top + box.size.height;
    final delta = top < heading - .5
        ? top - heading
        : bottom > position.viewportDimension + .5
            ? bottom - position.viewportDimension
            : 0.0;
    if (delta != 0) {
      position.jumpTo((position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
    }
  }

  void _step(List<SportsReplay> events, int index, int delta) {
    final next = index + delta;
    if (next < 0) {
      _focusToolbar();
      return;
    }
    if (next >= events.length) return;
    final node = _nodes.putIfAbsent(events[next].id, () => FocusNode());
    void focus() {
      if (!mounted || !sportsFocusAttached(node)) return;
      node.requestFocus();
      _revealCard(node.context!);
    }

    if (!sportsFocusAttached(node) && _scroll.hasClients) {
      _scroll.jumpTo((_scroll.offset + delta * 160)
          .clamp(0.0, _scroll.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) => focus());
    } else {
      focus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final view = _browseIndex.resolve(
      events: _snapshot?.events ?? const [],
      configuration: (_sport, _includeLikely, _range, _sort, _searchTerms),
      now: now,
      matches: _matchesFilters,
      compare: (a, b) {
        final sport = a.sport.compareTo(b.sport);
        if (sport != 0) return sport;
        if (_sort == _ReplaySort.popular) {
          final league = _priorities[a.id]!.compareTo(_priorities[b.id]!);
          if (league != 0) return league;
        }
        if (_sort == _ReplaySort.recent || _sort == _ReplaySort.popular) {
          final date = (b.eventDate?.sortKey ?? -1)
              .compareTo(a.eventDate?.sortKey ?? -1);
          if (date != 0) return date;
        }
        final time = _sort == _ReplaySort.ending
            ? a.broadcasts.first.programme.stop
                .compareTo(b.broadcasts.first.programme.stop)
            : b.broadcasts.first.programme.start
                .compareTo(a.broadcasts.first.programme.start);
        return time != 0 ? time : a.title.compareTo(b.title);
      },
    );
    final events = view.events;
    final possibleCount = widget.highlights
        ? 0
        : (_snapshot?.events
                .where((e) =>
                    e.evidence == ReplayEvidence.likely &&
                    (_sport == null || e.sport == _sport) &&
                    _matchesSearch(e) &&
                    replayDateInRange(e.eventDate, _range, now))
                .length ??
            0);
    _navigationEvents = events;
    final eventPositions = view.positions;
    final ranges = view.ranges;
    final scheme = Theme.of(context).colorScheme;
    final filters = SizedBox(
        height: sportsFilterHeight(context),
        child: Row(children: [
          Expanded(
              child: SportsFilterButton(
                  key: const ValueKey('replay-sport-picker'),
                  caption: 'Sport',
                  value: _sport == null ? 'All sports' : sportLabel(_sport!),
                  focusNode: _sportFocus,
                  selected: _sport != null,
                  onTap: _chooseSport)),
          const SizedBox(width: 5),
          Expanded(
              child: SportsFilterButton(
                  key: const ValueKey('replay-sort-picker'),
                  caption: 'Sort by',
                  value: _sortLabel,
                  focusNode: _sortFocus,
                  selected: _sort != _ReplaySort.popular,
                  onTap: _chooseSort)),
          if (!widget.highlights) ...[
            const SizedBox(width: 5),
            Expanded(
                child: SportsFilterButton(
                    key: const ValueKey('replay-date-picker'),
                    caption: 'Event date',
                    value: _rangeLabel(_range),
                    focusNode: _dateFocus,
                    selected: _range != ReplayDateRange.all,
                    onTap: _chooseDate)),
          ],
        ]));
    final actions = SizedBox(
        width: 32,
        child: PopupMenuButton<String>(
            key: const ValueKey('replay-options'),
            tooltip: widget.highlights ? 'Highlight options' : 'Replay options',
            padding: EdgeInsets.zero,
            color: interfaceColor(context, const Color(0xFF19212B)),
            surfaceTintColor: Colors.transparent,
            elevation: 8,
            position: PopupMenuPosition.under,
            constraints: const BoxConstraints(minWidth: 272, maxWidth: 300),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(
                    color: interfaceColor(context, const Color(0xFF343E4A)))),
            icon: Icon(Icons.more_horiz,
                size: 19, color: interfaceColor(context, Colors.white70)),
            onSelected: (value) {
              if (value == 'search') _toggleSearch();
              if (value == 'channels') {
                _browseChannels();
              }
              if (value == 'likely') {
                setState(() => _includeLikely = !_includeLikely);
              }
            },
            itemBuilder: (_) => [
                  PopupMenuItem<String>(
                      value: 'search',
                      height: 54,
                      child: _ReplayMenuItem(
                          icon: _searching ? Icons.close : Icons.search,
                          title: _searching
                              ? 'Close search'
                              : 'Search $_programmes',
                          subtitle: 'Team, event, league or channel')),
                  if (!widget.highlights) ...[
                    const PopupMenuDivider(height: 9),
                    PopupMenuItem<String>(
                        value: 'likely',
                        height: 60,
                        child: _ReplayMenuItem(
                            icon: Icons.manage_search_rounded,
                            title: 'Include possible replays',
                            subtitle: 'Listings without a clear replay label',
                            count: possibleCount,
                            selected: _includeLikely)),
                    PopupMenuItem<String>(
                        value: 'channels',
                        height: 60,
                        key: const ValueKey('replay-channel-directory'),
                        enabled: _snapshot?.unscheduled.isNotEmpty ?? false,
                        child: _ReplayMenuItem(
                            icon: Icons.live_tv_outlined,
                            title: 'Replay channels',
                            subtitle: 'Current programme unverified',
                            count: _snapshot?.unscheduled.length ?? 0)),
                  ],
                ]));
    final activity = ValueListenableBuilder<String?>(
        valueListenable: _pullActivity,
        builder: (context, pull, _) => SportsActivityLine(
              label: pull ??
                  [
                    _error != null
                        ? 'Update incomplete'
                        : events.isNotEmpty
                            ? 'Ready to watch'
                            : _loading
                                ? 'Loading $_programmes'
                                : 'Guide checked',
                    _error != null
                        ? 'Guide: check failed'
                        : _loading
                            ? 'Guide: updating'
                            : 'Guide: ${events.length} shown',
                    if (!widget.highlights)
                      _checkingDates
                          ? 'Dates: optional lookup'
                          : 'Dates: when known',
                  ].join('\n'),
              details: _error ??
                  (_loading
                      ? 'Checking programmes in your saved guide. Channels already listed remain available to watch.'
                      : _checkingDates
                          ? 'Looking up missing replay dates. This is optional: every listed channel is already available to watch.'
                          : '${events.length} $_programmes airing now. ${_snapshot?.channelsWithGuide ?? 0} channels with current guide listings.${!_includeLikely && possibleCount > 0 ? ' Open ••• and Include possible replays to see $possibleCount less certain listings.' : ''}'),
              busy: _loading || _checkingDates,
              hasError: _error != null,
              pulling: pull != null,
              refreshButton: SizedBox(
                  width: 30,
                  height: 28,
                  child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: (_, event) {
                        if (!_tvNavigation ||
                            (event is! KeyDownEvent &&
                                event is! KeyRepeatEvent)) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowRight ||
                            key == LogicalKeyboardKey.arrowDown) {
                          focusContent();
                        } else if (key == LogicalKeyboardKey.arrowUp) {
                          _focusToolbar();
                        } else if (key != LogicalKeyboardKey.arrowLeft) {
                          return KeyEventResult.ignored;
                        }
                        return KeyEventResult.handled;
                      },
                      child: IconButton(
                          key: const ValueKey('replays-refresh'),
                          focusNode: _refreshFocus,
                          tooltip: 'Check current guide',
                          constraints: const BoxConstraints.tightFor(
                              width: 30, height: 28),
                          padding: EdgeInsets.zero,
                          color: interfaceColor(context, Colors.white38),
                          icon: const Icon(Icons.refresh, size: 14),
                          onPressed: () {
                            if (!_loading) refresh(force: true);
                          }))),
            ));
    final content =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_searching)
        Padding(
            padding: const EdgeInsets.only(top: 3, bottom: 6),
            child: TvTextFieldGate(
                focusNode: _searchFocus,
                builder: (context, readOnly) => TextField(
                      key: const ValueKey('replay-search-field'),
                      controller: _searchController,
                      focusNode: _searchFocus,
                      readOnly: readOnly,
                      onChanged: _searchChanged,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _sportFocus.requestFocus(),
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                          hintText: 'Team, event, league or channel',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          prefixIcon: const Icon(Icons.search, size: 17),
                          prefixIconConstraints:
                              const BoxConstraints(minWidth: 34),
                          suffixIcon: IconButton(
                              tooltip: 'Close search',
                              iconSize: 17,
                              onPressed: _toggleSearch,
                              icon: const Icon(Icons.close)),
                          suffixIconConstraints:
                              const BoxConstraints(minWidth: 34, minHeight: 34),
                          filled: true,
                          fillColor:
                              interfaceColor(context, const Color(0xFF252B33)),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(3),
                              borderSide: BorderSide.none)),
                    ))),
      Expanded(
          child: CustomScrollView(
        controller: _scroll,
        key: const ValueKey('replays-scroll'),
        scrollCacheExtent: const ScrollCacheExtent.pixels(600),
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SportsRefreshControl(
              onRefresh: _loading ? null : () => refresh(force: true),
              externalStatus: true,
              onPullChanged: (label) => _pullActivity.value = label,
              updatingLabel: 'Checking $_programmes…',
              successLabel: 'Guide checked'),
          if (events.isEmpty)
            SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                              widget.highlights
                                  ? Icons.video_collection_outlined
                                  : Icons.replay_rounded,
                              size: 28,
                              color: scheme.primary),
                          const SizedBox(height: 10),
                          Text(
                              _loading
                                  ? 'Checking your channel guide…'
                                  : _range != ReplayDateRange.all ||
                                          _sport != null ||
                                          _searchTerms.isNotEmpty
                                      ? 'No $_programmes match these filters'
                                      : 'No $_programmes found on air',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                          if (_range != ReplayDateRange.all ||
                              _sport != null ||
                              _searchTerms.isNotEmpty)
                            TextButton(
                                onPressed: () => setState(() {
                                      _range = ReplayDateRange.all;
                                      _sport = null;
                                      _searchTerms = [];
                                      _searchController.clear();
                                    }),
                                child: const Text('Clear filters')),
                          const SizedBox(height: 8),
                          Text(
                              _loading
                                  ? 'Looking for programmes airing now. Listings appear as the guide is checked.'
                                  : _searchTerms.isNotEmpty
                                      ? 'Try a team, event, league or channel name, or clear the filters.'
                                      : _range != ReplayDateRange.all
                                          ? 'Try All dates to include older events and listings with incomplete dates.'
                                          : _snapshot?.channelsWithGuide == 0 &&
                                                  !_loading
                                              ? widget.highlights
                                                  ? 'No current guide entries are available. Check again after your guide updates.'
                                                  : 'No current guide entries are available. Check again after your guide updates. Replay channels are available in the ••• menu.'
                                              : widget.highlights
                                                  ? 'Highlight shows will appear here when they are listed as airing now in your guide.'
                                                  : !_includeLikely
                                                      ? 'No clear replay listings match these filters. Include possible replays in the ••• menu to browse less certain listings.'
                                                      : 'No replay listings match the current guide and filters. Channels with missing guide details are available in the ••• menu.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color:
                                      interfaceColor(context, Colors.white54))),
                        ])))),
          for (final range in ranges)
            SliverMainAxisGroup(
                key: ValueKey('replay-group-${events[range.$1].sport}'),
                slivers: [
                  SliverPersistentHeader(
                      pinned: true,
                      delegate: SportsPinnedHeading(
                          height:
                              (MediaQuery.textScalerOf(context).scale(13) + 16)
                                  .clamp(30.0, double.infinity),
                          child: Semantics(
                            header: true,
                            child: Container(
                                key: ValueKey(
                                    'replay-heading-${events[range.$1].sport}'),
                                alignment: Alignment.centerLeft,
                                child: Row(children: [
                                  Icon(sportIcon(events[range.$1].sport),
                                      size: 16, color: scheme.primary),
                                  const SizedBox(width: 7),
                                  Expanded(
                                      child: Text(
                                          sportLabel(events[range.$1].sport),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600))),
                                  Text('${range.$2 - range.$1}',
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: interfaceColor(
                                              context, Colors.white54))),
                                ])),
                          ))),
                  SliverList.builder(
                      itemCount: range.$2 - range.$1,
                      findChildIndexCallback: (key) {
                        final index = key is ValueKey<String>
                            ? eventPositions[key.value]
                            : null;
                        return index != null &&
                                index >= range.$1 &&
                                index < range.$2
                            ? index - range.$1
                            : null;
                      },
                      itemBuilder: (context, localIndex) {
                        final index = range.$1 + localIndex;
                        final event = events[index];
                        final broadcasts = event.broadcasts
                            .where((b) => b.programme.isNowPlaying(now))
                            .toList();
                        final primary = broadcasts
                                .where((b) => b.channel.id == widget.playingId)
                                .firstOrNull ??
                            broadcasts.first;
                        final focused =
                            _nodes.putIfAbsent(event.id, () => FocusNode());
                        return Column(
                            key: ValueKey(event.id),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Focus(
                                    canRequestFocus: false,
                                    skipTraversal: true,
                                    onKeyEvent: (_, key) {
                                      if (key is! KeyDownEvent &&
                                          key is! KeyRepeatEvent) {
                                        return KeyEventResult.ignored;
                                      }
                                      if (_tvNavigation &&
                                          key.logicalKey ==
                                              LogicalKeyboardKey.arrowLeft) {
                                        focusRefresh();
                                        return KeyEventResult.handled;
                                      }
                                      if (_tvNavigation &&
                                          key.logicalKey ==
                                              LogicalKeyboardKey.arrowRight) {
                                        return KeyEventResult.handled;
                                      }
                                      final delta = key.logicalKey ==
                                              LogicalKeyboardKey.arrowDown
                                          ? 1
                                          : key.logicalKey ==
                                                  LogicalKeyboardKey.arrowUp
                                              ? -1
                                              : 0;
                                      if (delta == 0) {
                                        return KeyEventResult.ignored;
                                      }
                                      _step(events, index, delta);
                                      return KeyEventResult.handled;
                                    },
                                    child: HoldToActivate(
                                        onTap: () => _play(primary),
                                        onHold: () => _details(event),
                                        child: ListenableBuilder(
                                          listenable: focused,
                                          builder: (context, content) =>
                                              Material(
                                            color: interfaceColor(context,
                                                const Color(0xFF222A34)),
                                            clipBehavior: Clip.antiAlias,
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                                side: BorderSide(
                                                    width: focused.hasFocus
                                                        ? 1.5
                                                        : 1,
                                                    color: focused.hasFocus
                                                        ? scheme.primary
                                                        : primary.channel.id ==
                                                                widget.playingId
                                                            ? scheme.primary
                                                                .withValues(
                                                                    alpha: .60)
                                                            : interfaceColor(
                                                                    context,
                                                                    Colors
                                                                        .white)
                                                                .withValues(
                                                                    alpha:
                                                                        .12))),
                                            child: InkWell(
                                                key: ValueKey(
                                                    'replay-${event.id}'),
                                                focusNode: focused,
                                                onTap: () => _play(primary),
                                                onLongPress: () =>
                                                    _details(event),
                                                focusColor:
                                                    scheme.primaryContainer,
                                                onFocusChange: (value) {
                                                  if (value) {
                                                    _lastFocusedEvent =
                                                        event.id;
                                                  }
                                                  if (value &&
                                                      focused.context != null) {
                                                    _revealCard(
                                                        focused.context!);
                                                  }
                                                },
                                                child: content),
                                          ),
                                          child: _ReplayContent(
                                              highlights: widget.highlights,
                                              leagueInitials:
                                                  _leagueInitials[event.id],
                                              event: event,
                                              date: _date(event),
                                              primary: primary,
                                              channelCount: broadcasts.length,
                                              playing: primary.channel.id ==
                                                  widget.playingId,
                                              now: now,
                                              onDetails: () => _details(event)),
                                        )),
                                  )),
                            ]);
                      }),
                ]),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],
      )),
    ]);
    if (widget.layoutBuilder != null) {
      return widget.layoutBuilder!(filters, activity, actions, content);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.headerBuilder != null)
        widget.headerBuilder!(filters, activity, actions)
      else ...[
        Row(children: [Expanded(child: filters), actions]),
        activity
      ],
      Expanded(child: content),
    ]);
  }
}

class _ReplayMenuItem extends StatelessWidget {
  const _ReplayMenuItem(
      {required this.icon,
      required this.title,
      required this.subtitle,
      this.selected,
      this.count});
  final IconData icon;
  final String title, subtitle;
  final bool? selected;
  final int? count;
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18, color: interfaceColor(context, Colors.white60)),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(subtitle,
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.25,
                      color: interfaceColor(context, Colors.white54))),
            ])),
        if (selected != null) ...[
          const SizedBox(width: 8),
          Semantics(
              checked: selected,
              child: Icon(
                  selected!
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 18,
                  color: selected!
                      ? Theme.of(context).colorScheme.primary
                      : interfaceColor(context, Colors.white30))),
        ],
        if (count != null) ...[
          const SizedBox(width: 8),
          Text('$count',
              style: TextStyle(
                  fontSize: 11,
                  color: interfaceColor(context, Colors.white54))),
        ],
      ]);
}

class _ReplayContent extends StatelessWidget {
  const _ReplayContent(
      {this.highlights = false,
      required this.event,
      this.leagueInitials,
      required this.date,
      required this.primary,
      required this.channelCount,
      required this.playing,
      required this.now,
      required this.onDetails});
  final bool highlights;
  final SportsReplay event;
  final String? leagueInitials;
  final ReplayEventDate? date;
  final ReplayBroadcast primary;
  final int channelCount;
  final bool playing;
  final DateTime now;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final likely = event.evidence == ReplayEvidence.likely;
    final condensed =
        isCondensedReplay(event.title, primary.programme.description);
    final parts = replayTitleParts(event.title, event.sport,
        highlights: highlights, description: primary.programme.description);
    final type = highlights
        ? 'Highlights'
        : likely
            ? 'Possible replay'
            : condensed
                ? 'Condensed'
                : 'Replay';
    final typeColor = likely
        ? interfaceColor(context, const Color(0xFFE2BD7D))
        : interfaceColor(context, Colors.white60);
    final remaining =
        primary.programme.stop.difference(now).inMinutes.clamp(0, 1440);
    final duration = primary.programme.stop
        .difference(primary.programme.start)
        .inMilliseconds;
    final progress = duration <= 0
        ? 0.0
        : (now.difference(primary.programme.start).inMilliseconds / duration)
            .clamp(0.0, 1.0);
    final synopsis =
        replaySynopsisForDisplay(primary.programme.description ?? '');
    return LayoutBuilder(builder: (context, constraints) {
      final compact = sportsLandscape(context);
      final wide = constraints.maxWidth >= (compact ? 450 : 680);
      final identity = Padding(
          padding: EdgeInsets.fromLTRB(compact ? 8 : 10, 2, 8, compact ? 3 : 6),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (leagueInitials != null) ...[
                _ReplayLeagueInitials(
                    label: leagueInitials!, sport: event.sport),
                const SizedBox(width: 6),
              ],
              Expanded(
                  child: Text(parts.competition,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary.withValues(alpha: .85)))),
              const SizedBox(width: 8),
              _ReplayBadge(
                  label: type, color: typeColor, filled: likely || condensed),
              SizedBox(
                  width: 34,
                  height: 26,
                  child: IconButton(
                      tooltip: 'Programme details and channels',
                      onPressed: onDetails,
                      icon: const Icon(Icons.more_horiz, size: 19),
                      padding: EdgeInsets.zero)),
            ]),
            Text(parts.title,
                style: TextStyle(
                    fontSize: compact
                        ? 12.5
                        : wide
                            ? 16
                            : 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: interfaceColor(context, const Color(0xFFF2F5F8)))),
            const SizedBox(height: 4),
            if (!highlights)
              _ReplayDateLine(
                date: date,
                now: now,
              ),
            if (synopsis.isNotEmpty && synopsis != parts.title)
              Padding(
                padding: EdgeInsets.only(top: highlights ? 0 : 4),
                child: Text(synopsis,
                    maxLines: compact || wide ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color:
                            interfaceColor(context, const Color(0xFFAAB5C1)))),
              ),
          ]));
      final channel = Padding(
          padding: EdgeInsets.fromLTRB(
              compact ? 7 : 10, compact ? 3 : 6, compact ? 7 : 10, 4),
          child: Column(children: [
            Row(children: [
              Container(
                  width: 28,
                  height: 28,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                      color: interfaceColor(context, Colors.white)
                          .withValues(alpha: .06),
                      borderRadius: BorderRadius.circular(4)),
                  child: CachedChannelLogo(
                      url: primary.channel.logoUrl,
                      icon: playing
                          ? Icons.equalizer_rounded
                          : Icons.live_tv_outlined,
                      color: playing
                          ? scheme.primary
                          : interfaceColor(context, Colors.white54))),
              const SizedBox(width: 7),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(primary.channel.name,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: interfaceColor(
                                context, const Color(0xFFDCE3EB)))),
                    const SizedBox(height: 2),
                    Text(
                        '${playing ? 'Watching' : 'On air'} ${DateFormat.Hm().format(primary.programme.start.toLocal())}–${DateFormat.Hm().format(primary.programme.stop.toLocal())}',
                        style: TextStyle(
                            fontSize: 9.5,
                            color: interfaceColor(
                                context, const Color(0xFF8E9BA9)))),
                  ])),
              if (!compact) ...[
                const SizedBox(width: 7),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (channelCount > 1)
                    _ReplayBadge(
                        label:
                            '+${channelCount - 1} ${channelCount == 2 ? 'channel' : 'channels'}',
                        color: scheme.primary),
                  Text(_remainingLabel(remaining),
                      style: TextStyle(
                          fontSize: 9.5,
                          color: remaining <= 10
                              ? interfaceColor(context, const Color(0xFFE2BD7D))
                              : interfaceColor(context, Colors.white60))),
                ]),
              ],
            ]),
            if (compact) ...[
              const SizedBox(height: 2),
              Align(
                  alignment: Alignment.centerRight,
                  child:
                      Wrap(alignment: WrapAlignment.end, spacing: 6, children: [
                    if (channelCount > 1)
                      _ReplayBadge(
                          label:
                              '+${channelCount - 1} ${channelCount == 2 ? 'channel' : 'channels'}',
                          color: scheme.primary),
                    Text(_remainingLabel(remaining),
                        style: TextStyle(
                            fontSize: 9.5,
                            color: remaining <= 10
                                ? interfaceColor(
                                    context, const Color(0xFFE2BD7D))
                                : interfaceColor(context, Colors.white60))),
                  ])),
            ],
            const SizedBox(height: 5),
            LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                borderRadius: BorderRadius.circular(1),
                backgroundColor: interfaceColor(context, Colors.white)
                    .withValues(alpha: .07),
                color: playing
                    ? scheme.primary
                    : interfaceColor(context, const Color(0xFF6E8399))),
          ]));
      final airing = DecoratedBox(
          decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .13),
              border: wide
                  ? Border(
                      left: BorderSide(
                          color: interfaceColor(context, Colors.white)
                              .withValues(alpha: .07)))
                  : Border(
                      top: BorderSide(
                          color: interfaceColor(context, Colors.white)
                              .withValues(alpha: .07)))),
          child: channel);
      if (wide) {
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(child: identity),
          SizedBox(width: compact ? 176 : 240, child: airing),
        ]);
      }
      return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [identity, airing]);
    });
  }
}

class _ReplayLeagueInitials extends StatelessWidget {
  const _ReplayLeagueInitials({required this.label, required this.sport});
  final String label;
  final String sport;

  @override
  Widget build(BuildContext context) {
    final color = interfaceColor(
        context,
        switch (sport) {
          'basketball' => const Color(0xFFF1B181),
          'football' => const Color(0xFFABA9EF),
          'hockey' || 'baseball' => const Color(0xFF9DC4DF),
          'racing' => const Color(0xFFF2A2A6),
          'tennis' => const Color(0xFFC6D888),
          'mma' => const Color(0xFFD5B0E0),
          _ => const Color(0xFF85CCB9),
        });
    // The adjacent competition name supplies the accessible label.
    return ExcludeSemantics(
      child: Container(
        width: 28,
        height: 21,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .105),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: .22), width: .6),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label,
              style: TextStyle(
                  fontSize: label.length > 3 ? 7.5 : 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .1,
                  height: 1,
                  color: color)),
        ),
      ),
    );
  }
}

class _ReplayBadge extends StatelessWidget {
  const _ReplayBadge(
      {required this.label, required this.color, this.filled = false});
  final String label;
  final Color color;
  final bool filled;
  @override
  Widget build(BuildContext context) => Container(
      padding: EdgeInsets.symmetric(horizontal: filled ? 6 : 0, vertical: 2),
      decoration: BoxDecoration(
          color: filled ? color.withValues(alpha: .10) : null,
          borderRadius: BorderRadius.circular(3)),
      child: Text(label,
          style: TextStyle(
              fontSize: 9.5, fontWeight: FontWeight.w500, color: color)));
}

class _ReplayDateLine extends StatelessWidget {
  const _ReplayDateLine({required this.date, required this.now});
  final ReplayEventDate? date;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final possible = date?.isPossible ?? false;
    final recent = replayDateInRange(date, ReplayDateRange.recent, now);
    final older = replayDateInRange(date, ReplayDateRange.older, now);
    final age = possible ? null : date?.ageLabel(now);
    final color = possible
        ? interfaceColor(context, const Color(0xFFE2BD7D))
        : recent
            ? Theme.of(context).colorScheme.primary
            : interfaceColor(context, Colors.white54);
    final label = date == null ? 'Event date not listed' : date!.label;
    return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 19),
        child: Row(children: [
          Icon(possible ? Icons.help_outline_rounded : Icons.event_outlined,
              size: 12,
              color: date == null
                  ? interfaceColor(context, Colors.white30)
                  : color),
          const SizedBox(width: 5),
          if (date != null)
            Text(
                possible
                    ? 'Possible · '
                    : date!.isGuideDate
                        ? 'Guide · '
                        : 'Event · ',
                style: TextStyle(
                    fontSize: 10.5,
                    color: possible
                        ? color
                        : interfaceColor(context, Colors.white38))),
          Flexible(
              child: Tooltip(
                  triggerMode: TooltipTriggerMode.manual,
                  message: date?.source ??
                      'No reliable original event date in the guide.',
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 10.5,
                          color: date == null
                              ? interfaceColor(context, Colors.white38)
                              : interfaceColor(context, Colors.white70))))),
          if (recent || older) ...[
            const SizedBox(width: 8),
            Tooltip(
                triggerMode: TooltipTriggerMode.manual,
                message: age ??
                    (recent
                        ? 'Within the past 4 weeks'
                        : 'At least 4 weeks old'),
                child: _ReplayBadge(
                    label: recent ? 'Recent' : 'Older',
                    color: color,
                    filled: true)),
          ],
        ]));
  }
}

final _highlightShortLabel = RegExp(r'\b(?:hlts|hls)\b', caseSensitive: false);

/// Keep the competition secondary and give the event itself the main line.
({String competition, String title}) replayTitleParts(
    String title, String sport,
    {String? description, bool highlights = false}) {
  if (highlights) title = title.replaceAll(_highlightShortLabel, 'Highlights');
  final synopsisMatch =
      highlights ? null : replaySynopsisMatch(title, description);
  if (synopsisMatch != null) return (competition: title, title: synopsisMatch);
  final subtitle = highlights ? null : replayEventSubtitle(description);
  if (subtitle != null &&
      subtitle != title &&
      !RegExp(r'\s(?:v\.?|vs\.?|versus|at|@)\s', caseSensitive: false)
          .hasMatch(title)) {
    return (competition: title, title: subtitle);
  }
  final split = RegExp(r'\s*:\s+|\s[-–—]\s').firstMatch(title);
  if (split != null && split.start > 1 && split.start < 60) {
    final prefix = title.substring(0, split.start).trim();
    final rest = title.substring(split.end).trim();
    // Do not split a matchup itself ("Boston — New York").
    if (rest.isNotEmpty &&
        RegExp(r'\b(nba|nfl|nhl|ncaa|college|football|soccer|tennis|atp|wta|cricket|boxing|ufc|rugby|nrl|formula|spfl|ucl|pl|alm|laliga|league|classic|cup|golf|billiard|volleyball|baseball|condensed|raptors|fiba|epcr|fight sports|conmebol|fútbol|s[uü]per lig)\b',
                caseSensitive: false)
            .hasMatch(prefix)) {
      final year =
          RegExp(r'^((?:19|20)\d{2}|in (?:30|60))\s*:\s*', caseSensitive: false)
              .firstMatch(rest);
      return (
        competition: year == null ? prefix : '$prefix · ${year[1]}',
        title: year == null ? rest : rest.substring(year.end)
      );
    }
  }
  return (competition: sportLabel(sport), title: title);
}

String _airing(ReplayBroadcast b) {
  final time = DateFormat.Hm();
  final remaining =
      b.programme.stop.difference(DateTime.now()).inMinutes.clamp(0, 1440);
  return '${time.format(b.programme.start.toLocal())}–${time.format(b.programme.stop.toLocal())} · ${_remainingLabel(remaining)}';
}

String _rangeLabel(ReplayDateRange range) => switch (range) {
      ReplayDateRange.all => 'All dates',
      ReplayDateRange.recent => 'Past 4 weeks',
      ReplayDateRange.older => 'Older',
      ReplayDateRange.unknown => 'Date unclear',
    };
String _remainingLabel(int minutes) => minutes < 60
    ? '${minutes == 0 ? '<1' : minutes} min left'
    : '${minutes ~/ 60}h${minutes % 60 == 0 ? '' : ' ${minutes % 60}m'} left';
