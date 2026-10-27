import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/sports_programme_excerpt.dart';

void main() {
  test('literal, whole-word emphasis never upgrades broad or generic terms',
      () {
    final highlighter = SportsProgrammeHighlighter(
        ['tennis', 'ATP', 'ladies', 'live', 'A+B', 'Ruud'],
        names: ['Casper Ruud']);
    final result = highlighter.excerpt(
        'Live ladies tennis: Casper Ruud at ATP. Not Ruudson or ATPCup. A+B.');
    expect([
      for (final m in result.emphasis) result.text.substring(m.start, m.end)
    ], [
      'tennis',
      'Casper Ruud',
      'ATP',
      'A+B'
    ]);
  });
  test('excerpt prioritises named participants beyond generic introduction',
      () {
    final highlighter =
        SportsProgrammeHighlighter(['tennis'], names: ['Casper Ruud']);
    final description = 'Tennis coverage. ${'Studio introduction. ' * 40}'
        'Casper Ruud faces Yunchaokete Bu on centre court. ${'More coverage. ' * 40}';
    final result = highlighter.excerpt(description);
    expect(result.text, contains('Casper Ruud faces Yunchaokete Bu'));
    expect(result.text, startsWith('… '));
    expect(result.text.length, lessThanOrEqualTo(324));
    expect(identical(result, highlighter.excerpt(description)), isTrue);
  });
  test('unicode boundaries avoid substrings in names', () {
    final h = SportsProgrammeHighlighter(['São Paulo', 'Ruud']);
    final result = h.excerpt('São Paulo vs Santos. Ruudé and Ruud.');
    expect([
      for (final m in result.emphasis) result.text.substring(m.start, m.end)
    ], [
      'São Paulo',
      'Ruud'
    ]);
  });
  test('cache, description processing and generated spans are bounded', () {
    final h = SportsProgrammeHighlighter(['tennis']);
    final first = h.excerpt('first');
    for (var i = 0; i < 1000; i++) {
      final result = h.excerpt('$i ${'tennis ' * 1000}');
      expect(result.text.length, lessThanOrEqualTo(324));
      expect(result.emphasis.length, lessThanOrEqualTo(24));
    }
    expect(identical(first, h.excerpt('first')), isFalse);
    expect(h.excerpt('').text, isEmpty);
  });
}
