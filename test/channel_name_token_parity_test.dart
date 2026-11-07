import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/channel_name_matching.dart';

Set<String> previousTokens(String name) {
  var best = -1, length = 0;
  for (final separator in ['|', ':', ' - ']) {
    final index = name.indexOf(separator);
    if (index > 0 && (best == -1 || index < best)) {
      best = index;
      length = separator.length;
    }
  }
  final text = best < 0 ? name : name.substring(best + length);
  return text
      .toUpperCase()
      .replaceAll(RegExp(r'[^\w+]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) =>
          t.isNotEmpty &&
          !{'HD', 'HEVC', 'UHD', 'FHD', 'SD', 'HDR', 'H265', 'H264', 'RAW'}
              .contains(t))
      .toSet();
}

void main() {
  test('channel tokenization preserves region, quality, plus and Unicode rules',
      () {
    final random = Random(203);
    final names = <String>[
      '',
      'HD UHD',
      '|ESPN+',
      'AU | ESPN HD',
      'US: CBS New York',
      'Sports - Sky+ H265',
      'A_B + HD+',
      'straße ß ſ İ ı 日本 한국 ᴴᴰ',
      '🇦🇺 Sports ４Ｋ',
      'x: y|z',
      'A\u0000B',
      for (var i = 0; i < 65536; i++) 'A${String.fromCharCode(i)}B',
      for (var i = 0; i < 3000; i++)
        String.fromCharCodes(
            List.generate(random.nextInt(80), (_) => random.nextInt(0x110000))),
    ];
    for (final name in names) {
      final expected = previousTokens(name);
      expect(normalizedChannelTokens(name), expected);
      final sorted = expected.toList()..sort();
      expect(canonicalChannelKey(name), sorted.join('\u0000'));
    }
    expect(channelNamesMatch('ESPN', 'ESPN+'), isFalse);
    expect(channelNamesMatch('CBS New York', 'CBS Boston'), isFalse);
  });
}
