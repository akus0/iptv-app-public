import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/screens/settings/add_playlist_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

class FailingPlaylists extends PlaylistManager {
  FailingPlaylists(StorageService storage) : super(storage, CatalogDatabase());
  int adds = 0, removes = 0;
  String? failure;
  bool failStorage = false, reject = true;
  Completer<void>? pending;
  @override
  String? get error => failure;
  @override
  Future<void> addPlaylist(PlaylistProfile profile) async {
    adds++;
    if (failStorage) throw StateError('Synthetic storage failure');
  }

  @override
  Future<void> loadPlaylist(String id) async {
    await pending?.future;
    failure = reject ? 'Provider rejected the account' : null;
  }

  @override
  Future<void> removePlaylist(String id) async {
    removes++;
    failure = null;
  }
}

void main() {
  for (final (mode, leave) in [
    for (final mode in ['M3U URL', 'Xtream Codes', 'Stalker / MAC'])
      for (final leave in [false, true]) (mode, leave)
  ]) {
    testWidgets(
        '$mode rejection, repeated save and retry are safe; leave=$leave',
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
      final manager = FailingPlaylists(storage);
      final guide = EpgService(storage);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: manager),
            ChangeNotifierProvider<EpgService>.value(value: guide)
          ],
          child: MaterialApp(
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const AddPlaylistScreen())),
                          child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final source = mode == 'Stalker / MAC'
          ? find.byKey(const ValueKey('playlist-mode-stalker'))
          : find.text(mode);
      await tester.ensureVisible(source);
      await tester.tap(source);
      await tester.pumpAndSettle();
      Future<void> enter(Finder f, String value) async {
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        tester.widget<TextField>(f).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        await tester.enterText(f, value);
        await tester.pump();
      }

      Finder field(String label) => find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label);
      await enter(field('Name'), 'Fixture playlist');
      final nameController =
          tester.widget<TextField>(field('Name')).controller!;
      if (mode == 'M3U URL') {
        await enter(field('M3U Playlist URL'), 'https://example.test/list');
      } else if (mode == 'Xtream Codes') {
        await enter(field('Server URL (e.g. http://host:port)'),
            'https://example.test');
        await enter(field('Username'), 'fixture');
        await enter(field('Password'), 'fixture');
      } else {
        await enter(
            find.byKey(const ValueKey('portalUrl')), 'https://example.test/c/');
        await enter(
            find.byKey(const ValueKey('portalMac')), '00:1a:79:12:34:56');
      }
      final save = find.byKey(const ValueKey('playlist-save'));
      await tester.ensureVisible(save);
      tester.widget<FilledButton>(save).focusNode!.requestFocus();
      await tester.pump();
      manager.pending = Completer<void>();
      final callback = tester.widget<FilledButton>(save).onPressed!;
      for (var i = 0; i < 30; i++) {
        callback();
      }
      await tester.pump();
      expect(manager.adds, 1);
      if (leave) {
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      manager.pending!.complete();
      await tester.pumpAndSettle();
      expect(manager.removes, 1);
      expect(manager.error, isNull);
      if (leave) {
        expect(find.text('Open'), findsOneWidget);
        expect(tester.takeException(), isNull);
        return;
      }
      expect(
          find.textContaining('Provider rejected the account'), findsOneWidget);
      expect(tester.widget<FilledButton>(save).focusNode!.hasFocus, isTrue);
      expect(nameController.text, 'Fixture playlist');
      manager.pending = Completer<void>();
      tester.widget<FilledButton>(save).onPressed!();
      await tester.pump();
      final moved =
          tester.widget<TextField>(find.byType(TextField).last).focusNode!;
      moved.requestFocus();
      await tester.pump();
      manager.pending!.complete();
      await tester.pumpAndSettle();
      expect(moved.hasFocus, isTrue,
          reason:
              'Completion must not steal focus after deliberate navigation.');
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      manager.failStorage = true;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Could not save the playlist. Please try again.'),
          findsWidgets);
      expect(tester.takeException(), isNull);
      manager.failStorage = false;
      manager.reject = false;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(manager.adds, 4);
      expect(manager.removes, 2);
    });
  }
}
