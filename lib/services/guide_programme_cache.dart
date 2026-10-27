import '../models/epg_program.dart';

/// Keep recently browsed guide rows without clearing a warm screen at capacity.
/// Empty guide rows count too. An oversized single timeline stays intact.
class GuideProgrammeCache {
  GuideProgrammeCache({this.maxChannels = 400, this.maxProgrammes = 20000});
  final int maxChannels, maxProgrammes;
  final _entries = <String, List<EpgProgram>>{};
  int _programmes = 0;
  int get length => _entries.length;
  int get programmeCount => _programmes;
  Map<String, List<EpgProgram>> snapshot() => Map.of(_entries);

  List<EpgProgram>? operator [](String id) {
    final hit = _entries.remove(id);
    if (hit != null) _entries[id] = hit;
    return hit;
  }

  void operator []=(String id, List<EpgProgram> rows) {
    _programmes -= _entries.remove(id)?.length ?? 0;
    _entries[id] = rows;
    _programmes += rows.length;
    while (_entries.length > maxChannels ||
        (_entries.length > 1 && _programmes > maxProgrammes)) {
      _programmes -= _entries.remove(_entries.keys.first)!.length;
    }
  }

  void clear() {
    _entries.clear();
    _programmes = 0;
  }
}
