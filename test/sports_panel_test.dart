import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/screens/sports_league_manager_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/sports_panel.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'package:nox_iptv/widgets/sports_hub_layout.dart';

Future<(StorageService, AppPreferences)> preferences(bool television) async {
  SharedPreferences.setMockInitialValues({});
  final storage = StorageService();
  await storage.init();
  await storage.setSportsLeagues(['nhl']);
  final prefs = AppPreferences(storage);
  await prefs.init();
  prefs.isTelevision = television;
  return (storage, prefs);
}

Widget app(StorageService storage, AppPreferences prefs, Widget child,
        {double keyboard = 0}) =>
    MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        ChangeNotifierProvider<AppPreferences>.value(value: prefs),
      ],
      child: MaterialApp(
        theme: buildAppTheme(prefs.palette),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewInsets: EdgeInsets.only(bottom: keyboard),
            padding: const EdgeInsets.only(top: 24, bottom: 16),
          ),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );

void viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final panel in [true, false]) {
    testWidgets(
        'sports overlays centre in the content column without dimming: panel=$panel',
        (tester) async {
      viewport(tester, const Size(1280, 720));
      final (storage, prefs) = await preferences(true);
      addTearDown(prefs.dispose);
      await tester.pumpWidget(app(
          storage,
          prefs,
          Builder(
              builder: (context) => TextButton(
                  onPressed: () {
                    if (panel) {
                      showSportsPanel<void>(
                          context: context,
                          maxWidth: 420,
                          builder: (_) => const Text('Panel'));
                    } else {
                      showSportsChoices(context,
                          title: 'Panel',
                          selected: '',
                          choices: const [SportsChoice('one', 'One', '')]);
                    }
                  },
                  child: const Text('Open')))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final rect = tester.getRect(panel
          ? find.byKey(const ValueKey('sports-panel-surface'))
          : find
              .descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.byType(Material))
              .first);
      final left = 20 + sportsPreviewWidth(1240) + 12;
      expect(rect.center.dx, closeTo((left + 1260) / 2, .1));
      expect(rect.left, greaterThan(left));
      expect(rect.right, lessThan(1260));
      expect(ModalRoute.of(tester.element(find.text('Panel')))!.barrierColor,
          Colors.transparent);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      final portrait = tester.getRect(panel
          ? find.byKey(const ValueKey('sports-panel-surface'))
          : find
              .descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.byType(Material))
              .first);
      expect(portrait.center.dx, closeTo(195, .1));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('side panel centres and uses portrait width after rotation',
      (tester) async {
    viewport(tester, const Size(960, 540));
    final (storage, prefs) = await preferences(true);
    addTearDown(prefs.dispose);
    await tester.pumpWidget(app(storage, prefs, Builder(builder: (context) {
      return TextButton(
          onPressed: () => showSportsPanel<void>(
              context: context,
              besidePreview: true,
              builder: (_) => const TextField()),
          child: const Text('Open'));
    })));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('sports-panel-surface'));
    expect(tester.getRect(surface).left, greaterThan(360));
    await tester.enterText(find.byType(TextField), 'Retained query');
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(tester.getRect(surface).center.dx, closeTo(195, .1));
    expect(tester.getSize(surface).width, 366);
    expect(find.text('Retained query'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'TV panel is instant, bounded, guarded and restores underlying focus',
      (tester) async {
    viewport(tester, const Size(960, 540));
    final (storage, prefs) = await preferences(true);
    addTearDown(prefs.dispose);
    final origin = FocusNode();
    final inside = FocusNode();
    addTearDown(origin.dispose);
    addTearDown(inside.dispose);
    Future<bool?>? result;
    Future<bool?>? duplicate;
    var disposed = false;
    Widget panel(BuildContext context) => Center(
            child: TextButton(
          focusNode: inside,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Done'),
        ));
    await tester.pumpWidget(app(
        storage,
        prefs,
        _PreviewSpy(
          onDispose: () => disposed = true,
          child: Builder(
              builder: (context) => TextButton(
                    focusNode: origin,
                    autofocus: true,
                    onPressed: () {
                      result = showSportsPanel<bool>(
                          context: context, builder: panel);
                      duplicate = showSportsPanel<bool>(
                          context: context, builder: panel);
                    },
                    child: const Text('Open'),
                  )),
        )));
    await tester.pumpAndSettle();
    final previous = tester.state(find.byType(_PreviewSpy));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(await duplicate, isNull);
    expect(find.byKey(const ValueKey('sports-panel-surface')), findsOneWidget);
    final bounds =
        tester.getRect(find.byKey(const ValueKey('sports-panel-surface')));
    expect(bounds.width, lessThanOrEqualTo(600));
    expect(bounds.left, greaterThan(360));
    expect(bounds.right, lessThanOrEqualTo(948));
    expect(disposed, isFalse);
    expect(identical(tester.state(find.byType(_PreviewSpy)), previous), isTrue);
    final route = ModalRoute.of(tester.element(find.text('Done')))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(route.traversalEdgeBehavior, TraversalEdgeBehavior.closedLoop);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(inside.hasFocus, isTrue);
    expect(origin.hasFocus, isFalse);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(origin.hasFocus, isTrue);
    expect(disposed, isFalse);
  });

  for (final method in ['close', 'back', 'barrier']) {
    testWidgets(
        'embedded league manager persists and returns change via $method',
        (tester) async {
      viewport(tester, const Size(960, 540));
      final (storage, prefs) = await preferences(true);
      addTearDown(prefs.dispose);
      Future<bool?>? result;
      await tester.pumpWidget(app(
          storage,
          prefs,
          Builder(
              builder: (context) => TextButton(
                    onPressed: () => result = showSportsPanel<bool>(
                        context: context,
                        builder: (_) =>
                            const SportsLeagueManagerScreen(embedded: true)),
                    child: const Text('Edit leagues'),
                  ))));
      await tester.tap(find.text('Edit leagues'));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('sports-panel-surface')),
              matching: find.byType(Scaffold)),
          findsOneWidget);
      final firstRow = FocusManager.instance.primaryFocus!;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      final search = tester.widget<TextField>(
          find.byKey(const ValueKey('league-manager-search')));
      expect(search.focusNode!.hasFocus, isTrue);
      final all = tester.widget<OutlinedButton>(
          find.byKey(const ValueKey('enable-all-leagues')));
      all.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(storage.getSportsAllLeagues(), isTrue);
      expect(find.text('All leagues favourited'), findsOneWidget);
      if (method == 'back') {
        firstRow.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pumpAndSettle();
        expect(
            tester.widget<ListView>(find.byType(ListView)).controller!.offset,
            greaterThan(0));
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            firstRow.debugLabel);
        final firstTile = find
            .byKey(ValueKey(firstRow.debugLabel!.substring('choice-'.length)));
        expect(firstTile.hitTestable(), findsOneWidget);
        final listBounds = tester.getRect(find.byType(ListView));
        final rowBounds = tester.getRect(firstTile);
        expect(rowBounds.top, greaterThanOrEqualTo(listBounds.top));
        expect(rowBounds.bottom, lessThanOrEqualTo(listBounds.bottom));
      }
      if (method == 'close') {
        await tester.tap(find.byKey(const ValueKey('close-leagues')));
      } else if (method == 'back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(const Offset(30, 200));
      }
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(find.byKey(const ValueKey('sports-panel-surface')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(360, 640), const Size(844, 390)]) {
    testWidgets('mobile panel fits safe areas and keyboard at $size',
        (tester) async {
      viewport(tester, size);
      final (storage, prefs) = await preferences(false);
      addTearDown(prefs.dispose);
      await tester.pumpWidget(app(
          storage,
          prefs,
          Builder(
              builder: (context) => TextButton(
                    onPressed: () => showSportsPanel<void>(
                        context: context,
                        builder: (context) => Column(children: [
                              const TextField(
                                  decoration:
                                      InputDecoration(labelText: 'Search')),
                              const Expanded(child: SizedBox()),
                              TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Close')),
                            ])),
                    child: const Text('Open'),
                  )),
          keyboard: 180));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final bounds =
          tester.getRect(find.byKey(const ValueKey('sports-panel-surface')));
      expect(bounds.width, lessThanOrEqualTo(600));
      expect(bounds.top, greaterThanOrEqualTo(24));
      expect(bounds.bottom, lessThanOrEqualTo(size.height - 180 - 16));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });
  }
}

class _PreviewSpy extends StatefulWidget {
  const _PreviewSpy({required this.child, required this.onDispose});
  final Widget child;
  final VoidCallback onDispose;
  @override
  State<_PreviewSpy> createState() => _PreviewSpyState();
}

class _PreviewSpyState extends State<_PreviewSpy> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
