import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_channel_filters.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';

class _Matcher extends SportsChannelMatcher {
  _Matcher(super.epg, this.initial);
  final List<ChannelMatch> initial;
  int discoveries = 0;
  @override
  Future<List<ChannelMatch>> alternativesFor(SportsGame game,
      {List<ChannelMatch> matches = const [],
      bool Function()? isCancelled}) async {
    discoveries++;
    return initial;
  }
}

void main() {
  testWidgets(
      'late evidence downgrades remove filtered rows without changing the saved choice',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final epg = EpgService(storage);
    final channel = Channel(
        id: 'one',
        rawId: 'one',
        playlistId: 'p',
        name: 'UK | Sports',
        group: 'UK | Sports',
        url: 'https://example.invalid/never-play');
    final initial = [ChannelMatch(channel, MatchReason.guide, 900)];
    final matcher = _Matcher(epg, initial);
    addTearDown(prefs.dispose);
    addTearDown(epg.dispose);
    addTearDown(matcher.dispose);
    final game = SportsGame(
        id: 'late-evidence',
        league: sportsLeagueById('eng.1')!,
        start: DateTime(2026, 11, 1),
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'a', name: 'Team A', shortName: 'A', abbreviation: 'A'),
        away: const SportsTeam(
            id: 'b', name: 'Team B', shortName: 'B', abbreviation: 'B'));
    final session = SportsChannelBrowseSession();
    session.write((game.league.id, game.id, game.start),
        const SportsChannelFilters(evidence: SportsChannelEvidence.specific));
    final online = Completer<List<ChannelMatch>>();
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider.value(value: epg)
        ],
        child: MaterialApp(
            home: Scaffold(
                body: SportsChannelPickerDialog(
          game: game,
          matcher: matcher,
          matches: initial,
          selectedId: channel.id,
          hasPick: true,
          onlineMatches: online.future,
          browseSession: session,
        )))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('game-channel:one')), findsOneWidget);
    online.complete([ChannelMatch(channel, MatchReason.league, 900)]);
    await tester.pumpAndSettle();
    expect(find.byType(SportsChannelList), findsNothing);
    expect(find.text('No channels match these filters.'), findsOneWidget);
    expect(find.byTooltip('Reset saved channel'), findsOneWidget);
    await tester.tap(find.text('Clear channel filters'));
    await tester.pumpAndSettle();
    final shown =
        tester.widget<SportsChannelRow>(find.byType(SportsChannelRow));
    expect(shown.selected, isTrue);
    expect(shown.result.match!.reason, MatchReason.league);
    expect(shown.result.match!.score, 900);
    expect(initial.single.reason, MatchReason.guide);
    expect(matcher.discoveries, 1);
    expect(tester.takeException(), isNull);
  });
}
