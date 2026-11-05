import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/xtream_api_service.dart';
import 'package:nox_iptv/utils/xtream.dart';
import 'package:nox_iptv/utils/smart_add_parser.dart';

void main() {
  late HttpServer server;
  late String base;
  final requests = <Uri>[];
  Object auth = 1;
  String status = 'Active';
  Object? expiry;
  String? bodyOverride;
  int responseCode = 200;
  bool bom = false;

  setUp(() async {
    requests.clear();
    auth = 1;
    status = 'Active';
    expiry = null;
    bodyOverride = null;
    responseCode = 200;
    bom = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}/panel';
    server.listen((request) async {
      requests.add(request.uri);
      request.response.statusCode =
          request.uri.path == '/panel/player_api.php' ? responseCode : 404;
      // Some panels omit the JSON content type. JSON still uses UTF-8.
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
      final action = request.uri.queryParameters['action'];
      final result = switch (action) {
        'get_live_categories' => [
            {'category_id': '1', 'category_name': '日本 스포츠'}
          ],
        'get_live_streams' => [
            {'stream_id': 7, 'category_id': '1', 'name': '日本 스포츠'}
          ],
        _ => {
            'user_info': {
              'auth': auth,
              'status': status,
              'max_connections': '2',
              'exp_date': expiry,
            }
          },
      };
      request.response.add([
        if (bom) ...[0xef, 0xbb, 0xbf],
        ...utf8.encode(bodyOverride ?? jsonEncode(result))
      ]);
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  XtreamApiService api([String? address]) => XtreamApiService(
      server: address ?? base,
      username: 'fixture+user',
      password: 'fixture&pass',
      playlistId: 'fixture');

  for (final endpoint in ['', '/player_api.php', '/get.php', '/xmltv.php']) {
    test('XC login accepts server or endpoint $endpoint without extra requests',
        () async {
      final address = endpoint.isEmpty
          ? ' $base/// '
          : '$base$endpoint?username=old&password=old#fragment';
      final service = api(address);
      await service.authenticate();
      expect(service.server, base);
      expect(requests, hasLength(1));
      expect(requests.single.queryParameters,
          {'username': 'fixture+user', 'password': 'fixture&pass'});
      final epg = Uri.parse(XtreamHelper.buildEpgUrl(
          server: address, username: 'fixture+user', password: 'fixture&pass'));
      expect(epg.path, '/panel/xmltv.php');
      expect(epg.queryParameters['password'], 'fixture&pass');
    });
  }

  test('XC host and port without a scheme reach the same endpoint', () async {
    await api(base.substring('http://'.length)).authenticate();
    expect(requests, hasLength(1));
  });

  for (final value in [1, '1']) {
    test(
        'XC accepts explicit authenticated value $value (${value.runtimeType})',
        () async {
      auth = value;
      final service = api();
      await service.authenticate();
      expect(service.maxConnections, 2);
      expect(service.expiryDate, isNull);
      expect(requests, hasLength(1));
    });
  }

  test('XC accepts casing and outer whitespace in an active status', () async {
    status = ' active ';
    await api().authenticate();
  });

  test('invalid optional expiry cannot reject an otherwise active login',
      () async {
    expiry = '9223372036854775807';
    final service = api();
    await service.authenticate();
    expect(service.expiryDate, isNull);
  });

  for (final address in [
    '',
    'http://',
    'https:/example.test',
    'ftp://example.test',
    'http://example.test:99999',
    'http://example.test:not-a-port',
    'http://fixture:secret@example.test',
    'http://example .test',
  ]) {
    test('invalid XC address is rejected locally: $address', () {
      expect(() => api(address), throwsFormatException);
      expect(requests, isEmpty);
    });
  }

  test('normalizing preserves HTTPS, ports, IPv6 and encoded panel paths', () {
    expect(XtreamHelper.normalizeServer('https://example.test:8443/panel/'),
        'https://example.test:8443/panel');
    expect(XtreamHelper.normalizeServer('http://[::1]:8080/player_api.php'),
        'http://[::1]:8080');
    expect(XtreamHelper.normalizeServer('https://example.test/a%2Fb/get.php'),
        'https://example.test/a%2Fb');
  });

  for (final code in [401, 403, 404, 429, 500]) {
    test('HTTP $code errors identify the response without exposing credentials',
        () async {
      responseCode = code;
      try {
        await api().authenticate();
        fail('Expected an HTTP error');
      } on XtreamException catch (e) {
        expect(e.message, contains('HTTP $code'));
        expect(e.message, isNot(contains('fixture')));
        expect(e.message, isNot(contains('127.0.0.1')));
      }
      expect(requests, hasLength(1));
    });
  }

  test('HTML and malformed login responses are not reported as bad passwords',
      () async {
    for (final body in ['<html>fixture-secret</html>', '{"user_info":[]}']) {
      bodyOverride = body;
      try {
        await api().authenticate();
        fail('Expected a response error');
      } on XtreamException catch (e) {
        expect(e.accountRejected, isFalse);
        expect(e.message, isNot(contains('fixture-secret')));
      }
    }
  });

  test('XC decodes UTF-8 catalogue and BOM without relying on content type',
      () async {
    bom = true;
    final service = api();
    await service.authenticate();
    final categories = await service.getLiveCategories();
    final channels = await service.getLiveStreams(
        categoryNames: {for (final c in categories) c.id: c.name});
    expect(categories.single.name, '日本 스포츠');
    expect(channels.single.name, '日本 스포츠');
    expect(channels.single.group, categories.single.name);
    expect(requests, hasLength(3));
  });

  for (final value in [0, '0', true, 2]) {
    test('XC does not accept a rejected or ambiguous auth value $value',
        () async {
      auth = value;
      await expectLater(api().authenticate(), throwsException);
      expect(requests, hasLength(1));
    });
  }

  for (final value in ['Expired', 'Disabled', 'Banned', '']) {
    test('XC does not accept inactive status $value', () async {
      status = value;
      await expectLater(api().authenticate(), throwsException);
    });
  }

  test('malformed catalogue cannot silently replace saved channels', () async {
    bodyOverride = '{"error":"temporary failure"}';
    await expectLater(api().getLiveStreams(categoryNames: {}), throwsException);
  });

  test('Smart Add preserves panel paths when extracting endpoint credentials',
      () {
    final parsed = parseSmartAddText(
        'https://example.test:8443/panel/get.php?username=fixture%2Buser&password=fixture%26pass&type=m3u_plus');
    expect(parsed.serverCandidates, ['https://example.test:8443/panel']);
    expect(parsed.username, 'fixture+user');
    expect(parsed.password, 'fixture&pass');
  });

  test('Smart Add still deduplicates ordinary root-server links', () {
    final parsed = parseSmartAddText(
        'Server: https://example.test Username: fixture Password: fixture\n'
        'https://example.test/player_api.php?username=fixture&password=fixture');
    expect(parsed.serverCandidates, ['https://example.test']);
    expect(parsed.username, 'fixture');
    expect(parsed.password, 'fixture');
  });

  test('Smart Add keeps explicit credentials ahead of sample URL credentials',
      () {
    final parsed = parseSmartAddText(
        'https://example.test/get.php?username=old&password=old\n'
        'Username: fixture-user\nPassword: fixture%26literal');
    expect(parsed.username, 'fixture-user');
    expect(parsed.password, 'fixture%26literal');
  });

  test('Smart Add decodes escaped credentials once, including percent signs',
      () {
    final parsed = parseSmartAddText(
        'https://example.test/get.php?username=fixture&password=fixture%2526%2B%26');
    expect(parsed.password, 'fixture%26+&');
  });
}
