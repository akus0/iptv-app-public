import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/vertical_rail_focus.dart';

class _MeasuredFocus extends FocusNode {
  int reads = 0;
  @override
  Rect get rect {
    reads++;
    return super.rect;
  }
}

void main() {
  testWidgets(
      'large rail reads each position once and reveals without animation',
      (tester) async {
    final nodes = List.generate(250, (_) => _MeasuredFocus());
    final scroll = ScrollController();
    final policy = VerticalRailTraversalPolicy();
    await tester.pumpWidget(MaterialApp(
        home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
                width: 220,
                height: 180,
                child: FocusTraversalGroup(
                    policy: policy,
                    child: FocusScope(
                        child: ListView(controller: scroll, children: [
                      Column(children: [
                        for (var i = 0; i < nodes.length; i++)
                          Focus(
                              focusNode: nodes[i],
                              child: SizedBox(
                                  height: 40,
                                  width: 200,
                                  child: Text('Category $i'))),
                      ])
                    ])))))));
    nodes.first.requestFocus();
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      for (final node in nodes) {
        node.reads = 0;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(nodes[i]));
      expect(nodes.every((n) => n.reads <= 1), isTrue,
          reason: 'Position transforms must not repeat inside a sort');
      expect(scroll.position.isScrollingNotifier.value, isFalse);
      if (i < 4) expect(scroll.offset, 0);
      expect(nodes[i].rect.bottom, lessThanOrEqualTo(180));
    }
    for (var i = 11; i >= 0; i--) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(nodes[i]));
      expect(nodes[i].rect.top, greaterThanOrEqualTo(0));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(nodes.first));
    await tester.pumpWidget(const SizedBox());
    for (final node in nodes) {
      node.dispose();
    }
    scroll.dispose();
  });

  testWidgets('rail follows reordered rows and skips disabled or removed rows',
      (tester) async {
    final nodes = List.generate(5, (_) => FocusNode());
    nodes[1].canRequestFocus = false;
    final policy = VerticalRailTraversalPolicy();
    Future<void> show(List<int> order) async {
      await tester.pumpWidget(MaterialApp(
          home: FocusTraversalGroup(
              policy: policy,
              child: FocusScope(
                  child: Column(children: [
                for (final i in order)
                  Focus(
                      key: ValueKey(i),
                      focusNode: nodes[i],
                      child: SizedBox(height: 40, child: Text('Row $i')))
              ])))));
      await tester.pump();
    }

    Future<void> down(int expected) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(nodes[expected]));
    }

    await show([0, 1, 2, 3, 4]);
    nodes[0].requestFocus();
    await tester.pump();
    await down(2);
    await show([0, 1, 2, 4, 3]);
    await down(4);
    await show([0, 1, 2, 4]);
    await down(4);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(nodes[2]));
    await tester.pumpWidget(const SizedBox());
    for (final node in nodes) {
      node.dispose();
    }
  });
}
