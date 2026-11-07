import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/compact_choice_list.dart';

void main() {
  testWidgets('row presentation is lazy and retained during focus paints',
      (tester) async {
    var builds = 0;
    var revision = 0;
    Widget app() => MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 320,
                child: CompactChoiceList(choices: [
                  for (var i = 0; i < 5000; i++)
                    CompactChoice(
                        id: '$i',
                        title: 'Row $i',
                        onTap: () {},
                        contentBuilder: (_) {
                          builds++;
                          return Text('Revision $revision / row $i');
                        })
                ]))));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(builds, lessThan(30));
    final initial = builds;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(builds, initial,
        reason: 'Focus repaint must retain content identity');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(find.text('Revision 0 / row 4999').hitTestable(), findsOneWidget);
    expect(builds, lessThan(60));
    revision++;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Revision 1 / row 4999').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'long grouped lists page and jump without retaining thousands of rows',
      (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var chosen = -1;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 500,
                height: 320,
                child: CompactChoiceList(
                    controller: scroll,
                    cacheExtent: 28,
                    showNavigation: true,
                    choices: [
                      for (var i = 0; i < 5000; i++)
                        CompactChoice(
                            id: '$i',
                            title: 'Result $i',
                            group: 'Group ${i ~/ 10}',
                            onTap: () => chosen = i)
                    ])))));
    await tester.pumpAndSettle();
    int focused() => int.parse(
        FocusManager.instance.primaryFocus!.debugLabel!.split('-').last);
    expect(focused(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(focused(), inInclusiveRange(4, 6));
    await tester.sendKeyEvent(LogicalKeyboardKey.channelDown);
    await tester.pumpAndSettle();
    expect(focused(), greaterThan(6));
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(focused(), 4999);
    expect(find.byKey(const ValueKey('4999')).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(chosen, 4999);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(focused(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('list-Next page')))
            .focusNode!
            .hasFocus,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(focused(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(focused(), greaterThan(0));
    final dynamic state = tester.state(find.byType(CompactChoiceList));
    expect(state.mountedFocusNodeCount, lessThan(30));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'paging remains bounded through rapid input and filtered replacements',
      (tester) async {
    var count = 1000;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return SizedBox(
          height: 300,
          child: CompactChoiceList(
              cacheExtent: 28,
              showNavigation: true,
              resetScrollKey: count,
              choices: [
                for (var i = 0; i < count; i++)
                  CompactChoice(id: '$i', title: 'Result $i', onTap: () {})
              ]));
    }))));
    await tester.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
    }
    update(() => count = 50);
    await tester.pumpAndSettle();
    expect(find.text('50 results'), findsOneWidget);
    update(() => count = 0);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Next page'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('page controls continue from a restored scroll position',
      (tester) async {
    final scroll = ScrollController(initialScrollOffset: 9600);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 300,
                child: CompactChoiceList(
                    controller: scroll,
                    autofocus: false,
                    showNavigation: true,
                    choices: [
                      for (var i = 0; i < 1000; i++)
                        CompactChoice(
                            id: '$i', title: 'Result $i', onTap: () {})
                    ])))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('list-Next page')));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThanOrEqualTo(9600));
    final selected = int.parse(
        FocusManager.instance.primaryFocus!.debugLabel!.split('-').last);
    expect(selected, greaterThan(200));
    expect(tester.takeException(), isNull);
  });
}
