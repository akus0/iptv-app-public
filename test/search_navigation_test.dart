import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/screens/search_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/poster_card.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

class _Playlist extends PlaylistManager {
  _Playlist(StorageService storage) : super(storage, CatalogDatabase());
  List<Channel> items = List.generate(
      10000,
      (i) => Channel(
            id: 'demo::c$i',
            rawId: 'c$i',
            playlistId: 'demo',
            name: 'Channel $i',
            group: 'Live',
            url: 'https://example.invalid/live',
          ));
  List<Channel> movies = [];
  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      category == 'tv'
          ? items
          : category == 'vod'
              ? movies
              : const [];
  @override
  Future<void> ensureLiveChannelsLoaded() async {}
}

void main() {
  testWidgets(
      'large search retains focused result and scroll during catalogue updates',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            home: const SearchScreen(initialScope: 'TV'))));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Channel');
    await tester.pump();
    final horizontal = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal);
    await tester.drag(horizontal, const Offset(-650, 0));
    await tester.pumpAndSettle();
    final cards = find.byType(PosterCard);
    final visible = cards.evaluate().firstWhere((e) {
      final r = tester.getRect(find.byWidget(e.widget));
      return r.left > 20 && r.right < 950;
    });
    final key = visible.widget.key!;
    final ink =
        find.descendant(of: find.byKey(key), matching: find.byType(InkWell));
    final node = tester.widget<InkWell>(ink).focusNode!;
    node.requestFocus();
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(key));
    final state = tester.state(find.byKey(key));
    playlist.notifyLibraryChanged();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue,
        reason:
            'An unrelated catalogue notification must not replace the focused row');
    expect(tester.state(find.byKey(key)), same(state));
    expect(tester.getRect(find.byKey(key)), rect);
    // A real live-catalogue change must update results and respect visibility.
    playlist.items =
        playlist.items.where((c) => c.name != 'Channel 9999').toList();
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    // Returning to a horizontally scrolled row must mount its recycled first
    // card before requesting focus, without losing the next remote command.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search-live-first');
    expect(tester.getRect(find.byKey(const ValueKey('Live TV_demo::c0'))).left,
        greaterThanOrEqualTo(0));
    tester.widget<TextField>(find.byType(TextField)).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Channel 9999');
    await tester.pumpAndSettle();
    expect(find.byType(PosterCard), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpWidget(const SizedBox());
    playlist.dispose();
    prefs.dispose();
    expect(tester.takeException(), isNull);
  });
  testWidgets('late result rows preserve focus and remote row order',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage);
    final live = playlist.items.first;
    playlist.items = [];
    playlist.movies = [
      Channel(
          id: 'demo::xt_vod_1',
          rawId: 'xt_vod_1',
          playlistId: 'demo',
          name: 'Channel movie',
          group: 'Movies',
          url: 'https://example.invalid/movie')
    ];
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            home: const SearchScreen(initialScope: 'TV'))));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Channel');
    await tester.pumpAndSettle();
    final node = tester.widget<PosterCard>(find.byType(PosterCard)).focusNode!;
    node.requestFocus();
    await tester.pumpAndSettle();
    playlist.items = [live];
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search-live-first');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    playlist.items = [];
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue);
    await tester.pumpWidget(const SizedBox());
    playlist.dispose();
    prefs.dispose();
    expect(tester.takeException(), isNull);
  });
}
