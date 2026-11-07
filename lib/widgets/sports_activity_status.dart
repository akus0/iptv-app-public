import 'dart:async';
import '../utils/interface_colors.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/sports_progress.dart';
import 'sports_header_controls.dart';

/// Cold-open feedback uses real progress, not a perpetual full-screen spinner.
/// No ticker/shimmer: only this bounded region repaints when a feed completes.
class SportsEventsLoading extends StatelessWidget {
  const SportsEventsLoading(
      {super.key,
      required this.scores,
      required this.channels,
      required this.eventCount});
  final ValueListenable<SportsWorkProgress?> scores, channels;
  final int eventCount;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
          child: Center(
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: AnimatedBuilder(
                  animation: Listenable.merge([scores, channels]),
                  builder: (context, _) {
                    final score = scores.value, channel = channels.value;
                    final feedProgress = score != null && score.total > 0;
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.event_note_rounded,
                          size: 30,
                          color: interfaceColor(context, Colors.white38)),
                      const SizedBox(height: 12),
                      Text(
                          eventCount > 0
                              ? 'Checking event channels'
                              : 'Loading events',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: interfaceColor(context, Colors.white70))),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                          key: const ValueKey('sports-initial-progress'),
                          minHeight: 2,
                          value: feedProgress
                              ? (score.completed / score.total).clamp(0.0, 1.0)
                              : channel != null && channel.total > 0
                                  ? (channel.completed / channel.total)
                                      .clamp(0.0, 1.0)
                                  : 0,
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: .65),
                          backgroundColor:
                              interfaceColor(context, Colors.white10)),
                      const SizedBox(height: 10),
                      Text(
                          feedProgress
                              ? '${score.completed} of ${score.total} event feeds checked'
                              : channel?.summary ??
                                  'Connecting to event feeds…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: interfaceColor(context, Colors.white54))),
                      const SizedBox(height: 4),
                      Text(
                          eventCount > 0
                              ? '$eventCount events loaded · searching your guide'
                              : 'Events appear as they arrive',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              color: interfaceColor(context, Colors.white38))),
                    ]);
                  }),
            )),
      ));
}

/// Only this bounded status panel listens to work counters. Event cards, filters,
/// scroll controllers and the player never rebuild for a status/elapsed tick.
class SportsActivityStatus extends StatefulWidget {
  const SportsActivityStatus(
      {super.key,
      required this.scores,
      required this.channels,
      required this.pull,
      required this.refreshButton,
      required this.eventCount,
      required this.checkedCount,
      this.reason,
      this.detailsFocusNode,
      this.onDetailsRight,
      this.moreEvents,
      this.loadingEvents = false,
      this.checkingChannels = false,
      this.hasUsableEvents = false,
      this.eventError,
      this.channelError,
      this.active = true,
      this.television = false,
      this.inline = false,
      this.onFeedDetails,
      this.error});
  final ValueListenable<SportsWorkProgress?> scores, channels;
  final ValueListenable<String?> pull;
  final ValueListenable<String>? reason;
  final FocusNode? detailsFocusNode;
  final VoidCallback? onDetailsRight;
  final ValueListenable<bool>? moreEvents;
  final bool loadingEvents, checkingChannels, hasUsableEvents;
  final String? eventError, channelError;
  final Widget refreshButton;
  final int eventCount, checkedCount;
  final bool active;

  final bool television, inline;
  final ValueChanged<BuildContext>? onFeedDetails;
  final String? error;
  @override
  State<SportsActivityStatus> createState() => _SportsActivityStatusState();
}

typedef _ActivitySnapshot = ({
  SportsWorkProgress? scores,
  SportsWorkProgress? channels,
  bool loadingEvents,
  bool checkingChannels,
  bool moreEvents,
  bool hasUsableEvents,
  int eventCount,
  int checkedCount,
  String? eventError,
  String? channelError,
  String? error,
  String? reason,
});

extension on _ActivitySnapshot {
  bool get eventsBusy => loadingEvents || scores != null || moreEvents;
  bool get channelsBusy => checkingChannels || channels != null;
  bool get busy => eventsBusy || channelsBusy;
  ({String events, String channels, String heading}) get labels {
    final scores = this.scores, channels = this.channels;
    final failed = error ?? eventError ?? channelError;
    final String events;
    if (scores != null || loadingEvents) {
      final percent = scores != null && scores.total > 0
          ? ' ${(100 * scores.completed / scores.total).clamp(0, 100).floor()}%'
          : '';
      events = scores != null && scores.failed > 0
          ? 'Loading · ${scores.failed} failed'
          : 'Loading$percent';
    } else if (eventError != null) {
      events = 'Some unavailable';
    } else if (moreEvents) {
      events = 'Adding more';
    } else {
      events = 'Loaded';
    }
    final String coverage;
    if (channelError != null) {
      coverage = 'Check failed';
    } else if (channelsBusy) {
      coverage = switch (channels?.stage) {
        SportsWorkStage.matching => channels!.total > 0
            ? 'Matching ${(100 * channels.completed / channels.total).clamp(0, 100).floor()}%'
            : 'Searching',
        SportsWorkStage.verifying => 'Verifying matches',
        SportsWorkStage.channels ||
        SportsWorkStage.channelIndex =>
          'Preparing channels',
        null => 'Queued',
        _ => channels!.total > 0
            ? 'Reading guide ${(100 * channels.completed / channels.total).clamp(0, 100).floor()}%'
            : 'Reading guide',
      };
    } else if (eventsBusy) {
      coverage = 'Waiting for events';
    } else if (checkedCount < eventCount) {
      coverage = 'Not all checked';
    } else {
      coverage = 'Checked';
    }
    final heading = failed != null
        ? hasUsableEvents
            ? 'Browse · partial update'
            : 'Update incomplete'
        : busy
            ? hasUsableEvents
                ? 'Browse now · updating'
                : 'Loading sports'
            : hasUsableEvents
                ? 'Ready to browse'
                : checkedCount < eventCount
                    ? 'Checks pending'
                    : 'Checks complete';
    return (events: events, channels: coverage, heading: heading);
  }
}

class _SportsActivityStatusState extends State<SportsActivityStatus> {
  ValueNotifier<_ActivitySnapshot>? _details;
  bool _detailsQueued = false;

  _ActivitySnapshot get _snapshot => (
        scores: widget.scores.value,
        channels: widget.channels.value,
        loadingEvents: widget.loadingEvents,
        checkingChannels: widget.checkingChannels,
        moreEvents: widget.moreEvents?.value ?? false,
        hasUsableEvents: widget.hasUsableEvents,
        eventCount: widget.eventCount,
        checkedCount: widget.checkedCount,
        eventError: widget.eventError,
        channelError: widget.channelError,
        error: widget.error,
        reason: widget.reason?.value,
      );

  void _queueDetailsUpdate() {
    if (_details == null || _detailsQueued) return;
    _detailsQueued = true;
    // Widget flags can change during the parent's build. Publish after that
    // synchronous work, coalescing counters and completion into one update.
    scheduleMicrotask(() {
      _detailsQueued = false;
      if (mounted && _details != null) _details!.value = _snapshot;
    });
  }

  @override
  void initState() {
    super.initState();
    _listen(widget, true);
  }

  void _listen(SportsActivityStatus target, bool add) {
    for (final source in <Listenable>[
      target.scores,
      target.channels,
      target.pull,
      if (target.reason != null) target.reason!,
      if (target.moreEvents != null) target.moreEvents!
    ]) {
      if (add) {
        source.addListener(_changed);
      } else {
        source.removeListener(_changed);
      }
    }
  }

  @override
  void didUpdateWidget(SportsActivityStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    _queueDetailsUpdate();
    if (oldWidget.scores != widget.scores ||
        oldWidget.channels != widget.channels ||
        oldWidget.pull != widget.pull ||
        oldWidget.reason != widget.reason ||
        oldWidget.moreEvents != widget.moreEvents) {
      _listen(oldWidget, false);
      _listen(widget, true);
    }
  }

  void _changed() {
    _queueDetailsUpdate();
    if (mounted && widget.active) setState(() {});
  }

  @override
  void dispose() {
    _listen(widget, false);
    super.dispose();
  }

  Future<void> _showDetails(BuildContext context) async {
    if (_details != null) return;
    final updates = ValueNotifier(_snapshot);
    _details = updates;
    try {
      await showSportsDialog<void>(
          context: context,
          builder: (_) => _SportsActivityDetails(
              updates: updates,
              television: widget.television,
              onFeedDetails: widget.onFeedDetails));
    } finally {
      _details = null;
      // The closing dialog may remain mounted for its exit transition. Its
      // listener detaches on disposal; no further progress is published here.
      updates.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _snapshot;
    final labels = data.labels;
    final events = data.scores != null && data.scores!.failed > 0
        ? '${data.scores!.failed} failed'
        : labels.events;
    final coverage = labels.channels
        .replaceFirst('Reading guide', 'Guide')
        .replaceFirst('Preparing channels', 'Preparing')
        .replaceFirst('Verifying matches', 'Verifying')
        .replaceFirst('Waiting for events', 'Waiting');
    return RepaintBoundary(
        child: LayoutBuilder(builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context);
      if (widget.inline) {
        final muted = interfaceColor(context, Colors.white38);
        Widget line(String label, String value) => Text.rich(
              key: ValueKey('sports-status-${label.toLowerCase()}'),
              TextSpan(children: [
                TextSpan(text: '$label ', style: TextStyle(color: muted)),
                TextSpan(text: value),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 9.5,
                  height: 1.35,
                  color: interfaceColor(context, Colors.white60)),
            );
        return Row(key: const ValueKey('sports-load-status'), children: [
          Expanded(
              child: TextButton(
            key: const ValueKey('sports-status-details'),
            focusNode: widget.detailsFocusNode,
            onPressed: () => _showDetails(context),
            style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft),
            child: Semantics(
                label:
                    'Events: ${widget.pull.value ?? events}. Channels: $coverage. Open live progress details.',
                excludeSemantics: true,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      line('Events', widget.pull.value ?? events),
                      line('Channels', coverage),
                    ])),
          )),
          widget.refreshButton,
        ]);
      }
      final portrait = compactSportsPortrait(context) &&
          constraints.maxWidth >= scale.scale(280) &&
          scale.scale(11) < 16;
      final wrapped = constraints.maxWidth < scale.scale(330);
      final muted = interfaceColor(context, Colors.white38);
      final valueStyle = TextStyle(
          fontSize: 10,
          height: 1.3,
          color: interfaceColor(context, Colors.white60));
      Widget task(String label, String value, IconData icon) => SizedBox(
          height: scale.scale(10) * 1.3 * (wrapped ? 2 : 1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
                padding: const EdgeInsets.only(top: 1, right: 4),
                child: Icon(icon, size: 10, color: muted)),
            SizedBox(
                width: scale.scale(60),
                child: Row(children: [
                  Flexible(
                      child: Text(label,
                          maxLines: 1,
                          style: TextStyle(
                              fontSize: 10, height: 1.3, color: muted))),
                  if (label == 'Channels') ...[
                    const SizedBox(width: 3),
                    Icon(Icons.info_outline, size: 9, color: muted),
                  ],
                ])),
            Expanded(
                child: Text(value,
                    key: ValueKey('sports-status-${label.toLowerCase()}'),
                    maxLines: wrapped ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: valueStyle)),
          ]));
      Widget portraitTask(String label, String value) => Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Row(children: [
                  Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 9.5, height: 1.2, color: muted))),
                  if (label == 'Channels') ...[
                    const SizedBox(width: 3),
                    Icon(Icons.info_outline, size: 9, color: muted),
                  ],
                ]),
                SizedBox(
                    height: scale.scale(10.5) * 2.5,
                    child: Text(value,
                        key: ValueKey('sports-status-${label.toLowerCase()}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            valueStyle.copyWith(fontSize: 10.5, height: 1.25))),
              ]));
      Widget narrowTask(String label, String value) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9.5, height: 1.2, color: muted)),
                SizedBox(
                    height: scale.scale(10) * 2.6,
                    child: Text(value,
                        key: ValueKey('sports-status-${label.toLowerCase()}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: valueStyle)),
              ]);
      final detailsButton = Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.arrowRight &&
                widget.onDetailsRight != null) {
              widget.onDetailsRight!();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextButton(
            key: const ValueKey('sports-status-details'),
            focusNode: widget.detailsFocusNode,
            onPressed: () => _showDetails(context),
            style: TextButton.styleFrom(
                foregroundColor: muted,
                minimumSize: Size(0, widget.television ? 28 : 40),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft),
            child: Semantics(
                label:
                    'Events: $events. Channels: $coverage. Open live progress details.',
                excludeSemantics: true,
                child: LayoutBuilder(builder: (context, available) {
                  if (available.maxWidth < scale.scale(180)) {
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      narrowTask('Events', widget.pull.value ?? events),
                      const SizedBox(height: 1),
                      narrowTask('Channels', coverage),
                    ]);
                  }
                  return portrait
                      ? Row(children: [
                          portraitTask('Events', widget.pull.value ?? events),
                          const SizedBox(width: 6),
                          portraitTask('Channels', coverage),
                        ])
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          task('Events', widget.pull.value ?? events,
                              Icons.event_outlined),
                          const SizedBox(height: 1),
                          task('Channels', coverage, Icons.live_tv_outlined),
                        ]);
                })),
          ));
      final stacked = constraints.maxWidth < scale.scale(260);
      return Container(
          key: const ValueKey('sports-load-status'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(
                      color: interfaceColor(context, Colors.white)
                          .withValues(alpha: .06)))),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                      detailsButton,
                      Align(
                          alignment: Alignment.centerRight,
                          child: widget.refreshButton),
                    ])
              : Row(children: [
                  Expanded(child: detailsButton),
                  Container(
                      width: 1,
                      height: 20,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      color: interfaceColor(context, Colors.white10)),
                  widget.refreshButton,
                ]));
    }));
  }
}

class _SportsActivityDetails extends StatelessWidget {
  const _SportsActivityDetails(
      {required this.updates, required this.television, this.onFeedDetails});
  final ValueListenable<_ActivitySnapshot> updates;
  final bool television;
  final ValueChanged<BuildContext>? onFeedDetails;

  @override
  Widget build(BuildContext context) => SportsCompactDialog(
      title: 'Events & channel status',
      description: 'Live progress · updates as work completes',
      maxWidth: 440,
      child: Focus(
          key: const ValueKey('sports-status-scroll'),
          autofocus: television,
          onKeyEvent: (node, event) {
            if (!television ||
                (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
              return KeyEventResult.ignored;
            }
            final direction = event.logicalKey == LogicalKeyboardKey.arrowDown
                ? 1
                : event.logicalKey == LogicalKeyboardKey.arrowUp
                    ? -1
                    : 0;
            final position = Scrollable.maybeOf(node.context!)?.position;
            if (direction == 0 ||
                position == null ||
                !position.hasContentDimensions) {
              return KeyEventResult.ignored;
            }
            final target = (position.pixels + direction * 80)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
            if (target == position.pixels && direction < 0) {
              return KeyEventResult.ignored;
            }
            position.jumpTo(target);
            return KeyEventResult.handled;
          },
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            RepaintBoundary(
                child: ValueListenableBuilder<_ActivitySnapshot>(
              valueListenable: updates,
              builder: (context, data, _) {
                final labels = data.labels,
                    scores = data.scores,
                    channels = data.channels;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(labels.heading,
                              key: const ValueKey('sports-detail-heading'),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: interfaceColor(
                                      context, Colors.white60)))),
                      _ActivityDetailCard(
                          title: 'Events',
                          icon: Icons.event_outlined,
                          stage: labels.events,
                          metrics: [
                            (
                              'Feeds checked',
                              scores != null && scores.total > 0
                                  ? '${scores.completed} / ${scores.total}'
                                  : data.eventError != null
                                      ? 'Unavailable'
                                      : (data.loadingEvents || scores != null)
                                          ? 'Loading'
                                          : 'Complete'
                            ),
                            ('Fixtures loaded', '${data.eventCount}'),
                          ],
                          note: data.moreEvents
                              ? 'Additional schedules are loading.'
                              : null,
                          error: data.eventError ??
                              (scores != null && scores.failed > 0
                                  ? '${scores.failed} feeds unavailable. Saved results are retained.'
                                  : null)),
                      if (onFeedDetails != null &&
                          (data.eventError != null ||
                              (scores?.failed ?? 0) > 0))
                        Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                                onPressed: () => onFeedDetails!(context),
                                child: const Text('Event feed error details'))),
                      const SizedBox(height: 8),
                      _ActivityDetailCard(
                          title: 'Channel matching',
                          icon: Icons.live_tv_outlined,
                          stage: data.channelError != null
                              ? labels.channels
                              : channels?.label ?? labels.channels,
                          metrics: [
                            (
                              'Current step',
                              data.channelError != null
                                  ? 'Unavailable'
                                  : channels != null && channels.total > 0
                                      ? '${channels.completed} / ${channels.total}'
                                      : data.channelsBusy
                                          ? 'In progress'
                                          : data.checkedCount < data.eventCount
                                              ? 'Pending'
                                              : 'Complete'
                            ),
                            (
                              'Fixture checks',
                              '${data.checkedCount} / ${data.eventCount}'
                            ),
                          ],
                          note:
                              'Checks count events reviewed, not channels found.',
                          error: data.channelError ??
                              (data.error != data.eventError
                                  ? data.error
                                  : null)),
                    ]);
              },
            )),
            const SizedBox(height: 14),
            const Text('Refresh both',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
                'Reloads event feeds and scores, then rechecks channels using your saved guide. It does not download your playlist or update EPG sources.',
                style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: interfaceColor(context, Colors.white54))),
          ])));
}

class _ActivityDetailCard extends StatelessWidget {
  const _ActivityDetailCard(
      {required this.title,
      required this.icon,
      required this.stage,
      required this.metrics,
      this.note,
      this.error});
  final String title, stage;
  final IconData icon;
  final List<(String, String)> metrics;
  final String? note, error;

  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: interfaceColor(context, Colors.white).withValues(alpha: .025),
          border: Border.all(color: interfaceColor(context, Colors.white10)),
          borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: interfaceColor(context, Colors.white54)),
          const SizedBox(width: 6),
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 4),
        SizedBox(
            height: MediaQuery.textScalerOf(context).scale(11) * 2.6,
            child: Text(stage,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: interfaceColor(context, Colors.white70)))),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final metric in metrics)
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(metric.$1,
                      style: TextStyle(
                          fontSize: 10,
                          height: 1.3,
                          color: interfaceColor(context, Colors.white54))),
                  const SizedBox(height: 3),
                  Text(metric.$2,
                      style: const TextStyle(
                          fontSize: 14,
                          height: 1.2,
                          fontWeight: FontWeight.w600)),
                ])),
        ]),
        if (note != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(note!,
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.35,
                      color: interfaceColor(context, Colors.white54)))),
        if (error != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!,
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: Theme.of(context).colorScheme.error))),
      ]));
}

/// Only mounted, pending card footers listen to stage changes. No per-card
/// timers or animated spinners, and no subscription to high-frequency counts.
class SportsEventMatchStatus extends StatelessWidget {
  const SportsEventMatchStatus(
      {super.key,
      required this.stage,
      required this.color,
      this.error,
      this.hasCandidates = false,
      this.fontSize = 11});
  final ValueListenable<SportsWorkStage?> stage;
  final Color color;
  final String? error;
  final bool hasCandidates;
  final double fontSize;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<SportsWorkStage?>(
          valueListenable: stage,
          builder: (context, value, _) {
            final label = error != null
                ? 'Channel check unavailable'
                : switch (value) {
                    null => 'Waiting for channel check',
                    SportsWorkStage.matching => hasCandidates
                        ? 'Finishing channel check'
                        : 'Looking for a channel',
                    SportsWorkStage.verifying => 'Finishing channel check',
                    _ => hasCandidates
                        ? 'Checking programme details'
                        : 'Waiting for guide',
                  };
            final step =
                value == null ? 0 : SportsWorkProgress(value).channelStep;
            return Semantics(
                label: error == null && step > 0
                    ? '$label. Channel check step $step of 3.'
                    : label,
                excludeSemantics: true,
                child: Row(children: [
                  if (error == null) ...[
                    for (var i = 1; i <= 3; i++)
                      Container(
                          width: 3,
                          height: i <= step ? 8 : 4,
                          margin: const EdgeInsets.only(right: 2),
                          decoration: BoxDecoration(
                              color: color.withValues(
                                  alpha: i <= step ? .85 : .25),
                              borderRadius: BorderRadius.circular(1))),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: fontSize, color: color))),
                ]));
          });
}

/// Shared, fixed-size chrome for live events, replays and highlights.
/// Pull/status updates rebuild only this line, never the programme list.
class SportsActivityLine extends StatelessWidget {
  const SportsActivityLine(
      {super.key,
      required this.label,
      required this.details,
      required this.refreshButton,
      this.compact = true,
      this.busy = false,
      this.pulling = false,
      this.hasError = false});
  final String label, details;
  final Widget refreshButton;
  final bool compact, busy, pulling, hasError;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 9.5 : 10.5;
    return SizedBox(
      height: (MediaQuery.textScalerOf(context).scale(fontSize) *
              (compact ? 4 : 1.5))
          .clamp(compact ? 38 : 28, double.infinity),
      child: Row(children: [
        if (!compact)
          Icon(
              pulling
                  ? Icons.arrow_downward_rounded
                  : busy
                      ? Icons.sync
                      : hasError
                          ? Icons.info_outline
                          : Icons.check_rounded,
              size: 12,
              color: busy
                  ? interfaceColor(context, Colors.white60)
                  : interfaceColor(context, Colors.white38)),
        if (!compact) const SizedBox(width: 5),
        Expanded(
            child: Tooltip(
                message: details,
                child: Text(label,
                    key: const ValueKey('sports-load-status'),
                    maxLines: compact ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: fontSize,
                        height: 1.25,
                        color: compact && !hasError && !pulling
                            ? interfaceColor(context, Colors.white38)
                            : interfaceColor(context, Colors.white60))))),
        refreshButton,
      ]),
    );
  }
}
