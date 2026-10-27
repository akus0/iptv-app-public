import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/screens/sports_league_manager_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new installs enable the full catalogue, including recent competitions',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    expect(storage.getSportsAllLeagues(), isTrue);
    final ids = savedSportsLeagues(storage).map((l) => l.id).toSet();
    expect(ids, kDefaultSportsLeagueIds.toSet());
    expect(
        ids,
        containsAll([
          'eng.2',
          'eng.3',
          'eng.4',
          'eng.5',
          'mma.ufc',
          'mma.pfl',
          'racing.f1',
          'tennis.atp',
          'tennis.wta',
          'guide.npb',
          'guide.kbo',
          'rugby.live',
          'guide.poker'
        ]));
    expect(sportsLeagueById('eng.2')!.region, 'England');
    for (final league in kSportsLeagueBank) {
      expect(kSportsLeagueRegions, contains(league.region), reason: league.id);
    }
    await storage.setSportsLeagues(['nhl']);
    expect(storage.getSportsAllLeagues(), isFalse);
    final reloaded = StorageService();
    await reloaded.init();
    expect(savedSportsLeagues(reloaded).any((l) => l.id == 'eng.2'), isFalse,
        reason: 'Explicit custom choices survive restart');
  });
  for (final size in [const Size(390, 844), const Size(960, 540)]) {
    testWidgets('single list enables every league and persists at $size',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsAddedLeagues([]);
      await storage.setHiddenGuideLeagues(
          kAutomaticSportsLeagues.map((l) => l.id).toList());
      await storage.setSportsFavoriteLeague('nhl');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width > 700;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(prefs.dispose);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storage),
            ChangeNotifierProvider<AppPreferences>.value(value: prefs),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              home: const SportsLeagueManagerScreen())));
      await tester.pumpAndSettle();
      expect(savedSportsLeagues(storage).map((l) => l.id), ['nhl']);
      expect(find.text('League bank'), findsNothing);
      expect(find.text('Your leagues'), findsNothing);
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        final button = tester.widget<OutlinedButton>(
            find.byKey(const ValueKey('enable-all-leagues')));
        expect(button.focusNode!.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(find.byKey(const ValueKey('enable-all-leagues')));
      }
      await tester.pumpAndSettle();
      final all = {
        ...kSportsLeagues.map((l) => l.id),
        ...kSportsLeagueBank.map((l) => l.id)
      };
      final saved = savedSportsLeagues(storage).map((l) => l.id).toList();
      expect(saved.toSet(), all);
      expect(saved.length, all.length,
          reason: 'Automatic competitions must not be duplicated');
      expect(storage.getSportsFavoriteLeague(), 'nhl');
      expect(storage.getHiddenGuideLeagues(), isEmpty);
      expect(storage.getSportsAllLeagues(), isTrue);
      expect(find.text('All leagues enabled'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('EFL Championship'), 250,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('EFL Championship'), findsOneWidget);
      // A league remains in place when disabled, and can be enabled directly
      // even when the legacy added-leagues preference is empty.
      await tester.tap(find.text('EFL Championship'));
      await tester.pumpAndSettle();
      expect(savedSportsLeagues(storage).any((l) => l.id == 'eng.2'), isFalse);
      expect(find.text('EFL Championship'), findsOneWidget);
      await tester.tap(find.text('EFL Championship'));
      await tester.pumpAndSettle();
      expect(storage.getSportsAddedLeagues(), isEmpty);
      expect(savedSportsLeagues(storage).any((l) => l.id == 'eng.2'), isTrue);
      final reloaded = StorageService();
      await reloaded.init();
      expect(savedSportsLeagues(reloaded).map((l) => l.id).toSet(), all);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
