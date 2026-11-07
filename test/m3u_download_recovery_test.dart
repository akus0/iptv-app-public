import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/playlist_failure.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_test.dart' show MemoryDb, MemoryStorage, movie;

class _Storage extends MemoryStorage {
  final writes = <String, String>{};
  @override
  Future<void> writeCacheFile(String name, String contents) async {
    writes[name] = contents;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('interrupted HTTP body keeps the previous catalogue and cache intact',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final sockets = <Socket>[];
    const body = '#EXTM3U\n#EXTINF:-1 tvg-id="new",New channel\n'
        'https://example.invalid/live/new\n';
    server.listen((socket) {
      sockets.add(socket);
      var replied = false;
      socket.listen((_) {
        if (replied) return;
        replied = true;
        requests++;
        // Deliberately close a response before its advertised length.
        socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 10000\r\n'
            'Connection: close\r\n\r\n$body'));
        unawaited(socket.close());
      });
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    SharedPreferences.setMockInitialValues({});
    final storage = _Storage();
    await storage.init();
    final session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'one',
            name: 'One',
            mode: 'm3u',
            sortOrder: 0,
            createdAt: DateTime(2026)),
        storage: storage,
        catalogDb: MemoryDb(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        onNotify: () {});
    final saved = movie(9);
    session.liveChannels = [saved];
    await session.loadFromUrl('http://127.0.0.1:${server.port}/playlist');
    expect(requests, 1);
    expect(session.liveChannels.single, same(saved));
    expect(storage.writes, isEmpty);
    expect(session.loadFailure?.stage, PlaylistFailureStage.download);
    expect(session.error, isNotNull);
    expect(session.isLoading, false);
    expect(session.loadingPhase, isNull);
  });

  test(
      'worker progress is bounded, finishes cleanly and retains configured headers',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seenAgents = <String?>[];
    var bytes = 0;
    server.listen((request) async {
      seenAgents.add(request.headers.value('user-agent'));
      request.response.bufferOutput = false;
      for (var i = 0; i < 12; i++) {
        final entry = utf8.encode('#EXTINF:-1 tvg-id="c$i",日本 $i\n'
            'https://example.invalid/live/$i\n');
        bytes += entry.length;
        request.response.add(entry);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 110));
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final progress = <int>[];
    final channels = await M3uParser.fetchAndParse(
        'http://127.0.0.1:${server.port}/playlist',
        playlistId: 'one',
        headers: const {'User-Agent': 'FixturePlayer/1'},
        onProgress: progress.add);
    expect(channels, hasLength(12));
    expect(seenAgents, ['FixturePlayer/1']);
    expect(progress.length, inInclusiveRange(2, 3));
    expect(progress, orderedEquals([...progress]..sort()));
    expect(progress.last, bytes);
    final reports = progress.length;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(progress.length, reports);
  });
}
