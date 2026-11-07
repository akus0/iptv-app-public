import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/multiview_session.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

Channel channel(int i, {String playlist = 'p', String? url}) => Channel(
    id: '$playlist::$i',
    rawId: '$i',
    playlistId: playlist,
    name: 'Channel $i',
    group: 'Sports',
    url: url ?? 'https://example.test/live/u/p/$i.ts');
PlaylistProfile profile({int max = 4}) => PlaylistProfile(
    id: 'p',
    name: 'Test',
    mode: 'xtream',
    sortOrder: 0,
    createdAt: DateTime(2026),
    xtreamUsername: 'u',
    xtreamPassword: 'p',
    maxConnections: max);

class FakeController extends VideoPlayerHdrController {
  FakeController(this.id, this.log,
      {this.gate, this.fail = false, this.failDispose = false})
      : super.networkUrl(Uri.parse('https://example.test/never-open'));
  final String id;
  final List<String> log;
  final Completer<void>? gate;
  final bool fail, failDispose;
  bool disposed = false;
  @override
  Future<void> initialize(
      {VideoViewType viewType = VideoViewType.textureView}) async {
    log.add('open:$id');
    await gate?.future;
    if (fail) throw StateError('decoder');
    value = const VideoPlayerHdrValue(
        duration: Duration.zero, size: Size(1920, 1080), isInitialized: true);
  }

  @override
  Future<void> setVolume(double v) async {
    log.add('volume:$id:$v');
    value = value.copyWith(volume: v);
  }

  @override
  Future<void> play() async {
    log.add('play:$id');
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    log.add('pause:$id');
    value = value.copyWith(isPlaying: false);
  }

  // Fake has no native player to release.
  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    log.add('close:$id');
    disposed = true;
    if (failDispose) throw StateError('release failed');
  }
}

void main() {
  test('grid budget follows layout without reconnecting existing players',
      () async {
    final log = <String>[];
    final budgets = <String>[];
    final session = MultiviewSession(
      createController: (c) => FakeController(c.id, log),
      configure: (_) async {},
      configureGrid: (c, screens) async =>
          budgets.add('${(c as FakeController).id}:$screens'),
    );
    await session.assign(0, channel(0));
    final first = session.cells[0].controller;
    await session.setVisibleCount(4);
    await session.assign(3, channel(3));
    await session.setVisibleCount(2);
    expect(session.cells[0].controller, same(first));
    expect(log.where((e) => e == 'open:p::0'), hasLength(1));
    expect(budgets, ['p::0:2', 'p::0:4', 'p::3:4', 'p::0:2']);
    expect(session.cells[3].controller, isNull);
    await session.close();
    session.dispose();
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> tick() => Future<void>.delayed(Duration.zero);
  test('same-account channels open; duplicate IDs and stream URLs do not',
      () async {
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) => FakeController(c.rawId, []));
    await s.assign(0, channel(1));
    final alias =
        channel(2, playlist: 'epg', url: 'https://another.test/u/p/2.ts');
    expect(s.problemFor(1, alias), isNull);
    await s.assign(1, alias);
    expect(s.cells[1].controller!.value.isPlaying, true);
    expect(s.problemFor(1, channel(1)), contains('already open'));
    expect(s.problemFor(1, channel(3, playlist: 'alias', url: channel(1).url)),
        contains('already open'));
    expect(s.problemFor(0, channel(1)), isNull);
    await s.close();
    s.dispose();
  });
  test('queued replacements release first and only the latest choice opens',
      () async {
    final log = <String>[];
    final gate = Completer<void>();
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) =>
            FakeController(c.rawId, log, gate: c.rawId == '1' ? gate : null));
    final a = s.assign(0, channel(1));
    await tick();
    final b = s.assign(0, channel(2));
    final c = s.assign(0, channel(3));
    gate.complete();
    await Future.wait([a, b, c]);
    expect(log.where((v) => v.startsWith('open:')), ['open:1', 'open:3']);
    expect(log.indexOf('close:1'), lessThan(log.indexOf('open:3')));
    expect(s.cells[0].channel!.rawId, '3');
    await s.close();
    s.dispose();
  });
  test('removing or exiting during connection never starts orphan playback',
      () async {
    for (final exit in [false, true]) {
      final log = <String>[], gate = Completer<void>();
      final s = MultiviewSession(
          configure: (_) async {},
          createController: (c) => FakeController(c.rawId, log, gate: gate));
      final a = s.assign(0, channel(1));
      await tick();
      final end = exit ? s.close() : s.clear(0);
      gate.complete();
      await Future.wait([a, end]);
      expect(log.where((v) => v.startsWith('play:')), isEmpty);
      expect(log.where((v) => v == 'close:1').length, 1);
      await s.close();
      s.dispose();
    }
  });
  test(
      'closing a connecting stream cancels immediately without waiting for data',
      () async {
    final log = <String>[];
    final gate = Completer<void>();
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) => FakeController(c.rawId, log, gate: gate));
    final opening = s.assign(0, channel(1));
    await tick();
    await s.close().timeout(const Duration(seconds: 1));
    expect(log, contains('close:1'));
    expect(log.where((v) => v.startsWith('play:')), isEmpty);
    gate.complete();
    await opening;
    s.dispose();
  });
  test(
      'rapid audio changes do not reconnect and removing sound chooses a remaining cell',
      () async {
    final log = <String>[];
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) => FakeController(c.rawId, log));
    await s.assign(0, channel(1));
    await s.assign(1, channel(2));
    await Future.wait([s.selectAudio(1), s.selectAudio(0), s.selectAudio(1)]);
    expect(s.cells[0].controller!.value.volume, 0);
    expect(s.cells[1].controller!.value.volume, 1);
    expect(log.where((v) => v.startsWith('open:')).length, 2);
    await s.clear(1);
    expect(s.active, 0);
    expect(s.cells[0].controller!.value.volume, 1);
    await s.toggleMute();
    expect(s.cells[0].controller!.value.volume, 0);
    await s.close();
    s.dispose();
  });
  test(
      'layout reduction closes hidden players and lifecycle resumes buffered playback intent',
      () async {
    final log = <String>[];
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) => FakeController(c.rawId, log));
    await s.setVisibleCount(4);
    for (var i = 0; i < 4; i++) {
      await s.assign(i, channel(i));
    }
    s.cells[1].controller!.value = s.cells[1].controller!.value
        .copyWith(isPlaying: false, isBuffering: true);
    await s.suspend(true);
    expect(s.cells.every((c) => !c.controller!.value.isPlaying), true);
    await s.suspend(false);
    expect(s.cells[0].controller!.value.isPlaying, true);
    expect(s.cells[1].controller!.value.isPlaying, true);
    await s.setVisibleCount(2);
    expect(s.cells[2].controller, isNull);
    expect(s.cells[3].controller, isNull);
    expect(log, containsAll(['close:2', 'close:3']));
    await s.close();
    s.dispose();
  });
  test(
      'one failed channel leaves the other player intact and failure can be retried',
      () async {
    final log = <String>[];
    var fail = true;
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) =>
            FakeController(c.rawId, log, fail: c.rawId == '2' && fail));
    await s.assign(0, channel(1));
    final original = s.cells[0].controller;
    await s.assign(1, channel(2));
    expect(s.cells[1].error, isNotNull);
    expect(s.cells[0].controller, same(original));
    fail = false;
    await s.assign(1, channel(2));
    expect(s.cells[1].error, isNull);
    expect(original!.value.isPlaying, true);
    await s.close();
    s.dispose();
  });
  test('failed release prevents opening another provider stream', () async {
    final log = <String>[];
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) =>
            FakeController(c.rawId, log, failDispose: true));
    await s.assign(0, channel(1));
    await s.assign(0, channel(2));
    expect(log.where((v) => v.startsWith('open:')).length, 1);
    expect(s.cells[0].error, contains('could not close'));
    await s.close();
    s.dispose();
  });
  test('position updates do not rebuild multiview chrome', () async {
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) => FakeController(c.rawId, []));
    await s.assign(0, channel(1));
    var cellUpdates = 0, gridUpdates = 0;
    s.cells[0].addListener(() => cellUpdates++);
    s.addListener(() => gridUpdates++);
    final c = s.cells[0].controller!;
    for (var i = 1; i < 100; i++) {
      c.value = c.value.copyWith(position: Duration(seconds: i));
    }
    expect(cellUpdates, 0);
    expect(gridUpdates, 0);
    await s.close();
    s.dispose();
  });
  test('background pause does not wait for a different channel to connect',
      () async {
    final log = <String>[], gate = Completer<void>();
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) =>
            FakeController(c.rawId, log, gate: c.rawId == '2' ? gate : null));
    await s.assign(0, channel(1));
    final connecting = s.assign(1, channel(2));
    await tick();
    log.clear();
    await s.suspend(true).timeout(const Duration(seconds: 1));
    expect(log, contains('pause:1'));
    expect(s.cells[0].controller!.value.isPlaying, false);
    gate.complete();
    await connecting;
    expect(s.cells[1].controller!.value.isPlaying, false);
    await s.suspend(false);
    expect(s.cells.take(2).every((c) => c.controller!.value.isPlaying), true);
    await s.close();
    s.dispose();
  });
  test(
      'audio changes coalesce and adding a muted tile does not interrupt current sound',
      () async {
    final log = <String>[];
    final s = MultiviewSession(
        configure: (_) async {},
        createController: (c) => FakeController(c.rawId, log));
    await s.assign(0, channel(1));
    log.clear();
    await s.assign(1, channel(2));
    expect(log.where((x) => x.startsWith('volume:1:')), isEmpty);
    log.clear();
    await Future.wait([s.selectAudio(1), s.selectAudio(0), s.selectAudio(1)]);
    expect(log.where((x) => x.startsWith('volume:')).length, 2);
    expect(s.cells[0].controller!.value.volume, 0);
    expect(s.cells[1].controller!.value.volume, 1);
    log.clear();
    await s.selectAudio(1);
    expect(log, isEmpty);
    await s.close();
    s.dispose();
  });
  test('multiview migration enables once and preserves a later hidden choice',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    expect(storage.getHideMultiview(), false);
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.setHideMultiview(true);
    await tick();
    final reopened = StorageService();
    await reopened.init();
    expect(reopened.getHideMultiview(), true);
    final loaded = AppPreferences(reopened);
    await loaded.init();
    expect(loaded.hideMultiview, true);
    prefs.dispose();
    loaded.dispose();
  });
}
