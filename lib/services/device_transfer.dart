import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'phone_pairing_service.dart' show privateLanIpv4;

/// Settings > Transfer to another device: copies this device's setup
/// (playlists, every viewer's favorites, hidden groups, progress, settings —
/// see `StorageService.exportForTransfer`) to another device on the same
/// Wi-Fi. No server, no account: the sender runs a one-time HTTP server on
/// its LAN address and nothing leaves the home network.
///
/// **The code** the sender shows is 9 digits: the last octet of its IPv4
/// (3 digits) — the receiver puts it after its own first three octets, so
/// nobody types an address — then a 6-digit secret.
///
/// **Security:** the receiver sends an ephemeral X25519 public key with an
/// HMAC keyed by the secret; the sender answers only if it checks out (five
/// wrong tries end the session), with its own public key (HMAC'd the same
/// way) and the payload AES-GCM-encrypted under a key derived from the
/// X25519 shared secret + the code. Someone sniffing the Wi-Fi sees only
/// ciphertext they can't open, even by trying every code offline; an active
/// attacker has five online guesses at a 1-in-a-million secret.
const int kTransferPortFirst = 47821;
const int kTransferPortCount = 5;
const String _path = '/vesper-transfer';

class TransferException implements Exception {
  const TransferException(this.kind);
  final TransferError kind;
  @override
  String toString() => 'TransferException($kind)';
}

enum TransferError {
  /// This device has no private IPv4 (not on Wi-Fi/Ethernet).
  noNetwork,

  /// Nothing answered at the code's address.
  unreachable,

  /// The sender rejected the code.
  wrongCode,

  /// The sender's session ended (sent already, expired, too many tries).
  closed,

  /// Garbage or tampered response.
  invalid,

  /// Internet transfer: no upload for that code (wrong, expired or deleted).
  notFound,

  /// Internet transfer: the setup is over the relay's size limit (or the
  /// relay is full).
  tooBig,
}

/// Sender side. [start] binds the server and fills [code]; [sent] completes
/// once a receiver has the data (or with an error when the session ends).
class TransferSendSession {
  TransferSendSession(this._payload,
      {this.lifetime = const Duration(minutes: 10)});

  /// The export map (already JSON-encodable).
  final Map<String, Object> _payload;
  final Duration lifetime;

  HttpServer? _server;
  String? _code;
  String? _address;
  int _wrongTries = 0;
  bool _done = false;
  Timer? _expiry;
  final _result = Completer<void>();

  /// "046382915" — null until [start] succeeds.
  String? get code => _code;

  /// This device's LAN address, shown small as a fallback hint.
  String? get address => _address;

  /// Completes when a receiver got the data; errors with
  /// [TransferError.closed] when the session expires or is locked.
  Future<void> get sent => _result.future;

  Future<void> start() async {
    final ip = await privateLanIpv4();
    if (ip == null) throw const TransferException(TransferError.noNetwork);
    HttpServer? server;
    for (var i = 0; i < kTransferPortCount && server == null; i++) {
      try {
        server = await HttpServer.bind(
            InternetAddress.anyIPv4, kTransferPortFirst + i);
      } catch (_) {
        // Port busy — try the next one; the receiver tries them all.
      }
    }
    if (server == null) {
      throw const TransferException(TransferError.unreachable);
    }
    _server = server;
    _address = ip.address;
    final octet = ip.rawAddress[3].toString().padLeft(3, '0');
    final secret = List.generate(6, (_) => _rng.nextInt(10).toString()).join();
    _code = '$octet$secret';
    _expiry = Timer(lifetime, () => _finish(error: true));
    server.listen(_handle,
        onError: (Object e) => debugPrint('Transfer: server error ${e.runtimeType}'));
  }

  Future<void> stop() => _finish(error: true);

  Future<void> _finish({required bool error}) async {
    if (_done) return;
    _done = true;
    _expiry?.cancel();
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (!_result.isCompleted) {
      if (error) {
        _result.completeError(const TransferException(TransferError.closed));
      } else {
        _result.complete();
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Cache-Control', 'no-store');
    var delivered = false;
    try {
      if (req.uri.path != _path || req.method != 'POST') {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      if (_done) {
        res.statusCode = HttpStatus.gone;
        return;
      }
      final body = await _readLimited(req, 4 * 1024);
      final hello = body == null ? null : _decodeMap(body);
      final pub = _b64(hello?['pub']);
      final mac = _b64(hello?['mac']);
      if (pub == null || mac == null || pub.length != 32) {
        res.statusCode = HttpStatus.badRequest;
        return;
      }
      final secret = _secretOf(_code!);
      final expected = await _mac(secret, 'hello', pub);
      if (!_equal(mac, expected)) {
        _wrongTries++;
        res.statusCode = HttpStatus.forbidden;
        if (_wrongTries >= 5) {
          unawaited(Future(() => _finish(error: true)));
        }
        return;
      }
      final reply = await _seal(secret, pub, utf8.encode(jsonEncode(_payload)));
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(reply));
      delivered = true;
    } catch (e) {
      debugPrint('Transfer: request failed: ${e.runtimeType}');
      res.statusCode = HttpStatus.internalServerError;
    } finally {
      await res.close();
    }
    // After the receiver has its answer — closing the server drops this
    // very connection (same lesson as PhonePairingSession).
    if (delivered) await _finish(error: false);
  }

  static Future<Map<String, Object?>> _seal(
      String secret, List<int> receiverPub, List<int> clear) async {
    final x = X25519();
    final mine = await x.newKeyPair();
    final myPub = (await mine.extractPublicKey()).bytes;
    final shared = await x.sharedSecretKey(
        keyPair: mine,
        remotePublicKey:
            SimplePublicKey(receiverPub, type: KeyPairType.x25519));
    final key = await _deriveKey(shared, secret, receiverPub, myPub);
    final box = await AesGcm.with256bits().encrypt(clear, secretKey: key);
    return {
      'pub': base64.encode(myPub),
      'mac': base64.encode(await _mac(secret, 'reply', myPub)),
      'iv': base64.encode(box.nonce),
      'ct': base64.encode(box.cipherText),
      'tag': base64.encode(box.mac.bytes),
    };
  }
}

/// Receiver side: reaches the sender named by [code] and returns its export
/// map. [host] overrides the address the code implies — for a home with two
/// networks (router + extender/second router), where the sender's address
/// doesn't share the receiver's first three octets. Throws
/// [TransferException].
Future<Map<String, Object?>> receiveTransfer(String code,
    {String? host}) async {
  if (!RegExp(r'^\d{9}$').hasMatch(code)) {
    throw const TransferException(TransferError.wrongCode);
  }
  final octet = int.parse(code.substring(0, 3));
  if (host == null && (octet < 1 || octet > 254)) {
    throw const TransferException(TransferError.wrongCode);
  }
  final secret = _secretOf(code);
  if (host == null) {
    final ip = await privateLanIpv4();
    if (ip == null) throw const TransferException(TransferError.noNetwork);
    final b = ip.rawAddress;
    host = '${b[0]}.${b[1]}.${b[2]}.$octet';
  }

  final x = X25519();
  final mine = await x.newKeyPair();
  final myPub = (await mine.extractPublicKey()).bytes;
  final hello = jsonEncode({
    'pub': base64.encode(myPub),
    'mac': base64.encode(await _mac(secret, 'hello', myPub)),
  });

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    for (var i = 0; i < kTransferPortCount; i++) {
      final uri = Uri.parse('http://$host:${kTransferPortFirst + i}$_path');
      HttpClientResponse res;
      String body;
      try {
        final req = await client.postUrl(uri);
        req.headers.contentType = ContentType.json;
        req.write(hello);
        res = await req.close().timeout(const Duration(seconds: 20));
        body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 30));
      } on SocketException {
        continue; // Nothing on this port — try the next one.
      } on TimeoutException {
        continue;
      }
      if (res.statusCode == HttpStatus.notFound) continue;
      if (res.statusCode == HttpStatus.forbidden) {
        throw const TransferException(TransferError.wrongCode);
      }
      if (res.statusCode == HttpStatus.gone) {
        throw const TransferException(TransferError.closed);
      }
      if (res.statusCode != HttpStatus.ok) {
        throw const TransferException(TransferError.invalid);
      }
      return await _open(secret, mine, myPub, body);
    }
    throw const TransferException(TransferError.unreachable);
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, Object?>> _open(
    String secret, SimpleKeyPair mine, List<int> myPub, String body) async {
  final reply = _decodeMap(body);
  final pub = _b64(reply?['pub']);
  final mac = _b64(reply?['mac']);
  final iv = _b64(reply?['iv']);
  final ct = _b64(reply?['ct']);
  final tag = _b64(reply?['tag']);
  if (pub == null || mac == null || iv == null || ct == null || tag == null) {
    throw const TransferException(TransferError.invalid);
  }
  // Proves the sender knew the code too (not just anyone answering there).
  if (!_equal(mac, await _mac(secret, 'reply', pub))) {
    throw const TransferException(TransferError.invalid);
  }
  final shared = await X25519().sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519));
  final key = await _deriveKey(shared, secret, myPub, pub);
  try {
    final clear = await AesGcm.with256bits()
        .decrypt(SecretBox(ct, nonce: iv, mac: Mac(tag)), secretKey: key);
    final map = jsonDecode(utf8.decode(clear));
    if (map is! Map<String, Object?>) {
      throw const TransferException(TransferError.invalid);
    }
    return map;
  } on SecretBoxAuthenticationError {
    throw const TransferException(TransferError.invalid);
  }
}

// ------------------------------------------------------------------ helpers

final _rng = Random.secure();

String _secretOf(String code) => code.substring(3);

Future<List<int>> _mac(String secret, String label, List<int> data) async {
  final mac = await Hmac.sha256().calculateMac(
      [...utf8.encode('$label|'), ...data],
      secretKey: SecretKey(utf8.encode('vesper-transfer|$secret')));
  return mac.bytes;
}

Future<SecretKey> _deriveKey(SecretKey shared, String secret,
    List<int> receiverPub, List<int> senderPub) {
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: utf8.encode('vesper-transfer|$secret'),
    info: [...receiverPub, ...senderPub],
  );
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int>? _b64(Object? v) {
  if (v is! String) return null;
  try {
    return base64.decode(v);
  } catch (_) {
    return null;
  }
}

Map<String, Object?>? _decodeMap(String s) {
  try {
    final v = jsonDecode(s);
    return v is Map<String, Object?> ? v : null;
  } catch (_) {
    return null;
  }
}

Future<String?> _readLimited(HttpRequest req, int max) async {
  final bytes = <int>[];
  await for (final chunk in req) {
    bytes.addAll(chunk);
    if (bytes.length > max) return null;
  }
  return utf8.decode(bytes, allowMalformed: true);
}
