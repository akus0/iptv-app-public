import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/utils/epg_timeline.dart';

void main() {
  final start = DateTime(2026, 10, 24);
  final rows = [
    for (var i = 0; i < 10000; i++)
      EpgProgram(
          channelId: 'test',
          title: '$i',
          start: start.add(Duration(minutes: i * 30)),
          stop: start.add(Duration(minutes: i * 30 + 20)))
  ];
  test('timeline finds current and next without treating gaps as on air', () {
    expect(programmeAt([], start), isNull);
    expect(nextProgrammeAfter([], start), isNull);
    expect(
        programmeAt(rows, start.subtract(const Duration(seconds: 1))), isNull);
    expect(nextProgrammeAfter(rows, start.subtract(const Duration(seconds: 1))),
        rows.first);
    for (final index in [0, 1, 5000, 9999]) {
      final row = rows[index];
      expect(programmeAt(rows, row.start), same(row));
      expect(programmeAt(rows, row.stop.subtract(const Duration(seconds: 1))),
          same(row));
      expect(programmeAt(rows, row.stop), isNull);
      expect(nextProgrammeAfter(rows, row.start),
          index == 9999 ? null : rows[index + 1]);
    }
  });
}
