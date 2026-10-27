import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'device_transfer.dart' show TransferError, TransferException;
import 'phone_pairing_service.dart' show kPairRelayBase, kRelayAppHeaders;

/// Settings > Transfer to another device > **Different network**: the
/// sender uploads its setup (`StorageService.exportForTransfer`), encrypted
/// on the device, to the relay's vault (`tools/pair_relay`, `/api/v/<id>`)
/// for 1 h / 24 h / 7 days; any device that types the 16-digit code pulls it
/// until it expires or the sender deletes it. No account.
///
/// **What the server sees:** an opaque id, a hashed write token, the expiry
/// and ciphertext. Id, write token and AES key all come from the code
/// (PBKDF2 → HKDF), so the relay can't read a setup or find its code; a
/// stolen blob costs ~2^53 slow PBKDF2 guesses to open.
///
const int kCloudCodeLength = 16;

const List<Duration> kCloudTransferLifetimes = [
  Duration(hours: 1),
  Duration(hours: 24),
  Duration(days: 7),
];

/// PBKDF2 rounds for a code. Pure Dart on a weak TV box: keep it ~1 s
/// (runs in an isolate, so the UI keeps spinning).
const int _codeIterations = 60000;
const int _blobVersion = 1;
const Duration _timeout = Duration(seconds: 60);

/// A pending upload as the sender remembers it.
class CloudTransfer {
  const CloudTransfer(this.code, this.expires);
  final String code;
  final DateTime expires;

  bool get isActive => expires.isAfter(DateTime.now());

  String toJson() =>
      jsonEncode({'code': code, 'expires': expires.millisecondsSinceEpoch});

  static CloudTransfer? fromJson(String? s) {
    if (s == null) return null;
    try {
      final m = jsonDecode(s) as Map<String, Object?>;
      return CloudTransfer(m['code'] as String,
          DateTime.fromMillisecondsSinceEpoch(m['expires'] as int));
    } catch (_) {
      return null;
    }
  }
}

/// What a code (or, later, a linked-device secret) unlocks on the vault.
class VaultKeys {
  const VaultKeys(this.id, this.token, this.key);

  /// Public blob id (base64url, 22 chars).
  final String id;

  /// Write/delete token (base64url); the relay stores only its SHA-256.
  final String token;

  /// AES-256-GCM key bytes.
  final List<int> key;

  static Future<VaultKeys> fromMaster(List<int> master) async {
    Future<List<int>> part(String label, int length) async {
      final k = await Hkdf(hmac: Hmac.sha256(), outputLength: length).deriveKey(
          secretKey: SecretKey(master),
          nonce: utf8.encode('vesper-vault-v1'),
          info: utf8.encode(label));
      return k.extractBytes();
    }

    return VaultKeys(
      _b64url(await part('id', 16)),
      _b64url(await part('token', 32)),
      await part('key', 32),
    );
  }

  static Future<VaultKeys> fromCode(String code) async {
    final master = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _codeIterations,
      bits: 256,
    ).deriveKey(
        secretKey: SecretKey(utf8.encode(code)),
        nonce: utf8.encode('vesper-transfer-code-v1'));
    return fromMaster(await master.extractBytes());
  }
}

/// 16 random digits — typed on a remote's number pad like the Wi-Fi code
/// (9 digits), and told apart from it by length.
String newCloudCode() {
  final rng = Random.secure();
  return List.generate(kCloudCodeLength, (_) => rng.nextInt(10).toString())
      .join();
}

/// "1234 5678 9012 3456".
String formatCloudCode(String code) => [
      for (var i = 0; i < code.length; i += 4)
        code.substring(i, min(i + 4, code.length)),
    ].join(' ');

/// Encrypts [payload] under a new code and uploads it for [lifetime].
/// Throws [TransferException].
Future<CloudTransfer> uploadCloudTransfer(
    Map<String, Object> payload, Duration lifetime) async {
  final code = newCloudCode();
  final created = DateTime.now().millisecondsSinceEpoch;
  final (keys, blob) = await Isolate.run(() async {
    final keys = await VaultKeys.fromCode(code);
    final clear = gzip.encode(utf8.encode(
        jsonEncode({'kind': 'transfer', 'created': created, 'data': payload})));
    return (keys, await _seal(keys, clear));
  });
  final res = await _call(() => http.put(_uri(keys.id),
      headers: {
        ...kRelayAppHeaders,
        'Content-Type': 'application/octet-stream',
        'X-Vault-Token': keys.token,
        'X-Vault-Ttl': '${lifetime.inSeconds}',
      },
      body: blob));
  switch (res.statusCode) {
    case 204:
    case 200:
      return CloudTransfer(code, DateTime.now().add(lifetime));
    case 413:
    case 507:
      throw const TransferException(TransferError.tooBig);
    default:
      throw const TransferException(TransferError.unreachable);
  }
}

/// Downloads and opens the setup [code] points to. Throws
/// [TransferException] (`notFound` = wrong, expired or deleted).
Future<Map<String, Object?>> downloadCloudTransfer(String code) async {
  if (!RegExp('^\\d{$kCloudCodeLength}\$').hasMatch(code)) {
    throw const TransferException(TransferError.wrongCode);
  }
  final keys = await Isolate.run(() => VaultKeys.fromCode(code));
  final res =
      await _call(() => http.get(_uri(keys.id), headers: kRelayAppHeaders));
  if (res.statusCode == 404) {
    throw const TransferException(TransferError.notFound);
  }
  if (res.statusCode != 200) {
    throw const TransferException(TransferError.unreachable);
  }
  final blob = res.bodyBytes;
  final data = await Isolate.run(() async {
    final clear = await _open(keys, blob);
    if (clear == null) return null;
    try {
      final env = jsonDecode(utf8.decode(gzip.decode(clear)));
      final data = env is Map ? env['data'] : null;
      return data is Map<String, Object?> ? data : null;
    } catch (_) {
      return null;
    }
  });
  if (data == null) throw const TransferException(TransferError.invalid);
  return data;
}

/// Removes the upload now (the sender's "Delete now"). A missing one counts
/// as deleted.
Future<void> deleteCloudTransfer(String code) async {
  final keys = await Isolate.run(() => VaultKeys.fromCode(code));
  final res = await _call(() => http.delete(_uri(keys.id),
      headers: {...kRelayAppHeaders, 'X-Vault-Token': keys.token}));
  if (res.statusCode != 204 && res.statusCode != 404) {
    throw const TransferException(TransferError.unreachable);
  }
}

// ------------------------------------------------------------------ helpers

/// The relay hosting the vault; tests point it at a local `relay.py`.
String cloudTransferBase = kPairRelayBase;

Uri _uri(String id) {
  if (cloudTransferBase.isEmpty) {
    throw const TransferException(TransferError.unreachable);
  }
  return Uri.parse('$cloudTransferBase/api/v/$id');
}

Future<http.Response> _call(Future<http.Response> Function() send) async {
  try {
    final res = await send().timeout(_timeout);
    if (res.statusCode == 429) {
      throw const TransferException(TransferError.unreachable);
    }
    return res;
  } on TransferException {
    rethrow;
  } catch (_) {
    // SocketException, ClientException, TimeoutException, TLS errors.
    throw const TransferException(TransferError.unreachable);
  }
}

/// `[version][nonce 12][ciphertext][tag 16]`, the id bound in as AAD.
Future<Uint8List> _seal(VaultKeys keys, List<int> clear) async {
  final box = await AesGcm.with256bits().encrypt(clear,
      secretKey: SecretKey(keys.key),
      aad: utf8.encode('vesper-vault|${keys.id}'));
  return Uint8List.fromList(
      [_blobVersion, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<List<int>?> _open(VaultKeys keys, Uint8List blob) async {
  if (blob.length < 1 + 12 + 16 || blob[0] != _blobVersion) return null;
  final nonce = blob.sublist(1, 13);
  final ct = blob.sublist(13, blob.length - 16);
  final tag = blob.sublist(blob.length - 16);
  try {
    return await AesGcm.with256bits().decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(keys.key),
        aad: utf8.encode('vesper-vault|${keys.id}'));
  } on SecretBoxAuthenticationError {
    return null;
  }
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
