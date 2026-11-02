import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/widgets/sports_activity_status.dart';
import 'package:nox_iptv/widgets/sports_refresh_control.dart';

void main() {
  testWidgets('cold loading shows real progress without a perpetual ticker',
      (tester) async {
    final scores = ValueNotifier<SportsWorkProgress?>(null);
    final channels = ValueNotifier<SportsWorkProgress?>(null);
    addTearDown(scores.dispose);
    addTearDown(channels.dispose);
    var surroundingBuilds = 0;
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (_) {
      surroundingBuilds++;
      return SportsEventsLoading(
          scores: scores, channels: channels, eventCount: 0);
    }))));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final location = tester.getTopLeft(find.text('Loading events'));
    scores.value = const SportsWorkProgress(SportsWorkStage.scores,
        completed: 12, total: 30);
    await tester.pumpAndSettle();
    expect(find.text('12 of 30 event feeds checked'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byKey(const ValueKey('sports-initial-progress')))
            .value,
        .4);
    expect(surroundingBuilds, 1);
    expect(tester.getTopLeft(find.text('Loading events')), location);
    expect(tester.binding.hasScheduledFrame, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending card advances stages without rebuilding its event',
      (tester) async {
    final stage = ValueNotifier<SportsWorkStage?>(SportsWorkStage.guide);
    addTearDown(stage.dispose);
    var cardBuilds = 0;
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(
            width: 216,
            child: Builder(builder: (_) {
              cardBuilds++;
              return SportsEventMatchStatus(stage: stage, color: Colors.white);
            }))));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for guide'), findsOneWidget);
    stage.value = SportsWorkStage.matching;
    await tester.pumpAndSettle();
    expect(find.text('Looking for a channel'), findsOneWidget);
    stage.value = SportsWorkStage.verifying;
    await tester.pumpAndSettle();
    expect(find.text('Finishing channel check'), findsOneWidget);
    stage.value = null;
    await tester.pumpAndSettle();
    expect(find.text('Waiting for channel check'), findsOneWidget);
    expect(cardBuilds, 1);
    expect(tester.binding.hasScheduledFrame, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('readiness keeps both outstanding tasks visible through handoffs',
      (tester) async {
    final scores = ValueNotifier<SportsWorkProgress?>(null);
    final channels = ValueNotifier<SportsWorkProgress?>(null);
    final extras = ValueNotifier<bool>(false);
    final pull = ValueNotifier<String?>(null);
    addTearDown(scores.dispose);
    addTearDown(channels.dispose);
    addTearDown(extras.dispose);
    addTearDown(pull.dispose);
    Future<void> show(
        {bool loading = false,
        bool checking = false,
        bool usable = false,
        int checked = 0,
        String? error}) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 210,
                  child: SportsActivityStatus(
                      compact: true,
                      scores: scores,
                      channels: channels,
                      pull: pull,
                      moreEvents: extras,
                      loadingEvents: loading,
                      checkingChannels: checking,
                      hasUsableEvents: usable,
                      channelError: error,
                      eventCount: 5,
                      checkedCount: checked,
                      refreshButton: const SizedBox(width: 30))))));
    }

    await show(loading: true);
    expect(find.textContaining('Events: loading'), findsOneWidget);
    expect(find.textContaining('Channels: waiting'), findsOneWidget);
    final size = tester.getSize(find.byType(SportsActivityStatus));
    channels.value = const SportsWorkProgress(SportsWorkStage.guide);
    extras.value = true;
    await show(usable: true, checking: true);
    expect(find.textContaining('Browse now'), findsOneWidget);
    expect(find.textContaining('Events: adding more'), findsOneWidget);
    expect(find.textContaining('Channels: guide scan'), findsOneWidget);
    extras.value = false;
    channels.value = const SportsWorkProgress(SportsWorkStage.matching,
        completed: 2, total: 5);
    await tester.pump();
    expect(find.textContaining('Events: loaded'), findsOneWidget);
    expect(find.textContaining('Channels: 3 events left'), findsOneWidget);
    channels.value = null;
    await show(usable: true, checked: 5);
    expect(find.textContaining('Ready to browse'), findsOneWidget);
    expect(find.textContaining('Channels: checked'), findsOneWidget);
    expect(tester.getSize(find.byType(SportsActivityStatus)), size);
    expect(tester.binding.hasScheduledFrame, false);
    await show(usable: true, checked: 5, error: 'Guide lookup failed');
    expect(find.textContaining('Browse · partial update'), findsOneWidget);
    expect(find.textContaining('Channels: check failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('progress is bounded and stage transitions remain observable', () {
    final messages = <SportsWorkProgress>[];
    final progress = SportsProgressReporter(messages.add);
    for (var i = 0; i < 80000; i++) {
      progress.report(SportsWorkStage.channels, completed: i, total: 80000);
    }
    progress.report(SportsWorkStage.guide);
    expect(messages.length, lessThan(5));
    expect(messages.last.stage, SportsWorkStage.guide);
  });

  for (final compact in [false, true]) {
    testWidgets(
        'work updates stay isolated with compact=$compact and keep refresh usable',
        (tester) async {
      final scores = ValueNotifier<SportsWorkProgress?>(null);
      final channels = ValueNotifier<SportsWorkProgress?>(null);
      final pull = ValueNotifier<String?>(null);
      var cardBuilds = 0, refreshes = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Column(children: [
        SizedBox(
            width: compact ? 129 : 600,
            child: SportsActivityStatus(
                compact: compact,
                scores: scores,
                channels: channels,
                pull: pull,
                eventCount: 239,
                checkedCount: 12,
                refreshButton: IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => refreshes++))),
        Builder(builder: (_) {
          cardBuilds++;
          return const Text('Events');
        }),
      ]))));
      final top = tester.getTopLeft(find.text('Events'));
      scores.value = const SportsWorkProgress(SportsWorkStage.scores,
          completed: 2, total: 30, detail: 'ATP');
      channels.value = const SportsWorkProgress(SportsWorkStage.guide);
      await tester.pump();
      expect(find.textContaining('Events: loading 6%'), findsOneWidget);
      expect(find.textContaining('Channels: guide scan'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Events')), top);
      expect(cardBuilds, 1);
      for (var i = 0; i < 10; i++) {
        channels.value = SportsWorkProgress(SportsWorkStage.matching,
            completed: i, total: 239);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.textContaining('Channels: 230 events left'), findsOneWidget);
      expect(cardBuilds, 1);
      await tester.tap(find.byIcon(Icons.refresh));
      expect(refreshes, 1);
      scores.value = channels.value = null;
      await tester.pump();
      expect(find.textContaining('Events: loaded'), findsOneWidget);
      expect(find.textContaining('Channels: not all checked'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(find.text('Events')), top);
      await tester.pumpWidget(const SizedBox());
      scores.dispose();
      channels.dispose();
      pull.dispose();
    });
  }

  testWidgets(
      'shared-status pull refresh holds no extra space during a slow request',
      (tester) async {
    final pending = Completer<bool>();
    final labels = <String?>[];
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CustomScrollView(
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        SportsRefreshControl(
            externalStatus: true,
            onPullChanged: labels.add,
            onRefresh: () {
              requests++;
              return pending.future;
            }),
        const SliverToBoxAdapter(
            child: SizedBox(
                height: 1200,
                child: Align(
                    alignment: Alignment.topLeft, child: Text('First event')))),
      ],
    ))));
    final position = tester.getTopLeft(find.text('First event'));
    final drag = await tester.startGesture(const Offset(100, 100));
    for (var i = 0; i < 8; i++) {
      await drag.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(requests, 1);
    await drag.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('First event')), position);
    expect(find.text('Updating scores…'), findsNothing);
    expect(labels, contains('Pull to refresh'));
    expect(labels.last, isNull);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('First event')), position);
    expect(tester.takeException(), isNull);
  });
}
