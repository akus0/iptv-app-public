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

class _Playlists extends PlaylistManager {
  _Playlists(StorageService storage) : super(storage, CatalogDatabase());
  final saved = <PlaylistProfile>[];
  final existing = <PlaylistProfile>[];
  final pending = Completer<void>();
  @override
  List<PlaylistProfile> get profiles => existing;
  @override
  Future<void> addPlaylist(PlaylistProfile profile) async {
    saved.add(profile);
    await pending.future;
  }

  @override
  Future<void> updatePlaylist(PlaylistProfile profile) => addPlaylist(profile);
  @override
  Future<void> loadPlaylist(String id) async {}
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540),
    const Size(1280, 720)
  ]) {
    for (final edit in [false, true]) {
      testWidgets('playlist action stays reachable $size edit=$edit',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = size.width > size.height
            ? const FakeViewPadding(left: 24, right: 48)
            : const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService();
        await storage.init();
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width >= 900;
        final playlists = _Playlists(storage);
        if (edit) {
          playlists.existing.add(PlaylistProfile(
              id: 'existing',
              name: 'Existing',
              mode: 'm3u',
              m3uUrl: 'https://example.test/list.m3u',
              createdAt: DateTime(2026),
              sortOrder: 2));
        }
        final epg = EpgService(storage);
        await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlists),
            ChangeNotifierProvider.value(value: epg),
          ],
          child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                      body: Center(
                          child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => AddPlaylistScreen(
                                    editPlaylistId: edit ? 'existing' : null))),
                        child: const Text('Open form'),
                      )),
                    )),
          ),
        ));
        await tester.tap(find.text('Open form'));
        await tester.pumpAndSettle();
        final save = find.ancestor(
            of: find.text(edit ? 'Save changes' : 'Add playlist'),
            matching: find.byWidgetPredicate((w) => w is FilledButton));
        expect(save.hitTestable(), findsOneWidget,
            reason: 'Save must not be below the form scroll');
        if (!edit) {
          for (final mode in ['Xtream Codes', 'Smart Add', 'M3U URL']) {
            await tester.ensureVisible(find.text(mode));
            await tester.pumpAndSettle();
            await tester.tap(find.text(mode));
            await tester.pumpAndSettle();
            expect(save.hitTestable(), findsOneWidget,
                reason: '$mode must keep the mobile action visible');
            expect(tester.takeException(), isNull);
          }
        }
        final xtream = prefs.isTelevision && !edit;
        if (xtream) {
          await tester.tap(find.text('Xtream Codes'));
          await tester.pumpAndSettle();
        }
        Finder field(String label) => find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label);
        Future<void> enter(String label, String text) async {
          await tester.ensureVisible(field(label));
          await tester.pumpAndSettle();
          if (prefs.isTelevision) {
            tester.widget<TextField>(field(label)).focusNode!.requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pump();
          }
          await tester.enterText(field(label), text);
          await tester.pump();
        }

        await enter('Name', 'Mobile playlist');
        if (xtream) {
          await enter(
              'Server URL (e.g. http://host:port)', 'https://example.test');
          await enter('Username', 'test-user');
          await enter('Password', 'test-password');
        } else {
          await enter('M3U Playlist URL', 'https://example.test/new.m3u');
        }
        final inset = size.height > size.width ? 280.0 : 180.0;
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pumpAndSettle();
        expect(save.hitTestable(), findsOneWidget);
        final bounds = tester.getRect(save);
        expect(bounds.bottom, lessThanOrEqualTo(size.height - inset));
        expect(
            bounds.right,
            lessThanOrEqualTo(
                size.width - (size.width > size.height ? 48 : 0)));
        await tester.tap(save);
        await tester.pump();
        expect(playlists.saved, hasLength(1));
        expect(playlists.saved.single.name, 'Mobile playlist');
        if (xtream) {
          expect(playlists.saved.single.mode, 'xtream');
          expect(playlists.saved.single.xtreamUsername, 'test-user');
          expect(playlists.saved.single.xtreamPassword, 'test-password');
        } else {
          expect(playlists.saved.single.m3uUrl, 'https://example.test/new.m3u');
        }
        if (edit) expect(playlists.saved.single.id, 'existing');
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        playlists.pending.complete();
        await tester.pumpAndSettle();
        expect(find.byType(AddPlaylistScreen), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        playlists.dispose();
        epg.dispose();
        prefs.dispose();
      });
    }
  }
}
