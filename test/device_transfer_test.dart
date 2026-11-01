import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/device_transfer.dart';
import 'package:nox_iptv/services/phone_pairing_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real sockets on this machine's LAN address — skipped when it has none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('storage export/import round-trips and keeps device-only keys',
      () async {
    SharedPreferences.setMockInitialValues({
      AppConstants.keyPlaylists: '[{"id":"a"}]',
      AppConstants.keyFavorites: ['a::1', 'a::2'],
      AppConstants.keyShowClock: true,
      '${AppConstants.keyLastPositionPrefix}a::9': 1234,
      AppConstants.keyLayoutMode: 'tv',
      AppConstants.keyLastFullSyncAt: 99,
    });
    final storage = StorageService();
    await storage.init();
    final exported = storage.exportForTransfer();
    expect(exported.keys, isNot(contains(AppConstants.keyLayoutMode)));
    expect(exported.keys, isNot(contains(AppConstants.keyLastFullSyncAt)));

    SharedPreferences.setMockInitialValues({
      AppConstants.keyLayoutMode: 'phone',
      AppConstants.keyFavorites: ['old::1'],
    });
    final receiver = StorageService();
    await receiver.init();
    await receiver.importForTransfer(exported);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConstants.keyPlaylists), '[{"id":"a"}]');
    expect(prefs.getStringList(AppConstants.keyFavorites), ['a::1', 'a::2']);
    expect(prefs.getBool(AppConstants.keyShowClock), true);
    expect(prefs.getInt('${AppConstants.keyLastPositionPrefix}a::9'), 1234);
    expect(prefs.getString(AppConstants.keyLayoutMode), 'phone');
  });

  test('send/receive over the LAN, wrong code rejected', () async {
    HttpOverrides.global = null; // the test binding fakes HTTP otherwise
    if (await privateLanIpv4() == null) {
      markTestSkipped('no private IPv4 on this machine');
      return;
    }
    final payload = <String, Object>{
      'k': {'t': 's', 'v': 'hello'},
    };
    final session = TransferSendSession(payload);
    await session.start();
    final code = session.code!;
    final wrong =
        '${code.substring(0, 3)}${code.substring(3) == '000000' ? '111111' : '000000'}';
    await expectLater(
        receiveTransfer(wrong),
        throwsA(isA<TransferException>()
            .having((e) => e.kind, 'kind', TransferError.wrongCode)));
    final got = await receiveTransfer(code);
    expect(got['k'], {'t': 's', 'v': 'hello'});
    await session.sent;
    // One use only.
    await expectLater(receiveTransfer(code), throwsA(isA<TransferException>()));
  });

  test('five wrong codes end the session', () async {
    HttpOverrides.global = null;
    if (await privateLanIpv4() == null) {
      markTestSkipped('no private IPv4 on this machine');
      return;
    }
    final session = TransferSendSession({});
    await session.start();
    final code = session.code!;
    final sent = session.sent.then((_) => 'sent', onError: (_) => 'closed');
    for (var i = 0; i < 5; i++) {
      final guess = '${code.substring(0, 3)}${(i + 1) * 111111 % 1000000}'
          .padRight(9, '0');
      if (guess == code) continue;
      await expectLater(
          receiveTransfer(guess), throwsA(isA<TransferException>()));
    }
    expect(await sent, 'closed');
    await expectLater(receiveTransfer(code), throwsA(isA<TransferException>()));
  });
}
