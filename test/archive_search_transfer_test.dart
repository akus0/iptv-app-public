import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/services/archive_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

ArchiveMeta _m(String id, String name) =>
    ArchiveMeta(id: id, type: ArchiveType.series, name: name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('search: partial words, titles starting with it first', () {
    // As the server answers "li" (loose matches mixed in), plus row titles.
    final found = [
      _m('1', 'The Lincoln Lawyer'),
      _m('2', 'Lioness'),
      _m('3', 'Shameless'), // no word starts with "li": dropped
      _m('4', 'Line of Fire'),
      _m('2', 'Lioness'), // same title from a row: once
      _m('5', 'Élite'),
      _m('6', 'Friday Night Lights'),
    ];
    expect(ArchiveService.rankSearch('li', found).map((m) => m.name), [
      'Lioness',
      'Line of Fire',
      'The Lincoln Lawyer',
      'Friday Night Lights',
    ]);
    // Accents and case don't matter; several words match in place.
    expect(ArchiveService.rankSearch('ELI', found).map((m) => m.id), ['5']);
    expect(ArchiveService.rankSearch('lincoln law', found).map((m) => m.id),
        ['1']);
    expect(ArchiveService.rankSearch('  ', found), isEmpty);
  });

  group('transfer: Include Archive tab data', () {
    const sources = '[{"url":"https://a/manifest.json"}]';
    const progressKey =
        '${AppConstants.keyLastPositionPrefix}archive::arc_vod_abc_tt1';
    const otherProgress = '${AppConstants.keyLastPositionPrefix}a::9';

    Future<StorageService> sender() async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyPlaylists: '[{"id":"a"}]',
        AppConstants.keyArchiveSources: sources,
        progressKey: 5000,
        otherProgress: 1234,
      });
      final s = StorageService();
      await s.init();
      return s;
    }

    Future<SharedPreferences> receive(Map<String, Object> payload) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyArchiveSources:
            '[{"url":"https://mine/manifest.json"}]',
        '${AppConstants.keyLastPositionPrefix}archive::arc_vod_x_tt2': 77,
      });
      final r = StorageService();
      await r.init();
      await r.importForTransfer(payload);
      return SharedPreferences.getInstance();
    }

    test('checked: archive sources and progress go across', () async {
      final payload = (await sender()).exportForTransfer();
      expect(payload.keys, contains(AppConstants.keyArchiveSources));
      expect(payload.keys, contains(progressKey));
      final prefs = await receive(payload);
      expect(prefs.getString(AppConstants.keyArchiveSources), sources);
      expect(prefs.getInt(progressKey), 5000);
      expect(prefs.getInt(otherProgress), 1234);
    });

    test('unchecked: left out, and the receiver keeps its own', () async {
      final payload = (await sender()).exportForTransfer(includeArchive: false);
      expect(payload.keys, isNot(contains(AppConstants.keyArchiveSources)));
      expect(payload.keys, isNot(contains(progressKey)));
      expect(payload.keys, contains(otherProgress));
      final prefs = await receive(payload);
      expect(prefs.getString(AppConstants.keyArchiveSources),
          '[{"url":"https://mine/manifest.json"}]');
      expect(
          prefs.getInt(
              '${AppConstants.keyLastPositionPrefix}archive::arc_vod_x_tt2'),
          77);
      expect(prefs.getInt(progressKey), isNull);
      expect(prefs.getInt(otherProgress), 1234);
      expect(prefs.getString(AppConstants.keyPlaylists), '[{"id":"a"}]');
      // The marker itself is never stored.
      expect(prefs.getKeys().where((k) => k.contains('archive_excluded')),
          isEmpty);
    });
  });
}
