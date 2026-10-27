import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/m3u_parser.dart';

void main() {
  test('commas in metadata and channel names preserve inactive event prefixes',
      () {
    final channels = M3uParser.parse('''#EXTM3U
#EXTINF:-1 tvg-id="soccer1" tvg-logo="https://example.invalid/logo,a.png" group-title="Sports, Events",End | Pertamina Grand Prix of Indonesia, Sprint Race | US: SOCCER PPV 1
https://example.invalid/live/1
#EXTINF:-1 tvg-id="nbc" group-title="Local",NBC 2 (WGRZ) BUFFALO, NY (D)
https://example.invalid/live/2
#EXTINF:-1 tvg-id="espn" group-title="Sports",NEXT | SAT, 10/10 - ESPN FC | US: ESPN+ PPV 160
https://example.invalid/live/3
#EXTINF:-1 tvg-id="plain",ESPN HD
https://example.invalid/live/4
''', playlistId: 'test');
    expect(channels.map((c) => c.name), [
      'End | Pertamina Grand Prix of Indonesia, Sprint Race | US: SOCCER PPV 1',
      'NBC 2 (WGRZ) BUFFALO, NY (D)',
      'NEXT | SAT, 10/10 - ESPN FC | US: ESPN+ PPV 160',
      'ESPN HD',
    ]);
    expect(channels.first.epgId, 'soccer1');
    expect(channels.first.group, 'Sports, Events');
    expect(channels.first.logoUrl, 'https://example.invalid/logo,a.png');
  });
  test(
      'streamed background import makes one request and preserves all live rows',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.write('#EXTM3U\n');
      for (var i = 0; i < 20000; i++) {
        request.response
            .write('#EXTINF:-1 tvg-id="shared" group-title="TV",Channel $i\n'
                'https://example.invalid/live/fixture/fixture/$i.ts\n');
      }
      await request.response.close();
    });
    try {
      final rows = await M3uParser.fetchAndParse(
          'http://127.0.0.1:${server.port}/playlist',
          playlistId: 'fixture',
          liveOnly: true);
      expect(rows, hasLength(20000));
      expect(rows.first.name, 'Channel 0');
      expect(rows.last.name, 'Channel 19999');
      expect(rows.first.id, 'fixture::shared#0');
      expect(rows.last.id, 'fixture::shared#19999');
      expect(rows.last.epgId, 'shared');
      expect(requests, 1);
    } finally {
      await server.close(force: true);
    }
  });
}
