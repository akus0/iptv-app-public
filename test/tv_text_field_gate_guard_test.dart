import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Require TvTextFieldGate around TV text fields so keyboard activation cannot trap remote
/// navigation. An intentional exception needs a nearby tv-text-field-gate: exempt comment
/// explaining why.
void main() {
  test('every TextField is gated (or explicitly exempt)', () {
    final offenders = <String>[];
    final field = RegExp(r'\b(TextField|TextFormField)\(');
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path
          .replaceAll('\\', '/')
          .endsWith('widgets/tv_text_field_gate.dart')) {
        continue;
      }
      final src = f.readAsStringSync();
      final fields = field.allMatches(src).length;
      if (fields == 0) continue;
      final gates = 'TvTextFieldGate('.allMatches(src).length;
      final exempt = 'tv-text-field-gate: exempt'.allMatches(src).length;
      if (fields > gates + exempt) {
        offenders.add('${f.path}: $fields field(s), $gates gated, '
            '$exempt exempt');
      }
    }
    expect(offenders, isEmpty,
        reason: 'Wrap these in TvTextFieldGate (lib/widgets/'
            'tv_text_field_gate.dart; FocusNodeOwner for dialogs), or add '
            'a "tv-text-field-gate: exempt — why" comment.');
  });
}
