import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/scroll_safety.dart';

void main() {
  testWidgets(
      'attached but unmeasured scroll waits for layout and clamps jumps',
      (tester) async {
    late ScrollController controller;
    var skipped = false;
    controller = ScrollController(
        initialScrollOffset: 160,
        onAttach: (_) {
          skipped = !jumpToIfLaidOut(controller, 0);
        });
    addTearDown(controller.dispose);
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(
            controller: controller,
            physics: const ClampingScrollPhysics(),
            child: const SizedBox(height: 2000))));
    expect(skipped, isTrue);
    expect(jumpToIfLaidOut(controller, 0), isTrue);
    expect(controller.offset, 0);
    expect(jumpToIfLaidOut(controller, 10000), isTrue);
    expect(controller.offset, controller.position.maxScrollExtent);
    expect(jumpToIfLaidOut(controller, -10), isTrue);
    expect(controller.offset, 0);
    await tester.pumpWidget(const SizedBox());
    expect(jumpToIfLaidOut(controller, 0), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an accidentally shared controller cannot read an ambiguous offset',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Row(children: [
          for (var i = 0; i < 2; i++)
            Expanded(
                child: SingleChildScrollView(
                    controller: controller,
                    child: const SizedBox(height: 2000))),
        ])));
    expect(laidOutScrollPosition(controller), isNull);
    expect(jumpToIfLaidOut(controller, 100), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
