import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:nox_iptv/widgets/phone_pair_panel.dart';
import 'package:http/http.dart' as http;
import 'package:nox_iptv/services/phone_pairing_service.dart';

class _LocalHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh builds do not use upstream relay or OAuth registrations', () {
    expect(kPairRelayBase, isEmpty);
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
        final result = session.results.first;
        final sent = await client.post(uri,
            body: jsonEncode({
              'mode': 'xtream',
              'server': 'https://example.test',
              'username': 'test-user',
              'password': 'test-password',
            }));
        expect(sent.statusCode, 204);
        final received = await result.timeout(const Duration(seconds: 2));
        expect(received.mode, 'xtream');
        expect(received.username, 'test-user');
        expect(received.password, 'test-password');
        expect(session.isExpired, isTrue);
      } finally {
        client.close();
        await session.stop();
      }
    }, _LocalHttpOverrides());
  });
  // Synthetic interface addresses; no device configuration is used.
  test('pairing prefers LAN and never advertises a known VPN tunnel', () {
    String address(List<int> octets) =>
        InternetAddress.fromRawAddress(Uint8List.fromList(octets)).address;
    ({String name, Iterable<InternetAddress> addresses}) adapter(
            String name, String ip) =>
        (name: name, addresses: [InternetAddress(ip)]);
    for (final vpn in ['tun0', 'wg0', 'ppp0', 'tailscale0', 'vpn0', 'utun3']) {
      expect(
          PhonePairingSession.selectLanAddress([
            adapter(vpn, address([10, 8, 0, 2])),
            adapter('wlan0', address([192, 168, 1, 20]))
          ])?.address,
          address([192, 168, 1, 20]));
      expect(
          PhonePairingSession.selectLanAddress([
            adapter(vpn, address([10, 8, 0, 2]))
          ]),
          isNull);
    }
    expect(
        PhonePairingSession.selectLanAddress([
          adapter('unknown', address([10, 8, 0, 2])),
          adapter('eth0', address([10, 0, 0, 20]))
        ])?.address,
        address([10, 0, 0, 20]));
    expect(
        PhonePairingSession.selectLanAddress([
          adapter('wlan0', address([169, 254, 1, 2])),
          adapter('eth0', address([203, 0, 113, 1]))
        ]),
        isNull);
    expect(
        PhonePairingSession.selectLanAddress([
          adapter('customLAN', address([172, 16, 0, 2]))
        ])?.address,
        address([172, 16, 0, 2]));
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
