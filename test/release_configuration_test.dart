import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:nox_iptv/widgets/phone_pair_panel.dart';
import 'package:http/http.dart' as http;
import 'package:nox_iptv/services/phone_pairing_service.dart';
import 'package:nox_iptv/services/tracker_api.dart';

class _LocalHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh builds do not use upstream relay or OAuth registrations', () {
    expect(kPairRelayBase, isEmpty);
    expect(kTraktClientId, isEmpty);
    expect(kSimklClientId, isEmpty);
    expect(kTraktRedirectUri, isEmpty);
  });

  test('LAN pairing still serves the form without a configured relay',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final session = PhonePairingSession();
      final client = http.Client();
      try {
        await session.start();
        session
            .startRelayPolling(); // No configured endpoint: no poll is scheduled.
        final local = session.lanUrl;
        if (local == null) {
          // Headless CI may have no private IPv4 interface.
          expect(session.isExpired, isFalse);
          return;
        }
        final uri = Uri.parse(local).replace(host: '127.0.0.1');
        final response = await client.get(uri);
        expect(response.statusCode, 200);
        expect(response.headers['cache-control'], 'no-store');
        expect(response.body.toLowerCase(), contains('<html'));
        final missing = await client.get(uri.replace(path: '/invalid'));
        expect(missing.statusCode, 404);
      } finally {
        client.close();
        await session.stop();
      }
    }, _LocalHttpOverrides());
  });
  testWidgets('LAN-only pairing retains the remote focus target',
      (tester) async {
    final toggle = FocusNode();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PhonePairPanel(
      toggleFocusNode: toggle,
      onResult: (_) {},
    ))));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('New code'), findsOneWidget);
    expect(
        find.text('Phone not on this Wi-Fi? Use the other code'), findsNothing);
    toggle.requestFocus();
    await tester.pump();
    expect(toggle.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    toggle.dispose();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
  });
}
