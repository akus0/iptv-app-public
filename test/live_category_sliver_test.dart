import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/live_category_folders.dart';

void main() {
  testWidgets('Lazy categories keep a distant selection reachable and visible',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await storage.setLiveCategoryFolders(false);
    final groups = List.generate(
        1000,
        (i) =>
            M3uGroup(title: 'Category $i', playlistId: 'demo', channels: []));
    final nodes = {for (final g in groups) g.title: FocusNode()};
    addTearDown(() {
      for (final n in nodes.values) {
        n.dispose();
      }
    });
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
          width: 210,
          height: 400,
          child: CustomScrollView(
            key: const ValueKey('viewport'),
            controller: scroll,
            slivers: [
              LiveCategoryFolders(
                sliver: true,
                groups: groups,
                storage: storage,
                selectedKey: 'demo::Category 980',
                playlistName: (_) => 'Demo',
                rowBuilder: (g, label) => Builder(
                    builder: (context) => SizedBox(
                          height: int.parse(g.title.split(' ').last).isEven
                              ? 48
                              : 72,
                          child: TextButton(
                              focusNode: nodes[g.title],
                              onPressed: () {},
                              onFocusChange: (focused) {
                                if (focused) {
                                  Scrollable.ensureVisible(context,
                                      alignmentPolicy:
                                          ScrollPositionAlignmentPolicy
                                              .keepVisibleAtEnd);
                                }
                              },
                              child: Text(label ?? g.title)),
                        )),
              )
            ],
          )),
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(TextButton).evaluate().length, lessThan(30));
    expect(nodes['Category 980']!.context, isNotNull);
    nodes['Category 980']!.requestFocus();
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byKey(const ValueKey('viewport')));
    expect(nodes['Category 980']!.hasPrimaryFocus, isTrue);
    expect(nodes['Category 980']!.rect.top, greaterThanOrEqualTo(bounds.top));
    expect(
        nodes['Category 980']!.rect.bottom, lessThanOrEqualTo(bounds.bottom));
    expect(find.byType(TextButton).evaluate().length, lessThan(30));
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus!;
      expect(focus.rect.top, greaterThanOrEqualTo(bounds.top));
      expect(focus.rect.bottom, lessThanOrEqualTo(bounds.bottom));
      expect(scroll.position.isScrollingNotifier.value, isFalse);
    }
    expect(nodes['Category 968']!.hasPrimaryFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
