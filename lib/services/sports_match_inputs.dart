import '../models/epg_program.dart';
import '../models/sports.dart';

/// Read-only inputs for matching. The scorer can run without preferences,
/// platform plugins, network clients or the widget tree.
abstract interface class SportsMatchGuide {
  int get changeRevision;
  DateTime? get lastUpdated;
  EpgProgram? getCurrentProgram(String channelId);
  EpgProgram? getNextProgram(String channelId);
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms);
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to);
}

abstract interface class SportsMatchPicks {
  String? channelIdFor(SportsGame game);
}
