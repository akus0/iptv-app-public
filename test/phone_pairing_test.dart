import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/phone_pairing_service.dart';

void main() {
  test(
      'Stalker pairing accepts registered MAC and bounds optional identity fields',
      () {
    for (final mac in [
      '001a79123456',
      '00:1a:79:12:34:56',
      '00-1a-79-12-34-56'
    ]) {
      final result = PairingResult.fromJson({
        'mode': 'stalker',
        'name': ' Portal ',
        'portalUrl': ' https://portal.example.test/c/ ',
        'portalMac': mac,
        'portalPassword': ' space-sensitive ',
        'portalDeviceId': 'a' * 300,
        'unknown': 'ignored',
      })!;
      expect(result.name, 'Portal');
      expect(
          result.portalDetails['portalUrl'], 'https://portal.example.test/c/');
      expect(result.portalDetails['portalPassword'], ' space-sensitive ');
      expect(result.portalDetails['portalDeviceId'], hasLength(200));
      expect(result.portalDetails.containsKey('unknown'), false);
      expect(() => result.portalDetails['portalUrl'] = 'changed',
          throwsUnsupportedError);
    }
  });

  test('incomplete Stalker payloads fail while existing modes remain accepted',
      () {
    for (final mac in [
      '',
      'invalid',
      '00:1a:79:12:34',
      '00:1a:79:12:34:56:78'
    ]) {
      expect(
          PairingResult.fromJson({
            'mode': 'stalker',
            'portalUrl': 'https://portal.example.test/c/',
            'portalMac': mac
          }),
          isNull);
    }
    expect(
        PairingResult.fromJson(
            {'mode': 'stalker', 'portalMac': '001a79123456'}),
        isNull);
    for (final payload in [
      {'mode': 'm3u', 'm3u': 'https://example.test/list'},
      {
        'mode': 'xtream',
        'server': 'https://example.test',
        'username': 'fixture',
        'password': 'fixture'
      },
      {'mode': 'link', 'link': 'https://example.test/manifest'},
    ]) {
      final result = PairingResult.fromJson(payload)!;
      expect(result.mode, payload['mode']);
      expect(result.portalDetails, isEmpty);
    }
  });

  test('encrypted relay carries Stalker fields and rejects tampered payloads',
      () async {
    final key = List<int>.generate(32, (i) => i);
    final payload = {
      'mode': 'stalker',
      'portalUrl': 'https://portal.example.test/c/',
      'portalMac': '00:1a:79:12:34:56',
      'portalSignature': 'fixture-signature'
    };
    final box = await AesGcm.with256bits()
        .encrypt(utf8.encode(jsonEncode(payload)), secretKey: SecretKey(key));
    final bytes = [...box.cipherText, ...box.mac.bytes];
    String encoded() =>
        jsonEncode({'iv': base64Encode(box.nonce), 'ct': base64Encode(bytes)});
    final result =
        await PhonePairingSession.decryptRelayPayload(encoded(), key);
    expect(result!.portalDetails['portalSignature'], 'fixture-signature');
    bytes[0] ^= 1;
    expect(
        await PhonePairingSession.decryptRelayPayload(encoded(), key), isNull);
  });
}
