// Optional offline audit of a sanitized guide export from tv_replay_audit.dart.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';

class _AuditGuide extends EpgService {
  _AuditGuide(super.storage, this.rows);
  final List<EpgProgram> rows;
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime at) => rows;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const path = String.fromEnvironment('REPLAY_AUDIT_INPUT');
  const output = String.fromEnvironment('REPLAY_AUDIT_OUTPUT');
  test('audit cached guide locally without network', () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final data = jsonDecode(await File(path).readAsString()) as Map;
      final programmes = <EpgProgram>[];
      final channels = <Channel>[];
      final classified = <Map<String, Object?>>[];
      for (final row in data['rows']) {
        final p = EpgProgram(
            channelId: row['channelId'],
            title: row['title'][0]['text'],
            description: row['desc']?[0]['text'],
            start: DateTime.parse(row['start']),
            stop: DateTime.parse(row['stop']),
            isLive: row['live'] != null);
        programmes.add(p);
        for (final c in row['channels']) {
          final id = 'audit${channels.length}';
          final channel = Channel(
              id: id,
              rawId: id,
              playlistId: 'audit',
              epgIdOverride: p.channelId,
              name: c['name'],
              group: c['group'],
              url: 'https://example.invalid/no-stream');
          channels.add(channel);
          final replay =
              classifySportsReplay(p, channel: channel, allowLikely: true);
          final highlight = classifySportsHighlights(p, channel: channel);
          if (classified.isEmpty ||
              classified.last['channelId'] != p.channelId) {
            classified.add({
              'channelId': p.channelId,
              'channel': channel.name,
              'group': channel.group,
              'title': p.title,
              'description': p.description,
              'live': p.isLive,
              'replay': replay?.evidence.name,
              'sport': replay?.sport,
              'highlight': highlight?.sport
            });
          }
        }
      }
      final guide = _AuditGuide(storage, programmes);
      try {
        final service = SportsReplayService(guide);
        final timer = Stopwatch()..start();
        final snapshot = await service.load(channels,
            revision: 1, at: DateTime.parse(data['at']));
        final cold = timer.elapsedMicroseconds;
        timer.reset();
        final warm = await service.load(channels,
            revision: 1, at: DateTime.parse(data['at']), force: true);
        expect(warm.events.map((e) => e.title),
            snapshot.events.map((e) => e.title));
        Map<String, Object?> event(SportsReplay e) => {
              'title': e.title,
              'sport': e.sport,
              'evidence': e.evidence.name,
              'channels': e.broadcasts.map((b) => b.channel.name).toList(),
              'channelId': e.broadcasts.first.programme.channelId,
            };
        final report = {
          'at': data['at'],
          'slots': programmes.length,
          'channels': channels.length,
          'withGuide': snapshot.channelsWithGuide,
          'coldUs': cold,
          'warmUs': timer.elapsedMicroseconds,
          'replays': snapshot.events.map(event).toList(),
          'highlights': snapshot.highlights.map(event).toList(),
          'rows': classified
        };
        await File(output).writeAsString(jsonEncode(report));
        // ignore: avoid_print
        print(
            'Replay audit: ${programmes.length} slots, ${snapshot.events.length} replay candidates, ${snapshot.highlights.length} highlights; cold ${cold ~/ 1000} ms');
      } finally {
        guide.dispose();
      }
    },
        createHttpClient: (_) =>
            throw StateError('Network forbidden in guide audit'));
  }, skip: path.isEmpty ? 'Optional private sanitized guide fixture' : false);
}
