import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

void main() {
  for (final television in [false, true]) {
    testWidgets('Material routes honour TV transition policy: $television',
        (tester) async {
      final palette = AppConstants.cyberpunkPalettes.first;
      final theme = buildAppTheme(palette, instantPageTransitions: television);
      final navigator = GlobalKey<NavigatorState>();
      var disposed = false;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        theme: theme,
        home: const Scaffold(body: Text('Home')),
      ));
      final route = MaterialPageRoute<void>(
          builder: (_) => _Detail(onDispose: () => disposed = true));
      navigator.currentState!.push(route);
      await tester.pump();
      if (television) {
        expect(route.transitionDuration, Duration.zero);
        expect(route.reverseTransitionDuration, Duration.zero);
        expect(route.animation!.status, AnimationStatus.completed);
      } else {
        expect(route.transitionDuration, greaterThan(Duration.zero));
        expect(route.reverseTransitionDuration, greaterThan(Duration.zero));
      }
      await tester.pumpAndSettle();
      expect(find.text('Detail'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pump();
      if (television) {
        await tester.pump();
        expect(disposed, isTrue);
        expect(find.text('Home'), findsOneWidget);
      } else {
        expect(disposed, isFalse);
      }
      await tester.pumpAndSettle();
      expect(disposed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  test('Both theme variants retain their identity until the palette changes',
      () {
    final palette = AppConstants.cyberpunkPalettes.first;
    final regular = buildAppTheme(palette);
    final tv = buildAppTheme(palette, instantPageTransitions: true);
    expect(buildAppTheme(palette), same(regular));
    expect(buildAppTheme(palette, instantPageTransitions: true), same(tv));
    final other = AppConstants.cyberpunkPalettes.last;
    expect(buildAppTheme(other, instantPageTransitions: true), isNot(same(tv)));
    expect(buildAppTheme(other), isNot(same(regular)));
  });
}

class _Detail extends StatefulWidget {
  const _Detail({required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Detail'));
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}
