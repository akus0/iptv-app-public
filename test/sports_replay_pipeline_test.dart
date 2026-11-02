import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Guide extends EpgService {
  _Guide(super.storage);
  List<EpgProgram> rows = [];
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime at) =>
      rows.where((p) => p.isNowPlaying(at));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 20, 12);
  EpgProgram slot(int i, String title, {bool live = false}) => EpgProgram(
      channelId: 'c$i',
      title: title,
      description: 'Coverage $i.',
      start: now.subtract(const Duration(minutes: 10)),
      stop: now.add(const Duration(hours: 1)),
      isLive: live);
  List<Channel> channels(int count) => List.generate(
      count,
      (i) => Channel(
          id: 'p::$i',
          rawId: '$i',
          playlistId: 'p',
          name: 'Channel $i',
          group: 'Channels',
          url: '',
          epgIdOverride: 'c$i'));
  late _Guide guide;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    guide = _Guide(storage);
  });
  tearDown(() => guide.dispose());

  test('large current working set reuses negatives and analyses corrections',
      () async {
    final input = channels(6000);
    guide.rows = List.generate(6000, (i) => slot(i, 'Evening programme $i'));
    final service = SportsReplayService(guide, backgroundAnalysis: false);
    expect((await service.load(input, revision: 1, at: now)).events, isEmpty);
    final misses = service.analysisMisses;
    await service.load(input, revision: 1, at: now, force: true);
    expect(service.analysisMisses, misses,
        reason: 'The working set must not thrash at the old 4096-entry limit');
    guide.rows[0] = slot(0, 'NBA: Red vs Blue (Replay)');
    final result = await service.load(input, revision: 1, at: now, force: true);
    expect(result.events.single.sport, 'basketball');
    expect(service.analysisMisses, misses + 1);
    expect(service.analysisEntries, 6000,
        reason: 'Departed programme metadata is released');
  });

  test('worker and local execution agree, with safe cards before completion',
      () async {
    final input = channels(1200);
    guide.rows = List.generate(
        1200,
        (i) => slot(
            i,
            i % 25 == 0
                ? 'NBA: Red $i vs Blue $i (Replay)'
                : i % 25 == 1
                    ? 'Tennis Highlights $i'
                    : 'Evening programme $i'));
    // A live simulcast at the end must suppress a likely replay at the start.
    guide.rows[2] = slot(2, 'NBA: White vs Green');
    guide.rows[1199] = slot(1199, 'NBA: White vs Green', live: true);
    final local = await SportsReplayService(guide, backgroundAnalysis: false)
        .load(input, revision: 1, at: now);
    final service = SportsReplayService(guide);
    final updates = <ReplayScanProgress>[];
    var completed = false;
    final result =
        await service.load(input, revision: 1, at: now, onProgress: (update) {
      expect(completed, false);
      expect(
          update.snapshot.events.any((e) => e.title.contains('White')), false);
      updates.add(update);
    });
    completed = true;
    expect(service.workerBatches, greaterThan(0));
    expect(service.workerFailures, 0);
    expect(updates, isNotEmpty);
    expect(updates.first.checked, lessThan(guide.rows.length));
    expect(updates.first.snapshot.events, isNotEmpty);
    expect(result.events.map((e) => (e.title, e.sport, e.broadcasts.length)),
        local.events.map((e) => (e.title, e.sport, e.broadcasts.length)));
    expect(result.highlights.map((e) => e.title),
        local.highlights.map((e) => e.title));
    final firstIds = updates.first.snapshot.events.map((e) => e.id).toList();
    expect(firstIds.length, lessThan(result.events.length));
    expect(updates.first.snapshot.events.map((e) => e.id), firstIds,
        reason: 'Later batches cannot mutate an already published snapshot');
    final batches = service.workerBatches;
    await service.load(input, revision: 1, at: now, force: true);
    expect(service.workerBatches, batches,
        reason: 'Unchanged scans do not start another worker');
  });
  test('cancelled worker warmup retains safe partials and foreground resumes',
      () async {
    final at = DateTime.now();
    final input = channels(600);
    guide.rows = List.generate(
        600,
        (i) => EpgProgram(
            channelId: 'c$i',
            title: 'NBA Red $i vs Blue $i (Replay)',
            start: at.subtract(const Duration(minutes: 1)),
            stop: at.add(const Duration(minutes: 10))));
    final service = SportsReplayService(guide);
    await service.warm(input,
        revision: 1, cancelled: () => service.workerBatches >= 2);
    expect(service.workerBatches, 2);
    expect(service.peek(revision: 1, at: at), isNull,
        reason: 'An interrupted scan is not a completed cache hit');
    var immediate = false;
    final pending = service.load(input, revision: 1, onProgress: (_) {
      immediate = true;
    });
    expect(immediate, true,
        reason: 'Already discovered cards can be shown immediately');
    final result = await pending;
    expect(result.events, hasLength(600));
    expect(service.workerFailures, 0);
    expect(service.peek(revision: 1), same(result));
  });
}
