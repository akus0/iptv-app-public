import 'package:nox_iptv/models/epg_source_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/custom_guide_source.dart';
import 'package:nox_iptv/screens/settings/epg_settings_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Storage extends StorageService {
  bool fail = false;
  @override
  Future<void> setCustomGuideSources(List<CustomGuideSource> sources) async {
    if (fail) throw StateError('Synthetic write failure');
    await super.setCustomGuideSources(sources);
  }
}

class _Guide extends EpgService {
  _Guide(super.storage);
  int refreshes = 0;
  EpgSourceStatus? status;
  @override
  EpgSourceStatus? sourceStatus(String source) => status;
  @override
  Future<void> refreshAll() async {
    refreshes++;
  }
}

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
        'custom XMLTV add, edit, toggle and remove work on $size without automatic downloads',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = _Storage();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final manager = PlaylistManager(storage, CatalogDatabase());
      final epg = _Guide(storage);
      await tester.pumpWidget(MultiProvider(providers: [
        Provider<StorageService>.value(value: storage),
        ChangeNotifierProvider.value(value: prefs),
        ChangeNotifierProvider.value(value: manager),
        ChangeNotifierProvider<EpgService>.value(value: epg),
      ], child: const MaterialApp(home: EpgSettingsScreen())));
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('add-custom-guide'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      final url = find.byKey(const ValueKey('custom-guide-url'));
      final save = find.byKey(const ValueKey('custom-guide-save'));
      await tester.enterText(
          find.byKey(const ValueKey('custom-guide-name')), 'Fixture guide');
      await tester.enterText(url, 'not a URL');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid http:// or https:// XMLTV URL.'),
          findsOneWidget);
      expect(storage.getCustomGuideSources(), isEmpty);
      await tester.enterText(url, 'https://example.test/guide.xml.gz');
      tester.view.viewInsets =
          FakeViewPadding(bottom: size.width < 600 ? 250 : 130);
      await tester.pumpAndSettle();
      expect(save.hitTestable(), findsOneWidget);
      storage.fail = true;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Could not save this guide. Please try again.'),
          findsOneWidget);
      expect(tester.widget<TextField>(url).controller!.text,
          'https://example.test/guide.xml.gz');
      storage.fail = false;
      await tester.tap(save);
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      final source = storage.getCustomGuideSources().single;
      expect(source.enabled, isTrue);
      final tile = find.byKey(ValueKey('custom-guide-${source.id}'));
      expect(find.text('Not checked this session'), findsWidgets);
      final evidenceRevision = epg.changeRevision;
      epg.status = EpgSourceStatus(EpgSourceState.failed, DateTime.now(),
          httpStatus: 503);
      epg.sourceStatusRevision.value++;
      await tester.pump();
      expect(find.textContaining('Update failed (HTTP 503)'), findsOneWidget);
      expect(epg.changeRevision, evidenceRevision,
          reason: 'Status updates must not invalidate sports matching.');
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture guide'));
      await tester.pumpAndSettle();
      expect(storage.getCustomGuideSources().single.enabled, isFalse);
      expect(epg.refreshes, 0);
      await tester.tap(find.byTooltip('Edit Fixture guide'));
      await tester.pumpAndSettle();
      await tester.enterText(url, 'https://example.test/updated.xml');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(storage.getCustomGuideSources().single.id, source.id);
      expect(storage.getCustomGuideSources().single.enabled, isFalse);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit Fixture guide'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('custom-guide-remove')));
      await tester.pumpAndSettle();
      expect(storage.getCustomGuideSources(), isEmpty);
      expect(epg.refreshes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }
}
