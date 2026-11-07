import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/screens/settings/add_playlist_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';

class _Storage extends StorageService {
  final caches = <String, String>{};
  late Directory directory;
  Future<void> Function(List<PlaylistProfile>)? afterProfileWrite;

  @override
  Future<void> setPlaylists(List<PlaylistProfile> playlists) async {
    await super.setPlaylists(playlists);
    await afterProfileWrite?.call(playlists);
  }

  @override
  Future<String?> readCacheFile(String name) async => caches[name];

  @override
  Future<String?> cacheFilePath(String name) async {
    final content = caches[name];
    if (content == null) return null;
    final file = File('${directory.path}/${Uri.encodeComponent(name)}');
    await file.writeAsString(content);
    return file.path;
  }

  @override
  Future<void> writeCacheFile(String name, String content) async {
    caches[name] = content;
  }
}

class _Catalog extends CatalogDatabase {
  bool failNextClear = false;
  int clears = 0;
  @override
  Future<void> clearForPlaylist(String playlistId) async {
    clears++;
    if (failNextClear) {
      failNextClear = false;
      throw const FileSystemException('Synthetic cache cleanup failure');
    }
  }
}

class _Guide extends EpgService {
  _Guide(super.storage);
  final requested = <Uri>[];

  @override
  Future<void> refresh(String url,
      {required Set<String> knownChannelIds,
      Map<String, String> headers = const {}}) async {
    requested.add(Uri.parse(url));
  }
}

class _Provider {
  _Provider(this.server) {
    server.listen((request) async {
      final query = request.uri.queryParameters;
      final user = query['username'];
      final action = query['action'] ?? 'auth';
      requests.add((user, query['password'], action));
      await pending[user]?.future;
      final Object body = responses[action] ??
          switch (action) {
            'auth' => {
                'user_info': {
                  'auth': rejected.contains(user) ? 0 : 1,
                  'status': 'Active',
                  'max_connections': '1',
                }
              },
            'get_live_categories' => [
                {'category_id': '1', 'category_name': 'Shared category'}
              ],
            'get_live_streams' => [
                for (var i = 1; i <= channelCount; i++)
                  {
                    'stream_id': i,
                    'name': 'Shared channel $i',
                    'category_id': '1'
                  }
              ],
            _ => {'unexpected': action},
          };
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
  }

  final HttpServer server;
  final requests = <(String?, String?, String)>[];
  final rejected = <String>{};
  final pending = <String, Completer<void>>{};
  final responses = <String, Object>{};
  int channelCount = 1;
  String get url => 'http://127.0.0.1:${server.port}';

  PlaylistProfile profile(String id) => PlaylistProfile(
        id: id,
        name: 'Same display name',
        mode: 'xtream',
        xtreamServer: url,
        xtreamUsername: id,
        xtreamPassword: '$id password+&',
        createdAt: DateTime(2026),
        sortOrder: 0,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  late PlaylistManager manager;
  late _Catalog catalog;
  late _Provider first;
  late _Provider second;
  final previousHttp = HttpOverrides.current;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({
      AppConstants.keyMigratedToMultiPlaylist: true,
      AppConstants.keyFavoritesDbReconciled: true,
    });
    storage = _Storage();
    storage.directory = await Directory.systemTemp.createTemp('xtream-test-');
    await storage.init();
    catalog = _Catalog();
    manager = PlaylistManager(storage, catalog);
    first = _Provider(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    second = _Provider(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  });

  tearDown(() async {
    manager.dispose();
    await first.server.close(force: true);
    await second.server.close(force: true);
    await storage.directory.delete(recursive: true);
    HttpOverrides.global = previousHttp;
  });

  Future<void> add(_Provider provider, String id) async {
    await manager.addPlaylist(provider.profile(id));
    await manager.loadPlaylist(id);
    expect(manager.isLoading, isFalse);
  }

  void expectRequests(_Provider provider, List<String> users) {
    expect(provider.requests, [
      for (final user in users)
        for (final action in [
          'auth',
          'get_live_categories',
          'get_live_streams'
        ])
          (user, '$user password+&', action),
    ]);
  }

  for (final sameServer in [false, true]) {
    test('two Xtream accounts remain independent; same server=$sameServer',
        () async {
      await add(first, 'first');
      expect(manager.error, isNull);
      final original = manager.channels.single;
      final originalCaches = Map.of(storage.caches);
      await add(sameServer ? first : second, 'second');

      expect(manager.error, isNull);
      expect(storage.getPlaylists().map((p) => p.id), ['first', 'second']);
      expect(manager.channels, hasLength(2));
      expect(manager.channels.map((c) => c.id).toSet(), hasLength(2));
      expect(manager.channels.map((c) => c.playlistId).toSet(),
          {'first', 'second'});
      expect(manager.channels.firstWhere((c) => c.playlistId == 'first'),
          same(original));
      expect(manager.channels.map((c) => c.url).toSet(), hasLength(2));
      for (final entry in originalCaches.entries) {
        expect(storage.caches[entry.key], entry.value);
      }
      expectRequests(first, sameServer ? ['first', 'second'] : ['first']);
      expectRequests(second, sameServer ? [] : ['second']);
      await manager.setPlaylistEnabled('first', false);
      expect(manager.channels.single.playlistId, 'second');
      await manager.setPlaylistEnabled('first', true);
      expect(manager.channels, hasLength(2));
      expectRequests(first, sameServer ? ['first', 'second'] : ['first']);
    });
  }

  test('a rejected first account cannot reject a working second provider',
      () async {
    first.rejected.add('first');
    await add(first, 'first');
    expect(manager.error, isNotNull);
    await add(second, 'second');
    expect(manager.error, isNull);
    expect(manager.anyPlaylistError, isNotNull);
    expect(manager.channels.single.playlistId, 'second');
    expect(storage.getPlaylists(), hasLength(2));
    expect(first.requests, [('first', 'first password+&', 'auth')]);
    expectRequests(second, ['second']);
  });

  test('removing a rejected second add preserves the first and allows retry',
      () async {
    await add(first, 'first');
    final original = manager.channels.single;
    second.rejected.add('second');
    await add(second, 'second');
    expect(manager.error, isNotNull);
    await manager.removePlaylist('second');
    expect(storage.getPlaylists().single.id, 'first');
    expect(manager.channels.single, same(original));
    second.rejected.clear();
    await add(second, 'second');
    expect(manager.error, isNull);
    expect(manager.channels, hasLength(2));
    expect(storage.getPlaylists(), hasLength(2));
    expectRequests(first, ['first']);
  });

  test('two large catalogues restore from independent caches without requests',
      () async {
    first.channelCount = 5000;
    second.channelCount = 4000;
    await add(first, 'first');
    await add(second, 'second');
    expect(manager.channels, hasLength(9000));
    expect(manager.channels.map((c) => c.id).toSet(), hasLength(9000));
    final urls = {for (final c in manager.channels) c.id: c.url};
    manager.dispose();
    manager = PlaylistManager(storage, _Catalog());
    await manager.init();
    await manager.ensureLiveChannelsLoaded();
    expect(manager.error, isNull);
    expect({for (final c in manager.channels) c.id: c.url}, urls);
    expectRequests(first, ['first']);
    expectRequests(second, ['second']);
  });

  test('adding during startup layout migration preserves both providers',
      () async {
    await storage.setPlaylists([first.profile('first')]);
    final migrating = Completer<void>();
    final resume = Completer<void>();
    storage.afterProfileWrite = (profiles) async {
      if (profiles.single.categoryLayout == 'auto') return;
      storage.afterProfileWrite = null;
      migrating.complete();
      await resume.future;
    };
    await manager.init(restoreInBackground: true);
    await migrating.future.timeout(const Duration(seconds: 5));
    final restored = expectLater(manager.whenRestored, completes);
    try {
      await manager.addPlaylist(second.profile('second'));
      await manager.loadPlaylist('second');
    } finally {
      resume.complete();
    }
    await restored;
    expect(manager.error, isNull);
    expect(manager.isLoading, isFalse);
    expect(manager.channels, hasLength(2));
    expect(storage.getPlaylists().map((p) => p.id), ['first', 'second']);
    expectRequests(first, ['first']);
    expectRequests(second, ['second']);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue, reason: 'Local playlist operation did not finish');
    });
    await tester.pump();
  }

  Future<void> settleForm(WidgetTester tester) async {
    await tester.pumpAndSettle();
    // HTTP completions run outside the widget clock. Drain their animation
    // callbacks before disposing a route or its scaffold messenger.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<_Guide> openForm(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = size.width >= 900;
    final guide = _Guide(storage);
    addTearDown(prefs.dispose);
    addTearDown(guide.dispose);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: manager),
          ChangeNotifierProvider<EpgService>.value(value: guide),
        ],
        child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AddPlaylistScreen())),
                        child: const Text('Open form')))))));
    await tester.tap(find.text('Open form'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.ensureVisible(find.text('Xtream Codes'));
    await tester.tap(find.text('Xtream Codes'));
    await tester.pump(const Duration(milliseconds: 200));

    Future<void> enter(String label, String value) async {
      final field = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label);
      await tester.ensureVisible(field);
      await tester.pump(const Duration(milliseconds: 200));
      if (prefs.isTelevision) {
        tester.widget<TextField>(field).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(field, value);
      await tester.pump();
    }

    await enter('Name', 'Same display name');
    await enter('Server URL (e.g. http://host:port)',
        '${second.url}/player_api.php?username=old&password=old');
    await enter('Username', 'second');
    await enter('Password', 'second password+&');
    await tester.ensureVisible(find.byKey(const ValueKey('playlist-save')));
    await tester.pump(const Duration(milliseconds: 200));
    return guide;
  }

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets('second provider saves through the real form at $size',
        (tester) async {
      await tester.runAsync(() => add(first, 'first'));
      final guide = await openForm(tester, size);
      final save = find.byKey(const ValueKey('playlist-save'));
      if (size.width >= 900) {
        tester.widget<FilledButton>(save).focusNode!.requestFocus();
        await tester.pump();
        await tester
            .runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.select));
      } else {
        await tester.runAsync(() => tester.tap(save));
      }
      await waitFor(tester, () => guide.requested.isNotEmpty);
      await settleForm(tester);
      expect(find.byType(AddPlaylistScreen), findsNothing);
      expect(storage.getPlaylists(), hasLength(2));
      expect(manager.channels, hasLength(2));
      expect(guide.requested.single.queryParameters,
          {'username': 'second', 'password': 'second password+&'});
      expectRequests(first, ['first']);
      expectRequests(second, ['second']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final failedAction in [
    'auth',
    'get_live_categories',
    'get_live_streams',
    'rollback'
  ]) {
    testWidgets('second add $failedAction failure rolls back and retries once',
        (tester) async {
      await tester.runAsync(() => add(first, 'first'));
      if (failedAction == 'auth' || failedAction == 'rollback') {
        second.rejected.add('second');
        catalog.failNextClear = failedAction == 'rollback';
      } else {
        second.responses[failedAction] = {'error': 'Unavailable'};
      }
      final guide = await openForm(tester, const Size(960, 540));
      final save = find.byKey(const ValueKey('playlist-save'));
      await tester.runAsync(() => tester.tap(save));
      await waitFor(tester,
          () => second.requests.isNotEmpty && manager.profiles.length == 1);
      await settleForm(tester);
      expect(find.byType(AddPlaylistScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('playlist-failure-dialog')),
          findsOneWidget);
      final expectedStage = switch (failedAction) {
        'auth' => 'PL-CONNECT-ACCESS',
        'rollback' => 'PL-SAVE-STORAGE',
        'get_live_categories' => 'PL-CATEGORIES-RESPONSE',
        _ => 'PL-CHANNELS-RESPONSE',
      };
      expect(find.textContaining(expectedStage), findsOneWidget);
      expect(storage.getPlaylists().single.id, 'first');
      expect(manager.channels.single.playlistId, 'first');
      expect(guide.requested, isEmpty);
      second.rejected.clear();
      second.responses.clear();
      final callback = tester.widget<FilledButton>(save).onPressed!;
      await tester.runAsync(() async {
        for (var i = 0; i < 20; i++) {
          callback();
        }
      });
      expect(guide.requested, isEmpty);
      expect(manager.profiles, hasLength(1));
      final retry = tester
          .widget<FilledButton>(
              find.byKey(const ValueKey('playlist-error-retry')))
          .onPressed!;
      await tester.runAsync(() async {
        for (var i = 0; i < 20; i++) {
          retry();
        }
      });
      await waitFor(tester, () => guide.requested.isNotEmpty);
      await settleForm(tester);
      expect(find.byType(AddPlaylistScreen), findsNothing);
      expect(storage.getPlaylists(), hasLength(2));
      expect(manager.channels, hasLength(2));
      const actions = ['auth', 'get_live_categories', 'get_live_streams'];
      expect(second.requests.map((r) => r.$3), [
        ...actions.take(actions
                .indexOf(failedAction == 'rollback' ? 'auth' : failedAction) +
            1),
        ...actions,
      ]);
      expect(catalog.clears, failedAction == 'rollback' ? 2 : 1);
      expectRequests(first, ['first']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('new form does not display an existing provider error',
      (tester) async {
    first.rejected.add('first');
    await tester.runAsync(() => add(first, 'first'));
    final guide = await openForm(tester, const Size(960, 540));
    expect(find.textContaining('Could not save playlist:'), findsNothing);
    await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('playlist-save'))));
    await waitFor(tester, () => guide.requested.isNotEmpty);
    await settleForm(tester);
    expect(find.byType(AddPlaylistScreen), findsNothing);
    expect(manager.error, isNull);
    expect(manager.anyPlaylistError, isNotNull);
    expect(storage.getPlaylists(), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  for (final firstFails in [false, true]) {
    testWidgets('add during slow restore; first account fails=$firstFails',
        (tester) async {
      final gate = (await tester.runAsync(() async => Completer<void>()))!;
      first.pending['first'] = gate;
      if (firstFails) first.rejected.add('first');
      await tester.runAsync(() async {
        await storage.setPlaylists([first.profile('first')]);
        await manager.init(restoreInBackground: true);
      });
      await waitFor(tester, () => first.requests.isNotEmpty);
      expect(manager.isLoading, isTrue);
      try {
        final guide = await openForm(tester, const Size(960, 540));
        final save = find.byKey(const ValueKey('playlist-save'));
        expect(tester.widget<FilledButton>(save).onPressed, isNotNull,
            reason: 'An unrelated provider must not disable adding a new one');
        await tester.runAsync(() => tester.tap(save));
        await waitFor(tester, () => guide.requested.isNotEmpty);
        await settleForm(tester);
        expect(find.byType(AddPlaylistScreen), findsNothing);
        expect(storage.getPlaylists(), hasLength(2));
        expect(manager.channels.single.playlistId, isNot('first'));
      } finally {
        await tester.runAsync(() async {
          gate.complete();
          await manager.whenRestored.timeout(const Duration(seconds: 5));
        });
        await tester.pumpWidget(const SizedBox());
      }
      expect(manager.channels, hasLength(firstFails ? 1 : 2));
      expect(storage.getPlaylists(), hasLength(2));
      expect(manager.error, isNull);
      if (firstFails) {
        expect(manager.anyPlaylistError, isNotNull);
        expect(first.requests.map((r) => r.$3), ['auth']);
      } else {
        expectRequests(first, ['first']);
      }
      expectRequests(second, ['second']);
    });
  }
}
