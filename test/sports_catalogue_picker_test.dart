import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/extended_sports.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';
import 'package:nox_iptv/widgets/sports_widgets.dart' show SportsLogo;

const addedScoreLeagues = [
  'aus.w.1',
  'ksa.kings.cup',
  'ind.2',
  'fifa.friendly',
  'fifa.friendly.w',
  'sco.cis',
  'sco.tennents',
  'eng.trophy',
  'concacaf.central.american.cup',
  'sco.2',
  'usa.w.usl.1',
  'fifa.wworld.u17',
  'mex.w.1',
  'col.1',
  'per.1',
  'conmebol.sudamericana',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    await storage.init();
  });

  test('every supported guide sport has a stable, enabled catalogue entry', () {
    final leagues = savedSportsLeagues(storage);
    final sports = sportsSportOptions(leagues, {}).map((o) => o.id).toSet();
    expect(
        sportsSportOptions(leagues, {})
            .singleWhere((o) => o.id == 'basketball')
            .currentLabel,
        'live / on air');
    for (final sport in extendedSportsPatterns.keys) {
      // Cricket and rugby intentionally require score-backed live matches.
      if (sport == 'cricket' || sport == 'rugby') continue;
      expect(sports, contains(sport), reason: sport);
      final choices = sportsLeagueOptions(leagues, {},
          sport: sport, favouriteCount: leagues.length);
      expect(choices.any((o) => o.id.startsWith('guide.')), isTrue,
          reason: sport);
    }
    final ids = sportsLeagueOptions(leagues, {}, favouriteCount: leagues.length)
        .map((o) => o.id)
        .toList();
    expect(ids.toSet().length, ids.length);
    expect(ids, containsAll(addedScoreLeagues));
    for (final id in addedScoreLeagues) {
      expect(sportsLeagueById(id)!.soccer, isTrue);
      expect(supportsSportsScoreboard(sportsLeagueById(id)!), isTrue);
    }
  });

  test('disabled guide sports stay disabled after saving and reopening',
      () async {
    await storage.setSportsLeagues(['nhl']);
    await storage.setHiddenGuideLeagues(['guide.badminton', 'guide.sumo']);
    final reload = StorageService();
    await reload.init();
    final leagues = savedSportsLeagues(reload);
    expect(sportsSportOptions(leagues, {}).map((o) => o.id),
        isNot(contains('badminton')));
    expect(leagues.map((l) => l.id), isNot(contains('guide.sumo')));
    expect(leagues.map((l) => l.id), isNot(contains('ind.2')));
  });

  for (final size in [const Size(390, 844), const Size(960, 540)]) {
    testWidgets('catalogue dropdown search works before events load at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width > 700;
      addTearDown(prefs.dispose);
      final leagues = savedSportsLeagues(storage);
      String? selection;
      for (final isSport in [true, false]) {
        await tester.pumpWidget(ChangeNotifierProvider.value(
            value: prefs,
            child: MaterialApp(
                theme: ThemeData.dark(),
                home: Builder(
                    builder: (context) => Scaffold(
                        body: TextButton(
                            onPressed: () async {
                              selection = await showSportsFilterPicker(context,
                                  title: isSport
                                      ? 'Choose sport'
                                      : 'Choose league',
                                  selected: '',
                                  options: isSport
                                      ? sportsSportOptions(leagues, {})
                                      : sportsLeagueOptions(leagues, {},
                                          favouriteCount: leagues.length));
                            },
                            child: const Text('Open')))))));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        if (!isSport) {
          expect(find.byType(SportsLogo), findsWidgets,
              reason:
                  'League choices use the same cached logos as management.');
        }
        // Read-only TV fields are intentionally gated behind OK; enable typing
        // through the same remote activation before using the test keyboard.
        if (prefs.isTelevision) {
          final field = tester.widget<TextField>(find.byType(TextField));
          field.focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
        }
        final queries = isSport
            ? {
                'Badminton': 'badminton',
                'Table tennis': 'table-tennis',
                'Sumo': 'sumo',
                'Ice skating': 'skating',
                'Padel': 'padel',
                'Taekwondo': 'taekwondo',
                'Sambo': 'sambo',
                'Sailing': 'sailing',
                'Climbing': 'climbing',
                'Gymnastics': 'gymnastics',
                'Wrestling': 'wrestling'
              }
            : {
                for (final id in [
                  ...addedScoreLeagues,
                  'kor.1',
                  'kor.2',
                  'basketball.easl',
                  'guide.table-tennis',
                  'guide.muay-thai',
                  'guide.padel',
                  'guide.taekwondo',
                  'guide.sambo',
                  'guide.pickleball',
                  'guide.triathlon',
                  'guide.sailing',
                  'guide.euroleague',
                  'guide.eurocup',
                  'guide.ahl',
                  'guide.aflw',
                  'guide.ekstraklasa',
                  'guide.cyclocross',
                  'guide.wwe',
                  'guide.aew',
                  'guide.tna'
                ])
                  sportsLeagueById(id)!.name: id
              };
        for (final query in queries.keys) {
          await tester.enterText(find.byType(TextField), query);
          await tester.pumpAndSettle();
          expect(find.byWidgetPredicate((w) => w is Text && w.data == query),
              findsOneWidget,
              reason: 'Visible result for $query, not the search text');
          expect(tester.takeException(), isNull);
        }
        final label = queries.keys.last;
        await tester
            .tap(find.byWidgetPredicate((w) => w is Text && w.data == label));
        await tester.pumpAndSettle();
        expect(selection, queries[label]);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
