import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/guide_enrichment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'primary commits before supplements; busy refresh coalesces and failures keep data',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('guide-pipeline-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final epg = EpgService(storage);
    addTearDown(() async {
      epg.dispose();
      messenger.setMockMethodCallHandler(pathChannel, null);
      await databaseFactory.deleteDatabase('${dir.path}/vesper_epg.db');
      await dir.delete(recursive: true);
    });
    final now = DateTime.now().toUtc();
    String stamp(DateTime d) =>
        '${d.toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(0, 14)} +0000';
    String xml(String id) =>
        '<tv><programme channel="$id" start="${stamp(now.subtract(const Duration(hours: 1)))}" stop="${stamp(now.add(const Duration(days: 1)))}"><title>Live programme</title></programme></tv>';
    final source = guideEnrichmentSources.first;
    var selected = true, complete = 0, active = 0, peak = 0;
    final requests = <String>[];
    final primaryGate = Completer<void>();
    epg.startAutoRefresh(
        360,
        () => [
              (
                url: 'https://example.invalid/primary',
                knownChannelIds: {'primary'}
              )
            ]);
    epg.supplementarySources = () async {
      expect(epg.getCurrentProgram('primary'), isNotNull);
      expect(epg.isLoading, isTrue);
      return selected
          ? [
              (
                url: source.url,
                knownChannelIds: {
                  '${source.prefix}extra',
                  '${source.prefix}missing'
                }
              ),
              (
                url: 'https://example.invalid/failure',
                knownChannelIds: {'failed'}
              )
            ]
          : [];
    };
    epg.onSupplementaryGuidesUpdated = () async {
      complete++;
    };
    await http.runWithClient(() async {
      final run = epg.refreshAll();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await epg.refreshAll();
      primaryGate.complete();
      await run;
      expect(peak, 1);
      expect(
          requests.where((r) => Uri.parse(r).path == '/primary'), hasLength(1));
      expect(epg.getCurrentProgram('${source.prefix}extra'), isNotNull);
      expect(epg.error, isNotNull);
      expect(epg.isLoading, isFalse);
      expect(complete, 1);
      await epg.refreshAll();
      expect(requests.where((r) => r.contains('epg-au')), hasLength(1),
          reason:
              'Absent listings must not repeatedly download a successful source');
      selected = false;
      final before = requests.length;
      await epg.refreshAll();
      expect(requests.length, before + 1);
      expect(epg.getCurrentProgram('${source.prefix}extra'), isNotNull);
      expect(epg.error, isNull);
      await epg.clearAll();
      selected = true;
      await epg.refreshAll();
      expect(requests.where((r) => r.contains('epg-au')), hasLength(2));
    },
        () => MockClient((request) async {
              active++;
              peak = active > peak ? active : peak;
              requests.add(request.url.toString());
              try {
                if (request.url.path == '/primary') {
                  await primaryGate.future;
                  return http.Response(xml('primary'), 200);
                }
                if (request.url.path == '/failure') {
                  return http.Response('unavailable', 503);
                }
                return http.Response(xml('extra'), 200);
              } finally {
                active--;
              }
            }));
  });
}
