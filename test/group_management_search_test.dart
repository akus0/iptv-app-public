import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/screens/settings/group_management_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Playlists extends PlaylistManager {
  _Playlists(StorageService storage) : super(storage, CatalogDatabase());
  final names = [
    'UK | Sports',
    'US | Sports',
    '日本 | Sports',
    for (var i = 0; i < 1000; i++) 'Category $i',
    'Last category',
  ];
  final hidden = {'UK | Sports'};
  final calls = <({
    String playlist,
    List<String> titles,
    bool hidden,
    bool load,
    String type
  })>[];
  int reads = 0;

  @override
  List<M3uGroup> get tvGroups {
    reads++;
    return [
      for (final title in names)
        M3uGroup(
            title: title,
            playlistId: 'target',
            channels: const [],
            isHidden: hidden.contains(title)),
      M3uGroup(
          title: 'Other playlist only',
          playlistId: 'other',
          channels: const []),
    ];
  }

  @override
  List<M3uGroup> groupsForPlaylist(String id, String type) =>
      tvGroups.where((g) => g.playlistId == id).toList();
  @override
  Future<void> ensureLibraryCategoriesFor(String id) async {}

  @override
  Future<void> setGroupHidden(String playlistId, String groupTitle, bool hidden,
          {bool loadImmediately = true, String type = 'tv'}) =>
      setGroupsHidden(playlistId, [groupTitle], hidden,
          loadImmediately: loadImmediately, type: type);

  @override
  Future<void> setGroupsHidden(
      String playlistId, Iterable<String> titles, bool hide,
      {bool loadImmediately = true, String type = 'tv'}) async {
    calls.add((
      playlist: playlistId,
      titles: titles.toList(),
      hidden: hide,
      load: loadImmediately,
      type: type
    ));
    for (final title in titles) {
      if (hide) {
        hidden.add(title);
      } else {
        hidden.remove(title);
      }
    }
    notifyListeners();
  }
}

void main() {
  late StorageService storage;
  late AppPreferences prefs;
  late _Playlists playlists;
  final search = find.byKey(const ValueKey('group-search'));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    prefs = AppPreferences(storage);
    await prefs.init();
    playlists = _Playlists(storage);
  });
  tearDown(() {
    playlists.dispose();
    prefs.dispose();
  });

  Future<void> open(WidgetTester tester,
      {Size size = const Size(390, 844),
      bool tv = false,
      bool defer = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    prefs.isTelevision = tv;
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlists),
        ],
        child: MaterialApp(
            home: GroupManagementScreen(
                playlistId: 'target', deferLoading: defer))));
    await tester.pumpAndSettle();
  }

  Future<void> query(WidgetTester tester, String value) async {
    await tester.enterText(search, value);
    await tester.pumpAndSettle();
  }

  for (final defer in [true, false]) {
    testWidgets('search preserves selections and loading policy defer=$defer',
        (tester) async {
      await open(tester, defer: defer);
      await query(tester, '  sPoRtS   uk ');
      expect(find.text('1 of 1004 categories'), findsOneWidget);
      expect(find.text('UK | Sports'), findsOneWidget);
      expect(find.text('US | Sports'), findsNothing);
      expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
      expect(playlists.calls, isEmpty);
      await tester.tap(find.text('UK | Sports'));
      await tester.pumpAndSettle();
      expect(playlists.calls.single.playlist, 'target');
      expect(playlists.calls.single.titles, ['UK | Sports']);
      expect(playlists.calls.single.load, !defer);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(
          tester.widget<TextField>(search).controller!.text, '  sPoRtS   uk ');
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Show All'), findsOneWidget);
      expect(playlists.hidden, isEmpty);
      await query(tester, '日本');
      expect(find.text('日本 | Sports'), findsOneWidget);
      await tester.tap(find.text('Hide matches'));
      await tester.pumpAndSettle();
      expect(playlists.calls.last.titles, ['日本 | Sports']);
      expect(playlists.calls.last.load, !defer);
      expect(playlists.hidden, {'日本 | Sports'});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('bulk actions cover all matches only and disable on no results',
      (tester) async {
    await open(tester);
    await query(tester, 'Category');
    expect(find.text('1001 of 1004 categories'), findsOneWidget);
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    await tester.tap(find.text('Hide matches'));
    await tester.pumpAndSettle();
    expect(playlists.calls.single.titles, hasLength(1001));
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Hide matches'))
            .onPressed,
        isNull);
    expect(playlists.calls.single.titles, contains('Last category'));
    expect(playlists.hidden, contains('UK | Sports'));
    expect(playlists.hidden, isNot(contains('US | Sports')));
    await tester.tap(find.text('Show matches'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Show matches'))
            .onPressed,
        isNull);
    expect(playlists.hidden, {'UK | Sports'});
    await query(tester, 'Other playlist only');
    expect(find.text('No categories match your search.'), findsOneWidget);
    for (final button
        in tester.widgetList<OutlinedButton>(find.byType(OutlinedButton))) {
      expect(button.onPressed, isNull);
    }
    expect(
        playlists.calls
            .every((call) => call.playlist == 'target' && !call.load),
        isTrue);
    final calls = playlists.calls.length;
    await tester.tap(find.widgetWithText(TextButton, 'Clear search'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    expect(playlists.calls.length, calls);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing stays local, resets scrolling and survives tab changes',
      (tester) async {
    await open(tester);
    final list = tester.widget<ListView>(find.byType(ListView));
    list.controller!.jumpTo(20000);
    await tester.pumpAndSettle();
    // Focusing updates shortcuts, but must not rebuild or re-read the playlist.
    final reads = playlists.reads;
    await query(tester, 'Last');
    expect(playlists.reads, reads);
    expect(find.text('Last category').hitTestable(), findsOneWidget);
    expect(list.controller!.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.text('Movies').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live TV'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, 'Last');
    expect(find.text('Last category'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('phone search fits with keyboard at $size', (tester) async {
      await open(tester, size: size);
      await query(tester, 'UK');
      final inset = size.width > size.height ? 180.0 : 280.0;
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      expect(search.hitTestable(), findsOneWidget);
      expect(find.text('UK | Sports').hitTestable(), findsOneWidget);
      expect(tester.getRect(search).bottom, lessThan(size.height - inset));
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('Hide matches').hitTestable(), findsOneWidget);
    });
  }

  testWidgets('library tabs save their own scope without downloading titles',
      (tester) async {
    await open(tester, defer: false);
    for (final entry in [('Movies', 'vod'), ('Series', 'series')]) {
      await tester.tap(find.text(entry.$1).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('UK | Sports').first);
      await tester.pumpAndSettle();
      expect(playlists.calls.last.type, entry.$2);
      expect(playlists.calls.last.load, isFalse);
    }
    expect(
        find.byKey(const ValueKey('group-done')).hitTestable(), findsOneWidget);
    expect(find.text('Confirm'), findsNothing);
  });
  testWidgets('remote can reach Done directly from the last category',
      (tester) async {
    await open(tester, tv: true, size: const Size(1280, 720));
    tester.widget<TextField>(search).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await query(tester, 'Last');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    Focus.of(tester.element(find.text('Last category'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'group-mgmt-done');
    expect(
        find.byKey(const ValueKey('group-done')).hitTestable(), findsOneWidget);
  });

  testWidgets('TV search opens on Select and permits remote traversal',
      (tester) async {
    await open(tester, size: const Size(1280, 720), tv: true);
    final field = tester.widget<TextField>(search);
    field.focusNode!.requestFocus();
    await tester.pump();
    expect(tester.widget<TextField>(search).readOnly, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tester.widget<TextField>(search).readOnly, isFalse);
    await query(tester, 'Sports');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(field.focusNode!.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(playlists.calls.single.titles,
        ['UK | Sports', 'US | Sports', '日本 | Sports']);
    expect(tester.takeException(), isNull);
  });
}
