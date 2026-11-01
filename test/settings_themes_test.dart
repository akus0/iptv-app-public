import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/screens/settings/settings_menu_screen.dart';
import 'package:nox_iptv/screens/settings/playlist_manager_screen.dart';
import 'package:nox_iptv/screens/settings/epg_settings_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

class _Playlist extends PlaylistManager {
  _Playlist(super.storage, super.catalogDb);
  @override
  List<PlaylistProfile> get profiles => [
        PlaylistProfile(
            id: 'demo',
            name: 'My playlist',
            mode: 'xtream',
            sortOrder: 0,
            createdAt: DateTime(2026, 10, 1),
            categoryLayout: 'organised',
            xtreamServer: 'https://example.invalid',
            xtreamUsername: 'demo')
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (fonts.isEmpty) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(File('$fonts/${entry.value}')
            .readAsBytes()
            .then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final palette in AppConstants.cyberpunkPalettes) {
    final scheme = buildAppTheme(palette).colorScheme;
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
    }

    test('${palette.id} readable surface, accent and focus colours', () {
      expect(contrast(scheme.onSurface, scheme.surface), greaterThan(7));
      expect(
          contrast(scheme.onSurfaceVariant, scheme.surface), greaterThan(4.5));
      expect(contrast(scheme.primary, scheme.surface), greaterThan(4.5));
      expect(contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
          greaterThan(4.5));
    });
    for (final size in [const Size(390, 844), const Size(960, 540)]) {
      testWidgets(
          '${palette.id} settings, playlist detail and sources fit $size',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService();
        await storage.init();
        await storage.setPaletteId(palette.id);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width > 600;
        final playlist = _Playlist(storage, CatalogDatabase()),
            epg = EpgService(storage);
        addTearDown(() {
          prefs.dispose();
          playlist.dispose();
          epg.dispose();
        });
        final capture = GlobalKey();
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider<StorageService>.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<EpgService>.value(value: epg),
            ],
            child: MaterialApp(
                theme: buildAppTheme(palette),
                home: RepaintBoundary(
                    key: capture,
                    child: const SettingsMenuScreen(includeTools: true)))));
        await tester.pumpAndSettle();
        Future<void> snapshot(String name) async {
          if (!const bool.fromEnvironment('CAPTURE_LAYOUT')) return;
          await tester.runAsync(() async {
            final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
                find.byType(RepaintBoundary));
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
                    '/tmp/iptv95-$name-${palette.id}-${size.width.toInt()}.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await snapshot('settings');
        await tester.tap(find.text('Playlists & guide'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('My playlist'));
        await tester.pumpAndSettle();
        await snapshot('playlist');
        expect(tester.takeException(), isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('TV guide'));
        await tester.pumpAndSettle();
        expect(find.byType(EpgSettingsScreen), findsOneWidget);
        await snapshot('guide');
        expect(tester.takeException(), isNull);
        expect(find.byType(PlaylistManagerScreen), findsNothing);
      });
    }
  }
}
