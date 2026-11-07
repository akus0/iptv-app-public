import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/live_category_folders.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/live_category_folders.dart';
import 'package:nox_iptv/widgets/live_category_icon.dart';
import 'package:nox_iptv/widgets/live_navigation_body.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (fonts.isEmpty) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
      if (File('$fonts/NotoColorEmoji.ttf').existsSync())
        'NotoColorEmoji': 'NotoColorEmoji.ttf'
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(File('$fonts/${entry.value}')
            .readAsBytes()
            .then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final (size, width, tv) in [
    (const Size(390, 844), 390.0, false),
    (const Size(844, 390), 180.0, false),
    (const Size(960, 540), 208.0, true),
  ]) {
    testWidgets('category hierarchy and browsing fit $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage)..isTelevision = tv;
      await prefs.init();
      await storage.setOpenLiveCategoryFolders({'epg/Sports'});
      final titles = (jsonDecode(
              File('test/fixtures/curated_category_titles.json')
                  .readAsStringSync()) as List)
          .cast<String>();
      final groups = [
        for (final t in titles)
          M3uGroup(title: t, playlistId: 'epg', channels: [])
      ];
      String? picked;
      final capture = GlobalKey();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette).copyWith(
                  textTheme: buildAppTheme(prefs.palette)
                      .textTheme
                      .apply(fontFamilyFallback: const ['NotoColorEmoji'])),
              home: Scaffold(
                  body: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                          width: width,
                          child: RepaintBoundary(
                              key: capture,
                              child: ColoredBox(
                                  color: buildAppTheme(prefs.palette)
                                      .scaffoldBackgroundColor,
                                  child:
                                      ListView(controller: scroll, children: [
                                    LiveCategoryFolders(
                                        groups: groups,
                                        storage: storage,
                                        selectedKey: null,
                                        playlistName: (_) => 'Playlist',
                                        rowBuilder: (g, label) => Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 2, vertical: 1),
                                            child: InkWell(
                                                onTap: () => picked = g.title,
                                                child: LiveNavigationBody(
                                                    label: label ?? g.title,
                                                    leading: LiveCategoryIcon(
                                                        label:
                                                            g is LiveCategoryCollection
                                                                ? g.sources
                                                                    .first.title
                                                                : g.title),
                                                    collapsed: false,
                                                    focused: false,
                                                    selected: false))))
                                  ])))))))));
      await tester.pumpAndSettle();
      final root = tester.widget<Text>(find.text('Sports'));
      final child = tester.widget<Text>(find.text('Formula 1'));
      expect(child.style!.fontSize, lessThan(root.style!.fontSize!));
      expect(tester.getTopLeft(find.text('Formula 1')).dx,
          greaterThan(tester.getTopLeft(find.text('Sports')).dx));
      await tester.ensureVisible(find.text('Formula 1'));
      await tester.tap(find.text('Formula 1'));
      expect(picked, '__live_collection__:Formula 1');
      expect(tester.takeException(), isNull);
      Future<void> captureImage(String name) async {
        if (!const bool.fromEnvironment('CAPTURE_LAYOUT')) return;
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/iptv-category-$name-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      scroll.jumpTo(0);
      await captureImage('sports');
      await tester.ensureVisible(find.text('Sports'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sports'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Entertainment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entertainment'));
      await tester.pumpAndSettle();
      expect(find.text('TV channels'), findsNothing);
      expect(find.text('Entertainment channels'), findsOneWidget);
      await Scrollable.ensureVisible(tester.element(find.text('Entertainment')),
          alignment: 0);
      await tester.pumpAndSettle();
      await captureImage('entertainment');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
