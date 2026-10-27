/// Small, metadata-only progress messages. Counts describe work, not confidence.
class SportsWorkProgress {
  const SportsWorkProgress(this.stage,
      {this.completed = 0, this.total = 0, this.detail, this.failed = 0});
  final SportsWorkStage stage;
  final int completed, total, failed;
  final String? detail;

  String get label => switch (stage) {
        SportsWorkStage.scores => 'Scores',
        SportsWorkStage.channels => 'Loading channels',
        SportsWorkStage.channelIndex => 'Indexing channels',
        SportsWorkStage.guideSnapshot => 'Reading current guide',
        SportsWorkStage.guide => 'Reading guide',
        SportsWorkStage.tennisGuide => 'Reading tennis guide',
        SportsWorkStage.programmes => 'Indexing programmes',
        SportsWorkStage.matching => 'Matching events',
        SportsWorkStage.verifying => 'Verifying matches',
      };
  String get summary => total > 0 ? '$label · $completed/$total' : '$label…';

  /// Stages are local to this channel-check pass, never an estimated overall %.
  int get channelStep => switch (stage) {
        SportsWorkStage.matching => 2,
        SportsWorkStage.verifying => 3,
        _ => 1,
      };

  String get channelStepLabel => switch (stage) {
        SportsWorkStage.channels ||
        SportsWorkStage.channelIndex =>
          'Prepare channels$_percent',
        SportsWorkStage.matching =>
          total > 0 ? 'Match $completed/$total' : 'Match events',
        SportsWorkStage.verifying => 'Final checks',
        _ => 'Read guide$_percent',
      };

  String get _percent =>
      total > 0 ? ' ${(100 * completed / total).clamp(0, 100).floor()}%' : '';
}

enum SportsWorkStage {
  scores,
  channels,
  channelIndex,
  guideSnapshot,
  guide,
  tennisGuide,
  programmes,
  matching,
  verifying
}

/// No timers, queues or result copies. Long-running loops can report their
/// actual position, at most about three times a second within each stage.
class SportsProgressReporter {
  SportsProgressReporter(this.callback);
  final void Function(SportsWorkProgress)? callback;
  final Stopwatch _clock = Stopwatch();
  SportsWorkStage? _stage;

  void report(SportsWorkStage stage,
      {int completed = 0, int total = 0, String? detail, bool force = false}) {
    if (callback == null) return;
    if (!force && stage == _stage && _clock.elapsedMilliseconds < 350) return;
    _stage = stage;
    _clock
      ..reset()
      ..start();
    callback!(SportsWorkProgress(stage,
        completed: completed, total: total, detail: detail));
  }
}
