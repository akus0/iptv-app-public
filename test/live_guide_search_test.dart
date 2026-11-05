import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/utils/live_guide_search.dart';

Channel channel(String name, String epg) => Channel(
    id: name,
    rawId: name,
    playlistId: 'demo',
    name: name,
    epgKey: epg,
    group: 'TV',
    url: 'https://example.test/live');

void main() {
  test('matches channel names and only current programme titles/descriptions',
      () async {
    final now = DateTime(2026, 10, 21, 20);
    final channels = [
      channel('ABC HD', 'abc'),
      channel('Fox Sports', 'fox'),
      channel('Cinema', 'cinema'),
      channel('Old News', 'old'),
      channel('### Sport ###', 'dummy')
    ];
    EpgProgram? programme(String id) => switch (id) {
          'abc' => EpgProgram(
              channelId: id,
              title: 'The World Today',
              description: 'Live election coverage',
              start: now.subtract(const Duration(minutes: 30)),
              stop: now.add(const Duration(minutes: 30))),
          'cinema' => EpgProgram(
              channelId: id,
              title: 'World Today',
              start: now.add(const Duration(hours: 1)),
              stop: now.add(const Duration(hours: 2))),
          'old' => EpgProgram(
              channelId: id,
              title: 'World Today',
              start: now.subtract(const Duration(hours: 1)),
              stop: now),
          _ => null,
        };
    for (final q in ['WORLD', 'election', 'abc world', 'world today']) {
      expect(
          (await searchLiveGuide(channels, q, programme, now: now))
              .map((c) => c.name),
          ['ABC HD']);
    }
    expect(
        (await searchLiveGuide(channels, 'FOX', programme, now: now))
            .map((c) => c.name),
        ['Fox Sports']);
    expect(await searchLiveGuide(channels, 'missing', programme, now: now),
        isEmpty);
    expect(await searchLiveGuide(channels, ' ', programme, now: now),
        same(channels));
    expect(isGuideSection(channels.last), true);
    expect(guideSectionTitle(channels.last), 'Sport');
  });
  test('80k channels share EPG lookups and yield while searching', () async {
    final channels =
        List.generate(80000, (i) => channel('Channel $i', 'epg${i % 500}'));
    final now = DateTime.now();
    var lookups = 0;
    var ticks = 0;
    final heartbeat = Timer.periodic(Duration.zero, (_) => ticks++);
    final matches = await searchLiveGuide(channels, 'football', (id) {
      lookups++;
      return EpgProgram(
          channelId: id,
          title: id == 'epg4' ? 'Live Football' : 'Other programme',
          start: now.subtract(const Duration(hours: 1)),
          stop: now.add(const Duration(hours: 1)));
    });
    heartbeat.cancel();
    expect(matches, hasLength(160));
    expect(lookups, 500);
    expect(ticks, greaterThan(0));
  });
  test('obsolete searches stop before looking up more channels', () async {
    var lookups = 0;
    expect(
        await searchLiveGuide([channel('ABC', 'abc')], 'news', (_) {
          lookups++;
          return null;
        }, cancelled: () => true),
        isEmpty);
    expect(lookups, 0);
  });
  test('narrowing an 80k search rescans only completed candidates', () async {
    final rows = List.generate(
        80000, (i) => channel(i < 12 ? 'Target $i' : 'Station $i', 'id$i'));
    final session = LiveGuideSearchSession();
    var reads = 0;
    EpgProgram? current(String _) {
      reads++;
      return null;
    }

    final now = DateTime(2026, 10, 24, 12);
    expect(
        await session.search(rows, 'tar', current,
            nextProgram: (_) => null, revision: () => 1, now: now),
        hasLength(12));
    reads = 0;
    final result = await session.search(rows, 'target 1', current,
        nextProgram: (_) => null, revision: () => 1, now: now);
    expect(result.map((c) => c.name), ['Target 1', 'Target 10', 'Target 11']);
    expect(reads, lessThanOrEqualTo(12));
    reads = 0;
    expect(
        await session.search(rows, 'station', current,
            nextProgram: (_) => null, revision: () => 1, now: now),
        hasLength(79988));
    expect(
        reads, greaterThan(0)); // Broader/replaced query scans original input.
  });

  test('narrowing expires at current programme and gap boundaries', () async {
    final rows = [channel('Network', 'network')];
    final session = LiveGuideSearchSession();
    final start = DateTime(2026, 10, 24, 12);
    var clock = start;
    final later = EpgProgram(
        channelId: 'network',
        title: 'Tennis final',
        start: start.add(const Duration(seconds: 1)),
        stop: start.add(const Duration(hours: 1)));
    EpgProgram? current(String _) => clock.isBefore(later.start) ? null : later;
    expect(
        await session.search(rows, 'ten', current,
            nextProgram: (_) => later, revision: () => 1, now: clock),
        isEmpty);
    clock = later.start;
    expect(
        await session.search(rows, 'tennis', current,
            nextProgram: (_) => null, revision: () => 1, now: clock),
        rows);
    final news = EpgProgram(
        channelId: 'network',
        title: 'Tennis news',
        start: later.stop,
        stop: later.stop.add(const Duration(hours: 1)));
    expect(
        await session.search(rows, 'news', (_) => later,
            nextProgram: (_) => news, revision: () => 1, now: clock),
        isEmpty);
    clock = news.start;
    expect(
        await session.search(rows, 'tennis news', (_) => news,
            nextProgram: (_) => null, revision: () => 1, now: clock),
        rows);
  });

  test(
      'guide changes, catalogue changes and clock rollback invalidate narrowing',
      () async {
    final first = [channel('Network', 'network')];
    final session = LiveGuideSearchSession();
    final now = DateTime(2026, 10, 24, 12);
    var revision = 1;
    var reads = 0;
    EpgProgram? current(String _) {
      reads++;
      return null;
    }

    Future<void> search(List<Channel> rows, String q, DateTime clock) async {
      await session.search(rows, q, current,
          nextProgram: (_) => null, revision: () => revision, now: clock);
    }

    await search(first, 'x', now);
    reads = 0;
    await search(first, 'xy', now);
    expect(reads, 0); // Completed empty candidate set is safe to reuse.
    revision++;
    await search(first, 'xyz', now);
    expect(reads, 1);
    final replacement = [...first];
    await search(replacement, 'xyzz', now);
    expect(reads, 2);
    await search(replacement, 'xyzzz', now.subtract(const Duration(seconds: 1)));
    expect(reads, 3);
    session.clear();
    await search(replacement, 'xyzzzz', now);
    expect(reads, 4);
  });

  test('cancelled and changing-guide searches never seed the candidate cache',
      () async {
    final rows = [channel('Network', 'network')];
    final session = LiveGuideSearchSession();
    var revision = 1, reads = 0;
    EpgProgram? current(String _) {
      reads++;
      return null;
    }

    await session.search(rows, 'a', current,
        nextProgram: (_) => null,
        revision: () => revision,
        cancelled: () => true);
    await session.search(rows, 'ab', (id) {
      revision++;
      return current(id);
    }, nextProgram: (_) => null, revision: () => revision);
    expect(reads, 1);
    await session.search(rows, 'abc', current,
        nextProgram: (_) => null, revision: () => revision);
    expect(reads, 2);
  });
}
