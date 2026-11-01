import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/sports_language.dart';

void main() {
  final connector = RegExp(sportsFixtureConnectorPattern);
  final joiningApostrophe = RegExp(sportsJoiningApostrophePattern);

  String normalizedSynopsis(String raw) =>
      normalizeSportsName(sportsLanguageText(raw.replaceAll('@', ' at '))
          .replaceAll(joiningApostrophe, ''));

  void check(String raw) {
    final normalized = normalizedSynopsis(raw);
    if (connector.hasMatch(normalized)) {
      expect(sportsSynopsisMayNameFixture(raw), isTrue, reason: raw);
    }
  }

  test('skips plain descriptions without possible fixture evidence', () {
    for (final text in [
      '',
      'Live football coverage from London.',
      'A family comedy about a holiday in Spain.',
      'Highlights of the latest basketball action.',
      'The hostsomething visitsomewhere versusness show.',
    ]) {
      expect(sportsSynopsisMayNameFixture(text), isFalse, reason: text);
    }
  });

  test('retains connectors through ASCII punctuation and translation', () {
    const words = [
      'vs',
      'v',
      'versus',
      'at',
      'against',
      'faces',
      'meets',
      'plays',
      'takes on',
      'take on',
      'host',
      'hosts',
      'visits',
      'contra',
      'contre',
      'gegen',
    ];
    const separators = [
      ' ',
      '.',
      ',',
      ':',
      '|',
      '-',
      '_',
      '+',
      '/',
      '\t',
      '\n'
    ];
    for (final word in words) {
      for (final left in separators) {
        for (final right in separators) {
          check('Arsenal$left$word${right}Chelsea');
          check('Arsenal$left${word.toUpperCase()}${right}Chelsea');
          check('$left$word$right');
        }
        check('Arsenal ${word.replaceAll(' ', left)} Chelsea');
      }
    }
  });

  test('ambiguous punctuation and all Unicode retain full verification', () {
    for (final text in [
      "Arsenal a't Chelsea",
      "Arsenal vs''Chelsea",
      'Arsenal@Chelsea',
      'Arsenal àt Chelsea',
      'Arsenal v\u0301s Chelsea',
      'Arsenal ｖｓ Chelsea',
      'Arsenal contre Chelsea',
      'Arsenal против Chelsea',
      'Arsenal対Chelsea',
      'Court １',
      'Sinner’s match',
    ]) {
      expect(sportsSynopsisMayNameFixture(text), isTrue, reason: text);
    }
  });

  test('random ASCII inputs never reject normalized connector evidence', () {
    final random = Random(160);
    const fragments = [
      'vs',
      'at',
      'v',
      'host',
      'takes',
      'on',
      'contra',
      'contre',
      'gegen',
      'futbol',
      'tenis',
      'arsenal',
      'chelsea',
      'a',
      't',
      's',
    ];
    for (var i = 0; i < 10000; i++) {
      final text = StringBuffer();
      for (var j = 0; j < 8; j++) {
        text.write(fragments[random.nextInt(fragments.length)]);
        text.writeCharCode(random.nextInt(128));
      }
      check(text.toString());
    }
  });
  test('ordinary synopsis matchup words cannot manufacture a sport', () {
    for (final text in [
      '',
      'A family meets at their holiday home.',
      'The detective plays a dangerous game against the thieves.',
      'An artist visits friends at the new gallery.',
      'A footballer meets a basketballer.',
    ]) {
      expect(sportsSynopsisMayNameSport(text), isFalse, reason: text);
    }
  });

  void checkSport(String raw) {
    final normalized = normalizedSynopsis(raw);
    if (RegExp(sportsExplicitSportPattern).hasMatch(normalized)) {
      expect(sportsSynopsisMayNameSport(raw), isTrue, reason: raw);
    }
  }

  test('sport rejection retains canonical words, translations and punctuation',
      () {
    const sports = [
      'futsal',
      'table tennis',
      'field hockey',
      'boxing',
      'handball',
      'badminton',
      'volleyball',
      'basketball',
      'nba',
      'wnba',
      'baseball',
      'mlb',
      'npb',
      'kbo',
      'softball',
      'soccer',
      'tennis',
      'atp',
      'wta',
      'ice hockey',
      'hockey',
      'nhl',
      'rugby',
      'golf',
      'american football',
      'college football',
      'nfl',
      'ncaaf',
      'futbol',
      'tenis',
      'baloncesto',
      'voleibol',
      'pallacanestro',
      'futebol',
      'tennis de table',
      'hockey sur glace',
    ];
    const separators = [
      ' ',
      '.',
      ':',
      '|',
      '-',
      '_',
      '+',
      '/',
      '@',
      '\t',
      '\n'
    ];
    for (final sport in sports) {
      for (final separator in separators) {
        checkSport('Team A vs Team B: $separator$sport$separator');
        checkSport(sport.toUpperCase().replaceAll(' ', separator));
      }
    }
  });

  test('native text and joining apostrophes retain full sport verification',
      () {
    for (final text in [
      "B'asketball",
      '篮球',
      'サッカー',
      '축구',
      'fútbol',
      'Ｔｅｎｎｉｓ',
      'NＨL',
      'ATP: Alcaraz vs João',
    ]) {
      expect(sportsSynopsisMayNameSport(text), isTrue, reason: text);
    }
  });

  test(
      'randomized synopsis punctuation never rejects normalized sport evidence',
      () {
    final random = Random(170);
    const fragments = [
      'college',
      'football',
      'american',
      'ice',
      'hockey',
      'table',
      'tennis',
      'tenis',
      'de',
      'mesa',
      'futbol',
      'nba',
      'baseball',
      'at',
      'against',
      'golf',
      'rugby',
      'pallacanestro',
      'boxeo',
      'nhl'
    ];
    for (var i = 0; i < 15000; i++) {
      final text = StringBuffer();
      for (var j = 0; j < 6; j++) {
        text.write(fragments[random.nextInt(fragments.length)]);
        text.writeCharCode(random.nextInt(128));
      }
      checkSport(text.toString());
    }
  });

  test('ordinary ASCII apostrophes do not force unrelated synopsis analysis',
      () {
    for (final text in [
      "Today's news and tomorrow's weather.",
      "A detective's search for the family's missing heirloom.",
      "'Something different' - tonight's entertainment.",
      "Basket'ball",
    ]) {
      expect(sportsSynopsisMayNameFixture(text), isFalse, reason: text);
      expect(sportsSynopsisMayNameSport(text), isFalse, reason: text);
    }
    // Rejecting extra punctuation must not hide genuine evidence elsewhere.
    check("Today's game: Arsenal vs Chelsea");
    checkSport("Tonight's basketball: Team A vs Team B");
  });

  test('quoted evidence and joining apostrophes retain exact verification', () {
    for (final text in [
      "Arsenal a't Chelsea",
      "Arsenal h'osts Chelsea",
      "Arsenal'vs'Chelsea",
      "Arsenal'contre'Chelsea",
      "Arsenal 'takes on' Chelsea",
    ]) {
      expect(sportsSynopsisMayNameFixture(text), isTrue, reason: text);
      check(text);
    }
    for (final text in [
      "B'asketball",
      "t'ennis",
      "g'olf",
      "ice h'ockey",
      "'basketball'",
      "college'football",
      "tennis'de'table",
    ]) {
      expect(sportsSynopsisMayNameSport(text), isTrue, reason: text);
      checkSport(text);
    }
    expect(sportsSynopsisMayNameFixture("O'Connor's story"), isTrue);
    expect(sportsSynopsisMayNameSport("O'Connor's story"), isTrue);
  });

  test('apostrophe positions never reject normalized fixture or sport words',
      () {
    for (final word in [
      'against',
      'hosts',
      'visits',
      'at',
      'takes on',
      'contra',
      'contre',
      'basketball',
      'soccer',
      'boxing',
      'ice hockey',
      'table tennis',
      'american football',
      'tenis de mesa',
      'futbol',
      'pallacanestro',
    ]) {
      for (var at = 0; at <= word.length; at++) {
        final punctuated = "${word.substring(0, at)}'${word.substring(at)}";
        for (final boundary in [' ', "'", '+', '_', '|', ':', '-', '\t']) {
          final text = "Today's programme: $boundary$punctuated$boundary";
          check(text);
          checkSport(text);
          check(text.toUpperCase());
          checkSport(text.toUpperCase());
        }
      }
    }
  });
}
