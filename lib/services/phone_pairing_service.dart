import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

/// Optional self-hosted relay. LAN pairing works without a relay.
const String kPairRelayBase = String.fromEnvironment('PAIR_RELAY_BASE');

/// Protocol marker understood by the bundled relay implementation; not a secret.
const Map<String, String> kRelayAppHeaders = {'X-VesperTV-App': '1'};

/// What a pairing session asks the phone for: the Add Playlist form, or one
/// long link (Settings > Archive sources' manifest URL). pair.html picks its
/// form from a `.link` / `#link` suffix on the URL fragment.
enum PairingKind { playlist, link }

/// What the phone sent: the same fields Add Playlist has, or one [link].
class PairingResult {
  const PairingResult({
    required this.mode,
    this.link = '',
    this.name = '',
    this.server = '',
    this.username = '',
    this.password = '',
    this.m3uUrl = '',
    this.epgUrl = '',
  });

  /// 'xtream', 'm3u' or 'link'.
  final String mode;

  /// Set when [mode] is 'link'.
  final String link;
  final String name;
  final String server;
  final String username;
  final String password;
  final String m3uUrl;
  final String epgUrl;

  /// Null when the payload isn't something the form could have produced.
  static PairingResult? fromJson(Object? json) {
    if (json is! Map) return null;
    String s(String k, int max) {
      final v = json[k];
      if (v is! String) return '';
      final t = v.trim();
      return t.length > max ? t.substring(0, max) : t;
    }

    final mode = s('mode', 10);
    final r = PairingResult(
      mode: mode,
      name: s('name', 80),
      server: s('server', 500),
      username: s('username', 200),
      password: s('password', 200),
      m3uUrl: s('m3u', 2000),
      epgUrl: s('epg', 2000),
      link: s('link', 4000),
    );
    if (mode == 'link') return r.link.isNotEmpty ? r : null;
    if (mode == 'xtream' &&
        r.server.isNotEmpty &&
        r.username.isNotEmpty &&
        r.password.isNotEmpty) {
      return r;
    }
    if (mode == 'm3u' && r.m3uUrl.isNotEmpty) return r;
    return null;
  }
}

/// Add Playlist > "From my phone": the TV shows a QR code, the phone opens a
/// form, and what's typed there lands back in the TV's Add Playlist fields.
///
/// Two ways in, because the TV can't know which network the phone is on:
/// - **Wi-Fi (default):** the TV runs a one-session HTTP server on its LAN
///   address and the QR opens `http://<tv-ip>:<port>/p/<token>` — nothing
///   leaves the home network.
/// - **Relay (fallback, phone on mobile data):** the QR opens the relay page
///   with `#<sessionId>.<key>` in the fragment (never sent to any server);
///   the phone AES-GCM-encrypts the form and uploads only ciphertext, which
///   the TV polls for and decrypts here.
///
/// Both stay armed together once started (one result wins), the server is
/// closed on [stop], and everything expires after [lifetime].
class PhonePairingSession {
  PhonePairingSession(
      {this.lifetime = const Duration(minutes: 10),
      this.kind = PairingKind.playlist});

  final Duration lifetime;

  /// Which form the phone shows; results of the other kind are refused.
  final PairingKind kind;

  /// The URL-fragment suffix pair.html reads (see [PairingKind]).
  String get _kindSuffix => kind == PairingKind.link ? 'link' : '';

  bool _accepts(PairingResult r) =>
      (r.mode == 'link') == (kind == PairingKind.link);

  final _results = StreamController<PairingResult>.broadcast();
  Stream<PairingResult> get results => _results.stream;

  HttpServer? _server;
  String? _lanUrl;
  late final String _token = _randomToken(8);
  late final List<int> _key = _randomBytes(32);
  late final String _sessionId = _b64url(_randomBytes(16));
  Timer? _relayPoll;
  Timer? _expiry;
  bool _done = false;
  String? _pageHtml;

  /// `http://<ip>:<port>/p/<token>`, or null when the TV has no private
  /// IPv4 address (then only the relay path can work).
  String? get lanUrl => _lanUrl;

  String get relayUrl => '$kPairRelayBase/p#$_sessionId.${_b64url(_key)}'
      '${_kindSuffix.isEmpty ? '' : '.$_kindSuffix'}';

  bool get isExpired => _done;

  Future<void> start() async {
    _expiry = Timer(lifetime, stop);
    _pageHtml = await rootBundle.loadString('assets/pair/pair.html');
    final ip = await _privateIpv4();
    if (ip == null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server = server;
      _lanUrl = 'http://${ip.address}:${server.port}/p/$_token'
          '${_kindSuffix.isEmpty ? '' : '#$_kindSuffix'}';
      server.listen(_handle, onError: (Object e) {
        debugPrint('PhonePairing: server error ${e.runtimeType}');
      });
    } catch (e) {
      debugPrint('PhonePairing: could not open the local server: ${e.runtimeType}');
    }
  }

  /// Starts polling the relay (only while the relay QR is on screen, so a
  /// Wi-Fi-only pairing never touches the VPS).
  void startRelayPolling() {
    if (kPairRelayBase.isEmpty || _done || _relayPoll != null) return;
    _relayPoll =
        Timer.periodic(const Duration(seconds: 2), (_) => _pollRelay());
  }

  void stopRelayPolling() {
    _relayPoll?.cancel();
    _relayPoll = null;
  }

  Future<void> stop() async {
    _done = true;
    stopRelayPolling();
    _expiry?.cancel();
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (!_results.isClosed) await _results.close();
  }

  void _deliver(PairingResult r) {
    if (_done || !_accepts(r)) return;
    _results.add(r);
    unawaited(stop());
  }

  // ------------------------------------------------------------- Wi-Fi path

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    PairingResult? received;
    res.headers
      ..set('Cache-Control', 'no-store')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('X-Content-Type-Options', 'nosniff');
    try {
      if (req.uri.path != '/p/$_token') {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      if (_done) {
        res.statusCode = HttpStatus.gone;
        return;
      }
      if (req.method == 'GET') {
        res.headers.contentType = ContentType.html;
        res.write(_pageHtml ?? '');
        return;
      }
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final body = await _readLimited(req, 16 * 1024);
      final result = body == null ? null : _decodeResult(body);
      if (result == null || !_accepts(result)) {
        res.statusCode = HttpStatus.badRequest;
        return;
      }
      res.statusCode = HttpStatus.noContent;
      received = result;
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
    } finally {
      await res.close();
    }
    // Send the phone response before closing the pairing server, which would otherwise
    // terminate the response connection.
    if (received != null) _deliver(received);
  }

  static Future<String?> _readLimited(HttpRequest req, int max) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > max) return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static PairingResult? _decodeResult(String json) {
    try {
      return PairingResult.fromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  /// The address a phone on the same network can reach: the first private
  /// IPv4 (Wi-Fi or Ethernet), skipping loopback and link-local.
  static Future<InternetAddress?> _privateIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      InternetAddress? fallback;
      for (final i in interfaces) {
        // Emulator/VPN/virtual adapters (docker, vEthernet, tun) aren't
        // what a phone on the home Wi-Fi can reach.
        final name = i.name.toLowerCase();
        final virtual = name.contains('docker') ||
            name.contains('veth') ||
            name.contains('vethernet') ||
            name.contains('tun') ||
            name.contains('virtualbox') ||
            name.contains('vmware');
        for (final a in i.addresses) {
          if (!_isPrivate(a)) continue;
          if (!virtual) return a;
          fallback ??= a;
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  static bool _isPrivate(InternetAddress a) {
    final b = a.rawAddress;
    if (b.length != 4) return false;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  // ------------------------------------------------------------- relay path

  bool _polling = false;

  Future<void> _pollRelay() async {
    if (_polling || _done) return;
    _polling = true;
    try {
      final res = await http
          .get(Uri.parse('$kPairRelayBase/api/s/$_sessionId'),
              headers: kRelayAppHeaders)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final result = await decryptRelayPayload(res.body, _key);
      if (result != null) _deliver(result);
    } catch (_) {
      // Offline or relay down — keep trying until the session expires.
    } finally {
      _polling = false;
    }
  }

  /// Opens a relay blob (`{"iv","ct"}`, base64) sealed by pair.html's
  /// WebCrypto AES-GCM with [key]. Null on any tampering or garbage.
  @visibleForTesting
  static Future<PairingResult?> decryptRelayPayload(
      String body, List<int> key) async {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final iv = base64.decode(json['iv'] as String);
      final ct = base64.decode(json['ct'] as String);
      if (ct.length < 16) return null;
      // WebCrypto appends the 16-byte GCM tag to the ciphertext.
      final box = SecretBox(ct.sublist(0, ct.length - 16),
          nonce: iv, mac: Mac(ct.sublist(ct.length - 16)));
      final clear =
          await AesGcm.with256bits().decrypt(box, secretKey: SecretKey(key));
      return _decodeResult(utf8.decode(clear));
    } catch (e) {
      debugPrint('PhonePairing: relay payload rejected: ${e.runtimeType}');
      return null;
    }
  }

  // ---------------------------------------------------------------- helpers

  static final _rng = Random.secure();

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _rng.nextInt(256));

  static String _b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// Short, unambiguous (no 0/O/1/l) so the Wi-Fi URL can be typed by hand.
  static String _randomToken(int n) {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    return List.generate(n, (_) => alphabet[_rng.nextInt(alphabet.length)])
        .join();
  }
}

/// The device's private LAN IPv4 (see [PhonePairingSession]); shared with
/// the device-to-device transfer.
Future<InternetAddress?> privateLanIpv4() => PhonePairingSession._privateIpv4();
