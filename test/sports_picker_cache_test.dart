import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';

class _Guide extends EpgService {
  _Guide() : super(StorageService());
  int revision = 0;
  @override
  int get changeRevision => revision;
}

class _Matcher extends SportsChannelMatcher {
  _Matcher(super.epg, {required super.clock});
  int calls = 0;
  bool throwSynchronously = false;
  Completer<List<ChannelMatch>> pending = Completer();
  List<ChannelMatch> evidence = [];
  @override
  Future<List<ChannelMatch>> alternativesFor(SportsGame game,
      {List<ChannelMatch> matches = const [], bool Function()? isCancelled}) {
    calls++;
    if (throwSynchronously) throw StateError('test failure');
    evidence = matches;
    return pending.future;
  }
}

final _start = DateTime.utc(2026, 10, 29, 12);
SportsGame _game([String id = 'fixture']) => SportsGame(
    id: id,
    league: sportsLeagueById('tennis.atp')!,
    start: _start,
    state: GameState.live,
    statusText: 'Live',
    home: const SportsTeam(
        id: 'a', name: 'Player One', shortName: 'One', abbreviation: 'ONE'),
    away: const SportsTeam(
        id: 'b', name: 'Player Two', shortName: 'Two', abbreviation: 'TWO'));
ChannelMatch _row(String id,
        {DateTime? stop, MatchReason reason = MatchReason.sport}) =>
    ChannelMatch(
        Channel(
            id: id,
            rawId: id,
            playlistId: 'test',
            name: 'Tennis $id',
            group: 'Sports',
            url: 'https://example.invalid/stream'),
        reason,
        100,
        programme: stop == null
            ? null
            : EpgProgram(
                channelId: id, title: 'Tennis', start: _start, stop: stop));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'reopening shares in-flight discovery and immediately retains all results',
      () async {
    final matcher = _Matcher(_Guide(), clock: () => _start);
    final first = matcher.loadPickerAlternatives(_game(),
        matches: [_row('picked', reason: MatchReason.pick)]);
    final reopened = matcher.loadPickerAlternatives(_game());
    expect(identical(first, reopened), isTrue);
    expect(matcher.calls, 1);
    expect(matcher.evidence, isEmpty);
    matcher.pending.complete([for (var i = 0; i < 168; i++) _row('$i')]);
    await first;
    expect(matcher.cachedPickerAlternatives(_game()), hasLength(168));
    expect(await matcher.loadPickerAlternatives(_game()), hasLength(168));
    expect(matcher.calls, 1);
    expect(matcher.cachedPickerAlternatives(_game('different')), isNull);
  });

  test('guide corrections, programme boundaries and TTL invalidate evidence',
      () async {
    var now = _start;
    final guide = _Guide();
    final matcher = _Matcher(guide, clock: () => now);
    final first = matcher.loadPickerAlternatives(_game());
    matcher.pending
        .complete([_row('a', stop: now.add(const Duration(minutes: 1)))]);
    await first;
    now = now.add(const Duration(minutes: 1));
    expect(matcher.cachedPickerAlternatives(_game()), isNull);
    final retained = matcher.retainedPickerAlternatives(_game())!;
    expect(retained.single.channel.id, 'a');
    expect(retained.single.isConfident, false);
    expect(retained.single.programme, isNull);
    matcher.pending = Completer();
    final second = matcher.loadPickerAlternatives(_game());
    matcher.pending.complete([_row('b')]);
    await second;
    guide.revision++;
    expect(matcher.cachedPickerAlternatives(_game()), isNull);
    expect(matcher.retainedPickerAlternatives(_game())!.single.channel.id, 'b');
    matcher.pending = Completer();
    final third = matcher.loadPickerAlternatives(_game());
    matcher.pending.complete([_row('c')]);
    await third;
    now = now.add(const Duration(minutes: 3));
    expect(matcher.cachedPickerAlternatives(_game()), isNull);
    expect(matcher.retainedPickerAlternatives(_game()), hasLength(1));
    now = now.add(const Duration(minutes: 12));
    expect(matcher.retainedPickerAlternatives(_game()), isNull);
  });

  test('failed, disposed and superseded searches cannot poison the cache',
      () async {
    final guide = _Guide();
    final matcher = _Matcher(guide, clock: () => _start);
    final failed = matcher.loadPickerAlternatives(_game());
    final check = expectLater(failed, throwsStateError);
    matcher.pending.completeError(StateError('test failure'));
    await check;
    matcher.pending = Completer();
    final retry = matcher.loadPickerAlternatives(_game());
    guide.revision++;
    matcher.pending.complete([_row('old')]);
    await retry;
    expect(matcher.cachedPickerAlternatives(_game()), isNull);
    matcher.pending = Completer();
    final disposed = matcher.loadPickerAlternatives(_game());
    matcher.dispose();
    matcher.pending.complete([_row('disposed')]);
    await disposed;
    expect(matcher.cachedPickerAlternatives(_game()), isNull);
  });

  test('completed event caches have a small LRU bound', () async {
    final matcher = _Matcher(_Guide(), clock: () => _start);
    for (var i = 0; i < 7; i++) {
      matcher.pending = Completer();
      final work = matcher.loadPickerAlternatives(_game('$i'));
      matcher.pending.complete([_row('$i')]);
      await work;
    }
    expect(matcher.cachedPickerAlternatives(_game('0')), isNull);
    expect(matcher.cachedPickerAlternatives(_game('6')), hasLength(1));
  });

  test('synchronous discovery failure also allows retry', () async {
    final matcher = _Matcher(_Guide(), clock: () => _start)
      ..throwSynchronously = true;
    await expectLater(
        matcher.loadPickerAlternatives(_game()), throwsStateError);
    matcher.throwSynchronously = false;
    final retry = matcher.loadPickerAlternatives(_game());
    matcher.pending.complete([_row('retry')]);
    expect(await retry, hasLength(1));
    expect(matcher.calls, 2);
  });
}
