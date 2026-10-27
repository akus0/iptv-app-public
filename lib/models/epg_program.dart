/// A single XMLTV `<programme>` entry: one show airing on one channel
/// between [start] and [stop].
class EpgProgram {
  EpgProgram({
    required this.channelId,
    required this.title,
    required this.start,
    required this.stop,
    this.description,
    this.isLive = false,
  });

  final String channelId;
  final String title;
  final String? description;

  /// Explicit XMLTV live marker. Absence does not prove a replay.
  final bool isLive;
  final DateTime start;
  final DateTime stop;

  bool isNowPlaying(DateTime now) => !now.isBefore(start) && now.isBefore(stop);
}
