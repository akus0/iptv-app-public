import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/sports_title_filter.dart';
import 'package:nox_iptv/utils/sports_language.dart';

void main() {
  final titles = [
    'Live football: Arsenal',
    'Tennis: João',
    'テニス',
    'ฟุตบอล',
    'ſport Kelvin',
    'Live.*[sport] 🎾',
    'Ｔｅｎｎｉｓ',
    'ТЕННИС',
    for (var i = 0; i < 2000; i++) 'Programme $i',
  ];
  List<String> expected(List<String> terms, List<String> input) {
    final pattern =
        RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
    return input.where((title) => sportsTitleMatches(pattern, title)).toList();
  }

  test('worker preserves literal, translated and empty-query results',
      () async {
    final filter = SportsTitleFilter();
    addTearDown(filter.dispose);
    final random = Random(159);
    for (var i = 0; i < 20; i++) {
      final terms = [
        ...[
          'tennis',
          'sport',
          'ſport',
          'K',
          'football',
          'João',
          'ฟุตบอล',
          '.*['
        ].where((_) => random.nextBool()),
        for (var j = 0; j < 100; j++) 'Programme ${random.nextInt(2000)}',
      ];
      expect(await filter.matches(terms, titles), expected(terms, titles));
    }
    expect(await filter.matches([], titles), titles);
    expect(await filter.matches(['missing'], titles), isEmpty);
    expect(await filter.matches(['tennis'], []), isEmpty);
  });

  test('concurrent lookups keep distinct keywords and ordered results',
      () async {
    final filter = SportsTitleFilter();
    addTearDown(filter.dispose);
    final queries = [
      for (var i = 0; i < 12; i++) ['Programme $i']
    ];
    final results =
        await Future.wait(queries.map((q) => filter.matches(q, titles)));
    for (var i = 0; i < queries.length; i++) {
      expect(results[i], expected(queries[i], titles));
    }
  });

  test('disposal during startup falls back exactly and permits restart',
      () async {
    final filter = SportsTitleFilter();
    addTearDown(filter.dispose);
    final pending = filter.matches(['tennis'], titles);
    filter.dispose();
    expect(await pending, expected(['tennis'], titles));
    expect(await filter.matches(['football'], titles),
        expected(['football'], titles));
  });

  test('small lookups preserve the same semantics', () async {
    final filter = SportsTitleFilter();
    addTearDown(filter.dispose);
    expect(await filter.matches(['tennis'], titles.take(20).toList()),
        expected(['tennis'], titles.take(20).toList()));
  });
}
