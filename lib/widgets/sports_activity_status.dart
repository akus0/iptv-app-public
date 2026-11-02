import '../utils/interface_colors.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/sports_progress.dart';

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

/// Only this small fixed row listens to work counters. Event cards, filters,
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
      this.moreEvents,
      this.loadingEvents = false,
      this.checkingChannels = false,
      this.hasUsableEvents = false,
      this.eventError,
      this.channelError,
      this.active = true,
      this.compact = false,
      this.error});
  final ValueListenable<SportsWorkProgress?> scores, channels;
  final ValueListenable<String?> pull;
  final ValueListenable<String>? reason;
  final ValueListenable<bool>? moreEvents;
  final bool loadingEvents, checkingChannels, hasUsableEvents;
  final String? eventError, channelError;
  final Widget refreshButton;
  final int eventCount, checkedCount;
  final bool active;

  /// Fits beside the preview summary without reserving a separate status row.
  final bool compact;
  final String? error;
  @override
  State<SportsActivityStatus> createState() => _SportsActivityStatusState();
}

class _SportsActivityStatusState extends State<SportsActivityStatus> {
  bool get _eventsBusy =>
      widget.loadingEvents ||
      widget.scores.value != null ||
      (widget.moreEvents?.value ?? false);
  bool get _channelsBusy =>
      widget.checkingChannels || widget.channels.value != null;
  bool get _busy => _eventsBusy || _channelsBusy;
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
    if (mounted && widget.active) setState(() {});
  }

  @override
  void dispose() {
    _listen(widget, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scores = widget.scores.value, channels = widget.channels.value;
    final failed = widget.error ?? widget.eventError ?? widget.channelError;
    final String events;
    if (scores != null || widget.loadingEvents) {
      final percent = scores != null && scores.total > 0
          ? ' ${(100 * scores.completed / scores.total).clamp(0, 100).floor()}%'
          : '';
      events = scores != null && scores.failed > 0
          ? 'Events:$percent · ${scores.failed} unavailable'
          : 'Events: loading$percent';
    } else if (widget.eventError != null) {
      events = 'Events: some unavailable';
    } else if (widget.moreEvents?.value ?? false) {
      events = 'Events: adding more';
    } else {
      events = 'Events: loaded';
    }
    final String coverage;
    if (widget.channelError != null) {
      coverage = 'Channels: check failed';
    } else if (_channelsBusy) {
      coverage = switch (channels?.stage) {
        SportsWorkStage.matching => channels!.total > 0
            ? 'Channels: ${(channels.total - channels.completed).clamp(0, channels.total)} events left'
            : 'Channels: searching',
        SportsWorkStage.verifying => 'Channels: finishing',
        SportsWorkStage.channels ||
        SportsWorkStage.channelIndex =>
          'Channels: preparing',
        null => 'Channels: queued',
        _ => channels!.total > 0
            ? 'Channels: guide ${(100 * channels.completed / channels.total).clamp(0, 100).floor()}%'
            : 'Channels: guide scan',
      };
    } else if (_eventsBusy) {
      coverage = 'Channels: waiting';
    } else if (widget.checkedCount < widget.eventCount) {
      coverage = 'Channels: not all checked';
    } else {
      coverage = 'Channels: checked';
    }
    final heading = failed != null
        ? widget.hasUsableEvents
            ? 'Browse · partial update'
            : 'Update incomplete'
        : _busy
            ? widget.hasUsableEvents
                ? 'Browse now · updating'
                : 'Loading sports'
            : widget.hasUsableEvents
                ? 'Ready to browse'
                : 'Checks complete';
    final label = widget.pull.value ??
        [heading, events, coverage].join(widget.compact ? '\n' : ' · ');
    final details = [
      heading,
      events,
      coverage,
      if (_busy && widget.reason != null) widget.reason!.value,
      if (widget.hasUsableEvents)
        'Channels already shown remain available while other events are checked.',
      if (_eventsBusy)
        'More events may arrive. Their channel checks run as they become available.',
      if (widget.moreEvents?.value ?? false)
        'Looking for additional schedules and broadcaster listings.',
      if (scores != null && scores.total > 0)
        '${scores.completed} of ${scores.total} event feeds checked.',
      if (scores != null && scores.failed > 0)
        '${scores.failed} feeds unavailable; retaining saved events.',
      if (channels != null) channels.summary,
      '${widget.checkedCount} of ${widget.eventCount} events have completed channel checks. This is not a count of matched channels.',
      if (failed != null) failed,
    ].join('\n');
    return SportsActivityLine(
      label: label,
      details: details,
      compact: widget.compact,
      busy: _busy,
      pulling: widget.pull.value != null,
      hasError: failed != null,
      refreshButton: widget.refreshButton,
    );
  }
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
