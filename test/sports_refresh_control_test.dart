import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/sports_refresh_control.dart';

void main() {
  Future<void> mount(WidgetTester tester, Future<bool> Function()? refresh,
      {bool reducedMotion = false}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Scaffold(
          body: Column(children: [
            const SizedBox(height: 180, child: Center(child: Text('Preview'))),
            Expanded(
              child: CustomScrollView(
                key: const ValueKey('events'),
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                slivers: [
                  SportsRefreshControl(onRefresh: refresh),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 100,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: 20,
                        itemBuilder: (_, i) => SizedBox(
                            width: 180, child: Center(child: Text('Event $i'))),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 1200)),
                ],
              ),
            ),
          ]),
        ),
      ),
    ));
  }

  Future<TestGesture> pull(WidgetTester tester, {int steps = 8}) async {
    final gesture = await tester.startGesture(const Offset(100, 300));
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
    return gesture;
  }

  testWidgets('small pulls and horizontal event swipes do not refresh',
      (tester) async {
    var calls = 0;
    await mount(tester, () async {
      calls++;
      return true;
    });
    await tester.drag(find.text('Event 0'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    final gesture = await pull(tester, steps: 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Pull to refresh'), findsNothing);
  });

  testWidgets('one refresh and haptic, fixed preview, then success and retract',
      (tester) async {
    final result = Completer<bool>();
    var calls = 0;
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await mount(tester, () {
      calls++;
      return result.future;
    });
    final previewPosition = tester.getTopLeft(find.text('Preview'));
    final gesture = await pull(tester);
    expect(calls, 1);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
    expect(find.text('Updating scores…'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Preview')), previewPosition);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));
    result.complete(true);
    await tester.pump();
    expect(find.text('Scores updated'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Scores updated'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed refresh retracts and allows a retry, with reduced motion',
      (tester) async {
    var calls = 0;
    await mount(tester, () async {
      calls++;
      throw StateError('Offline');
    }, reducedMotion: true);
    final gesture = await pull(tester);
    expect(
        tester
            .widget<CupertinoActivityIndicator>(
                find.byType(CupertinoActivityIndicator))
            .animating,
        isFalse);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Couldn’t refresh'), findsOneWidget);
    expect(find.text('Scores updated'), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final retry = await pull(tester);
    await retry.up();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during refresh is safe', (tester) async {
    final result = Completer<bool>();
    await mount(tester, () => result.future);
    final gesture = await pull(tester);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
    result.complete(true);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
