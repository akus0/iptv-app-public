import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/tv_menu_tile.dart';

/// A picker sheet with more entries than fit (a 12-language movie's audio
/// tracks): the autofocused entry and every D-pad step stay on screen.
void main() {
  Widget sheet(int selected) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 400),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < 12; i++)
                    TvMenuTile(
                      key: ValueKey(i),
                      autofocus: i == selected,
                      icon: Icons.audiotrack,
                      title: 'Track $i',
                      onTap: () {},
                    ),
                ]),
              ),
            ),
          ),
        ),
      );

  bool onScreen(WidgetTester tester, int i) {
    final box = tester.getRect(find.byKey(ValueKey(i)));
    final view = tester.getRect(find.byType(SingleChildScrollView));
    return box.top >= view.top - 0.5 && box.bottom <= view.bottom + 0.5;
  }

  testWidgets('autofocused entry far down is scrolled into view',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(sheet(10));
    await tester.pumpAndSettle();
    expect(onScreen(tester, 10), isTrue);
  });

  testWidgets('D-pad Down reaches the last entry, Up the first',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(sheet(0));
    await tester.pumpAndSettle();
    expect(onScreen(tester, 11), isFalse);
    for (var i = 0; i < 11; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(onScreen(tester, 11), isTrue);
    for (var i = 0; i < 11; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }
    expect(onScreen(tester, 0), isTrue);
  });
}
