import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/live_category_folders.dart';
import 'package:nox_iptv/widgets/live_category_icon.dart';
import 'package:nox_iptv/widgets/vertical_rail_focus.dart';

void main() {
  test('Display label preserves supplementary non-Latin characters', () {
    expect(LiveCategoryIcon.displayLabel('𠀀 channels'), '𠀀 channels');
    expect(LiveCategoryIcon.displayLabel('  🏟️ College Football'),
        'College Football');
    expect(LiveCategoryIcon.displayLabel('🏟️'), '🏟️');
  });

  for (final sliver in [false, true]) {
    testWidgets('Flat categories show provider pictograms once, sliver=$sliver',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      await storage.setLiveCategoryFolders(false);
      final groups = [
        '🇺🇸 TV Guide (USA)',
        '🏟️ College Football',
        '日本のテレビ',
        '한국 스포츠'
      ]
          .map((title) =>
              M3uGroup(title: title, playlistId: 'demo', channels: []))
          .toList();
      final folders = LiveCategoryFolders(
          groups: groups,
          storage: storage,
          selectedKey: null,
          sliver: sliver,
          playlistName: (_) => 'Demo',
          rowBuilder: (group, label) => Row(children: [
                LiveCategoryIcon(label: group.title),
                Text(label ?? group.title),
              ]));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: sliver
                  ? CustomScrollView(slivers: [folders])
                  : SingleChildScrollView(child: folders))));
      expect(find.text('🇺🇸'), findsOneWidget);
      expect(find.text('🏟️'), findsOneWidget);
      expect(find.text('TV Guide (USA)'), findsOneWidget);
      expect(find.text('College Football'), findsOneWidget);
      expect(find.text('日本のテレビ'), findsOneWidget);
      expect(find.text('한국 스포츠'), findsOneWidget);
      expect(groups.first.title, '🇺🇸 TV Guide (USA)');
      expect(tester.takeException(), isNull);
    });
  }

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
            body: FocusTraversalGroup(
                policy: VerticalRailTraversalPolicy(),
                child: Align(
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
                                      height: int.parse(g.title.split(' ').last)
                                              .isEven
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
                )))));
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
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    nodes['Category 0']!.requestFocus();
    await tester.pumpAndSettle();
    for (var i = 1; i <= 60; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 60));
      expect(nodes['Category $i']!.hasPrimaryFocus, isTrue,
          reason:
              'Down must visit every row in order, at index $i; focused ${nodes.entries.where((e) => e.value.hasPrimaryFocus).map((e) => e.key)}.');
    }
    for (var i = 59; i >= 0; i--) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 60));
      expect(nodes['Category $i']!.hasPrimaryFocus, isTrue,
          reason: 'Up must retrace the same rows, at index $i.');
    }

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
