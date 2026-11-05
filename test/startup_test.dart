import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/main.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/screens/welcome_add_playlist_screen.dart';
import 'package:nox_iptv/services/device_memory_service.dart';
import 'package:nox_iptv/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // Stall filesystem access, not a real network/provider. Both EPG and
    // playlist restoration are deliberately unfinished when home must open.
    final blockedPath = Completer<String>();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) => blockedPath.future,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.nox.nox_iptv/device_type'),
      (_) async => false,
    );
  });

  tearDown(() {
    for (final name in [
      'plugins.flutter.io/path_provider',
      'com.nox.nox_iptv/device_type',
      'com.nox.nox_iptv/device_memory'
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  for (final mode in ['m3u', 'xtream']) {
    testWidgets(
        'existing live-only $mode install reaches home while playlist restore stalls',
        (tester) async {
      final profile = PlaylistProfile(
          id: 'offline',
          name: 'Offline fixture',
          mode: mode,
          xtreamServer: 'https://example.invalid',
          xtreamUsername: 'fixture',
          xtreamPassword: 'fixture',
          m3uUrl: 'https://example.invalid/never-requested',
          sortOrder: 0,
          createdAt: DateTime(2026));
      SharedPreferences.setMockInitialValues({
        AppConstants.keyMigratedToMultiPlaylist: true,
        AppConstants.keyFavoritesDbReconciled: true,
        AppConstants.keyPlaylists: jsonEncode([profile.toJson()]),
      });
      await tester.pumpWidget(const NoxIptvApp());
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(TvHomeScreen), findsOneWidget);
      expect(find.byType(WelcomeAddPlaylistScreen), findsNothing);
      expect(find.text('Loading channels...'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(
          jsonDecode(prefs.getString(AppConstants.keyPlaylists)!).single['id'],
          'offline');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 21));
    });
  }

  testWidgets(
      'fresh install reaches playlist setup even with stalled guide cache',
      (tester) async {
    // The test font is wider than Android's Roboto; this test exercises boot,
    // not typography (covered by the layout tests).
    tester.platformDispatcher.textScaleFactorTestValue = 0.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const NoxIptvApp());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(WelcomeAddPlaylistScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('non-responding Android device probes use bounded fallbacks',
      (tester) async {
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.nox.nox_iptv/device_memory'),
      (_) => Completer<Map<String, dynamic>>().future,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.nox.nox_iptv/device_type'),
      (_) => Completer<bool>().future,
    );
    final memory = DeviceMemoryService.getMemoryInfo();
    final type = DeviceTypeService.isTelevision();
    await tester.pump(const Duration(seconds: 3));
    expect(await memory, isNull);
    expect(await type, isFalse);
  });
}
