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
  @override
  List<PlaylistProfile> get profiles => existing;
  @override
  Future<void> addPlaylist(PlaylistProfile profile) async => saved.add(profile);
  @override
  Future<void> updatePlaylist(PlaylistProfile profile) => addPlaylist(profile);
  @override
  Future<void> loadPlaylist(String id) async {}
}

class _Guide extends EpgService {
  _Guide(super.storage);
  final requested = <String>[];
  final requestHeaders = <Map<String, String>>[];
  @override
  Future<void> refresh(String url,
      {required Set<String> knownChannelIds,
      Map<String, String> headers = const {}}) async {
    requested.add(url);
    requestHeaders.add(headers);
  }
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540),
  ]) {
    for (final editing in [false, true]) {
      testWidgets(
          'XC validates locally and saves a corrected URL $size edit=$editing',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService();
        await storage.init();
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width >= 900;
        final manager = _Playlists(storage);
        final guide = _Guide(storage);
        if (editing) {
          manager.existing.add(PlaylistProfile(
              id: 'existing',
              name: 'Fixture',
              userAgent: 'ProviderPlayer/2',
              mode: 'xtream',
              xtreamServer: 'http://',
              xtreamUsername: 'fixture-user',
              xtreamPassword: 'fixture-pass',
              sortOrder: 0,
              createdAt: DateTime(2026)));
        }
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: manager),
              ChangeNotifierProvider<EpgService>.value(value: guide),
            ],
            child: MaterialApp(
                home: AddPlaylistScreen(
                    editPlaylistId: editing ? 'existing' : null))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (!editing) {
          await tester.ensureVisible(find.text('Xtream Codes'));
          await tester.tap(find.text('Xtream Codes'));
          await tester.pumpAndSettle();
        }
        Finder field(String label) => find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label);
        Future<void> enter(String label, String text) async {
          final f = field(label);
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          if (prefs.isTelevision) {
            tester.widget<TextField>(f).focusNode!.requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pump();
          }
          await tester.enterText(f, text);
          await tester.pump();
        }

        const serverLabel = 'Server URL (e.g. http://host:port)';
        await enter('Name', 'Fixture');
        await enter('Username', 'fixture-user');
        await enter('Password', 'fixture-pass');
        await enter(serverLabel, 'http://');
        final save = find.byKey(const ValueKey('playlist-save'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(manager.saved, isEmpty);
        expect(guide.requested, isEmpty);
        expect(find.textContaining('Enter a valid Xtream server URL'),
            findsWidgets);
        expect(tester.widget<TextField>(field(serverLabel)).focusNode!.hasFocus,
            isTrue);
        await enter(serverLabel,
            'https://example.test:8443/panel/player_api.php?username=old&password=old');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(manager.saved, hasLength(1));
        final profile = manager.saved.single;
        expect(profile.xtreamServer, 'https://example.test:8443/panel');
        expect(profile.xtreamUsername, 'fixture-user');
        expect(profile.xtreamPassword, 'fixture-pass');
        if (editing) expect(profile.id, 'existing');
        expect(guide.requestHeaders.single,
            editing ? {'User-Agent': 'ProviderPlayer/2'} : <String, String>{});
        final epg = Uri.parse(guide.requested.single);
        expect(epg.path, '/panel/xmltv.php');
        expect(epg.queryParameters,
            {'username': 'fixture-user', 'password': 'fixture-pass'});
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        manager.dispose();
        guide.dispose();
        prefs.dispose();
      });
    }
  }
}
