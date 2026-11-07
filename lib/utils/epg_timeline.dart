import '../models/epg_program.dart';

/// Timelines supplied by EpgService are sorted and have no overlapping slots.
int _firstStartingAfter(List<EpgProgram> rows, DateTime time) {
  var low = 0, high = rows.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (rows[middle].start.isAfter(time)) {
      high = middle;
    } else {
      low = middle + 1;
    }
  }
  return low;
}

EpgProgram? programmeAt(List<EpgProgram> rows, DateTime time) {
  final index = _firstStartingAfter(rows, time) - 1;
  return index >= 0 && rows[index].stop.isAfter(time) ? rows[index] : null;
}

EpgProgram? nextProgrammeAfter(List<EpgProgram> rows, DateTime time) {
  final index = _firstStartingAfter(rows, time);
  return index < rows.length ? rows[index] : null;
}
