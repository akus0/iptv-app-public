import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/stalker_portal_service.dart';

PlaylistProfile portalProfile(
        {String url = 'https://portal.example.test/c/'}) =>
    PlaylistProfile(
        id: 'portal-fixture',
        name: 'Portal fixture',
        mode: 'stalker',
        portalUrl: url,
        portalMac: '00:1A:79:12:34:56',
        sortOrder: 0,
        createdAt: DateTime(2026));
http.Response js(Object? value) =>
    http.Response(jsonEncode({'js': value}), 200);
Map<String, Object> portalRow(String id,
        {bool temporary = true, String? cmd}) =>
    {
      'id': id,
      'name': 'Channel $id',
      'tv_genre_id': '10',
      'cmd': cmd ?? 'ffmpeg http://localhost/ch/$id',
      'use_http_tmp_link': temporary ? 1 : 0,
      'use_load_balancing': 0,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'profile-first login supports the second auth step and rejects blocked accounts',
      () async {
    final actions = <String>[];
    var blocked = false;
    final client = StalkerPortalService(
        portalProfile().copyWith(
            portalUsername: 'fixture-user',
            portalPassword: 'fixture-password'), client: MockClient((r) async {
      final action = r.url.queryParameters['action']!;
      actions.add(action);
      if (action == 'handshake') return js({'token': 't'});
      if (action == 'do_auth') return js(true);
      if (blocked) return js({'status': 1, 'msg': 'provider-private-message'});
      return js(
          {'status': r.url.queryParameters['auth_second_step'] == '1' ? 0 : 2});
    }));
    addTearDown(client.dispose);
    await client.authenticate();
    expect(actions, ['handshake', 'get_profile', 'do_auth', 'get_profile']);
    blocked = true;
    final rejected = StalkerPortalService(portalProfile(),
        client: MockClient((r) async =>
            r.url.queryParameters['action'] == 'handshake'
                ? js({'token': 't'})
                : js({'status': 1, 'msg': 'provider-private-message'})));
    addTearDown(rejected.dispose);
    await expectLater(
        rejected.authenticate(),
        throwsA(isA<PortalException>()
            .having((e) => e.authentication, 'account rejection', true)
            .having((e) => e.toString(), 'redacted',
                isNot(contains('provider-private-message')))));
  });

  test(
      'canonical redirects retain request and portal identity on the same server',
      () async {
    final calls = <Uri>[];
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      calls.add(r.url);
      expect(r.headers['cookie'], contains('mac=00:1A:79:12:34:56;'));
      if (r.url.path == '/server/load.php') {
        return http.Response('', 302, headers: {
          'location': r.url.replace(path: '/portal.php').toString(),
        });
      }
      if (r.url.queryParameters['action'] == 'handshake') {
        return js({'token': 'session'});
      }
      expect(r.headers['authorization'], 'Bearer session');
      return js({'status': 0});
    }));
    addTearDown(client.dispose);
    await client.authenticate();
    expect(calls.length, 3);
    expect(calls.last.queryParameters['action'], 'get_profile');
  });

  test('cross-server redirects and HTTPS downgrade never forward credentials',
      () async {
    for (final location in [
      'https://different.example.test/portal.php',
      'http://portal.example.test/portal.php',
      'https://portal.example.test:9443/portal.php'
    ]) {
      var calls = 0;
      final client =
          StalkerPortalService(portalProfile(), client: MockClient((r) async {
        calls++;
        return http.Response('', 302, headers: {'location': location});
      }));
      addTearDown(client.dispose);
      await expectLater(client.authenticate(), throwsA(isA<PortalException>()));
      expect(calls, 1);
    }
  });

  test(
      'HTTPS upgrade is reused and relative playback credentials stay on the verified origin',
      () async {
    final requests = <Uri>[];
    final client = StalkerPortalService(
        portalProfile(url: 'http://portal.example.test/c/'),
        client: MockClient((r) async {
      requests.add(r.url);
      if (r.url.scheme == 'http') {
        return http.Response('', 301,
            headers: {'location': r.url.replace(scheme: 'https').toString()});
      }
      switch (r.url.queryParameters['action']) {
        case 'handshake':
          return js({'token': 'session'});
        case 'get_profile':
          return js({'status': 0});
        case 'get_genres':
          return js([
            {'id': '10', 'title': 'Sports'}
          ]);
        case 'get_all_channels':
          return js({
            'data': [portalRow('1')]
          });
        case 'create_link':
          return js({'cmd': 'ffmpeg /stream/channel'});
        default:
          throw StateError('Unexpected action');
      }
    }));
    addTearDown(client.dispose);
    final channels =
        await client.getLiveStreams(categoryNames: {'10': 'Sports'});
    final resolved = await client.resolve(channels.single);
    expect(requests.where((u) => u.scheme == 'http').length, 1);
    expect(resolved.url, 'https://portal.example.test/stream/channel');
    expect(resolved.httpHeaders['Authorization'], 'Bearer session');
  });

  test('redirect loops stop after three hops', () async {
    var calls = 0;
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      calls++;
      return http.Response('', 302, headers: {'location': r.url.toString()});
    }));
    addTearDown(client.dispose);
    await expectLater(client.authenticate(), throwsA(isA<PortalException>()));
    expect(calls, 4);
  });

  test('a stalled transport has a deadline and can be retried', () async {
    final pending = Completer<http.Response>();
    final client = StalkerPortalService(portalProfile(),
        requestTimeout: const Duration(milliseconds: 20),
        client: MockClient((r) => pending.future));
    addTearDown(client.dispose);
    await expectLater(client.authenticate(), throwsA(isA<PortalException>()));
    pending.complete(http.Response('offline', 503));
    await Future<void>.delayed(Duration.zero);
  });

  test(
      'MAC-only panels require a verified catalogue and reuse that first response',
      () async {
    final actions = <String>[];
    final client = StalkerPortalService(
        portalProfile(url: 'https://portal.example.test/portal.php'),
        client: MockClient((r) async {
      final action = r.url.queryParameters['action']!;
      actions.add(action);
      expect(r.headers.containsKey('authorization'), false);
      if (action == 'handshake') return js(null);
      return js([
        {'id': '10', 'title': 'Sports'}
      ]);
    }));
    addTearDown(client.dispose);
    expect((await client.getLiveCategories()).single.name, 'Sports');
    expect(actions, ['handshake', 'get_genres']);
  });

  test('separately listed episodes look up their own file before create_link',
      () async {
    final actions = <String>[];
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      final p = r.url.queryParameters;
      actions.add(p['action']!);
      if (p['action'] == 'handshake') return js({'token': 't'});
      if (p['action'] == 'get_profile') return js({'status': 0});
      if (p['action'] == 'create_link') {
        expect(p['cmd'], 'ffmpeg /episode-two');
        return js({'cmd': 'https://stream.example.test/two'});
      }
      if (p['season_id'] == '0') {
        return js({
          'total_items': 1,
          'data': [
            {
              'id': 'season-one',
              'name': 'Season 1',
              'cmd': 'wrong-parent-command'
            }
          ]
        });
      }
      if (p['episode_id'] == '0') {
        return js({
          'total_items': 1,
          'data': [
            {'id': 'episode-two', 'episode_number': 2, 'name': 'Second episode'}
          ]
        });
      }
      expect(p['movie_id'], '72');
      expect(p['season_id'], 'season-one');
      expect(p['episode_id'], 'episode-two');
      return js({
        'data': [
          {'id': 'file-two', 'cmd': 'ffmpeg /episode-two'}
        ]
      });
    }));
    addTearDown(client.dispose);
    final episodes = await client.getSeriesEpisodes(72, 'Series');
    expect(actions,
        ['handshake', 'get_profile', 'get_ordered_list', 'get_ordered_list']);
    final playable = await client.resolve(episodes.episodes[1]!.single);
    expect(playable.url, 'https://stream.example.test/two');
    expect(actions.last, 'create_link');
  });

  test('URL and MAC validation preserves configured portal path', () {
    expect(normalizePortalMac('00-1a-79-12-34-56'), '00:1A:79:12:34:56');
    expect(
        portalEndpoints('https://example.test/stalker_portal/c/')
            .map((u) => u.path),
        ['/stalker_portal/server/load.php', '/stalker_portal/portal.php']);
    expect(portalEndpoints('https://example.test/custom/api.php').single.path,
        '/custom/api.php');
    for (final bad in [
      'http://',
      'file:///portal',
      'https://user:secret@example.test/c/',
      'https://example.test/c/?token=secret'
    ]) {
      expect(() => portalEndpoints(bad), throwsA(isA<PortalException>()));
    }
    expect(
        () => normalizePortalMac('incorrect'), throwsA(isA<PortalException>()));
    final roundTrip = PlaylistProfile.fromJson(
        portalProfile().copyWith(portalSerial: 'fixture-serial').toJson());
    expect(roundTrip.hasCatalog, true);
    expect(roundTrip.isXtream, false);
    expect(roundTrip.portalSerial, 'fixture-serial');
  });

  test('one handshake serves concurrent callers; API work is capped at two',
      () async {
    var handshakes = 0, active = 0, peak = 0;
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      expect(r.followRedirects, false);
      expect(r.headers['cookie'], contains('mac=00:1A:79:12:34:56'));
      final action = r.url.queryParameters['action'];
      if (action == 'handshake') {
        handshakes++;
        return js({'token': 'fixture-session'});
      }
      expect(r.headers['authorization'], 'Bearer fixture-session');
      if (action == 'get_profile') {
        expect(r.url.queryParameters['sn'], '0000000000000');
        expect(r.url.queryParameters['num_banks'], '1');
        expect(r.url.queryParameters['hw_version'], '1.7-BD-00');
        expect(r.headers['referer'], 'https://portal.example.test/c/');
        return js({'id': 'fixture'});
      }
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
      return js([
        {'id': '10', 'title': 'Sports'}
      ]);
    }));
    addTearDown(client.dispose);
    await Future.wait(List.generate(12, (_) => client.getLiveCategories()));
    expect(handshakes, 1);
    expect(peak, 2);
  });

  test(
      'endpoint fallback stays on portal path; provider identities are forwarded only when supplied',
      () async {
    final seen = <String>[];
    final client = StalkerPortalService(
        portalProfile().copyWith(
            portalSerial: 'fixture',
            portalDeviceId: 'device-fixture'), client: MockClient((r) async {
      seen.add(r.url.path);
      if (r.url.path.endsWith('server/load.php')) return http.Response('', 404);
      if (r.url.queryParameters['action'] == 'handshake') {
        return js({'token': 't'});
      }
      expect(r.url.queryParameters['sn'], 'fixture');
      expect(r.url.queryParameters['device_id'], 'device-fixture');
      expect(r.url.queryParameters.containsKey('device_id2'), false);
      return js({'id': 'fixture'});
    }));
    addTearDown(client.dispose);
    await client.authenticate();
    expect(seen, ['/server/load.php', '/portal.php', '/portal.php']);
  });

  test(
      'expired session renews once; repeated rejection is bounded and redacted',
      () async {
    var handshakes = 0, genreCalls = 0;
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      switch (r.url.queryParameters['action']) {
        case 'handshake':
          return js({'token': 't${++handshakes}'});
        case 'get_profile':
          return js({'id': 'fixture'});
        default:
          genreCalls++;
          return http.Response('Authorization failed.', 200);
      }
    }));
    addTearDown(client.dispose);
    await expectLater(
        client.getLiveCategories(),
        throwsA(isA<PortalException>()
            .having((e) => e.authentication, 'authentication', true)));
    expect(handshakes, 2);
    expect(genreCalls, 2);
  });

  test(
      'commands persist; only chosen channel resolves; external streams receive no portal credentials',
      () async {
    var links = 0;
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      switch (r.url.queryParameters['action']) {
        case 'handshake':
          return js({'token': 'private-fixture-token'});
        case 'get_profile':
          return js({'id': 'fixture'});
        case 'get_all_channels':
          return js({
            'data': [portalRow('1'), portalRow('2')]
          });
        case 'create_link':
          links++;
          expect(r.url.queryParameters['cmd'], 'ffmpeg http://localhost/ch/2');
          return js({
            'cmd': 'ffmpeg https://stream.example.test/live/2?play_token=$links'
          });
        default:
          throw StateError('Unexpected request');
      }
    }));
    addTearDown(client.dispose);
    final channels =
        await client.getLiveStreams(categoryNames: {'10': 'Sports'});
    expect(links, 0);
    expect(channels.map((c) => c.epgId),
        ['stalker:portal-fixture:1', 'stalker:portal-fixture:2']);
    final original = channels[1];
    final decoded = Channel.fromJson(original.toJson());
    final first = await client.resolve(decoded);
    final second = await client.resolve(decoded);
    expect(links, 2);
    expect(first.url, isNot(second.url));
    expect(first.httpHeaders.containsKey('Cookie'), false);
    expect(first.httpHeaders.containsKey('Authorization'), false);
    expect(decoded.url, startsWith('stalker:'));
    expect(
        original.toJson().toString(), isNot(contains('private-fixture-token')));
    expect(Channel.fromJson(first.toJson()).httpHeaders, isEmpty);
  });

  test(
      'known static external streams open with zero portal requests on cached startup',
      () async {
    var requests = 0;
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      requests++;
      throw StateError('No request expected');
    }));
    addTearDown(client.dispose);
    final channel = Channel(
        id: 'portal-fixture::st_live_1',
        rawId: 'st_live_1',
        playlistId: 'portal-fixture',
        name: 'Static',
        group: 'TV',
        url: Uri(scheme: 'stalker', host: 'play', queryParameters: {
          'type': 'itv',
          'cmd': 'https://stream.example.test/live',
          'static': '1'
        }).toString());
    expect((await client.resolve(channel)).url,
        'https://stream.example.test/live');
    expect(requests, 0);
  });

  test(
      'relative created links use portal origin and authenticated playback headers',
      () async {
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      switch (r.url.queryParameters['action']) {
        case 'handshake':
          return js({'token': 'fixture-token'});
        case 'get_profile':
          return js({'id': 'fixture'});
        case 'create_link':
          return js({'cmd': 'ffmpeg /stream/one?token=fixture'});
        default:
          throw StateError('Unexpected request');
      }
    }));
    addTearDown(client.dispose);
    final c = Channel(
        id: 'portal-fixture::st_live_1',
        rawId: 'st_live_1',
        playlistId: 'portal-fixture',
        name: 'Test',
        group: 'TV',
        url: Uri(scheme: 'stalker', host: 'play', queryParameters: {
          'type': 'itv',
          'cmd': 'ffmpeg http://localhost/ch/1'
        }).toString());
    final resolved = await client.resolve(c);
    expect(
        resolved.url, 'https://portal.example.test/stream/one?token=fixture');
    expect(resolved.httpHeaders['Authorization'], 'Bearer fixture-token');
    expect(resolved.httpHeaders.containsKey('Accept'), false);
  });

  test('paged fallback covers catalogue and rejects repeating/incomplete pages',
      () async {
    var repeat = false;
    final pages = <int>[];
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      switch (r.url.queryParameters['action']) {
        case 'handshake':
          return js({'token': 't'});
        case 'get_profile':
          return js({'id': 'fixture'});
        case 'get_all_channels':
          return http.Response('', 404);
        default:
          final p = int.parse(r.url.queryParameters['p']!);
          pages.add(p);
          return js({
            'total_items': 3,
            'data': p == 1 || repeat
                ? [portalRow('1'), portalRow('2')]
                : [portalRow('3')]
          });
      }
    }));
    addTearDown(client.dispose);
    expect(await client.getLiveStreams(categoryNames: {}), hasLength(3));
    expect(pages, [1, 2]);
    repeat = true;
    pages.clear();
    await expectLater(client.getLiveStreams(categoryNames: {}),
        throwsA(isA<PortalException>()));
    expect(pages, [1, 2]);
  });

  test(
      'guide is one bulk request, namespaced, timestamp based and independent of channel resolution',
      () async {
    final actions = <String>[];
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      final a = r.url.queryParameters['action']!;
      actions.add(a);
      if (a == 'handshake') return js({'token': 't'});
      if (a == 'get_profile') return js({'id': 'fixture'});
      expect(a, 'get_epg_info');
      expect(r.url.queryParameters['period'], '24');
      return js({
        'data': {
          '1': [
            {
              'start_timestamp': '1793500000',
              'stop_timestamp': 1793503600,
              'name': 'Live fixture',
              'descr': 'Fixture description'
            },
            {'name': 'Invalid time'}
          ]
        }
      });
    }));
    addTearDown(client.dispose);
    final rows = await client.guideRows();
    expect(rows, hasLength(1));
    expect(rows.single.channelId, 'stalker:portal-fixture:1');
    expect(rows.single.description, 'Fixture description');
    expect(actions, ['handshake', 'get_profile', 'get_epg_info']);
  });

  test(
      'movie and series catalogues load only requested categories, episodes resolve on selection',
      () async {
    final seen = <Map<String, String>>[];
    final client =
        StalkerPortalService(portalProfile(), client: MockClient((r) async {
      final p = r.url.queryParameters;
      seen.add(p);
      if (p['action'] == 'handshake') return js({'token': 't'});
      if (p['action'] == 'get_profile') return js({'id': 'fixture'});
      if (p['action'] == 'create_link') {
        expect(p['series'], '2');
        return js({'cmd': 'https://stream.example.test/ep2'});
      }
      if (p['type'] == 'vod') {
        return js({
          'total_items': 1,
          'data': [
            {'id': '91', 'name': 'Movie', 'cmd': 'ffmpeg /media/file_91.mpg'}
          ]
        });
      }
      if (p['movie_id'] == '72') {
        return js({
          'total_items': 1,
          'data': [
            {
              'id': 'season-1',
              'name': 'Season 1',
              'cmd': 'ffmpeg /media/file_72.mpg',
              'series': [1, 2]
            }
          ]
        });
      }
      return js({
        'total_items': 1,
        'data': [
          {'id': '72', 'name': 'Series'}
        ]
      });
    }));
    addTearDown(client.dispose);
    final movies = await client.getVodStreams('5', 'Movies');
    expect(Channel.isLiveId(movies.single.rawId), false);
    final series = await client.getSeriesForCategory('7');
    expect(series.single.seriesId, 72);
    final episodes = await client.getSeriesEpisodes(72, 'Series');
    expect(episodes.episodes[1], hasLength(2));
    expect(seen.any((p) => p['action'] == 'create_link'), false);
    expect((await client.resolve(episodes.episodes[1]!.last)).url,
        'https://stream.example.test/ep2');
    expect(
        seen.where((p) => p.containsKey('category')).map((p) => p['category']),
        ['5', '7']);
  });
}
