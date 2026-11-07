import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/widgets/sports_activity_status.dart';
import 'package:nox_iptv/widgets/sports_refresh_control.dart';

void main() {
  setUpAll(() async {
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    if (fonts.isEmpty) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'Ahem': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(File('$fonts/${entry.value}')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
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

    await show();
    expect(find.textContaining('Not all checked'), findsOneWidget);
    await show(loading: true);
    expect(find.textContaining('Loading'), findsOneWidget);
    expect(find.textContaining('Waiting'), findsOneWidget);
    final size = tester.getSize(find.byType(SportsActivityStatus));
    channels.value = const SportsWorkProgress(SportsWorkStage.guide);
    extras.value = true;
    await show(usable: true, checking: true);
    expect(find.textContaining('Adding more'), findsOneWidget);
    expect(find.textContaining('Guide'), findsOneWidget);
    extras.value = false;
    channels.value = const SportsWorkProgress(SportsWorkStage.matching,
        completed: 2, total: 5);
    await tester.pump();
    expect(find.textContaining('Loaded'), findsOneWidget);
    expect(find.textContaining('Matching 40%'), findsOneWidget);
    channels.value = null;
    await show(usable: true, checked: 5);
    expect(find.textContaining('Checked'), findsOneWidget);
    expect(tester.getSize(find.byType(SportsActivityStatus)), size);
    expect(tester.binding.hasScheduledFrame, false);
    await show(usable: true, checked: 5, error: 'Guide lookup failed');
    expect(find.textContaining('Check failed'), findsOneWidget);
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
            width: compact ? 276 : 600,
            child: SportsActivityStatus(
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
          return const Text('Event cards');
        }),
      ]))));
      final top = tester.getTopLeft(find.text('Event cards'));
      scores.value = const SportsWorkProgress(SportsWorkStage.scores,
          completed: 2, total: 30, detail: 'ATP');
      channels.value = const SportsWorkProgress(SportsWorkStage.guide);
      await tester.pump();
      expect(find.textContaining('Loading 6%'), findsOneWidget);
      expect(find.textContaining('Guide'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Event cards')), top);
      expect(cardBuilds, 1);
      for (var i = 0; i < 10; i++) {
        channels.value = SportsWorkProgress(SportsWorkStage.matching,
            completed: i, total: 239);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.textContaining('Matching 3%'), findsOneWidget);
      expect(cardBuilds, 1);
      await tester.tap(find.byIcon(Icons.refresh));
      expect(refreshes, 1);
      scores.value = channels.value = null;
      await tester.pump();
      expect(find.textContaining('Loaded'), findsOneWidget);
      expect(find.textContaining('Not all checked'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(find.text('Event cards')), top);
      await tester.pumpWidget(const SizedBox());
      scores.dispose();
      channels.dispose();
      pull.dispose();
    });
  }

  for (final width in [320.0, 390.0]) {
    for (final textScale in [1.0, 1.6]) {
      testWidgets('portrait inline progress at $width / $textScale',
          (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final scores = ValueNotifier<SportsWorkProgress?>(null);
        final channels = ValueNotifier<SportsWorkProgress?>(null);
        final pull = ValueNotifier<String?>(null);
        addTearDown(scores.dispose);
        addTearDown(channels.dispose);
        addTearDown(pull.dispose);
        var parentBuilds = 0, refreshes = 0, feedDetails = 0;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: MediaQueryData(
                size: Size(width, 844),
                textScaler: TextScaler.linear(textScale)),
            child: Scaffold(body: Builder(builder: (context) {
              parentBuilds++;
              return Column(children: [
                SizedBox(
                    height: 54 * textScale,
                    child: Row(children: [
                      const Expanded(
                          child: Text('Preview title',
                              key: ValueKey('preview-title'))),
                      SizedBox(
                          width: ((width - 24) * .48).clamp(140.0, 180.0) - 8,
                          child: SportsActivityStatus(
                            inline: true,
                            scores: scores,
                            channels: channels,
                            pull: pull,
                            eventCount: 250,
                            checkedCount: 10,
                            onFeedDetails: (_) => feedDetails++,
                            refreshButton: SizedBox(
                                width: 40,
                                height: 44,
                                child: IconButton(
                                    tooltip:
                                        'Refresh events and channel matches',
                                    onPressed: () => refreshes++,
                                    icon: const Icon(Icons.refresh))),
                          )),
                    ])),
                const Text('Event cards'),
              ]);
            })),
          ),
        ));
        final listTop = tester.getTopLeft(find.text('Event cards'));
        final initial = tester.getRect(find.byType(SportsActivityStatus));
        for (final stage in SportsWorkStage.values) {
          scores.value = const SportsWorkProgress(SportsWorkStage.scores,
              completed: 12, total: 152);
          channels.value =
              SportsWorkProgress(stage, completed: 1500, total: 19101);
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byType(SportsActivityStatus)), initial);
          expect(tester.getTopLeft(find.text('Event cards')), listTop);
          expect(parentBuilds, 1);
          expect(tester.binding.hasScheduledFrame, false);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byTooltip('Refresh events and channel matches'));
        expect(refreshes, 1);
        scores.value = const SportsWorkProgress(SportsWorkStage.scores,
            completed: 12, total: 152, failed: 2);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('sports-status-details')));
        await tester.pumpAndSettle();
        expect(find.text('12 / 152'), findsOneWidget);
        await tester.ensureVisible(find.text('Event feed error details'));
        await tester.tap(find.text('Event feed error details'));
        expect(feedDetails, 1);
        scores.value = const SportsWorkProgress(SportsWorkStage.scores,
            completed: 30, total: 152);
        await tester.pumpAndSettle();
        expect(find.text('30 / 152'), findsOneWidget);
        expect(find.text('Event feed error details'), findsNothing);
        expect(parentBuilds, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [276.0, 320.0, 390.0, 480.0]) {
    for (final textScale in [1.0, 1.6]) {
      testWidgets('status stays readable and stationary at $width / $textScale',
          (tester) async {
        final scores = ValueNotifier<SportsWorkProgress?>(null);
        final channels = ValueNotifier<SportsWorkProgress?>(null);
        final pull = ValueNotifier<String?>(null);
        addTearDown(scores.dispose);
        addTearDown(channels.dispose);
        addTearDown(pull.dispose);
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
                body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                        width: width,
                        child: MediaQuery(
                          data: MediaQueryData(
                              size: Size(width, 844),
                              textScaler: TextScaler.linear(textScale)),
                          child: SportsActivityStatus(
                            scores: scores,
                            channels: channels,
                            pull: pull,
                            eventCount: 250,
                            checkedCount: 10,
                            refreshButton: TextButton.icon(
                                onPressed: () {},
                                icon: const Icon(Icons.refresh, size: 13),
                                label: const Text('Refresh both',
                                    style: TextStyle(fontSize: 10.5))),
                          ),
                        ))))));
        final original = tester.getRect(find.byType(SportsActivityStatus));
        for (final stage in SportsWorkStage.values) {
          channels.value =
              SportsWorkProgress(stage, completed: 1500, total: 19101);
          scores.value = const SportsWorkProgress(SportsWorkStage.scores,
              completed: 12, total: 152, failed: 2);
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byType(SportsActivityStatus)), original);
          for (final key in ['events', 'channels']) {
            final text = find.byKey(ValueKey('sports-status-$key'));
            final paragraph = tester.renderObject<RenderParagraph>(text);
            expect(paragraph.didExceedMaxLines, false,
                reason:
                    '$key must be readable at $width / $textScale / $stage');
          }
          expect(tester.takeException(), isNull);
          expect(tester.binding.hasScheduledFrame, false);
        }
        await tester.tap(find.byKey(const ValueKey('sports-status-details')));
        await tester.pumpAndSettle();
        expect(find.text('Events & channel status'), findsOneWidget);
        expect(find.text('12 / 152'), findsOneWidget);
        expect(find.textContaining('does not download your playlist'),
            findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
          await tester.runAsync(() async {
            final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
                find.byType(RepaintBoundary));
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('/tmp/iptv-status-$width-$textScale.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }

  testWidgets(
      'live details coalesce progress and receive completion and source changes',
      (tester) async {
    final scores = ValueNotifier<SportsWorkProgress?>(const SportsWorkProgress(
        SportsWorkStage.scores,
        completed: 4,
        total: 30));
    final firstChannels = ValueNotifier<SportsWorkProgress?>(
        const SportsWorkProgress(SportsWorkStage.matching,
            completed: 7, total: 80));
    final replacement = ValueNotifier<SportsWorkProgress?>(null);
    final pull = ValueNotifier<String?>(null);
    addTearDown(scores.dispose);
    addTearDown(firstChannels.dispose);
    addTearDown(replacement.dispose);
    addTearDown(pull.dispose);
    var channels = firstChannels;
    var loading = true, checking = true, active = true;
    var eventCount = 80, checkedCount = 2, parentBuilds = 0;
    String? channelError;
    late StateSetter change;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      change = setState;
      parentBuilds++;
      return SportsActivityStatus(
          scores: scores,
          channels: channels,
          pull: pull,
          loadingEvents: loading,
          checkingChannels: checking,
          active: active,
          eventCount: eventCount,
          checkedCount: checkedCount,
          channelError: channelError,
          refreshButton: const SizedBox(width: 80));
    }))));
    await tester.tap(find.byKey(const ValueKey('sports-status-details')));
    await tester.pumpAndSettle();
    expect(find.text('4 / 30'), findsOneWidget);
    expect(find.text('7 / 80'), findsOneWidget);
    var detailBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget.runtimeType.toString() == '_ActivityDetailCard') {
        detailBuilds++;
      }
      previous?.call(element, builtOnce);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    final before = parentBuilds;
    for (var i = 1; i <= 50; i++) {
      channels.value =
          SportsWorkProgress(SportsWorkStage.matching, completed: i, total: 80);
    }
    scores.value = const SportsWorkProgress(SportsWorkStage.scores,
        completed: 12, total: 30);
    await tester.pumpAndSettle();
    expect(find.text('50 / 80'), findsOneWidget);
    expect(find.text('12 / 30'), findsOneWidget);
    expect(parentBuilds, before);
    expect(detailBuilds, 2,
        reason: 'A burst rebuilds the two detail cards once');
    expect(tester.binding.hasScheduledFrame, false);
    if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
      await tester.runAsync(() async {
        RenderObject? node = tester
            .renderObject(find.byKey(const ValueKey('sports-detail-heading')));
        RenderRepaintBoundary? boundary;
        while (node != null) {
          if (node is RenderRepaintBoundary) boundary = node;
          node = node.parent;
        }
        final image = await boundary!.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/iptv-status-live-dialog.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    // Non-listenable widget fields also reach the open popup after the host builds.
    scores.value = channels.value = null;
    change(() {
      loading = checking = false;
      checkedCount = eventCount = 84;
    });
    await tester.pumpAndSettle();
    expect(find.text('84 / 84'), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('sports-detail-heading')))
            .data,
        'Checks complete');

    change(() {
      channels = replacement;
      active = false;
      checking = true;
    });
    await tester.pumpAndSettle();
    replacement.value = const SportsWorkProgress(SportsWorkStage.guide,
        completed: 400, total: 900);
    firstChannels.value = const SportsWorkProgress(SportsWorkStage.matching,
        completed: 1, total: 999);
    await tester.pumpAndSettle();
    expect(find.text('400 / 900'), findsOneWidget);
    expect(find.text('1 / 999'), findsNothing);
    change(() {
      checking = false;
      channelError = 'Guide check unavailable';
    });
    replacement.value = null;
    await tester.pumpAndSettle();
    expect(find.text('Guide check unavailable'), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('sports-detail-heading')))
            .data,
        'Update incomplete');

    replacement.value = const SportsWorkProgress(SportsWorkStage.guide);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final closedBuilds = detailBuilds;
    change(() {
      channelError = null;
      checking = true;
    });
    replacement.value = const SportsWorkProgress(SportsWorkStage.guide,
        completed: 899, total: 900);
    await tester.pumpAndSettle();
    expect(detailBuilds, closedBuilds);
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, false);
    await tester.tap(find.byKey(const ValueKey('sports-status-details')));
    await tester.pumpAndSettle();
    expect(find.text('899 / 900'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV status details scroll with the remote in a short viewport',
      (tester) async {
    tester.view.physicalSize = const Size(700, 280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scores = ValueNotifier<SportsWorkProgress?>(null);
    final channels = ValueNotifier<SportsWorkProgress?>(null);
    final pull = ValueNotifier<String?>(null);
    addTearDown(scores.dispose);
    addTearDown(channels.dispose);
    addTearDown(pull.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SportsActivityStatus(
                television: true,
                scores: scores,
                channels: channels,
                pull: pull,
                eventCount: 250,
                checkedCount: 12,
                refreshButton: const SizedBox(width: 90)))));
    await tester.tap(find.byKey(const ValueKey('sports-status-details')));
    await tester.pumpAndSettle();
    final node =
        tester.element(find.byKey(const ValueKey('sports-status-scroll')));
    final position = Scrollable.of(node).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(position.pixels, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

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
