import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/tv_text_field_gate.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The D-pad must be able to leave a gated text field that has a cursor
/// (typed in once): Flutter's own arrow handling moved the cursor instead
/// and kept the remote on the field ("stuck in the text field").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FocusNode above, field, below;
  late TextEditingController controller;

  Future<void> pump(WidgetTester tester, {required bool tv}) async {
    above = FocusNode(debugLabel: 'above');
    field = FocusNode(debugLabel: 'field');
    below = FocusNode(debugLabel: 'below');
    controller = TextEditingController();
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage)..isTelevision = tv;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: prefs,
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            TextButton(
                focusNode: above, onPressed: () {}, child: const Text('A')),
            TvTextFieldGate(
              focusNode: field,
              builder: (context, readOnly) => TextField(
                  controller: controller, focusNode: field, readOnly: readOnly),
            ),
            TextButton(
                focusNode: below, onPressed: () {}, child: const Text('B')),
          ]),
        ),
      ),
    ));
    // A field that was typed in: text and a cursor.
    controller.value = const TextEditingValue(
        text: 'nba', selection: TextSelection.collapsed(offset: 3));
    field.requestFocus();
    await tester.pumpAndSettle();
  }

  testWidgets('TV: Down leaves a typed-in field', (tester) async {
    await pump(tester, tv: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(below.hasFocus, isTrue);
  });

  testWidgets('TV: Up leaves a typed-in field', (tester) async {
    await pump(tester, tv: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(above.hasFocus, isTrue);
    expect(controller.text, 'nba');
  });

  testWidgets('TV: reported keyboard dismissal restores Down navigation',
      (tester) async {
    await pump(tester, tv: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'tennis');
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pump();
    tester.testTextInput.hide();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(field.hasFocus, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(below.hasFocus, true);
    expect(controller.text, 'tennis');
  });

  testWidgets('TV: overlay keyboard retains arrows and held cursor editing',
      (tester) async {
    await pump(tester, tv: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(TvTextFieldGate.isEditing(field), true);
    expect(tester.view.viewInsets.bottom, 0);
    const activator = TvNavigationActivator(LogicalKeyboardKey.arrowLeft);
    expect(
        activator.accepts(
            const KeyDownEvent(
                physicalKey: PhysicalKeyboardKey.arrowLeft,
                logicalKey: LogicalKeyboardKey.arrowLeft,
                timeStamp: Duration.zero),
            HardwareKeyboard.instance),
        false);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(field.hasFocus, true);
    expect(controller.selection.baseOffset, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(field.hasFocus, true);
    expect(TvTextFieldGate.isEditing(field), true);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(TvTextFieldGate.isEditing(field), false);
    expect(find.byType(TextField), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(below.hasFocus, true);
  });

  testWidgets(
      'TV: inactive keyboard window preserves editing; background clears it',
      (tester) async {
    await pump(tester, tv: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(TvTextFieldGate.isEditing(field), true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(TvTextFieldGate.isEditing(field), false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(below.hasFocus, true);
  });

  testWidgets("TV: a screen's own key handler keeps the last word",
      (tester) async {
    await pump(tester, tv: true);
    // Like Add Playlist's _handleFieldEscapeKey: Down goes to a field of its
    // choosing (here, deliberately not the one below).
    bool handler(KeyEvent e) {
      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowDown) {
        above.requestFocus();
        return true;
      }
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(handler));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(above.hasFocus, isTrue);
  });

  testWidgets('phone: arrows still move the cursor', (tester) async {
    await pump(tester, tv: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(field.hasFocus, isTrue);
    expect(controller.selection.baseOffset, 0);
  });
}
