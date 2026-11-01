import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/sports_language.dart';

void main() {
  String asciiReference(String text) {
    final words = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9+]+'))
        .where((word) => word.isNotEmpty)
        .join(' ');
    return words.isEmpty ? ' ' : ' $words ';
  }

  test('every ASCII byte preserves padding and separator collapse', () {
    expect(normalizeSportsName(''), ' ');
    for (var first = 0; first < 128; first++) {
      for (var second = 0; second < 128; second++) {
        final pair = String.fromCharCodes([first, second]);
        for (final text in [pair, 'ESPN+$pair', '${pair}HD', 'A${pair}B']) {
          expect(normalizeSportsName(text), asciiReference(text),
              reason: 'bytes $first, $second');
        }
      }
    }
  });

  test('random ASCII labels preserve whole-string normalization', () {
    final random = Random(161);
    for (var i = 0; i < 4000; i++) {
      final text = String.fromCharCodes(
          List.generate(random.nextInt(2050), (_) => random.nextInt(128)));
      expect(normalizeSportsName(text), asciiReference(text));
    }
  });

  test('buffer boundaries and long input retain identical padding', () {
    for (final length in [1, 2047, 2048, 2049, 8192]) {
      for (final text in ['A' * length, '+' * length, '.' * length]) {
        expect(normalizeSportsName(text), asciiReference(text));
      }
      final text = '${'A' * (length - 1)}É';
      expect(normalizeSportsName(text), ' ${'a' * (length - 1)}e ');
    }
  });

  test('Unicode anywhere in a label keeps original folding and script', () {
    const cases = {
      'João': 'joao',
      'Se\u0301bastien': 'sebastien',
      'ＡＴＰ １２': 'atp 12',
      'Straße': 'strasse',
      'ТЕННИС': 'теннис',
      'テニス': 'テニス',
      '한국': '한국',
      'กุลวุฒิ': 'กุลวุฒิ',
      '🎾': '',
      '\uD800': '',
      '\uDC00': '',
    };
    for (final entry in cases.entries) {
      expect(normalizeSportsName(entry.key),
          entry.value.isEmpty ? ' ' : ' ${entry.value} ');
      for (final text in [
        '${entry.key} ESPN+',
        'ESPN+ ${entry.key}',
        'Live: ${entry.key} | ESPN+',
      ]) {
        expect(normalizeSportsName(text),
            normalizeSportsName(text.replaceFirst(entry.key, entry.value)));
      }
    }
  });
}
