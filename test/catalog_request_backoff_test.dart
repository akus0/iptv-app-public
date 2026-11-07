import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_failure.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/models/xtream_category.dart';
import 'package:nox_iptv/models/xtream_series.dart';
import 'package:nox_iptv/services/catalog_request_backoff.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_test.dart' show Api, MemoryDb, MemoryStorage, movie;

class _FailingApi extends Api {
  Object? failure = const PlaylistRequestException('Unavailable',
      reason: PlaylistFailureReason.http, httpStatus: 503);
  @override
  int? get maxConnections => 1;
  @override
  Future<List<Channel>> getVodStreams(String id, String name) async {
    loads++;
    if (failure != null) throw failure!;
    return [movie(1, group: name)];
  }

  @override
  Future<List<XtreamSeries>> getSeriesForCategory(String id) async {
    loads++;
    if (failure != null) throw failure!;
    return [];
  }
}

class _Db extends MemoryDb {
  @override
  Future<int> getSeriesCategoryCount(String playlistId, String name) async => 0;
  @override
  Future<List<Channel>> getVodCategory(String playlistId, String name,
          {int? limit}) async =>
      counts.containsKey(name) ? [movie(1, group: name)] : [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final error in [
    TimeoutException('synthetic'),
    const PlaylistRequestException('network',
        reason: PlaylistFailureReason.network),
    const PlaylistRequestException('access',
        reason: PlaylistFailureReason.access),
    for (final status in [401, 403, 429, 500, 502, 503, 504])
      PlaylistRequestException('http',
          reason: PlaylistFailureReason.http, httpStatus: status),
  ]) {
    test(
        'repeated ${error.runtimeType} ${error is PlaylistRequestException ? error.httpStatus : ''} pauses until expiry',
        () async {
      var now = DateTime(2026);
      final gate = CatalogRequestBackoff(now: () => now);
      final owner = Object();
      var calls = 0;
      Future<int> fail() async {
        calls++;
        throw error;
      }

      await expectLater(gate.run(owner, fail), throwsA(same(error)));
      expect(gate.isPausedFor(owner), false);
      await expectLater(gate.run(owner, fail), throwsA(same(error)));
      expect(gate.isPausedFor(owner), true);
      await expectLater(
          gate.run(owner, fail), throwsA(isA<CatalogRequestsPaused>()));
      expect(calls, 2);
      now = now.add(const Duration(minutes: 2));
      expect(await gate.run(owner, () async => 42), 42);
      expect(gate.isPausedFor(owner), false);
    });
  }

  test('category errors and successful responses do not trip provider pause',
      () async {
    final gate = CatalogRequestBackoff();
    final owner = Object();
    for (final error in [
      const PlaylistRequestException('not found',
          reason: PlaylistFailureReason.http, httpStatus: 404),
      const PlaylistRequestException('response',
          reason: PlaylistFailureReason.response),
      const PlaylistRequestException('storage',
          reason: PlaylistFailureReason.storage),
      StateError('local failure'),
    ]) {
      for (var i = 0; i < 3; i++) {
        await expectLater(
            gate.run(owner, () async => throw error), throwsA(same(error)));
      }
      expect(gate.isPausedFor(owner), false);
    }
    for (var i = 0; i < 4; i++) {
      await expectLater(
          gate.run(owner, () async => throw TimeoutException('test')),
          throwsA(isA<TimeoutException>()));
      await gate.run(owner, () async => 1);
      expect(gate.isPausedFor(owner), false);
    }
  });

  test('late requests cannot reset a pause or poison a replacement connection',
      () async {
    final gate = CatalogRequestBackoff();
    final owner = Object();
    final old = Completer<int>();
    final pending = gate.run(owner, () => old.future);
    for (var i = 0; i < 2; i++) {
      await expectLater(
          gate.run(owner, () async => throw TimeoutException('test')),
          throwsA(isA<TimeoutException>()));
    }
    old.complete(1);
    await pending;
    expect(gate.isPausedFor(owner), true);
    gate.reset();
    final late = Completer<int>();
    final failed = expectLater(
        gate.run(owner, () => late.future), throwsA(isA<TimeoutException>()));
    final replacement = Object();
    await gate.run(replacement, () async => 1);
    late.completeError(TimeoutException('test'));
    await failed;
    await expectLater(
        gate.run(replacement, () async => throw TimeoutException('test')),
        throwsA(isA<TimeoutException>()));
    expect(gate.isPausedFor(replacement), false);
  });

  late PlaylistSession session;
  late _FailingApi api;
  late _Db db;
  late MemoryStorage storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = MemoryStorage();
    await storage.init();
    api = _FailingApi();
    db = _Db();
    session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'one',
            name: 'One',
            mode: 'xtream',
            sortOrder: 0,
            createdAt: DateTime(2026)),
        storage: storage,
        catalogDb: db,
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        onNotify: () {})
      ..catalogApi = api;
    session.vodCategories = [
      for (var i = 0; i < 100; i++)
        XtreamCategory(id: '$i', name: 'Category $i')
    ];
    session.vodCategoryIdByName
        .addEntries(session.vodCategories.map((c) => MapEntry(c.name, c.id)));
    session.seriesCategoryIdByName['Shows'] = 'shows';
  });

  test(
      'full refresh stops after shared failures and never marks partial data fresh',
      () async {
    db.counts['Saved'] = 4;
    await session.refreshAllCategories();
    expect(api.loads, 2);
    expect(storage.getLastFullSyncAt('one'), isNull);
    expect(session.isWarmingCatalog, false);
    expect(session.error, isNotNull);
    expect(session.categoryFailureCounts, isEmpty);
    await session.loadLibraryCategory('Saved', 'vod');
    expect(api.loads, 2);
    expect(db.counts['Saved'], 4);
    await session.warmAllCategories();
    expect(api.loads, 2);
    api.failure = null;
    await session.refreshAllCategories();
    expect(api.loads, 102);
    expect(storage.getLastFullSyncAt('one'), isNotNull);
    expect(db.counts['Category 99'], 1);
  });

  test(
      'queued category loads share cooldown across movies and series; explicit retry works',
      () async {
    final attempts = [
      for (var i = 0; i < 10; i++)
        session
            .loadLibraryCategory('Category $i', 'vod')
            .then<Object?>((_) => null, onError: (Object e) => e)
    ];
    final errors = await Future.wait(attempts);
    expect(api.loads, 2);
    expect(errors.take(2).every((e) => e is PlaylistRequestException), true);
    expect(errors.skip(2).every((e) => e is CatalogRequestsPaused), true);
    await expectLater(session.loadLibraryCategory('Shows', 'series'),
        throwsA(isA<CatalogRequestsPaused>()));
    db.counts['Saved'] = 3;
    await session.ensureCategoryLoaded('Saved', 'vod');
    expect(session.vodByCategoryName['Saved'], hasLength(1));
    expect(api.loads, 2);
    api.failure = null;
    await session.loadLibraryCategory('Category 0', 'vod', refresh: true);
    expect(api.loads, 3);
    await session.loadLibraryCategory('Category 1', 'vod');
    expect(api.loads, 4);
  });

  test('category-specific failures still allow other categories to load',
      () async {
    api.failure = const PlaylistRequestException('not found',
        reason: PlaylistFailureReason.http, httpStatus: 404);
    await session.refreshAllCategories();
    expect(api.loads, 100);
    expect(storage.getLastFullSyncAt('one'), isNull);
  });
}
