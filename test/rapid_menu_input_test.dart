import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nox_iptv/utils/guarded_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/tv_menu_tile.dart';

void main() {
  testWidgets(
      'dialog bursts are bounded, nested choices work and exit is guarded',
      (tester) async {
    late BuildContext origin;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      origin = context;
      return const Scaffold(body: Text('Origin'));
    })));
    Future<int?> open() => showGuardedDialog<int>(
        context: origin,
        builder: (dialog) => AlertDialog(title: const Text('Outer'), actions: [
              TextButton(
                  onPressed: () => showGuardedDialog<int>(
                      context: dialog,
                      builder: (inner) =>
                          AlertDialog(title: const Text('Inner'), actions: [
                            TextButton(
                                onPressed: () => popRouteIfCurrent(inner, 7),
                                child: const Text('Choose'))
                          ])),
                  child: const Text('Nested'))
            ]));
    final result = open();
    for (var i = 0; i < 20; i++) {
      unawaited(open());
    }
    await tester.pumpAndSettle();
    expect(find.text('Outer', skipOffstage: false), findsOneWidget);
    await tester.tap(find.text('Nested'));
    await tester.pumpAndSettle();
    expect(find.text('Inner'), findsOneWidget);
    final choose = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Choose'))
        .onPressed!;
    for (var i = 0; i < 20; i++) {
      choose();
    }
    await tester.pumpAndSettle();
    expect(find.text('Outer'), findsOneWidget);
    Navigator.of(origin).pop(42);
    unawaited(open());
    await tester.pumpAndSettle();
    expect(await result, 42);
    expect(find.text('Outer', skipOffstage: false), findsNothing);
    final again = open();
    await tester.pumpAndSettle();
    expect(find.text('Outer'), findsOneWidget);
    Navigator.of(origin).pop();
    await tester.pumpAndSettle();
    await again;
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid menu activation opens one page and closes one page',
      (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: Builder(
            builder: (context) => Scaffold(
                body: TvMenuTile(
                    icon: Icons.settings,
                    title: 'Open',
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (context) => Scaffold(
                                body: TvMenuTile(
                                    icon: Icons.close,
                                    title: 'Close',
                                    onTap: () =>
                                        Navigator.of(context).pop())))))))));
    final open = tester.widget<ListTile>(find.byType(ListTile)).onTap!;
    for (var i = 0; i < 20; i++) {
      open();
    }
    await tester.pumpAndSettle();
    expect(find.text('Close', skipOffstage: false), findsOneWidget);
    final close = tester.widget<ListTile>(find.byType(ListTile)).onTap!;
    for (var i = 0; i < 20; i++) {
      close();
    }
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(nav.currentState!.canPop(), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holding OK does not repeatedly activate a menu setting',
      (tester) async {
    var activations = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TvMenuTile(
                icon: Icons.tune,
                title: 'Setting',
                autofocus: true,
                onTap: () {
                  activations++;
                }))));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    for (var i = 0; i < 30; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(activations, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activations, 2);
  });
}
