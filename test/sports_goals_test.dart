import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/sports_service.dart';

Map<String, dynamic> _play(String type, bool scoring,
        {String? scorer,
        List<String> assists = const [],
        int a = 0,
        int h = 0}) =>
    {
      'type': {'abbreviation': type, 'text': type},
      'scoringPlay': scoring,
      'period': {'displayValue': '2nd'},
      'clock': {'displayValue': '13:14'},
      'team': {'id': '13'},
      'awayScore': a,
      'homeScore': h,
      'participants': [
        if (scorer != null)
          {
            'type': 'scorer',
            'athlete': {'shortName': scorer}
          },
        for (final x in assists)
          {
            'type': 'assister',
            'athlete': {'shortName': x}
          },
      ],
    };

void main() {
  test('hockey: every goal from plays, with assists and running score', () {
    final body = jsonEncode({
      'plays': [
        _play('faceoff', false),
        _play('goal', true,
            scorer: 'S. Durzi', assists: ['P. Dorofeyev', 'T. Kartye'], h: 1),
        _play('shot', false),
        _play('goal', true, scorer: 'O. Bjorkstrand', h: 4),
        // A basketball basket is a scoring play too, but not a goal.
        _play('jumpshot', true, scorer: 'X. Hoop', h: 6),
      ],
    });
    final s = parseEspnSummary((body, '13', '25'));
    expect(s.goals.map((g) => g.scorer), ['S. Durzi', 'O. Bjorkstrand']);
    final first = s.goals.first;
    expect(first.period, '2nd');
    expect(first.minute, '13:14');
    expect(first.assists, ['P. Dorofeyev', 'T. Kartye']);
    expect(first.score, '0-1');
    expect(first.teamId, '13');
    expect(s.goals.last.assists, isEmpty); // unassisted
  });
}
