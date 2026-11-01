import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/sports_feed_diagnostics.dart';

void main() {
  for (final palette in AppConstants.cyberpunkPalettes
      .where((p) => ['classic_tv', 'oled', 'light'].contains(p.id))) {
    for (final accessible in [false, true]) {
      testWidgets(
          'feed notice dismisses and matches ${palette.id}, accessibility=$accessible',
          (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final theme = buildAppTheme(palette);
        late BuildContext source;
        var details = 0;
        await tester.pumpWidget(MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(accessibleNavigation: accessible),
                child: child!),
            home: Scaffold(body: Builder(builder: (context) {
              source = context;
              return const SizedBox.expand();
            }))));
        void show() => showSportsFeedNotice(source, onDetails: () => details++);
        show();
        await tester.pumpAndSettle();
        final notice = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(
            notice.backgroundColor, theme.colorScheme.surfaceContainerHighest);
        expect(
            (notice.content as Text).style!.color, theme.colorScheme.onSurface);
        if (theme.colorScheme.brightness == Brightness.dark) {
          expect(notice.backgroundColor!.computeLuminance(), lessThan(.2));
        }
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        show();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        show();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Details'));
        await tester.pumpAndSettle();
        expect(details, 1);
        expect(find.byType(SnackBar), findsNothing);
        show();
        show();
        show();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing,
            reason: 'Repeated notices must not form a lingering queue');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
