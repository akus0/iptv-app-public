import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:nox_iptv/models/playlist_failure.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/m3u_parser.dart';

void main() {
  test('attribute scanner preserves legacy results on malformed metadata', () {
    final legacy = RegExp(r'([a-zA-Z0-9_-]+)="([^"]*)"');
    final random = Random(142);
    const fragments = [
      'tvg-id="one"',
      'TVG-ID="two"',
      'group-title="日本, 한국"',
      'tvg-logo="https://example.invalid/a,b?c=d"',
      'tvg-id=""',
      'tvg_id="x"',
      'a-b="v"',
      'ékey="value"',
      'a="x=y"',
      'broken="unterminated',
      '="orphan"',
      'a=""b="c"',
      'no=quotes',
      "single='value'",
      ' spaced = "ignored" ',
      '"',
      '=',
      '-',
      '_',
      ' ',
      ',',
      '1="2"',
      '😀',
    ];
    for (var i = 0; i < 12000; i++) {
      final fields = List.generate(1 + random.nextInt(12),
          (_) => fragments[random.nextInt(fragments.length)]).join('');
      final line = '#EXTINF:-1 $fields';
      final expected = <String, String>{
        for (final match in legacy.allMatches(line))
          match[1]!.toLowerCase(): match[2]!,
      };
      expect(M3uParser.attributesOf(line), expected, reason: line);
    }
  });

  test('active bytes reset the timeout even without a complete line', () async {
    final stream = StreamController<List<int>>();
    final progress = <int>[];
    final result = M3uParser.parseStream(stream.stream,
        playlistId: 'slow',
        onProgress: progress.add,
        stallTimeout: const Duration(milliseconds: 400));
    var finished = false;
    result.then((_) => finished = true);
    stream.add(utf8.encode('#EXTM3U\n#EXTINF:-1 tvg-id="x",日本'));
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stream.add(utf8.encode('語'));
      expect(finished, false);
    }
    stream.add(utf8.encode('\nhttps://example.invalid/live/1\n'));
    await stream.close();
    final rows = await result;
    expect(rows.single.name, '日本${List.filled(8, '語').join()}');
    expect(progress.last, greaterThan(progress.first));
  });

  for (final partial in [false, true]) {
    test('silent download fails and cancels subscription (partial=$partial)',
        () async {
      var cancelled = false;
      final stream =
          StreamController<List<int>>(onCancel: () => cancelled = true);
      final result = M3uParser.parseStream(stream.stream,
          playlistId: 'stalled',
          stallTimeout: const Duration(milliseconds: 30));
      final failed = expectLater(
          result,
          throwsA(isA<PlaylistRequestException>().having(
              (e) => e.reason, 'reason', PlaylistFailureReason.timeout)));
      if (partial) {
        stream.add(utf8.encode(
            '#EXTM3U\n#EXTINF:-1,Partial\nhttps://example.invalid/live/1\n'));
      }
      await failed;
      expect(cancelled, true);
      await stream.close();
    });
  }

  test('split UTF-8, CRLF, fallbacks and live-only filtering survive streaming',
      () async {
    final bytes = utf8.encode('#EXTM3U\r\n'
        '#EXTINF:-1 tvg-id="same",日本語\r\n#EXTGRP:国際\r\n'
        '#EXTVLCOPT:sub-file=https://example.invalid/a?x=y\r\n'
        'https://example.invalid/live/a/b/1.ts\r\n'
        '#EXTINF:-1 tvg-id="same",한국\r\nhttps://example.invalid/live/a/b/2.ts\r\n'
        '#EXTINF:-1,Movie\r\nhttps://example.invalid/movie/a/b/3.mp4\r\n');
    final progress = <int>[];
    final rows = await M3uParser.parseStream(
        Stream.fromIterable(bytes.map((b) => [b])),
        playlistId: 'split',
        liveOnly: true,
        onProgress: progress.add);
    expect(rows.map((c) => c.name), ['日本語', '한국']);
    expect(rows.first.group, '国際');
    expect(rows.first.subtitleUrl, 'https://example.invalid/a?x=y');
    expect(rows.map((c) => c.id).toSet(), hasLength(2));
    expect(progress.last, bytes.length);
    expect(progress.length, lessThanOrEqualTo(3));
  });

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
