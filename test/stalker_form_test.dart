import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/widgets/tv_menu_tile.dart';
import 'package:nox_iptv/screens/settings/add_playlist_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Playlists extends PlaylistManager {
  _Playlists(StorageService storage) : super(storage, CatalogDatabase());
  final saved = <PlaylistProfile>[];
  @override
  Future<void> addPlaylist(PlaylistProfile p) async {
    saved.add(p);
  }

  @override
  Future<void> loadPlaylist(String id) async {}
}

class _Guide extends EpgService {
  _Guide(super.storage);
  final requested = <String>[];
  @override
  Future<void> refreshPortal(String id) async {
    requested.add(id);
  }
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'Stalker form validates MAC, saves identity and keeps action visible $size',
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
      final epg = _Guide(storage);
      await tester.pumpWidget(MultiProvider(providers: [
        Provider.value(value: storage),
        ChangeNotifierProvider.value(value: prefs),
        ChangeNotifierProvider<PlaylistManager>.value(value: manager),
        ChangeNotifierProvider<EpgService>.value(value: epg)
      ], child: const MaterialApp(home: AddPlaylistScreen())));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const ValueKey('playlist-mode-stalker')));
      await tester.tap(find.byKey(const ValueKey('playlist-mode-stalker')));
      await tester.pumpAndSettle();
      Future<void> enter(Finder f, String text) async {
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

      await enter(
          find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == 'Name'),
          'Portal fixture');
      await enter(find.byKey(const ValueKey('portalUrl')),
          'https://portal.example.test/c/');
      await enter(find.byKey(const ValueKey('portalMac')), 'bad-mac');
      final save = find.byKey(const ValueKey('playlist-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(manager.saved, isEmpty);
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('portalMac')))
              .focusNode!
              .hasFocus,
          isTrue);
      expect(find.text('Enter the MAC address registered with your provider.'),
          findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(AddPlaylistScreen)))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await enter(find.byKey(const ValueKey('portalMac')), '00-1a-79-12-34-56');
      if (prefs.isTelevision) {
        tester
            .widget<TextField>(find.byKey(const ValueKey('portalMac')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<TextButton>(
                    find.byKey(const ValueKey('portal-advanced')))
                .focusNode!
                .hasFocus,
            isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('portalUsername')))
                .focusNode!
                .hasFocus,
            isTrue);
      } else {
        await tester
            .ensureVisible(find.byKey(const ValueKey('portal-advanced')));
        await tester.tap(find.byKey(const ValueKey('portal-advanced')));
        await tester.pumpAndSettle();
      }
      final password = find.byKey(const ValueKey('portalPassword'));
      await enter(password, 'fixture-password');
      expect(tester.widget<TextField>(password).obscureText, isTrue);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      if (prefs.isTelevision) {
        tester.widget<TextField>(password).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
            tester
                .widget<IconButton>(find.byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == 'Show password'))
                .focusNode!
                .hasFocus,
            isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(find.byTooltip('Show password'));
      }
      await tester.pump();
      expect(tester.widget<TextField>(password).obscureText, isFalse);
      expect(tester.widget<TextField>(password).controller!.text,
          'fixture-password');
      await tester.tap(find.byTooltip('Hide password'));
      await tester.pump();
      expect(tester.widget<TextField>(password).obscureText, isTrue);
      await enter(find.byKey(const ValueKey('portalSerial')), 'fixture-serial');
      if (prefs.isTelevision) {
        tester
            .widget<TvMenuTile>(
                find.byKey(const ValueKey('playlist-mode-stalker')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<TvMenuTile>(find.byWidgetPredicate(
                    (w) => w is TvMenuTile && w.title == 'Smart Add'))
                .focusNode!
                .hasFocus,
            isTrue,
            reason:
                'Arrow keys in the source list must not return to an old field');
      }
      if (!prefs.isTelevision) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 180);
        await tester.pumpAndSettle();
      }
      expect(save.hitTestable(), findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(manager.saved.single.mode, 'stalker');
      expect(manager.saved.single.portalMac, '00:1A:79:12:34:56');
      expect(manager.saved.single.portalSerial, 'fixture-serial');
      expect(manager.saved.single.portalPassword, 'fixture-password');
      expect(epg.requested, [manager.saved.single.id]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }
}
