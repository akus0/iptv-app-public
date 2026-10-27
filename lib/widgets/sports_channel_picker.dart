import '../utils/interface_colors.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/sports.dart';
import '../utils/formula_one.dart';
import '../utils/sports_programme_excerpt.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/sports_channel_matcher.dart';
import 'tv_text_field_gate.dart';

/// Preserve the matcher's evidence ordering and its diversified tie order.
/// A downgraded future/shared feed can retain a high score, but must stay below
/// event-specific evidence. Sort only these bounded suggestions, never a playlist.
int _compareSuggestions(ChannelMatch a, ChannelMatch b) {
  final aPick = a.reason == MatchReason.pick;
  final bPick = b.reason == MatchReason.pick;
  if (aPick != bPick) return aPick ? -1 : 1;
  if (a.isConfident != b.isConfident) return a.isConfident ? -1 : 1;
  return b.score.compareTo(a.score);
}

List<ChannelMatch> rankChannelSuggestions(List<ChannelMatch> matches) =>
    (matches.indexed.toList()
          ..sort((a, b) {
            final order = _compareSuggestions(a.$2, b.$2);
            return order != 0 ? order : a.$1.compareTo(b.$1);
          }))
        .map((entry) => entry.$2)
        .toList();

/// Merge a fresh shortlist into already-ranked alternatives in one pass.
/// New evidence replaces old evidence for that channel, including downgrades.
/// Avoid re-sorting thousands of broad alternatives while enrichment finishes.
List<ChannelMatch> mergeChannelSuggestions(
    List<ChannelMatch> ranked, List<ChannelMatch> evidence) {
  final updatedIds = evidence.map((m) => m.channel.id).toSet();
  final fresh = rankChannelSuggestions(evidence);
  final merged = <ChannelMatch>[];
  var next = 0;
  for (final old in ranked) {
    if (updatedIds.contains(old.channel.id) || old.reason == MatchReason.pick) {
      continue;
    }
    while (next < fresh.length && _compareSuggestions(fresh[next], old) <= 0) {
      merged.add(fresh[next++]);
    }
    merged.add(old);
  }
  merged.addAll(fresh.skip(next));
  return merged;
}

// Broad alternatives can include coverage of other simultaneous events. Only
// pin/label playback started for this game, or its top recommendation. Never
// infer event identity merely from membership in the related-channel list.
String? _relevantPlayingId(List<ChannelMatch> ranked,
    {String? playingId,
    String? selectedId,
    ChannelMatch? tileMatch,
    Channel? playingChannel}) {
  if (playingId == null) return null;
  final topId =
      selectedId ?? tileMatch?.channel.id ?? ranked.firstOrNull?.channel.id;
  return playingChannel?.id == playingId || topId == playingId
      ? playingId
      : null;
}

/// Keep event-specific playback/choice context ahead of ranked alternatives. This is
/// presentation only: it must never upgrade a possible match's confidence.
List<ChannelMatch> pinChannelSuggestions(List<ChannelMatch> ranked,
    {String? playingId,
    String? selectedId,
    ChannelMatch? tileMatch,
    Channel? playingChannel,
    Channel? selectedChannel}) {
  final relevantPlayingId = _relevantPlayingId(ranked,
      playingId: playingId,
      selectedId: selectedId,
      tileMatch: tileMatch,
      playingChannel: playingChannel);
  final ids = <String>{
    if (relevantPlayingId != null) relevantPlayingId,
    if (selectedId != null) selectedId,
    if (tileMatch != null) tileMatch.channel.id,
  };
  if (ids.isEmpty) return ranked;
  final pinned = <String, ChannelMatch>{
    for (final m in ranked)
      if (ids.contains(m.channel.id)) m.channel.id: m,
  };
  if (playingChannel != null && playingChannel.id == playingId) {
    pinned.putIfAbsent(
        playingChannel.id,
        () => ChannelMatch(playingChannel, MatchReason.sport, 0,
            detail: 'Playing channel · current match unverified'));
  }
  if (selectedChannel != null && selectedChannel.id == selectedId) {
    pinned.putIfAbsent(selectedChannel.id,
        () => ChannelMatch(selectedChannel, MatchReason.pick, 1000));
  }
  if (tileMatch != null) {
    pinned.putIfAbsent(
        tileMatch.channel.id,
        () => ChannelMatch(tileMatch.channel, MatchReason.sport, 0,
            detail: 'Previous tile suggestion · current match unverified'));
  }
  return [
    for (final id in ids)
      if (pinned[id] case final match?) match,
    for (final m in ranked)
      if (!pinned.containsKey(m.channel.id)) m,
  ];
}

class SportsChannelChoice {
  const SportsChannelChoice(this.channel,
      {this.manual = false, this.multiview = false})
      : reset = false;
  const SportsChannelChoice.reset()
      : channel = null,
        manual = false,
        multiview = false,
        reset = true;
  final Channel? channel;
  final bool manual, reset, multiview;
}

/// Suggestions and manual search share one route, layout and readable rows.
/// Back from search restores the suggestions without losing the query.
class SportsChannelPickerDialog extends StatefulWidget {
  const SportsChannelPickerDialog(
      {super.key,
      required this.game,
      required this.matches,
      required this.matcher,
      this.matching = false,
      this.hideScores = false,
      this.hasPick = false,
      this.selectedId,
      this.playingId,
      this.playingChannel,
      this.tileMatch,
      this.playFullScreen = false,
      this.allowMultiview = false,
      this.onlineMatches});
  final SportsGame game;
  final List<ChannelMatch> matches;
  final SportsChannelMatcher matcher;
  final Future<List<ChannelMatch>>? onlineMatches;
  final bool matching, hideScores, hasPick, playFullScreen;
  final bool allowMultiview;
  final String? selectedId, playingId;

  /// Supply only when playback was started for [game], not for another event.
  final Channel? playingChannel;
  final ChannelMatch? tileMatch;
  @override
  State<SportsChannelPickerDialog> createState() =>
      _SportsChannelPickerDialogState();
}

class _SportsChannelPickerDialogState extends State<SportsChannelPickerDialog> {
  bool _multiview = false;
  final _watchMode = FocusNode(debugLabel: 'sports-channel-watch');
  final _multiviewMode = FocusNode(debugLabel: 'sports-channel-multiview');
  KeyEventResult _modeKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _watchMode.requestFocus();
      case LogicalKeyboardKey.arrowRight:
        _multiviewMode.requestFocus();
      case LogicalKeyboardKey.arrowUp:
        _close.requestFocus();
      case LogicalKeyboardKey.arrowDown:
        if (_search) {
          _field.requestFocus();
        } else {
          _findButton.requestFocus();
        }
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  final _controller = TextEditingController();
  late final _field = FocusNode(onKeyEvent: (_, event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final selected = _suggestions.indexOf(_controller.text);
      final chip = _chips.isEmpty ? null : _chips[selected < 0 ? 0 : selected];
      if (chip?.parent != null) {
        chip!.requestFocus();
      } else {
        _list.currentState?.focusCurrent();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      (_watchMode.parent != null
              ? (_multiview ? _multiviewMode : _watchMode)
              : _close)
          .requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  });
  final _findButton = FocusNode(debugLabel: 'sports-channel-find');
  final _resetButton = FocusNode(debugLabel: 'sports-channel-reset');
  final _close = FocusNode(debugLabel: 'sports-channel-close');
  KeyEventResult _actionsKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _list.currentState?.focusCurrent();
      case LogicalKeyboardKey.arrowUp:
        (_watchMode.parent != null
                ? (_multiview ? _multiviewMode : _watchMode)
                : _close)
            .requestFocus();
      case LogicalKeyboardKey.arrowLeft:
        _findButton.requestFocus();
      case LogicalKeyboardKey.arrowRight:
        (widget.hasPick ? _resetButton : _findButton).requestFocus();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  final _list = GlobalKey<_SportsChannelListState>();
  final _chips = <FocusNode>[];
  late final _suggestions = SportsChannelMatcher.searchSuggestions(widget.game);
  late final _programmeHighlighter = SportsProgrammeHighlighter([
    ..._suggestions,
    ...?widget.game.event?.matchingNames
  ], names: [
    widget.game.home.name,
    widget.game.home.shortName,
    widget.game.away.name,
    widget.game.away.shortName,
  ]);
  late List<ChannelMatch> _ranked = rankChannelSuggestions(widget.matches);
  late List<ChannelMatch> _matches = _pin(_ranked);
  List<ChannelSearchResult> _results = [];
  String? _resultsQuery;
  Timer? _debounce;
  int _generation = 0;
  bool _search = false, _busy = false, _expanding = false;
  bool _onlinePending = false, _suggestionsFailed = false;
  int _alternativeGeneration = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _chips.addAll([for (final _ in _suggestions) FocusNode()]);
    _expand(widget.matches);
    final online = widget.onlineMatches;
    if (online != null) {
      _onlinePending = true;
      online.then((matches) {
        if (!mounted) return;
        if (matches.isNotEmpty) _expand(matches);
        setState(() => _onlinePending = false);
      }).catchError((Object _) {
        if (mounted) {
          setState(() {
            _onlinePending = false;
            _suggestionsFailed = true;
          });
        }
      });
    }
  }

  String? get _playingId => _relevantPlayingId(_ranked,
      playingId: widget.playingId,
      selectedId: widget.selectedId,
      tileMatch: widget.tileMatch,
      playingChannel: widget.playingChannel);

  bool get _hasPinned =>
      _matches.isNotEmpty &&
      (_matches.first.channel.id == _playingId ||
          _matches.first.channel.id == widget.selectedId ||
          _matches.first.channel.id == widget.tileMatch?.channel.id);

  F1Feed? _feedFilter;
  List<ChannelMatch>? _rowMatches;
  F1Feed? _rowFilter;
  List<ChannelSearchResult> _suggestedRows = const [];

  List<ChannelSearchResult> get _rows {
    if (_search) return _results;
    if (!identical(_rowMatches, _matches) || _rowFilter != _feedFilter) {
      _rowMatches = _matches;
      _rowFilter = _feedFilter;
      _suggestedRows = [
        for (final match in _matches)
          if (_feedFilter == null || _feedFor(match) == _feedFilter)
            ChannelSearchResult(match.channel,
                match: match, programme: match.programme)
      ];
    }
    return _suggestedRows;
  }

  F1Feed _feedFor(ChannelMatch m) =>
      f1FeedKind(m.channel) ?? (m.isConfident ? F1Feed.main : F1Feed.other);

  List<ChannelMatch> _pin(List<ChannelMatch> rows) {
    if (isFormulaOne(widget.game)) {
      final groups = <F1Feed, List<ChannelMatch>>{};
      for (final m in rows) {
        (groups[_feedFor(m)] ??= []).add(m);
      }
      rows = [for (final kind in F1Feed.values) ...?groups[kind]];
    }
    return pinChannelSuggestions(rows,
        playingId: widget.playingId,
        selectedId: widget.selectedId,
        tileMatch: widget.tileMatch,
        playingChannel: widget.playingChannel,
        selectedChannel: widget.selectedId == null
            ? null
            : widget.matcher.channelById(widget.selectedId!));
  }

  @override
  void didUpdateWidget(SportsChannelPickerDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playingId != widget.playingId ||
        oldWidget.selectedId != widget.selectedId ||
        oldWidget.playingChannel != widget.playingChannel ||
        oldWidget.tileMatch != widget.tileMatch) {
      // Also updates when playback changes outside this dialog.
      _matches = _pin(_ranked);
      _results = _withLatestEvidence(_results);
    }
  }

  void _expand(List<ChannelMatch> evidence) {
    final generation = ++_alternativeGeneration;
    setState(() {
      _expanding = true;
      _ranked = mergeChannelSuggestions(_ranked, evidence);
      _matches = _pin(_ranked);
      _results = _withLatestEvidence(_results);
    });
    // Display existing choices immediately, including while online enrichment
    // finishes. Never replace a broad list with the eight-item card shortlist.
    widget.matcher
        .alternativesFor(widget.game,
            matches: evidence,
            isCancelled: () => !mounted || generation != _alternativeGeneration)
        .then((matches) {
      if (!mounted || generation != _alternativeGeneration) return;
      setState(() {
        _ranked = matches; // Evidence order was computed off the UI isolate.
        _matches = _pin(_ranked);
        _results = _withLatestEvidence(_results);
        _expanding = false;
      });
    }).catchError((Object _) {
      if (!mounted || generation != _alternativeGeneration) return;
      setState(() {
        _expanding = false;
        _suggestionsFailed = true;
      });
    });
  }

  // Discovery may finish while someone is browsing search results. Update the
  // bounded rows in place without rescanning the playlist or changing their
  // order. Programme hits belong to the query, not the event suggestion.
  List<ChannelSearchResult> _withLatestEvidence(
      List<ChannelSearchResult> results) {
    if (results.isEmpty) return results;
    final evidence = {for (final m in _matches) m.channel.id: m};
    return [
      for (final row in results)
        ChannelSearchResult(row.channel,
            match: evidence[row.channel.id],
            programme: row.programmeSearchHit
                ? row.programme
                : evidence[row.channel.id]?.programme,
            programmeSearchHit: row.programmeSearchHit),
    ];
  }

  String? _returnSuggestionId;
  double? _returnSuggestionOffset;
  void _openSearch() {
    _returnSuggestionId = _list.currentState?.currentChannelId;
    _returnSuggestionOffset = _list.currentState?.scrollOffset;
    setState(() => _search = true);
    if (_controller.text.isEmpty) {
      _controller.text = _suggestions.firstOrNull ?? '';
    }
    _find();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_search) return;
      final tv = context.read<AppPreferences>().isTelevision;
      if (tv && _chips.isNotEmpty) {
        _chips.first.requestFocus();
      } else {
        _field.requestFocus();
      }
    });
  }

  void _back() {
    _debounce?.cancel();
    _generation++;
    _field.unfocus();
    setState(() {
      _search = false;
      _busy = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _list.currentState
        ?.focusChannel(_returnSuggestionId,
            scrollOffset: _returnSuggestionOffset));
  }

  void _find({bool typing = false}) {
    _debounce?.cancel();
    final generation = ++_generation;
    final query = _controller.text;
    setState(() {
      _busy = true;
      _error = null;
    });
    Future<void> run() async {
      if (!mounted || !_search || generation != _generation) return;
      try {
        final results = await widget.matcher.searchWithGuide(query,
            matches: _matches,
            isCancelled: () => !mounted || generation != _generation);
        if (!mounted || generation != _generation) return;
        setState(() {
          _results = _withLatestEvidence(results);
          _resultsQuery = query;
          _busy = false;
        });
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _busy = false;
          _error = 'Search unavailable. Try another keyword.';
        });
      }
    }

    if (typing) {
      _debounce = Timer(const Duration(milliseconds: 180), run);
    } else {
      unawaited(run());
    }
  }

  @override
  void dispose() {
    _generation++;
    _alternativeGeneration++;
    _debounce?.cancel();
    _controller.dispose();
    _field.dispose();
    _close.dispose();
    _findButton.dispose();
    _resetButton.dispose();
    _watchMode.dispose();
    _multiviewMode.dispose();
    for (final chip in _chips) {
      chip.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available = math.max(
        0.0,
        media.size.height -
            media.viewInsets.bottom -
            media.padding.vertical -
            24);
    final short = available < (widget.allowMultiview ? 420 : 360);
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    return PopScope(
      canPop: !_search,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _search) _back();
      },
      child: Dialog(
        key: const ValueKey('sports-channel-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        backgroundColor: interfaceColor(context, const Color(0xFF171D25)),
        child: SizedBox(
            width: 840,
            // Small suggestion lists use their actual content height. Larger
            // lists stay bounded and lazy, including thousands of alternatives.
            height: !_search && rows.isNotEmpty && rows.length <= 3
                ? null
                : math.min(available, 720),
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          height: 40,
                          child: Row(children: [
                            if (_search)
                              IconButton(
                                  tooltip: 'Back to suggested channels',
                                  onPressed: _back,
                                  icon: const Icon(Icons.arrow_back, size: 19)),
                            Expanded(
                                child: Text(
                                    _search
                                        ? 'Find a channel'
                                        : _multiview
                                            ? 'Choose for multiview'
                                            : 'Watch on…',
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600))),
                            IconButton(
                                focusNode: _close,
                                tooltip: 'Close channels',
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close, size: 19)),
                          ])),
                      if (widget.allowMultiview && available >= 250)
                        Focus(
                            onKeyEvent: _modeKey,
                            child: Row(children: [
                              ChoiceChip(
                                  focusNode: _watchMode,
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  labelStyle: const TextStyle(fontSize: 12),
                                  label: const Text('Watch now'),
                                  selected: !_multiview,
                                  onSelected: (_) =>
                                      setState(() => _multiview = false)),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                  focusNode: _multiviewMode,
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  labelStyle: const TextStyle(fontSize: 12),
                                  avatar: const Icon(Icons.grid_view, size: 16),
                                  label: const Text('Multiview'),
                                  selected: _multiview,
                                  onSelected: (_) =>
                                      setState(() => _multiview = true)),
                            ])),
                      if (!short) ...[
                        Text(widget.game.title,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 6),
                            child: Text(
                                [
                                  widget.game.league.shortName,
                                  if (isFormulaOne(widget.game) &&
                                      widget.game.event?.session != null)
                                    widget.game.event!.session!,
                                  if (isF1BuildUp(widget.game, DateTime.now()))
                                    'Build-up',
                                  if (widget.game.league.kind ==
                                          SportsKind.tennis &&
                                      widget.game.event != null)
                                    widget.game.event!.title,
                                  if (widget.game.event?.court != null)
                                    widget.game.event!.court!,
                                  if (widget.game.source != 'ESPN')
                                    widget.game.source,
                                  if (widget.game.state == GameState.live)
                                    widget.game.isGuideEvent
                                        ? widget.game.statusText
                                        : widget.game.isScheduleOnly
                                            ? 'Scheduled now · verify in guide'
                                            : 'Live',
                                  if (!widget.hideScores &&
                                      widget.game.state != GameState.pre &&
                                      widget.game.first.score != null &&
                                      widget.game.second.score != null &&
                                      !widget.game.league.isField)
                                    '${widget.game.first.score ?? '-'} – ${widget.game.second.score ?? '-'}',
                                  DateFormat('EEE d MMM · HH:mm')
                                      .format(widget.game.start.toLocal()),
                                ].join(' · '),
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: interfaceColor(
                                        context, Colors.white60)))),
                      ],
                      if (!_search && isFormulaOne(widget.game))
                        SizedBox(
                          height: 36,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final feed in <F1Feed?>[
                                null,
                                for (final kind in F1Feed.values)
                                  if (_matches.any((m) => _feedFor(m) == kind))
                                    kind,
                              ])
                                Padding(
                                  padding: const EdgeInsets.only(right: 5),
                                  child: ChoiceChip(
                                    key: ValueKey(
                                        'f1-feed-${feed?.name ?? 'all'}'),
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    label: Text(
                                        feed == null
                                            ? 'All feeds'
                                            : f1FeedLabel(feed),
                                        style: const TextStyle(fontSize: 10.5)),
                                    selected: _feedFilter == feed,
                                    onSelected: (_) =>
                                        setState(() => _feedFilter = feed),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      if (_search) ...[
                        SizedBox(
                            height: 40,
                            child: TvTextFieldGate(
                                focusNode: _field,
                                builder: (context, readOnly) => TextField(
                                      key: const ValueKey(
                                          'sports-channel-search'),
                                      controller: _controller,
                                      focusNode: _field,
                                      readOnly: readOnly,
                                      style: const TextStyle(fontSize: 13),
                                      decoration: InputDecoration(
                                          isDense: true,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 10, vertical: 9),
                                          prefixIcon: const Icon(Icons.search,
                                              size: 18),
                                          prefixIconConstraints:
                                              const BoxConstraints(
                                                  minWidth: 34),
                                          hintText:
                                              'Channel or programme keywords',
                                          suffixIcon: IconButton(
                                              tooltip: 'Clear search',
                                              icon: const Icon(Icons.close,
                                                  size: 16),
                                              onPressed: () {
                                                _controller.clear();
                                                _find();
                                                _field.requestFocus();
                                              })),
                                      onChanged: (_) => _find(typing: true),
                                      onSubmitted: (_) =>
                                          _list.currentState?.focusFirst(),
                                    ))),
                        if (!short)
                          SizedBox(
                              height: 36,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _suggestions.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 5),
                                itemBuilder: (context, i) => Center(
                                    child: ActionChip(
                                  focusNode: _chips[i],
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  label: Text(_suggestions[i],
                                      style: const TextStyle(fontSize: 10.5)),
                                  onPressed: () {
                                    _controller.text = _suggestions[i];
                                    _find();
                                  },
                                )),
                              )),
                      ],
                      if (!short)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                                _busy
                                    ? 'Searching your playlist and guide…'
                                    : _search
                                        ? '${rows.length}${rows.length >= 200 ? '+' : ''} results · best matches first'
                                        : _expanding
                                            ? '${rows.length} channels · finding more related channels…'
                                            : '${rows.length} channels · ${_hasPinned ? 'pinned first; alternatives ranked' : 'most likely first'}${context.read<AppPreferences>().isTelevision ? ' · Right: channel tools' : ''}',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onSurfaceVariant))),
                      if (!_search)
                        SizedBox(
                            height: 40,
                            child: Focus(
                                onKeyEvent: _actionsKey,
                                child: Row(children: [
                                  Expanded(
                                      child: TextButton.icon(
                                          focusNode: _findButton,
                                          onPressed: _openSearch,
                                          icon: const Icon(Icons.search,
                                              size: 17),
                                          label: const Text(
                                              'Find another channel',
                                              style: TextStyle(fontSize: 12)))),
                                  if (widget.hasPick)
                                    IconButton(
                                        focusNode: _resetButton,
                                        tooltip: 'Reset saved channel',
                                        onPressed: () => Navigator.pop(context,
                                            const SportsChannelChoice.reset()),
                                        icon: const Icon(Icons.restart_alt,
                                            size: 18)),
                                ]))),
                      Flexible(
                          child: _busy && _search && rows.isEmpty
                              ? const Center(
                                  child: SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)))
                              : rows.isEmpty
                                  ? Center(
                                      child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Text(
                                              _error ??
                                                  (_search
                                                      ? _controller.text
                                                              .trim()
                                                              .isEmpty
                                                          ? 'Search a channel name or programme. The shortcuts above can help.'
                                                          : 'No channels found. Try a player, tournament, sport or network.'
                                                      : _expanding ||
                                                              _onlinePending
                                                          ? 'Looking for channel suggestions…'
                                                          : _suggestionsFailed
                                                              ? 'Could not finish checking suggestions. Search your playlist above.'
                                                              : widget.matcher.guideStatusFor(widget.game) ??
                                                                  'No matched channels. Search your playlist above.'),
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: interfaceColor(
                                                      context, Colors.white60)),
                                              textAlign: TextAlign.center)))
                                  : IgnorePointer(
                                      ignoring: _busy,
                                      child: ExcludeFocus(
                                          excluding: _busy,
                                          child: SportsChannelList(
                                              key: _list,
                                              rows: rows,
                                              highlighter:
                                                  _programmeHighlighter,
                                              search: _search,
                                              searchKey: _search
                                                  ? _resultsQuery
                                                  : _feedFilter?.name,
                                              selectedId: widget.selectedId,
                                              playingId: _playingId,
                                              tileId:
                                                  widget.tileMatch?.channel.id,
                                              onExitUp: () => _search
                                                  ? _field.requestFocus()
                                                  : _findButton.requestFocus(),
                                              onExitRight: () => _search
                                                  ? _field.requestFocus()
                                                  : _findButton.requestFocus(),
                                              onChoose: (c) => Navigator.pop(
                                                  context,
                                                  SportsChannelChoice(c,
                                                      multiview: _multiview,
                                                      manual: _search)))))),
                    ]))),
      ),
    );
  }
}

class SportsChannelList extends StatefulWidget {
  const SportsChannelList(
      {super.key,
      required this.rows,
      required this.onChoose,
      this.highlighter,
      this.search = false,
      this.searchKey,
      this.selectedId,
      this.playingId,
      this.tileId,
      this.onExitUp,
      this.onExitRight});
  final List<ChannelSearchResult> rows;
  final SportsProgrammeHighlighter? highlighter;
  final ValueChanged<Channel> onChoose;
  final VoidCallback? onExitUp, onExitRight;
  final bool search;
  final String? searchKey;
  final String? selectedId, playingId, tileId;
  @override
  State<SportsChannelList> createState() => _SportsChannelListState();
}

class _SportsChannelListState extends State<SportsChannelList> {
  final _scroll = ScrollController();
  // Only mounted rows register here. Row state owns and disposes its node.
  final _nodes = <String, FocusNode>{};
  final _parking = FocusNode(skipTraversal: true);
  int _index = 0, _focusRequest = 0;
  String? _pendingId;
  late Map<String, int> _rowIndices = _indices();

  Map<String, int> _indices() => {
        for (final entry in widget.rows.indexed) entry.$2.channel.id: entry.$1,
      };
  @visibleForTesting
  int get mountedFocusNodeCount => _nodes.length;

  void _register(String id, FocusNode node) => _nodes[id] = node;
  void _unregister(String id, FocusNode node) {
    if (identical(_nodes[id], node)) _nodes.remove(id);
  }

  bool _laidOut(FocusNode node) {
    final context = node.context;
    if (context == null || !context.mounted) return false;
    RenderObject? object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return false;
    }
    while (object != null) {
      final data = object.parentData;
      if (data is SliverMultiBoxAdaptorParentData &&
          (data.layoutOffset == null || data.keptAlive)) {
        return false;
      }
      object = object.parent;
    }
    return true;
  }

  String? get currentChannelId =>
      _index < widget.rows.length ? widget.rows[_index].channel.id : null;
  double? get scrollOffset => _scroll.hasClients ? _scroll.offset : null;
  void focusChannel(String? id, {double? scrollOffset}) =>
      _focus(_rowIndices[id] ?? 0, scrollOffset: scrollOffset);
  void focusFirst() => _focus(0);
  void focusCurrent() =>
      _focus(_index.clamp(0, math.max(0, widget.rows.length - 1)));
  void _focus(int index, {double? scrollOffset}) {
    final request = ++_focusRequest;
    _pendingId = null;
    if (!mounted || widget.rows.isEmpty) return;
    if (index < 0) {
      widget.onExitUp?.call();
      return;
    }
    if (index >= widget.rows.length) {
      FocusScope.of(context).focusInDirection(TraversalDirection.down);
      return;
    }
    _index = index;
    final id = widget.rows[index].channel.id;
    _pendingId = id;
    if (scrollOffset != null && _scroll.hasClients) {
      // Restore actual geometry when returning from search. A whole-list
      // estimate can be very wrong after switching between 200 search results
      // and thousands of differently sized suggestions.
      _parking.requestFocus();
      _scroll.jumpTo(scrollOffset.clamp(0.0, _scroll.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || request != _focusRequest || !_parking.hasFocus) return;
        _seek(id, request, 0);
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    _seek(id, request, 0);
  }

  void _seek(String id, int request, int attempts) {
    if (!mounted ||
        request != _focusRequest ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    if (attempts > 0 && !_parking.hasFocus) return;
    final index = _rowIndices[id];
    if (index == null) return;
    final node = _nodes[id];
    if (node != null && _laidOut(node)) {
      _index = index;
      _pendingId = null;
      node.requestFocus();
      // Reveal either edge without moving an already visible row. A tall
      // suggestion aligns at its start so its channel and programme stay visible.
      Scrollable.ensureVisible(node.context!,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(node.context!,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      return;
    }
    if (!_scroll.hasClients || attempts >= 10) {
      _pendingId = null;
      return;
    }
    _parking.requestFocus();
    final position = _scroll.position;
    int? first, last;
    for (final entry in _nodes.entries) {
      final row = _rowIndices[entry.key];
      if (row == null || !_laidOut(entry.value)) continue;
      first = first == null ? row : math.min(first, row);
      last = last == null ? row : math.max(last, row);
    }
    // Adjacent remote steps use local geometry, not a whole-list average
    // distorted by long programme descriptions hundreds of rows away.
    final nearby = first != null &&
        last != null &&
        index >= first - (last - first + 1) &&
        index <= last + (last - first + 1);
    final estimate = index *
        (position.maxScrollExtent + position.viewportDimension) /
        math.max(1, widget.rows.length);
    final target = nearby || attempts > 0
        ? position.pixels +
            (first != null && index < first ? -1 : 1) *
                position.viewportDimension *
                .5
        : estimate;
    _scroll.jumpTo(
        (index == 0 ? 0.0 : target).clamp(0.0, position.maxScrollExtent));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _seek(id, request, attempts + 1));
    WidgetsBinding.instance.scheduleFrame();
  }

  void _focused(String id) {
    if (_pendingId != null && _pendingId != id) ++_focusRequest;
    _pendingId = null;
    _index = _rowIndices[id] ?? _index;
  }

  @override
  void didUpdateWidget(SportsChannelList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.rows, widget.rows) &&
        oldWidget.search == widget.search &&
        oldWidget.searchKey == widget.searchKey) {
      return;
    }
    final focusedId = _pendingId ??
        _nodes.entries
            .where((entry) => entry.value.hasFocus)
            .map((entry) => entry.key)
            .firstOrNull;
    _rowIndices = _indices();
    final request = ++_focusRequest;
    _pendingId = null;
    final newSearch = widget.search &&
        (!oldWidget.search || oldWidget.searchKey != widget.searchKey);
    if (newSearch) {
      _index = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      return;
    }
    _index = (_rowIndices[focusedId] ?? _index)
        .clamp(0, math.max(0, widget.rows.length - 1));
    if (focusedId != null &&
        _rowIndices.containsKey(focusedId) &&
        context.read<AppPreferences>().isTelevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            request != _focusRequest ||
            !(_nodes[focusedId]?.hasFocus == true || _parking.hasFocus)) {
          return;
        }
        final current = _rowIndices[focusedId];
        if (current != null) _focus(current);
      });
    }
  }

  @override
  void dispose() {
    ++_focusRequest;
    _scroll.dispose();
    _parking.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
          bindings: {
            if (widget.onExitRight != null)
              const SingleActivator(LogicalKeyboardKey.arrowRight):
                  widget.onExitRight!,
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _focus(_index + 1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                _focus(_index - 1),
          },
          child: Focus(
              focusNode: _parking,
              child: ListView.builder(
                  controller: _scroll,
                  shrinkWrap: widget.rows.length <= 3,
                  padding: EdgeInsets.zero,
                  itemCount: widget.rows.length,
                  findChildIndexCallback: (key) =>
                      key is ValueKey<String> ? _rowIndices[key.value] : null,
                  itemBuilder: (context, i) {
                    final row = widget.rows[i];
                    return _SportsChannelTile(
                        key: ValueKey(row.channel.id),
                        id: row.channel.id,
                        register: _register,
                        unregister: _unregister,
                        onFocus: _focused,
                        autofocus: !widget.search && i == 0,
                        onChoose: () => widget.onChoose(row.channel),
                        child: SportsChannelRow(
                            animateLogo:
                                !context.read<AppPreferences>().isTelevision,
                            result: row,
                            highlighter: widget.highlighter,
                            rank: i + 1,
                            fromTile: !widget.search &&
                                widget.tileId == row.channel.id,
                            search: widget.search,
                            playing: widget.playingId == row.channel.id,
                            selected: widget.selectedId == row.channel.id));
                  })));
}

class _SportsChannelTile extends StatefulWidget {
  const _SportsChannelTile(
      {super.key,
      required this.id,
      required this.register,
      required this.unregister,
      required this.onFocus,
      required this.autofocus,
      required this.onChoose,
      required this.child});
  final String id;
  final void Function(String, FocusNode) register, unregister;
  final ValueChanged<String> onFocus;
  final bool autofocus;
  final VoidCallback onChoose;
  final Widget child;
  @override
  State<_SportsChannelTile> createState() => _SportsChannelTileState();
}

class _SportsChannelTileState extends State<_SportsChannelTile> {
  final _node = FocusNode();
  @override
  void initState() {
    super.initState();
    widget.register(widget.id, _node);
  }

  @override
  void dispose() {
    widget.unregister(widget.id, _node);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: _node,
      // Focus paints the surround; keep the much larger programme text layer
      // reusable while stepping between cards. ListView bounds mounted layers.
      child: RepaintBoundary(child: widget.child),
      builder: (context, content) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
              animationDuration: context.read<AppPreferences>().isTelevision
                  ? Duration.zero
                  : kThemeChangeDuration,
              color: _node.hasFocus
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: .1)
                  : interfaceColor(context, const Color(0xFF1B232D)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(
                      color: _node.hasFocus
                          ? Theme.of(context).colorScheme.primary
                          : interfaceColor(context, const Color(0xFF4B5868)),
                      width: _node.hasFocus ? 2 : 1)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                  key: ValueKey('game-channel:${widget.id}'),
                  focusNode: _node,
                  // The explicit border/fill already shows TV focus. Avoid a
                  // second animated ink highlight repainting the entire card.
                  focusColor: context.read<AppPreferences>().isTelevision
                      ? Colors.transparent
                      : null,
                  autofocus: widget.autofocus,
                  onFocusChange: (focused) {
                    if (focused) widget.onFocus(widget.id);
                  },
                  onTap: widget.onChoose,
                  child: content))));
}

/// Full text and cached guide data only: no requests, per-row timers or scans.
/// Channel identity is separate from the schedule, with Now visually dominant.
class SportsChannelRow extends StatelessWidget {
  const SportsChannelRow(
      {super.key,
      required this.result,
      required this.rank,
      this.highlighter,
      this.playing = false,
      this.selected = false,
      this.fromTile = false,
      this.search = false,
      this.animateLogo = true});
  final ChannelSearchResult result;
  final SportsProgrammeHighlighter? highlighter;
  final int rank;
  final bool playing, selected, fromTile, search, animateLogo;

  static bool _same(EpgProgram? a, EpgProgram? b) =>
      a != null &&
      b != null &&
      a.start.isAtSameMomentAs(b.start) &&
      a.stop.isAtSameMomentAs(b.stop) &&
      a.title == b.title;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final channel = result.channel;
    final match = result.match;
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final cachedCurrent = epg.getCurrentProgram(channel.epgId);
    final evidence = result.programme;
    // A cached result may outlive its slot; never call an ended slot Now.
    final current = [cachedCurrent, match?.programme, evidence]
        .whereType<EpgProgram>()
        .where((p) => p.isNowPlaying(now))
        .firstOrNull;
    final cachedNext = epg.getNextProgram(channel.epgId);
    final next = cachedNext != null &&
            cachedNext.start.isAfter(now) &&
            cachedNext.stop.isAfter(cachedNext.start)
        ? cachedNext
        : null;
    final extra = <EpgProgram>[];
    for (final slot in [match?.programme, evidence]) {
      if (slot != null &&
          slot.stop.isAfter(slot.start) &&
          !_same(slot, current) &&
          !_same(slot, next) &&
          !extra.any((p) => _same(p, slot))) {
        extra.add(slot);
      }
    }
    // Compact caches may omit descriptions. Reuse richer evidence only when
    // it describes exactly the same slot; never attach a different show's copy.
    EpgProgram described(EpgProgram slot) {
      var best = slot;
      for (final candidate in [
        cachedCurrent,
        cachedNext,
        match?.programme,
        evidence
      ]) {
        if (_same(slot, candidate) &&
            (candidate!.description?.trim().length ?? 0) >
                (best.description?.trim().length ?? 0)) {
          best = candidate;
        }
      }
      return best;
    }

    final reason = switch (match?.reason) {
      MatchReason.pick => 'Your saved choice',
      MatchReason.guide => 'Event found in guide',
      MatchReason.name => 'Event in channel name',
      MatchReason.network => match?.detail?.startsWith('Dedicated F1') == true
          ? 'Dedicated F1 feed'
          : 'Listed broadcaster',
      MatchReason.listing => match?.programme != null
          ? 'Players listed by broadcaster'
          : 'Event TV listing',
      MatchReason.tournament => 'Tournament coverage · exact event unverified',
      MatchReason.league => 'League coverage · exact event unverified',
      MatchReason.sport => 'Sport-related · exact event unverified',
      null => result.programmeSearchHit
          ? 'Programme search match'
          : 'Channel name match',
    };
    final detail = match?.detail?.trim();
    final showDetail = detail != null &&
        detail.isNotEmpty &&
        !channel.name.toLowerCase().contains(detail.toLowerCase()) &&
        ![current, next, ...extra]
            .whereType<EpgProgram>()
            .any((p) => p.title.toLowerCase().contains(detail.toLowerCase()));
    final identity =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(3)),
            child: channel.logoUrl?.isNotEmpty == true
                ? CachedNetworkImage(
                    imageUrl: channel.logoUrl!,
                    fit: BoxFit.contain,
                    memCacheWidth: 80,
                    fadeInDuration: animateLogo
                        ? const Duration(milliseconds: 500)
                        : Duration.zero,
                    fadeOutDuration: animateLogo
                        ? const Duration(milliseconds: 1000)
                        : Duration.zero,
                    errorWidget: (_, __, ___) => Icon(Icons.live_tv,
                        size: 20,
                        color: interfaceColor(context, Colors.white54)))
                : Icon(Icons.live_tv,
                    size: 20, color: interfaceColor(context, Colors.white54))),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(channel.name,
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: interfaceColor(context, const Color(0xFFF0F4F8)))),
          if (channel.group.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(channel.group,
                    style: TextStyle(
                        fontSize: 10,
                        height: 1.2,
                        color:
                            interfaceColor(context, const Color(0xFFA5B1BF))))),
        ])),
        const SizedBox(width: 6),
        if (playing || selected || fromTile)
          Tooltip(
              message: playing
                  ? 'Playing channel'
                  : selected
                      ? 'Saved choice'
                      : 'Channel shown on event tile',
              child: Icon(Icons.push_pin_outlined,
                  size: 13, color: interfaceColor(context, Colors.white38)))
        else
          Text('#$rank',
              semanticsLabel: 'Option $rank',
              style: TextStyle(
                  fontSize: 10,
                  color: interfaceColor(context, Colors.white54),
                  fontWeight: FontWeight.w500)),
      ]),
      const SizedBox(height: 6),
      Wrap(
          spacing: 5,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ConfidenceBadge(match: match),
            if (f1FeedKind(channel) case final feed?)
              _ChannelTag(f1FeedLabel(feed)),
            if (playing)
              _ChannelTag('Playing',
                  icon: Icons.play_arrow, color: scheme.primary)
            else if (selected && match?.reason != MatchReason.pick)
              const _ChannelTag('Saved', icon: Icons.bookmark_outline),
            if (fromTile && !playing && !selected)
              const _ChannelTag('On event tile',
                  icon: Icons.view_agenda_outlined),
          ]),
      Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text('Why · $reason',
              style: TextStyle(
                  fontSize: 10.5,
                  height: 1.3,
                  color: interfaceColor(context, const Color(0xFFBAC5D1))))),
      for (final evidence in match?.supportingBroadcasts ?? const <String>[])
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(evidence,
                style: TextStyle(
                    fontSize: 10.5,
                    height: 1.25,
                    color: interfaceColor(context, const Color(0xFFB3BECA))))),
      if (showDetail)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                '${match?.reason == MatchReason.network ? 'Network' : match?.isConfident == true ? 'Matched' : 'Coverage'} · $detail',
                style: TextStyle(
                    fontSize: 10.5,
                    height: 1.25,
                    color: interfaceColor(context, const Color(0xFFB3BECA))))),
    ]);
    Widget programme(EpgProgram slot, String label, {bool primary = false}) =>
        _ChannelProgramme(
            slot: described(slot),
            highlighter: highlighter,
            label: label,
            now: now,
            primary: primary,
            evidenceLabel: !_same(slot, match?.programme)
                ? null
                : switch (match?.reason) {
                    MatchReason.guide || MatchReason.name => 'Event match',
                    MatchReason.network ||
                    MatchReason.listing =>
                      'Listed coverage',
                    MatchReason.tournament ||
                    MatchReason.league ||
                    MatchReason.sport =>
                      'Guide context',
                    _ => null,
                  },
            searchMatch:
                search && result.programmeSearchHit && _same(slot, evidence));
    final guide =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (current != null)
        programme(current, 'NOW', primary: true)
      else
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('Now · No programme information',
                style: TextStyle(
                    fontSize: 11,
                    height: 1.25,
                    color: interfaceColor(context, const Color(0xFFA5B1BF))))),
      for (final slot in extra) ...[
        const SizedBox(height: 7),
        programme(
            slot,
            slot.start.isAfter(now)
                ? 'LATER'
                : slot.stop.isAfter(now)
                    ? 'AT THIS TIME'
                    : 'EARLIER'),
      ],
      if (next != null) ...[
        const SizedBox(height: 6),
        programme(next, 'NEXT'),
      ],
    ]);
    final header = Padding(padding: const EdgeInsets.all(10), child: identity);
    final schedule = Padding(padding: const EdgeInsets.all(10), child: guide);
    return LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 620
            ? Ink(
                decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                  interfaceColor(context, const Color(0xFF2A3543)),
                  interfaceColor(context, const Color(0xFF2A3543)),
                  Colors.transparent,
                  Colors.transparent
                ], stops: const [
                  0,
                  5 / 12,
                  5 / 12,
                  1
                ])),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: header),
                      Expanded(flex: 7, child: schedule),
                    ]))
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Ink(
                    color: interfaceColor(context, const Color(0xFF2A3543)),
                    child: header),
                Divider(
                    height: 1,
                    color: interfaceColor(context, const Color(0xFF435062))),
                schedule,
              ]));
  }
}

/// Qualitative evidence labels, not uncalibrated probability percentages.
/// A saved choice is a preference; general coverage is never called confirmed.
class _ConfidenceBadge extends StatelessWidget {
  const _ConfidenceBadge({required this.match});
  final ChannelMatch? match;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon, explanation) = switch (match?.reason) {
      MatchReason.pick => (
          'Your pick',
          interfaceColor(context, const Color(0xFF90CAF9)),
          Icons.bookmark_outline,
          'The channel you saved for this event.'
        ),
      MatchReason.guide || MatchReason.name => (
          'High confidence',
          interfaceColor(context, const Color(0xFFA0DEBD)),
          Icons.check_circle_outline,
          'Event-specific evidence in the guide or channel name.'
        ),
      MatchReason.network || MatchReason.listing => (
          'Likely',
          interfaceColor(context, const Color(0xFF90CAF9)),
          Icons.live_tv,
          'Broadcaster or schedule evidence; stream availability is not verified.'
        ),
      MatchReason.tournament || MatchReason.league || MatchReason.sport => (
          'Possible',
          interfaceColor(context, const Color(0xFFE2C18C)),
          Icons.help_outline,
          'Related coverage; this specific match is not confirmed.'
        ),
      null => (
          'Unverified',
          interfaceColor(context, const Color(0xFFB3BECA)),
          Icons.search,
          'Matches your search; not verified for this event.'
        ),
    };
    return Tooltip(
        message: explanation,
        child: Semantics(
            label: '$label. $explanation',
            excludeSemantics: true,
            child:
                _ChannelTag(label, color: color, icon: icon, emphasis: true)));
  }
}

class _ChannelTag extends StatelessWidget {
  const _ChannelTag(this.label, {this.icon, this.color, this.emphasis = false});
  final bool emphasis;
  final String label;
  final IconData? icon;
  final Color? color;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
          color: (color ?? interfaceColor(context, Colors.white))
              .withValues(alpha: emphasis ? .14 : .06),
          borderRadius: BorderRadius.circular(3)),
      child: Text.rich(
          TextSpan(children: [
            if (icon != null)
              WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(icon,
                          size: 12,
                          color: color ??
                              interfaceColor(
                                  context, const Color(0xFFB3BECA))))),
            TextSpan(text: label),
          ]),
          style: TextStyle(
              fontSize: 10,
              fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
              height: 1.15,
              color:
                  color ?? interfaceColor(context, const Color(0xFFB3BECA)))));
}

class _ChannelProgramme extends StatelessWidget {
  const _ChannelProgramme(
      {required this.slot,
      required this.label,
      required this.now,
      this.primary = false,
      this.evidenceLabel,
      this.highlighter,
      this.searchMatch = false});
  final EpgProgram slot;
  final String label;
  final DateTime now;
  final bool primary, searchMatch;
  final String? evidenceLabel;
  final SportsProgrammeHighlighter? highlighter;

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final start = slot.start.toLocal(), end = slot.stop.toLocal();
    final time = DateFormat.Hm();
    final date = DateFormat('EEE d MMM');
    final when =
        '${_sameDay(start, now.toLocal()) ? '' : '${date.format(start)} · '}'
        '${time.format(start)}–${_sameDay(start, end) ? '' : '${date.format(end)} '}'
        '${time.format(end)}';
    final minutes =
        math.max(1, (slot.stop.difference(now).inSeconds / 60).ceil());
    final remaining = minutes >= 60
        ? '${minutes ~/ 60}h${minutes % 60 == 0 ? '' : ' ${minutes % 60}m'} left'
        : '${minutes}m left';
    final relevant = evidenceLabel != null || searchMatch;
    final compact = !primary && !relevant;
    if (compact) {
      final muted = interfaceColor(context, const Color(0xFF94A1B1));
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 9, height: 1.35, color: muted)),
        const SizedBox(width: 6),
        Text(
            '${_sameDay(start, now.toLocal()) ? '' : '${date.format(start)} '}${time.format(start)}',
            style: TextStyle(fontSize: 10, height: 1.25, color: muted)),
        const SizedBox(width: 6),
        Expanded(
            child: Text(slot.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, height: 1.25, color: muted))),
      ]);
    }
    final description = slot.description?.trim();
    final excerpt = !compact &&
            description != null &&
            description.isNotEmpty &&
            description != slot.title.trim()
        ? (highlighter ?? SportsProgrammeHighlighter(const []))
            .excerpt(description)
        : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 9.5,
                    height: 1.2,
                    letterSpacing: .4,
                    fontWeight: FontWeight.w700,
                    color: primary
                        ? Theme.of(context).colorScheme.primary
                        : interfaceColor(context, const Color(0xFFA5B1BF)))),
            Text('$when${primary ? ' · $remaining' : ''}',
                style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    color: interfaceColor(context, const Color(0xFFA5B1BF)))),
            if (relevant)
              Text(
                  evidenceLabel != null && searchMatch
                      ? '$evidenceLabel · Search match'
                      : evidenceLabel ?? 'Search match',
                  style: TextStyle(
                      fontSize: 9.5,
                      height: 1.2,
                      fontWeight: FontWeight.w500,
                      color: interfaceColor(context, const Color(0xFFB3BECA)))),
          ]),
      const SizedBox(height: 3),
      Text(slot.title,
          style: TextStyle(
              fontSize: primary ? 12 : 11,
              height: 1.25,
              fontWeight: primary ? FontWeight.w500 : FontWeight.w400,
              color: primary
                  ? interfaceColor(context, const Color(0xFFF0F4F8))
                  : interfaceColor(context, const Color(0xFFB3BECA)))),
      if (excerpt != null) ...[
        const SizedBox(height: 4),
        Text.rich(
            TextSpan(children: [
              for (var i = 0; i <= excerpt.emphasis.length; i++) ...[
                TextSpan(
                    text: excerpt.text.substring(
                        i == 0 ? 0 : excerpt.emphasis[i - 1].end,
                        i == excerpt.emphasis.length
                            ? excerpt.text.length
                            : excerpt.emphasis[i].start)),
                if (i < excerpt.emphasis.length)
                  TextSpan(
                      text: excerpt.text.substring(
                          excerpt.emphasis[i].start, excerpt.emphasis[i].end),
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: interfaceColor(
                              context, const Color(0xFFDFE6EF)))),
              ],
            ]),
            style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: interfaceColor(context, const Color(0xFFAEBBC9)))),
      ] else if (primary &&
          relevant &&
          (description == null || description.isEmpty)) ...[
        const SizedBox(height: 3),
        Text('No synopsis in guide',
            style: TextStyle(
                fontSize: 10,
                color: interfaceColor(context, const Color(0xFF94A1B1)))),
      ],
    ]);
  }
}
