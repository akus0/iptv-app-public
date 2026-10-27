import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';

class _ReviewGuide extends EpgService {
  _ReviewGuide(super.storage, this.programmes);
  final List<EpgProgram> programmes;
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime at) =>
      programmes.where((p) => p.isNowPlaying(at));
}

void main() {
  const path = String.fromEnvironment('REPLAY_REVIEW_GUIDE_FILE');
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'second saved-guide time slot: missed sports, highlights, duplicates and dates',
      () async {
    await HttpOverrides.runZoned(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final data = jsonDecode(await File(path).readAsString()) as Map;
      final rows = data['rows'] as List;
      final channels = <Channel>[];
      final programmes = <EpgProgram>[];
      for (final row in rows) {
        programmes.add(EpgProgram(
            channelId: row['channelId'],
            title: row['title'][0]['text'],
            description: row['desc']?[0]['text'],
            start: DateTime.parse(row['start']),
            stop: DateTime.parse(row['stop']),
            isLive: row['live'] != null));
        for (final c in row['channels']) {
          final id = 'review${channels.length}';
          channels.add(Channel(
              id: 'review::$id',
              rawId: id,
              playlistId: 'review',
              name: c['name'],
              group: c['group'],
              epgIdOverride: row['channelId'],
              url: 'https://example.test/no-stream'));
        }
      }
      final guide = _ReviewGuide(storage, programmes);
      try {
        final service = SportsReplayService(guide);
        final timer = Stopwatch()..start();
        final snapshot = await service.load(channels,
            revision: 1, at: DateTime.parse(data['at']));
        final firstMs = timer.elapsedMilliseconds;
        timer.reset();
        final refreshed = await service.load(channels,
            revision: 1, at: DateTime.parse(data['at']), force: true);
        final refreshMs = timer.elapsedMilliseconds;
        expect(refreshed.events.map((e) => e.title),
            snapshot.events.map((e) => e.title));
        expect(refreshed.highlights.map((e) => e.title),
            snapshot.highlights.map((e) => e.title));
        // ignore: avoid_print
        print(
            'Real saved guide: first $firstMs ms, unchanged forced refresh $refreshMs ms.');
        final events = snapshot.events;
        final highlights = snapshot.highlights;
        for (final title in [
          'NFL Panthers',
          'U.S. F1',
          'SA v AUS Hlts',
          'Phoenix v Melbourne City Hls',
          'Archery Highlights',
          'PADEL:',
          'On the Fly',
          'Full Court'
        ]) {
          expect(highlights.any((e) => e.title.contains(title)), true,
              reason: title);
        }
        expect(
            highlights.any((e) =>
                RegExp('SportsCenter|SportsCentre|News|Upcoming|Champions Club')
                    .hasMatch(e.title)),
            false);
        expect(highlights.every((e) => e.eventDate == null), true);
        expect(
            highlights
                .map((e) => e.id)
                .toSet()
                .intersection(events.map((e) => e.id).toSet()),
            isEmpty);
        // ignore: avoid_print
        print('Saved-guide highlights: ${highlights.length} programmes.');
        expect(events.any((e) => e.title.contains('Super Lig')), true);
        expect(events.any((e) => e.title.contains('FIBA 3x3')), true);
        expect(events.any((e) => e.title.contains('EPCR Challenge Cup')), true);
        expect(events.any((e) => e.title.contains('Sudamericana')), true);
        final condensed =
            events.firstWhere((e) => e.title.contains('Kansas State'));
        expect(condensed.sport, 'football');
        expect(condensed.eventDate?.label, '26 Sep 2026');
        expect(condensed.evidence, ReplayEvidence.labelled);
        expect(condensed.broadcasts.length, greaterThan(1));
        final raptors =
            events.where((e) => e.title.contains('Raptors in 30')).toList();
        expect(raptors, hasLength(1));
        expect(raptors.single.eventDate?.label, '21 Oct 2026');
        expect(raptors.single.broadcasts.length, greaterThan(1));
        expect(events.where((e) => e.title.contains('Minnesota Timberwolves')),
            hasLength(1));
        expect(events.any((e) => RegExp(r'\b(?:Hlts|Hls)\b').hasMatch(e.title)),
            false);
        expect(
            events
                .expand((e) => e.broadcasts)
                .any((b) => isLiveSportsProgramme(b.programme)),
            false);
        // ignore: avoid_print
        print(
            'Current-period offline audit: ${events.length} listings; ${events.where((e) => e.eventDate != null).length} with date information; ${events.where((e) => e.evidence == ReplayEvidence.likely).length} likely.');
      } finally {
        guide.dispose();
      }
    },
        createHttpClient: (_) =>
            throw StateError('Network forbidden in replay audit'));
  }, skip: path.isEmpty ? 'Optional sanitized current-period guide' : false);
}
