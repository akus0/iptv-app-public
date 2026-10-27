import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/library_categories.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/library_category_rail.dart';
import 'package:nox_iptv/widgets/live_category_folders.dart';
import 'package:nox_iptv/widgets/live_category_icon.dart';
import 'package:nox_iptv/widgets/live_navigation_body.dart';

void main() {
  for (final (size, width, tv) in [
    (const Size(390, 844), 180.0, false),
    (const Size(844, 390), 180.0, false),
    (const Size(960, 540), 208.0, true),
  ]) {
    testWidgets('virtual categories match natural Live TV rows at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage)..isTelevision = tv;
      await prefs.init();
      final groups = [
        for (final title in [
          'EN - ACTION',
          'EN - DRAMA',
          'EN - An unusually long category title',
          'NETFLIX MOVIES',
          'NETFLIX KIDS'
        ])
          M3uGroup(title: title, playlistId: 'one', channels: []),
      ];
      final tree = LibraryCategoryTree(groups, organise: (_) => true);
      final root = tree.roots.single;
      final rows = [
        (node: root, depth: 0),
        for (final n in root.children) (node: n, depth: 1)
      ];
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              home: Scaffold(
                  body: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    SizedBox(
                        width: width,
                        child: LibraryCategoryRail(
                            tree: tree,
                            selected: groups.first,
                            focusNode: focus,
                            names: const {},
                            onSelect: (_) {},
                            onBrowse: () {},
                            onMainMenu: () {})),
                    SizedBox(
                        width: width,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          for (final r in rows)
                            LiveCategoryBranch(
                                depth: r.depth,
                                folder: r.node.isFolder,
                                collapsed: false,
                                child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 2, vertical: 1),
                                    child: r.node.isFolder
                                        ? LiveCategoryFolderBody(
                                            label: r.node.title,
                                            count: r.node.categoryCount,
                                            open: r.depth == 0,
                                            selected: r.depth == 0,
                                            collapsed: false,
                                            focused: false)
                                        : LiveNavigationBody(
                                            label: r.node.title,
                                            leading: LiveCategoryIcon(
                                                label: r.node.title),
                                            collapsed: false,
                                            focused: false,
                                            selected:
                                                r.node.group == groups.first)))
                        ])),
                  ])))));
      await tester.pumpAndSettle();
      for (final r in rows) {
        final bodies = find.byWidgetPredicate(
            (w) => w is LiveNavigationBody && w.label == r.node.title);
        expect(bodies, findsNWidgets(2));
        expect(tester.getSize(bodies.first), tester.getSize(bodies.last),
            reason:
                '${r.node.title}: virtual row must not override Live TV size');
        final labels = find.text(r.node.title);
        expect(tester.widget<Text>(labels.first).style,
            tester.widget<Text>(labels.last).style);
        expect(
            tester.getTopLeft(labels.last).dx -
                tester.getTopLeft(labels.first).dx,
            closeTo(width, .01));
        BoxDecoration decoration(Finder body) => tester
            .widget<Container>(find
                .descendant(
                    of: body,
                    matching: find.byWidgetPredicate(
                        (w) => w is Container && w.decoration is BoxDecoration))
                .first)
            .decoration! as BoxDecoration;
        expect(decoration(bodies.first), decoration(bodies.last));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
