import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/services/stalker_portal_service.dart';

import 'stalker_portal_test.dart' show portalProfile, portalRow, js;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bare address discovers redirected portal without sending credentials',
      () async {
    final calls = <Uri>[];
    final api = StalkerPortalService(
      portalProfile(url: 'https://portal.example.test'),
      client: MockClient((r) async {
        calls.add(r.url);
        if (r.url.path.isEmpty || r.url.path == '/stalker_portal/c/') {
          expect(r.headers.containsKey('cookie'), isFalse);
          expect(r.headers.containsKey('authorization'), isFalse);
          expect(r.headers.containsKey('referer'), isFalse);
          return r.url.path.isEmpty
              ? http.Response('', 302,
                  headers: {'location': '/stalker_portal/c/'})
              : http.Response('<html>Portal</html>', 200);
        }
        if (r.url.path != '/stalker_portal/server/load.php') {
          return http.Response('', 404);
        }
        if (r.url.queryParameters['action'] == 'handshake') {
          return js({'token': 'fixture'});
        }
        if (r.url.queryParameters['action'] == 'get_profile') {
          return js({'status': 0});
        }
        return js([]);
      }),
    );
    addTearDown(api.dispose);
    await api.authenticate();
    expect(calls.map((u) => u.path), [
      '/server/load.php',
      '/portal.php',
      '/portal.php',
      '',
      '/stalker_portal/c/',
      '/stalker_portal/server/load.php',
      '/stalker_portal/server/load.php',
    ]);
    final count = calls.length;
    await api.authenticate();
    expect(calls, hasLength(count));
    await api.getLiveCategories();
    expect(calls.last.path, '/stalker_portal/server/load.php');
  });

  test('working portal and rejected account never probe the browser page',
      () async {
    for (final blocked in [false, true]) {
      var calls = 0;
      final api =
          StalkerPortalService(portalProfile(), client: MockClient((r) async {
        calls++;
        expect(r.url.path, '/server/load.php');
        return r.url.queryParameters['action'] == 'handshake'
            ? js({'token': 'fixture'})
            : js({'status': blocked ? 1 : 0});
      }));
      addTearDown(api.dispose);
      if (blocked) {
        await expectLater(api.authenticate(), throwsA(isA<PortalException>()));
      } else {
        await api.authenticate();
      }
      expect(calls, 2);
    }
  });

  for (final target in [
    'https://external.example.test/c/',
    'http://portal.example.test/c/',
    'https://portal.example.test:9443/c/',
    'https://user:secret@portal.example.test/c/',
    '/c/?token=fixture',
    '/c/#fragment',
  ]) {
    test('browser discovery refuses an unsafe destination $target', () async {
      var browserCalls = 0;
      final api = StalkerPortalService(
          portalProfile(url: 'https://portal.example.test'),
          client: MockClient((r) async {
        expect(r.url.host, 'portal.example.test');
        if (r.url.path.isEmpty) {
          browserCalls++;
          return http.Response('', 302, headers: {'location': target});
        }
        expect(r.url.path, anyOf('/server/load.php', '/portal.php'));
        return http.Response('', 404);
      }));
      addTearDown(api.dispose);
      await expectLater(api.authenticate(), throwsA(isA<PortalException>()));
      expect(browserCalls, 1);
    });
  }

  test('browser discovery loop and stalled transport remain bounded', () async {
    for (final stall in [false, true]) {
      var browserCalls = 0;
      final pending = Completer<http.Response>();
      final api = StalkerPortalService(
          portalProfile(url: 'https://portal.example.test'),
          requestTimeout: const Duration(milliseconds: 20),
          client: MockClient((r) async {
        if (r.url.path.isEmpty || r.url.path == '/loop') {
          browserCalls++;
          if (stall) return pending.future;
          return http.Response('', 302, headers: {'location': '/loop'});
        }
        return http.Response('', 404);
      }));
      addTearDown(api.dispose);
      await expectLater(api.authenticate(), throwsA(isA<PortalException>()));
      expect(browserCalls, stall ? 1 : 4);
      if (stall) pending.complete(http.Response('', 503));
    }
  });

  test('live paging retries only failed page and reports bounded progress',
      () async {
    final pages = <int>[];
    final progress = <int>[];
    var interrupted = false;
    final api =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      final p = r.url.queryParameters;
      if (p['action'] == 'handshake') return js({'token': 'fixture'});
      if (p['action'] == 'get_profile') return js({'status': 0});
      if (p['action'] == 'get_all_channels') return http.Response('', 404);
      final page = int.parse(p['p']!);
      pages.add(page);
      if (page == 100 && !interrupted) {
        interrupted = true;
        return http.Response('', 503);
      }
      return js({
        'total_items': 2800,
        'data': List.generate(14, (i) => portalRow('${(page - 1) * 14 + i}'))
      });
    }));
    addTearDown(api.dispose);
    final result =
        await api.getLiveStreams(categoryNames: {}, onProgress: progress.add);
    expect(result, hasLength(2800));
    expect(result.map((c) => c.id).toSet(), hasLength(2800));
    expect(pages, [
      ...List.generate(100, (i) => i + 1),
      ...List.generate(101, (i) => i + 100)
    ]);
    expect(progress.first, 14);
    expect(progress.last, 2800);
    expect(progress.length, lessThan(20));
  });

  test(
      'persistent live-page failure retries once, library failure does not retry',
      () async {
    for (final live in [true, false]) {
      var pages = 0;
      final api =
          StalkerPortalService(portalProfile(), client: MockClient((r) async {
        final action = r.url.queryParameters['action'];
        if (action == 'handshake') return js({'token': 'fixture'});
        if (action == 'get_profile') return js({'status': 0});
        if (action == 'get_all_channels') return http.Response('', 404);
        pages++;
        return http.Response('', 503);
      }));
      addTearDown(api.dispose);
      await expectLater(
          live
              ? api.getLiveStreams(categoryNames: {})
              : api.getVodStreams('1', 'Movies'),
          throwsA(isA<PortalException>()));
      expect(pages, live ? 2 : 1);
    }
  });

  test(
      'partial bulk response does not restart paging after a malformed later page',
      () async {
    final pages = <int>[];
    final api =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      final p = r.url.queryParameters;
      if (p['action'] == 'handshake') return js({'token': 'fixture'});
      if (p['action'] == 'get_profile') return js({'status': 0});
      if (p['action'] == 'get_all_channels') {
        return js({
          'total_items': 4,
          'data': [portalRow('1')]
        });
      }
      final page = int.parse(p['p']!);
      pages.add(page);
      if (page == 1) {
        return js({
          'total_items': 4,
          'data': [portalRow('1'), portalRow('2')]
        });
      }
      return http.Response('<html>Failed</html>', 200);
    }));
    addTearDown(api.dispose);
    await expectLater(
        api.getLiveStreams(categoryNames: {}), throwsA(isA<PortalException>()));
    expect(pages, [1, 2]);
  });

  test('malformed and rate-limited live pages are not retried', () async {
    for (final status in [200, 429]) {
      var pages = 0;
      final api =
          StalkerPortalService(portalProfile(), client: MockClient((r) async {
        final action = r.url.queryParameters['action'];
        if (action == 'handshake') return js({'token': 'fixture'});
        if (action == 'get_profile') return js({'status': 0});
        if (action == 'get_all_channels') return http.Response('', 404);
        pages++;
        return http.Response('<html>Unavailable</html>', status);
      }));
      addTearDown(api.dispose);
      await expectLater(api.getLiveStreams(categoryNames: {}),
          throwsA(isA<PortalException>()));
      expect(pages, 1);
    }
  });
}
