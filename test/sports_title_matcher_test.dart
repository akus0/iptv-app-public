import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/sports_language.dart';
import 'package:nox_iptv/utils/sports_title_matcher.dart';

void main() {
  test('ASCII churn preserves exact results across fallback-only cache reuse',
      () {
    final cache = SportsTitleTextCache(maxEntries: 32, maxCharacters: 2048);
    final titles = [
      for (var i = 0; i < 18; i++) 'テニス João $i',
      for (var i = 0; i < 256; i++) 'Ordinary programme $i',
      'tenis de mesa',
      'Pista 12',
      'ſport Kelvin',
      'Joao\u0303',
      'テ' * 3000,
    ];
    for (final terms in [
      ['missing'],
      ['tennis'],
      ['ordinary'],
      ['joao'],
      ['table tennis'],
      ['court'],
      ['ſport', 'Kelvin'],
      ['missing'],
    ]) {
      final matcher = SportsTitleMatcher(terms,
          textCache: cache, precomputeTransitions: true);
      final reference =
          RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
      for (final title in [...titles, ...titles.reversed]) {
        expect(matcher.matches(title), sportsTitleMatches(reference, title));
      }
    }
  });

  test('precomputed transitions retain every ASCII byte and Unicode reset', () {
    final terms = [for (var c = 0; c < 128; c++) 'x${String.fromCharCode(c)}y'];
    final matcher = SportsTitleMatcher(terms, precomputeTransitions: true);
    final reference =
        RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
    for (final middle in [
      for (var c = 0; c < 128; c++) String.fromCharCode(c),
      'é',
      'K',
      'ſ',
      'İ',
      '\uD800',
      'テ',
      '🎾',
    ]) {
      for (final text in [
        'prefix x${middle}y suffix',
        'x${middle}z',
        'x$middle'
      ]) {
        expect(matcher.matches(text), sportsTitleMatches(reference, text));
      }
    }
  });

  test('wide keyword sets exceed the table budget without losing matches', () {
    final random = Random(164);
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final terms = [
      for (var i = 0; i < 1000; i++)
        List.generate(40, (_) => alphabet[random.nextInt(alphabet.length)])
            .join()
    ];
    final matcher = SportsTitleMatcher(terms, precomputeTransitions: true);
    final reference =
        RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
    for (final text in [
      'No matching programme',
      terms.first,
      terms.last.toUpperCase(),
      for (var i = 0; i < terms.length; i += 37) 'prefix ${terms[i]} suffix',
      for (var i = 0; i < terms.length; i += 101) terms[i].substring(1),
    ]) {
      expect(matcher.matches(text), sportsTitleMatches(reference, text));
    }
  });

  test('more than 16-bit states retain the sparse matcher without truncation',
      () {
    final term = 'a' * 65536;
    final matcher = SportsTitleMatcher([term], precomputeTransitions: true);
    expect(matcher.matches(term), isTrue);
    expect(matcher.matches('prefix $term suffix'), isTrue);
    expect(matcher.matches(term.substring(1)), isFalse);
  });

  for (final precompute in [false, true]) {
    group('precompute=$precompute', () {
      test('mixed queries retain ASCII hits beside native text and decoration',
          () {
        final terms = [
          for (var c = 0; c < 128; c++) 'x${String.fromCharCode(c)}y',
          'テニス',
          '축구',
          '足球',
          'João',
          'Σ',
          'µ',
          'ſ',
          'K',
        ];
        final matcher = SportsTitleMatcher(terms,
            textCache: SportsTitleTextCache(),
            precomputeTransitions: precompute);
        final reference =
            RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
        for (var c = 0; c < 128; c++) {
          for (final surrounding in ['🎾', 'é', '한국', '日本', '\uD800']) {
            final title =
                '$surrounding X${String.fromCharCode(c)}Y $surrounding';
            expect(matcher.matches(title), sportsTitleMatches(reference, title),
                reason: 'ASCII byte $c beside $surrounding');
          }
        }
      });

      test('mixed-query misses retain combined case folding and translation',
          () {
        for (final terms in [
          ['テニス', '축구', '足球', 'Σ', 'µ', 'ſ', 'K'],
          ['football', 'k', 's', 'テニス', 'Σ', 'µ', 'İ'],
          ['tennis', 'soccer', 'baseball', '축구', 'ſ', 'K'],
          ['missing', 'João', 'ς', 'Μ', 'ı'],
        ]) {
          final matcher =
              SportsTitleMatcher(terms, precomputeTransitions: precompute);
          final reference =
              RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
          for (final title in [
            'ſ',
            'S',
            'K',
            'K',
            'İ',
            'i',
            'ı',
            'Σ',
            'ς',
            'σ',
            'µ',
            'Μ',
            'μ',
            '🎾 テニス',
            '축구',
            '한국프로야구',
            'Fútbol',
            'Ｔｅｎｎｉｓ',
            'Joao\u0303',
            'João',
            '풋볼 documentary',
            'Fóotball documentary',
            'Ordinary documentary 🎾',
          ]) {
            expect(matcher.matches(title), sportsTitleMatches(reference, title),
                reason: '$terms / $title');
          }
        }
      });

      test(
          'literal index preserves regex, Unicode and translated guide results',
          () {
        final titles = [
          'Live: ATP Basel',
          'Теннис: ATP Basel',
          'テニス ATP Basel',
          'Tênis: João vs Sébastien',
          'ESPN+ [1] Sky.Sports (Live)',
          'Football: USA vs Netherlands',
          'Fußball: Deutschland',
          '한국프로야구',
          'Poker highlights',
          'sHe sells seashells',
          'İstanbul ı I i',
          'K Kelvin',
          'long ſ S s',
          '',
          'Movie night',
        ];
        for (final terms in <List<String>>[
          [],
          [''],
          ['tennis', 'basel', 'poker', 'baseball'],
          ['espn+', '[1]', '.', '(', r'\'],
          ['he', 'she', 'hers', 'his'],
          ['sebastien', 'joao'],
          ['i', 'İ', 'ı'],
          ['k', 's'],
          ['ТЕННИС', 'ATP', 'João'],
          ['soccer', 'germany'],
        ]) {
          final matcher =
              SportsTitleMatcher(terms, precomputeTransitions: precompute);
          final reference = RegExp(terms.toSet().map(RegExp.escape).join('|'),
              caseSensitive: false);
          for (final title in titles) {
            expect(matcher.matches(title), sportsTitleMatches(reference, title),
                reason: '$terms / $title');
          }
        }
      });

      test('overlapping prefixes and suffixes agree with the previous search',
          () {
        final random = Random(9327);
        const alphabet = 'aAbBcCdD .+|[]';
        String word(int length) => List.generate(
            length, (_) => alphabet[random.nextInt(alphabet.length)]).join();
        for (var batch = 0; batch < 80; batch++) {
          final terms = List.generate(80, (_) => word(1 + random.nextInt(10)));
          final index =
              SportsTitleMatcher(terms, precomputeTransitions: precompute);
          final previous =
              RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
          for (var row = 0; row < 100; row++) {
            final title = word(random.nextInt(100));
            expect(index.matches(title), sportsTitleMatches(previous, title));
          }
        }
      });

      test('mixed-script titles retain literal and language-fallback semantics',
          () {
        final random = Random(159);
        final alphabet = 'aAbBcCdD .+|[]éßſKıİµΜσΣςテ足球ไทย한국🎾'.runes.toList();
        String text(int length) => String.fromCharCodes(List.generate(
            length, (_) => alphabet[random.nextInt(alphabet.length)]));
        for (var batch = 0; batch < 24; batch++) {
          final terms = [
            'tennis',
            'football',
            'baseball',
            'table tennis',
            'atp',
            'espn+',
            'joao',
            'strasse',
            ...List.generate(120, (i) => 'fixture$i'),
            ...List.generate(24, (_) => text(1 + random.nextInt(8))),
          ];
          final matcher =
              SportsTitleMatcher(terms, precomputeTransitions: precompute);
          final reference =
              RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
          final titles = [
            '🎾 ATP Tennis: João',
            'テニス: fixture11',
            'ТЕННИС fixture110',
            'ฟุตบอล: fixture23',
            '한국프로야구',
            'İstanbul - Tennis',
            'ſport Kelvin',
            'µ Μ σ Σ ς',
            'ＳＴＲＡＳＳＥ',
            'Straße',
            'Joao\u0303',
            'Live.*[sport] 🎾',
            'Football\nไทย',
            for (var i = 0; i < 180; i++) text(random.nextInt(160)),
          ];
          for (final title in titles) {
            expect(matcher.matches(title), sportsTitleMatches(reference, title),
                reason: 'batch $batch / $title');
          }
        }
      });
      test('ASCII keyword sets retain exact semantics in Unicode titles', () {
        final random = Random(1590);
        const ascii = 'aAbBcCdDkKsS .+|[]';
        final native = 'éßſKıİµΜσΣςテ足球ไทย한국🎾'.runes.toList();
        for (var batch = 0; batch < 40; batch++) {
          final terms = List.generate(
              100,
              (_) => List.generate(1 + random.nextInt(8),
                  (_) => ascii[random.nextInt(ascii.length)]).join());
          final matcher =
              SportsTitleMatcher(terms, precomputeTransitions: precompute);
          final reference =
              RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
          for (var i = 0; i < 100; i++) {
            final title = String.fromCharCodes(List.generate(
                120,
                (_) => random.nextBool()
                    ? native[random.nextInt(native.length)]
                    : ascii.codeUnitAt(random.nextInt(ascii.length))));
            expect(
                matcher.matches(title), sportsTitleMatches(reference, title));
          }
        }
      });
      test('bounded text reuse survives changed keywords and eviction', () {
        final cache = SportsTitleTextCache(maxEntries: 3, maxCharacters: 100);
        final titles = [
          'テニス',
          'Football',
          'Tênis João',
          'Movie night',
          'Football changed to tennis',
          '',
          'a' * 3000,
          'ſport Kelvin'
        ];
        for (final terms in <List<String>>[
          ['tennis'],
          ['football'],
          ['missing'],
          ['joao'],
          []
        ]) {
          final matcher = SportsTitleMatcher(terms,
              textCache: cache, precomputeTransitions: precompute);
          final reference =
              RegExp(terms.map(RegExp.escape).join('|'), caseSensitive: false);
          for (final title in [...titles, ...titles.reversed]) {
            expect(
                matcher.matches(title), sportsTitleMatches(reference, title));
          }
        }
      });
    });
  }
}
