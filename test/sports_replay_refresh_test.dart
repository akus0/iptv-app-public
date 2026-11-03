import 'package:nox_iptv/widgets/sports_activity_status.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/replay_schedule_service.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/sports_replays_panel.dart';

final channel = Channel(
    id: 'test::sports',
    rawId: 'sports',
    playlistId: 'test',
    name: 'Sports',
    group: 'Sports',
    url: 'https://example.invalid/never-play');

ReplaySnapshot snapshot(String title) {
  final now = DateTime.now();
  final event = SportsReplay(sport: 'racing', title: title, broadcasts: [
    ReplayBroadcast(
        channel,
        EpgProgram(
            channelId: channel.epgId,
            title: title,
            start: now.subtract(const Duration(minutes: 10)),
            stop: now.add(const Duration(hours: 1))))
  ]);
  return ReplaySnapshot([event], 1, highlights: [event]);
}

class _Playlist extends PlaylistManager {
  _Playlist(StorageService storage) : super(storage, CatalogDatabase());
  List<Channel> rows = [channel];
  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      rows;
}

class _HeldReplays extends SportsReplayService {
  _HeldReplays(super.epg);
  final pending = <Completer<ReplaySnapshot>>[];
  final updates = <void Function(ReplayScanProgress)?>[];
  final forces = <bool>[];
  final cancellations = <bool Function()?>[];
  final inputs = <List<Channel>>[];
  int running = 0, peak = 0;
  @override
  Future<ReplaySnapshot> load(List<Channel> channels,
      {required Object revision,
      DateTime? at,
      bool force = false,
      bool Function()? cancelled,
      void Function(ReplayScanProgress)? onProgress}) {
    final task = Completer<ReplaySnapshot>();
    pending.add(task);
    updates.add(onProgress);
    forces.add(force);
    cancellations.add(cancelled);
    inputs.add(channels);
    running++;
    if (running > peak) peak = running;
    return task.future.whenComplete(() => running--);
  }
}

class _FailingDates extends ReplayScheduleService {
  _FailingDates() : super(fetch: (_, __) async => [], cached: () => []);
  @override
  Future<void> enrich(List<SportsReplay> events,
      {required bool Function() cancelled,
      required void Function() onUpdate}) async {
    throw StateError('Optional date source failed');
  }
}

void main() {
  for (final highlights in [false, true]) {
    testWidgets(
        'sport shelves navigate, restore positions and open pinned lists: highlights=$highlights',
        (tester) async {
      tester.view.physicalSize = const Size(650, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final guide = EpgService(storage);
      final playlist = _Playlist(storage);
      final service = _HeldReplays(guide);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<EpgService>.value(value: guide),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ],
          child: MaterialApp(
              home: Scaffold(
                  body: SportsReplaysPanel(
                      active: true,
                      highlights: highlights,
                      service: service,
                      dateService: _FailingDates(),
                      onPlay: (_) async {})))));
      await tester.pump();
      final now = DateTime.now();
      final events = [
        for (final sport in ['darts', 'poker', 'tennis'])
          for (var i = 0; i < 8; i++)
            SportsReplay(
                sport: sport,
                title: '$sport programme $i',
                broadcasts: [
                  ReplayBroadcast(
                      Channel(
                          id: '$sport-$i',
                          rawId: '$sport-$i',
                          playlistId: 'test',
                          name: 'Channel $i',
                          group: 'Sport',
                          url: 'https://example.invalid/never-play'),
                      EpgProgram(
                          channelId: '$sport-$i',
                          title: '$sport programme $i',
                          description:
                              'Extended coverage of $sport, with the key moments, competitors and venue details from this programme. (Sports)',
                          start: now.subtract(const Duration(minutes: 15)),
                          stop: now.add(const Duration(hours: 1))))
                ])
      ];
      final partial = events.where((e) => e.sport != 'darts').toList();
      service.updates.single?.call(ReplayScanProgress(
          ReplaySnapshot(partial, partial.length, highlights: partial),
          50,
          100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('poker programme 0'), findsWidgets,
          reason: 'Usable cards appear before discovery completes');
      final pokerCard = find.byWidgetPredicate((w) =>
          w is InkWell &&
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('replay-poker-0:'));
      final pokerFocus = tester.widget<InkWell>(pokerCard).focusNode!;
      pokerFocus.requestFocus();
      await tester.pump(const Duration(milliseconds: 100));
      service.pending.single
          .complete(ReplaySnapshot(events, events.length, highlights: events));
      await tester.pumpAndSettle();
      expect(pokerFocus.hasFocus, isTrue,
          reason:
              'Arrival of an earlier sport must preserve the selected card');
      expect(
          tester.getRect(pokerCard).overlaps(
              tester.getRect(find.byKey(const ValueKey('replays-scroll')))),
          isTrue);
      final synopsis = find.text(
          'Extended coverage of darts, with the key moments, competitors and venue details from this programme.');
      expect(synopsis, findsWidgets,
          reason: 'Both replay and highlight cards include the guide synopsis');
      expect(tester.widget<Text>(synopsis.first).maxLines, greaterThan(1));
      final scrollFinder = find.byKey(const ValueKey('replays-scroll'));
      final scroll = tester.widget<CustomScrollView>(scrollFinder).controller!;
      Finder card(String sport, int i) => find.byWidgetPredicate((w) =>
          w is InkWell &&
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('replay-$sport-$i:'));
      FocusNode node(String sport, int i) =>
          tester.widget<InkWell>(card(sport, i)).focusNode!;
      expect(find.text('darts programme 7'), findsNothing,
          reason: 'Horizontal cards remain lazily built');
      node('darts', 0).requestFocus();
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
      }
      expect(node('darts', 6).hasFocus, isTrue);
      final shelf = tester
          .widget<ListView>(find
                  .byKey(const PageStorageKey('replay-shelf-false-darts'))
                  .evaluate()
                  .isNotEmpty
              ? find.byKey(const PageStorageKey('replay-shelf-false-darts'))
              : find.byKey(const PageStorageKey('replay-shelf-true-darts')))
          .controller!;
      final savedHorizontal = shelf.offset;
      expect(savedHorizontal, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(node('poker', 0).hasFocus, isTrue,
          reason: 'Down moves to the next sport, not a distant card');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(node('tennis', 0).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(node('darts', 6).hasFocus, isTrue);
      expect(shelf.offset, closeTo(savedHorizontal, .1));
      // Left from the first card reaches View all; another left reaches refresh.
      node('poker', 0).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      final heading = find.byKey(const ValueKey('replay-heading-poker'));
      expect(tester.widget<TextButton>(heading).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'replays-refresh');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(node('poker', 0).hasFocus, isTrue);
      final overviewOffset = scroll.offset;
      await tester.tap(heading);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('replay-all-sports')), findsOneWidget);
      expect(find.byKey(const ValueKey('replay-heading-darts')), findsNothing);
      scroll.jumpTo(180);
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(scrollFinder).dy;
      expect(tester.getTopLeft(heading).dy, closeTo(top, .1),
          reason: 'The full sport list retains its pinned heading');
      node('poker', 1).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(card('poker', 0)).dy,
          greaterThanOrEqualTo(tester.getBottomRight(heading).dy - .1));
      await tester.tap(find.byKey(const ValueKey('replay-all-sports')));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(overviewOffset, .1));
      expect(shelf.offset, closeTo(savedHorizontal, .1));
      // Compact portrait and larger text must retain the synopsis without overflow.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      playlist.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }
  for (final highlights in [false, true]) {
    testWidgets(
        'guide updates coalesce and survive pause/retry, highlights=$highlights',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final guide = EpgService(storage);
      final playlist = _Playlist(storage);
      final service = _HeldReplays(guide);
      final key = GlobalKey<SportsReplaysPanelState>();
      Widget app({bool active = true}) => MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: prefs),
                ChangeNotifierProvider<EpgService>.value(value: guide),
                ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ],
              child: MaterialApp(
                  home: Scaffold(
                      body: SportsReplaysPanel(
                          key: key,
                          active: active,
                          highlights: highlights,
                          service: service,
                          dateService: _FailingDates(),
                          onPlay: (_) async {}))));
      await tester.pumpWidget(app());
      await tester.pump();
      expect(service.pending, hasLength(1));
      for (var i = 0; i < 50; i++) {
        guide.guideRowsLoaded.value++;
      }
      final forced = key.currentState!.refresh(force: true);
      expect(key.currentState!.refresh(), same(forced));
      expect(service.pending, hasLength(1));
      service.pending.first.complete(snapshot('First replay'));
      await tester.pump();
      expect(service.pending, hasLength(2));
      expect(service.forces, [false, true]);
      service.pending.last.complete(snapshot('Updated replay'));
      await tester.pumpAndSettle();
      expect(await forced, true);
      expect(service.pending, hasLength(2));
      expect(find.text('Updated replay'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'optional date failure cannot break guide browsing');

      // Rows arriving while idle also refresh without a general guide notification.
      guide.guideRowsLoaded.value++;
      await tester.pump(const Duration(milliseconds: 210));
      expect(service.pending, hasLength(3));
      playlist.rows = [];
      playlist.notifyListeners();
      service.pending.last.complete(snapshot('Removed channel result'));
      await tester.pump();
      expect(find.text('Removed channel result'), findsNothing);
      expect(service.pending, hasLength(4));
      expect(service.inputs.last, isEmpty);
      service.pending.last.complete(snapshot('Current catalogue'));
      await tester.pumpAndSettle();

      // A background panel must not start its queued scan or periodic scans.
      final background = key.currentState!.refresh();
      key.currentState!.refresh(force: true);
      await tester.pump();
      final count = service.pending.length;
      await tester.pumpWidget(app(active: false));
      expect(service.cancellations.last!(), isTrue);
      service.pending.last.complete(snapshot('Before pause'));
      await tester.pumpAndSettle();
      await background;
      await tester.pump(const Duration(seconds: 31));
      expect(service.pending, hasLength(count));
      await tester.pumpWidget(app());
      await tester.pump();
      expect(service.pending, hasLength(count + 1));
      expect(service.forces.last, true);
      service.pending.last.completeError(StateError('Guide unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Before pause'), findsNothing);
      expect(find.text('Current catalogue'), findsOneWidget);
      expect(
          tester
              .widget<SportsActivityLine>(find.byType(SportsActivityLine))
              .details,
          'Couldn’t read the guide. Tap refresh to retry.');
      final retry = key.currentState!.refresh(force: true);
      await tester.pump();
      service.pending.last.complete(snapshot('Recovered replay'));
      await tester.pumpAndSettle();
      expect(await retry, true);
      expect(find.text('Recovered replay'), findsOneWidget);
      expect(
          tester
              .widget<SportsActivityLine>(find.byType(SportsActivityLine))
              .hasError,
          isFalse);
      expect(service.peak, 1);
      expect(tester.takeException(), isNull);

      // Returning before cancellation reaches the worker must not revive the
      // old generation or leave the newly active panel without a refresh.
      final returning = key.currentState!.refresh();
      await tester.pump();
      final oldTask = service.pending.last;
      final oldCancelled = service.cancellations.last!;
      final beforeReturn = service.pending.length;
      await tester.pumpWidget(app(active: false));
      await tester.pumpWidget(app());
      expect(oldCancelled(), isTrue);
      expect(service.pending, hasLength(beforeReturn));
      oldTask.complete(snapshot('Abandoned result'));
      await tester.pump();
      expect(find.text('Abandoned result'), findsNothing);
      expect(service.pending, hasLength(beforeReturn + 1));
      expect(service.cancellations.last!(), isFalse);
      service.pending.last.complete(snapshot('Returned replay'));
      await tester.pumpAndSettle();
      expect(await returning, isTrue);
      expect(find.text('Returned replay'), findsOneWidget);
      expect(service.peak, 1);

      // A late completion after closing cannot restart work or touch disposed UI.
      final closing = key.currentState!.refresh();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(service.cancellations.last!(), isTrue);
      service.pending.last.complete(snapshot('Too late'));
      await tester.pump();
      expect(await closing, false);
      guide.guideRowsLoaded.value++;
      expect(tester.takeException(), isNull);
      playlist.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }
}
