import 'package:nox_iptv/widgets/tv_switch_list_tile.dart';
import 'package:nox_iptv/screens/settings/playlist_manager_screen.dart';
import 'package:nox_iptv/screens/settings/group_management_screen.dart';
import 'package:nox_iptv/screens/settings/theme_screen.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/widgets/iptv_bottom_bar.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/screens/settings/settings_menu_screen.dart';
import 'package:nox_iptv/screens/settings/general_settings_screen.dart';
import 'package:nox_iptv/screens/settings/epg_settings_screen.dart';
import 'package:nox_iptv/utils/guide_enrichment.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

class Guide extends EpgService {
  Guide(super.storage);
  int clears = 0;
  @override
  Future<void> clearAll() async {
    clears++;
  }

  final requests = <String>[];
  Completer<void>? pending;
  @override
  Future<void> refresh(String url,
      {required Set<String> knownChannelIds}) async {
    requests.add(url);
    if (pending != null) await pending!.future;
  }
}

class Playlist extends PlaylistManager {
  Playlist(StorageService storage) : super(storage, CatalogDatabase());
  final calls = <String>[];
  Completer<void>? cleanup;
  @override
  Future<int> tidyThaiChannels() async {
    calls.add('cleanup');
    if (cleanup != null) await cleanup!.future;
    return 1;
  }

  @override
  Future<int> applyGuideEnrichment(EpgService epg,
      {Set<String>? allowedSources, bool primaryOnly = false}) async {
    calls.add('local');
    return 1;
  }

  @override
  Set<String> thaiGuideCandidates(EpgService epg) => {'regional'};
  @override
  Future<int> applyThaiGuide(EpgService epg) async {
    calls.add('supplement');
    return 1;
  }

  @override
  Set<String> guideEnrichmentCandidates(
          EpgService epg, GuideEnrichmentSource source) =>
      {'guide'};
}

void main() {
  late StorageService storage;
  late AppPreferences prefs;
  late Playlist playlist;
  late Guide guide;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
    prefs = AppPreferences(storage);
    await prefs.init();
    playlist = Playlist(storage);
    guide = Guide(storage);
  });
  tearDown(() {
    prefs.dispose();
    playlist.dispose();
    guide.dispose();
  });
  Future<void> open(WidgetTester tester, Widget page, Size size,
      {double scale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<AppPreferences>.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<EpgService>.value(value: guide),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: page)));
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 720)
  ]) {
    testWidgets('settings and startup choices fit $size', (tester) async {
      await open(tester, const SettingsMenuScreen(), size);
      expect(find.text('Your TV'), findsOneWidget);
      expect(find.textContaining('noxqcx'), findsNothing);
      await tester.ensureVisible(find.text('Playback & preferences'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playback & preferences'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Playback at startup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playback at startup'));
      await tester.pumpAndSettle();
      expect(find.text('Do not play automatically'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Full screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Full screen'));
      await tester.pumpAndSettle();
      expect(storage.getResumeLastChannelAtStartup(), isTrue);
      expect(storage.getResumeLastChannelInGuide(), isFalse);
      await tester.tap(find.text('Playback at startup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In the preview'));
      await tester.pumpAndSettle();
      expect(storage.getResumeLastChannelAtStartup(), isFalse);
      expect(storage.getResumeLastChannelInGuide(), isTrue);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('remote activates focused settings entry', (tester) async {
    await open(tester, const SettingsMenuScreen(), const Size(1280, 720));
    Focus.of(tester.element(find.text('Playback & preferences')))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Playback at startup'), findsOneWidget);
  });
  testWidgets(
      'group management has only Live TV and an accessible confirmation tab',
      (tester) async {
    await open(tester, const GroupManagementScreen(playlistId: 'fixture'),
        const Size(1280, 720));
    expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(2));
    expect(find.text('Movies'), findsNothing);
    expect(find.text('TV Shows'), findsNothing);
    await tester.tap(find.text('Confirm').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('unused movie and series navigation options are removed',
      (tester) async {
    await open(tester, const GeneralSettingsScreen(), const Size(390, 844));
    expect(find.text('Movies'), findsNothing);
    expect(find.text('TV Shows'), findsNothing);
    expect(find.text('Clear Movies & TV Shows history'), findsNothing);
  });
  testWidgets('source choices persist without starting downloads',
      (tester) async {
    await open(tester, const EpgSettingsScreen(), const Size(390, 844));
    expect(find.text('Fill guide gaps'), findsNothing);
    await tester.ensureVisible(find.text('Australia'));
    await tester.tap(find.text('Australia'));
    await tester.pumpAndSettle();
    expect(storage.getSupplementaryGuideSelection(), {'au'});
    expect(guide.requests, isEmpty);
    await tester.tap(find.text('Australia'));
    await tester.pumpAndSettle();
    expect(storage.getSupplementaryGuideSelection(), isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('settings support enlarged phone text', (tester) async {
    await open(tester, const SettingsMenuScreen(), const Size(320, 640),
        scale: 1.4);
    await tester.drag(find.byType(ListView), const Offset(0, -550));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'guide page exposes only automatic maintenance and confirms guide-only clear',
      (tester) async {
    await open(tester, const EpgSettingsScreen(), const Size(390, 844));
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Guide matching'), findsNothing);
    expect(find.text('Channel links'), findsNothing);
    await tester.scrollUntilVisible(find.text('Clear guide listings'), 160);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear guide listings'));
    await tester.pumpAndSettle();
    expect(guide.clears, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(guide.clears, 0);
    await tester.scrollUntilVisible(find.text('Clear guide listings'), 160);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear guide listings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear listings'));
    await tester.pumpAndSettle();
    expect(guide.clears, 1);
    expect(tester.takeException(), isNull);
  });
  test(
      'retired palette resolves to the current theme without resetting preferences',
      () async {
    await storage.setPaletteId('dark_gold');
    await storage.setGuideViewMode('live');
    final restored = AppPreferences(storage);
    await restored.init();
    expect(restored.palette.id, 'classic_tv');
    expect(restored.guideViewMode, 'timeline');
    expect(AppConstants.cyberpunkPalettes, hasLength(3));
    restored.dispose();
  });
  testWidgets('themes persist and old layout switches are absent',
      (tester) async {
    await open(tester, const ThemeScreen(), const Size(320, 640));
    expect(find.text('Channel list'), findsNothing);
    expect(find.text('Schedule grid'), findsNothing);
    for (final (label, id) in [
      ('Light', 'light'),
      ('OLED black', 'oled'),
      ('Dark grey', 'classic_tv')
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(storage.getPaletteId(), id);
      final restored = AppPreferences(storage);
      await restored.init();
      expect(restored.palette.id, id);
      restored.dispose();
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('settings keeps navigation and exposes the moved tools',
      (tester) async {
    await open(tester, const SettingsMenuScreen(includeTools: true),
        const Size(390, 844));
    expect(find.byKey(const ValueKey('bottom-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('bottom-more')), findsNothing);
    expect(tester.widget<IptvBottomBar>(find.byType(IptvBottomBar)).selected,
        'settings');
    expect(find.text('Search'), findsNothing);
    expect(find.text('Refresh playlists'), findsNothing);
    expect(find.text('Switch profile'), findsNothing);
    prefs.setHideMultiview(false);
    await tester.pumpAndSettle();
    expect(prefs.hideMultiview, isFalse);
    expect(find.text('Multiview'), findsOneWidget);
    await tester.tap(find.text('Playlists & guide'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistManagerScreen), findsOneWidget);
    expect(find.text('Refresh playlists'), findsOneWidget);
    expect(find.text('TV guide'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('multiview can be enabled while media hub remains removed',
      (tester) async {
    await open(tester, const GeneralSettingsScreen(), const Size(390, 844));
    expect(find.text('Media Hub'), findsNothing);
    await tester.ensureVisible(find.text('Watch multiple channels'));
    final tile = tester.widget<TvSwitchListTile>(find.ancestor(
        of: find.text('Watch multiple channels'),
        matching: find.byType(TvSwitchListTile)));
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNotNull);
  });
}
