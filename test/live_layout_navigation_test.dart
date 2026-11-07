import 'package:nox_iptv/widgets/settings_navigation.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'player_polish_test.dart' as player_fixture;
import 'package:nox_iptv/widgets/main_navigation_rail.dart';
import 'package:nox_iptv/models/sports_favourites_filter.dart';
import 'package:nox_iptv/widgets/sports_filter_picker.dart';
import 'package:nox_iptv/widgets/sports_fixture_row.dart';
import 'package:nox_iptv/utils/sports_channel_filter.dart';
import 'package:nox_iptv/widgets/sports_event_controls.dart';
import 'package:nox_iptv/widgets/sports_schedule_panel.dart';
import 'package:nox_iptv/utils/sports_time_filter.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/screens/sports_teams_screen.dart';
import 'package:nox_iptv/screens/sports_league_manager_screen.dart';
import 'package:nox_iptv/widgets/standings_team_tile.dart';
import 'sports_standings_service_test.dart' as standings_fixture;
import 'package:nox_iptv/utils/constants.dart';
import 'package:nox_iptv/screens/settings/settings_menu_screen.dart';
import 'package:nox_iptv/widgets/sports_header_controls.dart';
import 'package:nox_iptv/widgets/sports_channel_picker.dart';
import 'package:nox_iptv/widgets/sports_activity_status.dart';
import 'package:nox_iptv/widgets/channel_now_label.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nox_iptv/widgets/compact_choice_list.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/screens/library_screen.dart';
import 'package:nox_iptv/utils/top_level_tab_route.dart';
import 'package:nox_iptv/screens/sports_screen.dart';
import 'package:nox_iptv/widgets/sports_replays_panel.dart';
import 'package:nox_iptv/widgets/player_controls.dart';
import 'package:nox_iptv/screens/sports_live_list_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_browse_cache.dart';
import 'package:nox_iptv/utils/sports_calendar.dart';
import 'package:nox_iptv/utils/route_observer.dart';
import 'package:nox_iptv/utils/tv_theme.dart';

class _Supplement extends SportsSupplementService {
  _Supplement()
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  int warms = 0, loads = 0;
  final games = [
    SportsGame(
      id: 'extra-demo',
      league: sportsLeagueById('tennis.atp')!,
      start: DateTime.now(),
      state: GameState.live,
      statusText: 'Live',
      source: 'TheSportsDB',
      home: const SportsTeam(
          id: 'a', name: 'Extra Player', shortName: 'Extra', abbreviation: ''),
      away: const SportsTeam(
          id: 'b',
          name: 'Another Player',
          shortName: 'Another',
          abbreviation: ''),
      event: const SportsEventInfo(title: 'European Open'),
    )
  ];
  @override
  Future<void> warmBroadcasts(List<SportsGame> games,
      {required bool Function() cancelled}) async {
    warms++;
  }

  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {bool Function()? cancelled}) async {
    loads++;
    return games;
  }

  @override
  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      loads == 0 ? const [] : games;
}

class _PollingScores extends SportsService {
  _PollingScores({DateTime? start})
      : start = start ?? DateTime.now(),
        super.withClient(MockClient((_) async => http.Response('{}', 200)));
  final DateTime start;
  int calls = 0;

  // This fixture supplies its complete schedule in memory. Do not inherit the
  // network/parser fallback when navigation selects a league with no rows.
  @override
  Future<DateTime?> nextGameStart(SportsLeague league, DateTime from) async =>
      null;

  @override
  Future<List<SportsGame>> gamesForDayWhileActive(
          List<SportsLeague> leagues, DateTime day,
          {required bool Function() shouldContinue,
          bool forceRefresh = false,
          void Function(List<SportsGame>)? onProgress,
          void Function(SportsWorkProgress)? onStatus}) =>
      gamesForDay(leagues, day,
          forceRefresh: forceRefresh,
          onProgress: onProgress,
          onStatus: onStatus);
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    calls++;
    return [
      for (var i = 0; i < (calls == 1 ? 216 : 217); i++)
        SportsGame(
            id: 'poll-$i',
            league: sportsLeagueById('nhl')!,
            start: start,
            state: GameState.live,
            statusText: 'Live',
            home: SportsTeam(
                id: 'h$i',
                name: i == 216 ? 'Zebrafish United' : 'Boston Bruins',
                shortName: 'Home',
                abbreviation: 'H',
                score: '$calls'),
            away: const SportsTeam(
                id: 'a',
                name: 'Toronto Maple Leafs',
                shortName: 'Away',
                abbreviation: 'A'))
    ];
  }
}

class _InlineScores extends _PollingScores {
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
          SportsLeague league, DateTime from, DateTime through,
          {bool Function()? shouldContinue}) async =>
      (games: await gamesForDay([league], from), incomplete: false);

  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleDay(
          List<SportsLeague> leagues, DateTime day,
          {bool Function()? shouldContinue,
          void Function(List<SportsGame>)? onProgress}) async =>
      (games: await gamesForDay(leagues, day), incomplete: false);
}

class _BrowseScores extends _PollingScores {
  _BrowseScores({super.start});
  final requestedLeagues = <List<String>>[];
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
          SportsLeague league, DateTime from, DateTime through,
          {bool Function()? shouldContinue}) async =>
      (games: const <SportsGame>[], incomplete: false);
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleDay(
          List<SportsLeague> leagues, DateTime day,
          {bool Function()? shouldContinue,
          void Function(List<SportsGame>)? onProgress}) async =>
      (games: const <SportsGame>[], incomplete: false);
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    calls++;
    requestedLeagues.add(leagues.map((l) => l.id).toList());
    return [
      for (var i = 0; i < 24; i++)
        SportsGame(
          id: 'browse-$i',
          league: sportsLeagueById('nhl')!,
          start: start,
          state: GameState.live,
          statusText: 'Live',
          home: SportsTeam(
              id: 'h$i',
              name: 'Homealpha${String.fromCharCode(97 + i)}',
              shortName: 'Homealpha${String.fromCharCode(97 + i)}',
              abbreviation: '',
              score: '$calls'),
          away: SportsTeam(
              id: 'a$i',
              name: 'Awaybeta${String.fromCharCode(97 + i)}',
              shortName: 'Awaybeta${String.fromCharCode(97 + i)}',
              abbreviation: ''),
        )
    ];
  }

  List<EpgProgram> rows({int from = 0}) => [
        for (var i = from; i < 24; i++)
          EpgProgram(
              channelId: 'feed-$i',
              title:
                  'Ice Hockey: Homealpha${String.fromCharCode(97 + i)} vs Awaybeta${String.fromCharCode(97 + i)}',
              start: start.subtract(const Duration(minutes: 5)),
              stop: start.add(const Duration(hours: 2)))
      ];
}

class _FilterScopeScores extends _BrowseScores {
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    calls++;
    requestedLeagues.add(leagues.map((l) => l.id).toList());
    return [
      for (final league in leagues)
        if (['nhl', 'eng.1', 'nba'].contains(league.id))
          for (var i = 0; i < 2; i++)
            SportsGame(
                id: 'scope-$i',
                league: league,
                start: start,
                state: GameState.live,
                statusText: 'Live',
                home: SportsTeam(
                    id: 'h$i',
                    name: 'Home $i',
                    shortName: 'Home $i',
                    abbreviation: 'H'),
                away: const SportsTeam(
                    id: 'a',
                    name: 'Away',
                    shortName: 'Away',
                    abbreviation: 'A'))
    ];
  }
}

class _ReopenScores extends _BrowseScores {
  List<SportsGame> cached = [];
  Completer<List<SportsGame>>? pending;
  @override
  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      cached
          .where((game) => leagues.any((l) => l.id == game.league.id))
          .toList();
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    cached = pending != null
        ? await pending!.future
        : await super.gamesForDay(leagues, day);
    return cachedGamesForDay(leagues, day);
  }
}

class _RowScores extends _PollingScores {
  _RowScores(
      {this.counts = const {},
      this.upcoming = const {},
      this.namedTeams = false});
  final bool namedTeams;
  final Map<String, int> counts;
  final Set<String> upcoming;
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
          {void Function(List<SportsGame>)? onProgress,
          bool forceRefresh = false,
          void Function(SportsWorkProgress)? onStatus}) async =>
      [
        for (final league in leagues)
          for (var i = 0;
              i < (counts[league.id] ?? (counts.isEmpty ? 20 : 0));
              i++)
            SportsGame(
                id: 'row-$i',
                league: league,
                start: start,
                state: upcoming.contains(league.id)
                    ? GameState.pre
                    : GameState.live,
                statusText: 'Live',
                home: SportsTeam(
                    id: 'h$i',
                    name: namedTeams ? 'Boston Bruins' : 'Home $i',
                    shortName: namedTeams ? 'Boston Bruins' : 'Home $i',
                    abbreviation: 'H'),
                away: SportsTeam(
                    id: 'a$i',
                    name: namedTeams ? 'Toronto Maple Leafs' : 'Away $i',
                    shortName: namedTeams ? 'Toronto Maple Leafs' : 'Away $i',
                    abbreviation: 'A'))
      ];
}

class _HeldScores extends _PollingScores {
  final activityChecks = <bool Function()>[];
  @override
  Future<List<SportsGame>> gamesForDayWhileActive(
      List<SportsLeague> leagues, DateTime day,
      {required bool Function() shouldContinue,
      bool forceRefresh = false,
      void Function(List<SportsGame>)? onProgress,
      void Function(SportsWorkProgress)? onStatus}) {
    activityChecks.add(shouldContinue);
    return super.gamesForDayWhileActive(leagues, day,
        shouldContinue: shouldContinue,
        forceRefresh: forceRefresh,
        onProgress: onProgress,
        onStatus: onStatus);
  }

  final done = Completer<List<SportsGame>>();
  void Function(List<SportsGame>)? publish;
  List<SportsGame> batch = [];
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) {
    publish = onProgress;
    onStatus?.call(const SportsWorkProgress(SportsWorkStage.scores, total: 3));
    return done.future;
  }

  Future<void> firstBatch() async {
    batch =
        (await super.gamesForDay([sportsLeagueById('nhl')!], DateTime.now()))
            .take(1)
            .toList();
    publish?.call(batch);
  }
}

class _CalendarScores extends _PollingScores {
  final days = <DateTime>[];
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) async {
    days.add(day);
    return [];
  }
}

class _RecoveringScores extends _HeldScores {
  final retries = <Completer<List<SportsGame>>>[];
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
      {void Function(List<SportsGame>)? onProgress,
      bool forceRefresh = false,
      void Function(SportsWorkProgress)? onStatus}) {
    if (publish == null) {
      return super.gamesForDay(leagues, day,
          onProgress: onProgress,
          forceRefresh: forceRefresh,
          onStatus: onStatus);
    }
    final request = Completer<List<SportsGame>>();
    retries.add(request);
    onStatus?.call(const SportsWorkProgress(SportsWorkStage.scores, total: 3));
    return request.future;
  }
}

class _WarmGuide extends _SlowGuide {
  _WarmGuide(super.storage);
  int reads = 0;
  @override
  EpgProgram? getCurrentProgram(String id) {
    reads++;
    return super.getCurrentProgram(id);
  }
}

class _SlowGuide extends _Epg {
  _SlowGuide(super.storage);
  final requests = <Completer<List<EpgProgram>>>[];
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) {
    final request = Completer<List<EpgProgram>>();
    requests.add(request);
    return request.future;
  }
}

class _PriorityGuide extends _Epg {
  _PriorityGuide(super.storage);
  final laterGate = Completer<void>();
  final order = <String>[];
  bool held = false;
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) async {
    if (from.isAfter(DateTime.now().add(const Duration(hours: 1)))) {
      order.add('later');
      if (!held) {
        held = true;
        await laterGate.future;
      }
    } else if (terms.any((term) => term.contains('zebrafish'))) {
      order.add('urgent');
    }
    return [];
  }
}

class _Playlist extends PlaylistManager {
  _Playlist(super.storage, super.db);
  final fixtureChannels = [
    for (final name in [
      'ABC HD',
      'SBS HD',
      'Seven',
      'Nine',
      '10 HD',
      'ABC News',
      'SBS World',
      'Fox Sports',
      'Fox Sports HD'
    ])
      Channel(
          id: 'demo::$name',
          rawId: name,
          playlistId: 'demo',
          name: name,
          group: 'Australian TV',
          url: 'https://example.test/live'),
  ];
  @override
  bool get hasLiveChannels => channels.isNotEmpty;

  @override
  List<Channel> get channels => fixtureChannels;
  @override
  List<M3uGroup> get tvGroups => [
        M3uGroup(
            title: 'Australian TV',
            playlistId: 'demo',
            channels: fixtureChannels)
      ];
  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      groupTitle == null
          ? fixtureChannels
          : fixtureChannels.where((c) => c.group == groupTitle).toList();
  @override
  Future<void> ensureLiveChannelsLoaded() async {
    catalogueLoads++;
  }

  int catalogueLoads = 0;
}

class _RailPlaylist extends _Playlist {
  _RailPlaylist(super.storage, super.db);
  @override
  List<M3uGroup> get tvGroups => [
        for (final c in fixtureChannels)
          M3uGroup(title: c.group, playlistId: c.playlistId, channels: [c])
      ];
  @override
  List<Channel> get favoriteLiveChannelsWithGroups =>
      fixtureChannels.take(2).toList();
}

class _Playback extends PlaybackService {
  _Playback(super.storage, super.playlist);
  final played = <Channel>[];
  Completer<void>? openGate;
  Completer<void>? stopGate;
  final history = <Channel>[];
  @override
  List<Channel> recentLiveChannels({int limit = 10}) =>
      history.take(limit).toList();
  @override
  Future<void> play(Channel channel) async {
    played.add(channel);
    currentChannel = channel;
    notifyListeners();
    await openGate?.future;
  }

  @override
  Future<void> stop() async {
    await stopGate?.future;
    currentChannel = null;
    notifyListeners();
  }
}

class _ScheduleQueryEpg extends _Epg {
  _ScheduleQueryEpg(super.storage);
  int queries = 0;
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
      List<String> ids, DateTime from, DateTime to) {
    queries++;
    return super.findSportsProgrammesForChannels(ids, from, to);
  }

  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
      DateTime from, DateTime to, List<String> terms,
      {List<String>? channelIds}) {
    queries++;
    return super.findProgrammesByTitle(from, to, terms, channelIds: channelIds);
  }
}

class _DrillEpg extends _Epg {
  _DrillEpg(super.storage);
  late final anchor = DateTime(
      now.year, now.month, now.day, now.hour, now.minute - now.minute % 30);
  @override
  List<EpgProgram> getPrograms(String channelId) => [
        for (var i = -24; i < 96; i++)
          EpgProgram(
            channelId: channelId,
            title: 'Slot $i',
            start: anchor.add(Duration(minutes: i * 5)),
            stop: anchor.add(Duration(minutes: (i + 1) * 5)),
          ),
      ];
}

class _Epg extends EpgService {
  _Epg(super.storage);
  Completer<List<EpgProgram>>? pending;
  List<EpgProgram> replays = [];
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      replays
          .where((p) =>
              ids.contains(p.channelId) &&
              p.start.isBefore(to) &&
              p.stop.isAfter(from))
          .toList();
  final withoutGuide = <String>{};
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime now) =>
      replays.where((p) => p.isNowPlaying(now));
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      pending == null ? [] : await pending!.future;
  // Keep the fixture's current slot valid across a wall-clock hour rollover.
  final now = DateTime.now().subtract(const Duration(minutes: 30));
  @override
  List<EpgProgram> getPrograms(String channelId) => [
        for (var i = -1; i < 5; i++)
          EpgProgram(
              channelId: channelId,
              title: [
                'Morning News',
                'The World Today',
                'Live Sport',
                'Evening Report',
                'Coast to Coast',
                'Night News'
              ][i + 1],
              description:
                  'News, stories and live coverage from across Australia and around the world.',
              start: now.add(Duration(hours: i)),
              stop: now.add(Duration(hours: i + 1))),
      ];
  @override
  EpgProgram? getCurrentProgram(String channelId) => withoutGuide
          .contains(channelId)
      ? null
      : replays
              .where((p) =>
                  normalizeEpgId(p.channelId) == normalizeEpgId(channelId) &&
                  p.isNowPlaying(DateTime.now()))
              .firstOrNull ??
          getPrograms(channelId)[1];
  @override
  EpgProgram? getNextProgram(String channelId) => getPrograms(channelId)[2];
}

// Isolate replies use real time; pumpAndSettle alone advances only fake time.
// Matching/layout fixtures explicitly exercise favourite feeds. Scope tests below
// start with no Events selection to verify the unfiltered production default.
void setLayoutPreferences(Map<String, Object> values) {
  SharedPreferences.setMockInitialValues({
    'sports_events_selection': <String>['', '', 'favourites'],
    ...values,
  });
}

VoidCallback? sportsRefreshAction(WidgetTester tester) {
  final button = tester.widget(find.byKey(const ValueKey('sports-refresh')));
  return switch (button) {
    IconButton(:final onPressed) => onPressed,
    ButtonStyleButton(:final onPressed) => onPressed,
    _ => throw StateError('Expected a refresh button'),
  };
}

String sportsChannelStatus(WidgetTester tester) {
  final text =
      tester.widget<Text>(find.byKey(const ValueKey('sports-status-channels')));
  return text.data ?? text.textSpan!.toPlainText();
}

Future<void> settleSports(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
    if (!tester.binding.hasScheduledFrame) break;
  }
  await tester.pumpAndSettle();
}

Future<void> captureSports(WidgetTester tester, Size size, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_LAYOUT')) return;
  await tester.pump(const Duration(milliseconds: 200));
  await tester.runAsync(() async {
    final boundary = tester
        .firstRenderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary));
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/iptv-$name-${size.width.toInt()}.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

http.Response _tennisFixture() => http.Response(
    jsonEncode({
      'events': [
        {
          'id': 'tournament',
          'name': 'BNP Paribas Fortis European Open',
          'groupings': [
            {
              'grouping': {'displayName': "Men's Singles"},
              'competitions': [
                {
                  'id': 'tennis-demo',
                  'date': DateTime.now().toUtc().toIso8601String(),
                  'round': {'displayName': 'Round 2'},
                  'venue': {
                    'fullName': 'Brussels, Belgium',
                    'court': 'Court 2'
                  },
                  'status': {
                    'type': {'state': 'in', 'shortDetail': '2nd Set'}
                  },
                  'competitors': [
                    {
                      'athlete': {'id': '1', 'displayName': 'Yunchaokete Bu'},
                      'linescores': [
                        {'value': 6},
                        {'value': 3}
                      ]
                    },
                    {
                      'athlete': {'id': '2', 'displayName': 'Casper Ruud'},
                      'linescores': [
                        {'value': 4},
                        {'value': 2}
                      ]
                    },
                  ]
                }
              ]
            }
          ]
        }
      ]
    }),
    200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(SportsChannelMatcher.disposeShared);
  setUp(SportsService.resetForTesting);
  tearDown(SportsService.resetForTesting);
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'sports tabs separate touch selection and remote focus at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final previousStrategy = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      addTearDown(
          () => FocusManager.instance.highlightStrategy = previousStrategy);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      final tv = prefs.isTelevision = size.width == 960;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final guide = _Epg(storage), scores = _InlineScores();
      final standings = SportsStandingsService(
          client: MockClient((_) async =>
              http.Response(standings_fixture.table(teams: 8), 200)));
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: guide),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(
                  scores: scores,
                  standings: standings,
                  clock: () => scores.start))));
      await settleSports(tester);
      Finder tab(String id) => find.byKey(ValueKey('sports-view-$id'));
      FocusNode node(String id) =>
          tester.widget<TextButton>(tab(id)).focusNode!;
      const ids = ['events', 'standings', 'schedule', 'replays', 'highlights'];
      void expectTabs(String selected, {String? outlined}) {
        for (final id in ids) {
          final button = tester.widget<TextButton>(tab(id));
          final semantics = button.child! as Semantics;
          expect(semantics.properties.selected, id == selected,
              reason: '$id selection');
          final underline =
              ((semantics.child! as Container).decoration! as BoxDecoration)
                  .border! as Border;
          expect(underline.bottom.color.a > 0, id == selected,
              reason: '$id underline');
          final material = tester
              .widgetList<Material>(
                  find.descendant(of: tab(id), matching: find.byType(Material)))
              .firstWhere((m) => m.type == MaterialType.button);
          expect((material.shape! as RoundedRectangleBorder).side.color.a > 0,
              id == outlined,
              reason: '$id focus border');
          expect(material.color!.a > 0, id == outlined,
              reason: '$id focus fill');
        }
      }

      node('events').requestFocus();
      await tester.pumpAndSettle();
      expectTabs('events', outlined: tv ? 'events' : null);
      await tester.tap(tab('standings'));
      await settleSports(tester);
      expect(node('standings').hasFocus, isTrue);
      expectTabs('standings', outlined: tv ? 'standings' : null);
      final calls = scores.calls;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pumpAndSettle();
      expectTabs('standings', outlined: 'standings');
      expect(scores.calls, calls,
          reason: 'Changing input mode only repaints tabs');
      final standingsPanel =
          find.byKey(const ValueKey('sports-inline-standings'));
      final retained = tester.widget(standingsPanel);
      final screenContext = tester.element(find.byType(SportsScreen));
      unawaited(showDialog<void>(
          context: screenContext,
          builder: (context) => AlertDialog(actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close probe'))
              ])));
      await tester.pumpAndSettle();
      expect(tester.widget(standingsPanel), same(retained),
          reason: 'A popup must not rebuild unchanged Sports content');
      await tester.tap(find.text('Close probe'));
      await tester.pumpAndSettle();
      expect(tester.widget(standingsPanel), same(retained));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(node('events').hasFocus, isTrue);
      expectTabs('standings', outlined: 'events');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleSports(tester);
      expectTabs('events', outlined: 'events');
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      for (final id in [
        'highlights',
        'schedule',
        'standings',
        'replays',
        'events'
      ]) {
        await tester.ensureVisible(tab(id));
        await tester.pumpAndSettle();
        await tester.tap(tab(id));
        await settleSports(tester);
        expect(node(id).hasFocus, isTrue);
        expectTabs(id, outlined: tv ? id : null);
      }
      // Real key input restores keyboard focus visuals on a touch device.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(node('standings').hasFocus, isTrue);
      expectTabs('events', outlined: 'standings');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleSports(tester);
      expectTabs('standings', outlined: 'standings');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expectTabs('standings');
      expect(playback.played, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      SportsChannelMatcher.disposeShared();
      playlist.dispose();
      playback.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }

  for (final destination in [
    'tab',
    'manager',
    'background',
    'covered',
    'dispose'
  ]) {
    testWidgets('favourite feed work stops on $destination and resumes safely',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsLeagues(['nhl', 'nba', 'eng.1']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final guide = _Epg(storage), scores = _HeldScores();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: guide),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores, clock: () => scores.start))));
      await tester.pump();
      expect(scores.activityChecks, hasLength(1));
      final original = scores.activityChecks.single;
      expect(original(), isTrue);
      if (destination == 'tab') {
        await tester.tap(find.byKey(const ValueKey('sports-view-schedule')));
      } else if (destination == 'manager') {
        await tester.tap(find.byTooltip('Sports options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Manage favourite leagues'));
      } else if (destination == 'background') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      } else if (destination == 'covered') {
        Navigator.of(tester.element(find.byType(SportsScreen))).push<void>(
            MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Other page'))));
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      await tester.pump();
      expect(original(), isFalse,
          reason: 'Leaving must stop scheduling, not only hide progress.');
      await scores.firstBatch();
      scores.done.complete(scores.batch);
      await settleSports(tester);
      if (destination != 'dispose') {
        if (destination == 'manager') {
          await tester.tap(find.byKey(const ValueKey('close-leagues')));
        } else if (destination == 'background') {
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        } else if (destination == 'covered') {
          Navigator.of(tester.element(find.text('Other page'))).pop();
          await tester.pump(const Duration(seconds: 6));
        } else {
          await tester.tap(find.byKey(const ValueKey('sports-view-events')));
        }
        await settleSports(tester);
        expect(scores.activityChecks.length, greaterThan(1));
        expect(original(), isFalse,
            reason: 'Returning cannot revive old work.');
        expect(scores.activityChecks.last(), isTrue);
        expect(
            find.byKey(const ValueKey('sports-view-events')), findsOneWidget);
      }
      expect(playback.played, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      SportsChannelMatcher.disposeShared();
      playlist.dispose();
      playback.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }

  for (final overlay in [false, true]) {
    testWidgets('cold Sports results preserve user focus: overlay=$overlay',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final guide = _Epg(storage), scores = _HeldScores();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: guide),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores, clock: () => scores.start))));
      await tester.pump();
      final tab = tester
          .widget<TextButton>(find.byKey(const ValueKey('sports-view-events')))
          .focusNode!;
      expect(tab.hasFocus, isTrue,
          reason: 'Events receives entry focus before the first scores arrive');
      if (overlay) {
        await tester.tap(find.byKey(const ValueKey('events-favourites-only')));
        await tester.pumpAndSettle();
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      final chosen = FocusManager.instance.primaryFocus;
      expect(chosen, isNotNull);
      await scores.firstBatch();
      scores.done.complete(scores.batch);
      await settleSports(tester);
      expect(FocusManager.instance.primaryFocus, same(chosen),
          reason: 'Late scores must not redirect the next remote activation');
      if (overlay) {
        expect(find.text('Show results'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
            tester
                .widget<TextButton>(
                    find.byKey(const ValueKey('sports-view-schedule')))
                .focusNode!
                .hasFocus,
            isTrue);
      }
      expect(playback.played, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      SportsChannelMatcher.disposeShared();
      playlist.dispose();
      playback.dispose();
      guide.dispose();
      prefs.dispose();
    });
  }

  testWidgets(
      'Events retains its own scope while Schedule and Standings share browsing',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsLeagues(['nhl', 'nba']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final guide = _Epg(storage), scores = _InlineScores();
    var standingsRequests = 0;
    final standings = SportsStandingsService(client: MockClient((_) async {
      standingsRequests++;
      return http.Response(standings_fixture.table(teams: 20), 200);
    }));
    addTearDown(standings.close);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: guide),
        ],
        child: RepaintBoundary(
            child: MaterialApp(
                theme: buildAppTheme(prefs.palette),
                navigatorObservers: [appRouteObserver],
                home: SportsScreen(
                    scores: scores,
                    standings: standings,
                    clock: () => scores.start)))));
    await settleSports(tester);
    Future<void> tapKey(String id) async {
      final item = find.byKey(ValueKey(id));
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      await tester.tap(item);
      await settleSports(tester);
    }

    expect(
        tester
            .widget<SportsFilterButton>(
                find.byKey(const ValueKey('sport-picker')))
            .value,
        'All sports');
    expect(
        tester
            .widget<SportsFilterButton>(
                find.byKey(const ValueKey('league-picker')))
            .value,
        'All leagues');
    expect(
        tester
            .widget<SportsFavouritesFilterButton>(
                find.byKey(const ValueKey('events-favourites-only')))
            .filter,
        SportsFavouritesFilter.all);
    await tapKey('events-favourites-only');
    await tapKey('sports-favourites-favourites');
    final calls = scores.calls;
    await tapKey('sport-picker');
    expect(find.text('Manage favourite leagues'), findsOneWidget);
    await tapKey('basketball');
    await tapKey('league-picker');
    await captureSports(tester, const Size(390, 844), 'enabled-league-picker');
    await tapKey('nba');
    expect(scores.calls, calls,
        reason: 'Events sport and league filters are local.');
    await tapKey('sports-view-schedule');
    final panel =
        tester.widget<SportsSchedulePanel>(find.byType(SportsSchedulePanel));
    expect(panel.browseState.sport, 'basketball');
    expect(panel.browseState.leagueId, 'nba');
    expect(
        panel.overviewLeagues!.map((l) => l.id), containsAll(['nba', 'nhl']));
    await tapKey('schedule-league');
    expect(find.text('Manage favourite leagues'), findsOneWidget);
    expect(find.byKey(const ValueKey('eng.1')), findsNothing);
    await tapKey('__all_sports__');
    expect(panel.browseState.sport, isNull);
    expect(panel.browseState.leagueId, isNull);
    final loaded = scores.calls;
    await tapKey('sports-view-events');
    expect(
        tester
            .widget<SportsFilterButton>(
                find.byKey(const ValueKey('sport-picker')))
            .value,
        'Basketball');
    expect(
        tester
            .widget<SportsFilterButton>(
                find.byKey(const ValueKey('league-picker')))
            .value,
        'NBA');
    expect(scores.calls, loaded);
    await tapKey('sports-view-standings');
    final teamPanel =
        tester.widget<SportsTeamsScreen>(find.byType(SportsTeamsScreen));
    expect(teamPanel.favouriteLeagueIds, containsAll(['nba', 'nhl']));
    // Choosing a league in Standings carries through an intermediate tab.
    await tapKey('standings-sport');
    await tapKey('hockey');
    expect(find.textContaining('Favourite league ·'), findsWidgets);
    final leagueList = find.descendant(
        of: find.byType(Dialog), matching: find.byType(CompactChoiceList));
    final lastLeague =
        tester.widget<CompactChoiceList>(leagueList).choices.last;
    expect(tester.getRect(find.byKey(ValueKey(lastLeague.id))).bottom,
        lessThanOrEqualTo(tester.getRect(leagueList).bottom),
        reason:
            'A short list fits its last row without unnecessary scrolling.');
    await captureSports(tester, const Size(390, 844), 'standings-league-scope');
    await tapKey('nhl');
    await tapKey('sports-view-highlights');
    await tapKey('sports-view-schedule');
    var schedule =
        tester.widget<SportsSchedulePanel>(find.byType(SportsSchedulePanel));
    expect(schedule.browseState.leagueId, 'nhl');
    expect(schedule.browseState.sport, 'hockey');
    // A sport-only change also reaches Standings, without opening Events first.
    await tapKey('schedule-sport');
    await tapKey('basketball');
    await tapKey('sports-view-standings');
    expect(
        tester
            .widget<SportsTeamsScreen>(find.byType(SportsTeamsScreen))
            .initialLeague
            ?.id,
        'nba');
    await tapKey('sports-view-events');
    expect(
        tester
            .widget<SportsFilterButton>(
                find.byKey(const ValueKey('sport-picker')))
            .value,
        'Basketball');
    expect(
        tester
            .widget<SportsFilterButton>(
                find.byKey(const ValueKey('league-picker')))
            .value,
        'NBA');
    final requestsBefore = standingsRequests;
    // Exploring a non-enabled league never silently enables a feed.
    await tapKey('sports-view-standings');
    await tapKey('standings-favourites-only');
    await tapKey('sports-favourites-all');
    await tapKey('standings-sport');
    await tapKey('soccer');
    expect(find.textContaining('Other league ·'), findsWidgets);
    await tapKey('eng.1');
    await tapKey('sports-view-schedule');
    schedule =
        tester.widget<SportsSchedulePanel>(find.byType(SportsSchedulePanel));
    expect(schedule.browseState.sport, 'soccer');
    expect(schedule.browseState.leagueId, 'eng.1');
    expect(storage.getSportsLeagues(), ['nhl', 'nba']);
    expect(standingsRequests, requestsBefore + 1);
    // Merely revisiting Standings retains its cached league and requests no data.
    await tapKey('sports-view-standings');
    expect(
        tester
            .widget<SportsTeamsScreen>(find.byType(SportsTeamsScreen))
            .initialLeague
            ?.id,
        'eng.1');
    expect(standingsRequests, requestsBefore + 1);
    final scoreRequestsBeforeManagement = scores.calls;
    await tapKey('standings-league');
    await tapKey('__manage_leagues__');
    expect(find.byType(SportsLeagueManagerScreen), findsOneWidget);
    await captureSports(
        tester, const Size(390, 844), 'favourite-league-manager');
    await tapKey('close-leagues');
    expect(find.byType(SportsTeamsScreen), findsOneWidget);
    expect(standingsRequests, requestsBefore + 1);
    expect(scores.calls, scoreRequestsBeforeManagement,
        reason:
            'Opening and cancelling league management does not reload scores or standings.');
    expect(storage.getSportsEventsSelection(),
        ['basketball', 'nba', 'favourites']);
    final application =
        tester.widget<MultiProvider>(find.byType(MultiProvider).first);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(application);
    await settleSports(tester);
    expect(
        tester
            .widget<SportsFilterButton>(
                find.byKey(const ValueKey('league-picker')))
            .value,
        'NBA');
    expect(
        tester
            .widget<SportsFavouritesFilterButton>(
                find.byKey(const ValueKey('events-favourites-only')))
            .filter,
        SportsFavouritesFilter.favourites);
    expect(playback.played, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
    SportsChannelMatcher.disposeShared();
    playlist.dispose();
    playback.dispose();
    guide.dispose();
    prefs.dispose();
  });

  testWidgets(
      'Schedule watches the Events selection without another match pass',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final guide = _ScheduleQueryEpg(storage), scores = _InlineScores();
    final game =
        (await scores.gamesForDay([sportsLeagueById('nhl')!], scores.start))
            .first;
    final channel = playlist.fixtureChannels.first;
    await SportsChannelPicks.load(storage).pickForGame(game, channel.id);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: guide),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            builder: (context, child) => RepaintBoundary(child: child),
            home: SportsScreen(scores: scores, clock: () => scores.start))));
    Future<void> flush() async {
      for (var i = 0; i < 25; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    final event = find.byKey(const ValueKey('card-nhl:poll-0'));
    expect(find.descendant(of: event, matching: find.text(channel.name)),
        findsOneWidget);
    final catalogueLoads = playlist.catalogueLoads, queries = guide.queries;
    await tester.tap(find.byKey(const ValueKey('sports-view-schedule')));
    await flush();
    final row = tester
        .widgetList<SportsFixtureRow>(find.byType(SportsFixtureRow))
        .firstWhere((row) => row.game.id == game.id);
    expect(row.channelName, channel.name);
    final panel =
        tester.widget<SportsSchedulePanel>(find.byType(SportsSchedulePanel));
    expect(panel.channelMatchForGame!(row.game)?.channel.id, channel.id);
    expect(playback.played, isEmpty);
    await tester.tap(find.byKey(const ValueKey('nhl:poll-0')));
    await flush();
    expect(playback.played.map((c) => c.id), [channel.id]);
    expect(find.byType(SportsSchedulePanel), findsOneWidget);
    expect(playlist.catalogueLoads, catalogueLoads);
    expect(guide.queries, queries,
        reason: 'Schedule must use the existing match, including for playback');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
    SportsChannelMatcher.disposeShared();
    playlist.dispose();
    playback.dispose();
    guide.dispose();
    prefs.dispose();
  });

  testWidgets(
      'All is the Events default and other tabs cannot change its favourites filter',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('all');
    await storage.setSportsFollowedTeams(['eng.1|h1']);
    await storage.setSportsTeamNames({'eng.1|h1': 'Saved club'});
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final guide = _Epg(storage), scores = _FilterScopeScores();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: guide),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            builder: (context, child) => RepaintBoundary(child: child),
            home: SportsScreen(scores: scores, clock: () => scores.start))));
    Future<void> flush() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    Future<void> tapKey(String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await flush();
    }

    await flush();
    final savedLeagues = storage.getSportsLeagues();
    expect(scores.requestedLeagues.single, containsAll(['nhl', 'eng.1']));
    expect(scores.requestedLeagues.single, contains('nba'),
        reason:
            'Events opens across all leagues, independent of saved favourites.');
    await tapKey('events-favourites-only');
    await tapKey('sports-favourites-favourites');
    expect(find.byKey(const ValueKey('card-nhl:scope-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-nhl:scope-1')), findsOneWidget);
    // Choose the team league to inspect its two games without virtualized shelves.
    await tapKey('league-picker');
    final field = tester.widget<TextField>(find.byType(TextField));
    field.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Premier League');
    await tester.pumpAndSettle();
    await tapKey('eng.1');
    expect(find.byKey(const ValueKey('card-eng.1:scope-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-eng.1:scope-0')), findsNothing);
    await tapKey('events-favourites-only');
    await captureSports(tester, const Size(960, 540), 'favourites-filter');
    await tapKey('sports-favourites-all');
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('card-eng.1:scope-0')), findsOneWidget);
    await tapKey('sport-picker');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    await tapKey('');
    expect(scores.requestedLeagues.last, containsAll(['nba', 'nhl', 'eng.1']),
        reason:
            'All really includes the wider catalogue, without needing to pick extra leagues.');
    await tapKey('events-favourites-only');
    await tapKey('sports-favourites-leagues');
    expect(scores.requestedLeagues.last, contains('nhl'));
    expect(scores.requestedLeagues.last, isNot(contains('eng.1')));
    expect(scores.requestedLeagues.last, isNot(contains('nba')));
    expect(find.byKey(const ValueKey('card-nhl:scope-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-nhl:scope-1')), findsOneWidget);
    await tapKey('events-favourites-only');
    await tapKey('sports-favourites-teams');
    expect(scores.requestedLeagues.last, ['eng.1']);
    await captureSports(tester, const Size(960, 540), 'favourites-teams');
    expect(find.byKey(const ValueKey('card-eng.1:scope-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-eng.1:scope-0')), findsNothing);
    await tapKey('events-favourites-only');
    await tapKey('sports-favourites-all');
    await tapKey('sports-view-schedule');
    expect(
        tester
            .widget<SportsSchedulePanel>(find.byType(SportsSchedulePanel))
            .browseState
            .onlyFavourites,
        false);
    await tapKey('schedule-favourites-only');
    await tapKey('sports-favourites-teams');
    await tapKey('sports-view-highlights');
    await tapKey('sports-view-events');
    expect(
        tester
            .widget<SportsFavouritesFilterButton>(
                find.byKey(const ValueKey('events-favourites-only')))
            .filter,
        SportsFavouritesFilter.all);
    expect(scores.requestedLeagues.last, contains('nba'));
    expect(storage.getSportsLeagues(), savedLeagues);
    await tapKey('sports-view-standings');
    expect(
        tester
            .widget<SportsTeamsScreen>(find.byType(SportsTeamsScreen))
            .favouritesFilter,
        SportsFavouritesFilter.teams);
    await tapKey('sports-view-events');
    await tapKey('events-favourites-only');
    await tapKey('sports-favourites-leagues');
    await tapKey('sports-view-standings');
    await tapKey('standings-favourites-only');
    await tapKey('sports-favourites-all');
    await tapKey('sports-view-events');
    expect(
        tester
            .widget<SportsFavouritesFilterButton>(
                find.byKey(const ValueKey('events-favourites-only')))
            .filter,
        SportsFavouritesFilter.leagues);
    expect(storage.getSportsLeagues(), savedLeagues);
    expect(playback.played, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
    SportsChannelMatcher.disposeShared();
    playlist.dispose();
    playback.dispose();
    guide.dispose();
    prefs.dispose();
  });
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final cache = await Directory.systemTemp.createTemp('iptv-layout-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cache.path,
    );
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

  testWidgets(
      'top-level library switches preserve menu geometry and return Live TV focus without animation',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final db = CatalogDatabase();
    final playlist = _Playlist(storage, db);
    final playback = _Playback(storage, playlist);
    final epg = _Epg(storage);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          Provider<CatalogDatabase>.value(value: db),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: const TvHomeScreen())));
    await tester.pumpAndSettle();
    const ids = ['live', 'sports', 'movies', 'series', 'settings'];
    Finder menu(String id) => find.byKey(ValueKey('main-nav-$id'));
    final bounds = {for (final id in ids) id: tester.getRect(menu(id))};
    final icons = {
      for (final id in ids)
        id: tester
            .widget<Icon>(
                find.descendant(of: menu(id), matching: find.byType(Icon)))
            .icon
    };
    final releasing = Completer<void>();
    playback.currentChannel = playlist.fixtureChannels.first;
    playback.stopGate = releasing;
    addTearDown(() {
      if (!releasing.isCompleted) releasing.complete();
    });
    await tester.tap(menu('movies'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget,
        reason: 'Library navigation must not wait for native player release');
    expect(releasing.isCompleted, isFalse);
    releasing.complete();
    await tester.pump();
    expect(playback.pendingResumeChannel, playlist.fixtureChannels.first);
    final route = ModalRoute.of(tester.element(find.byType(LibraryScreen)))!;
    expect(route, isA<TopLevelTabRoute<String>>());
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    for (final id in ids) {
      expect(tester.getRect(menu(id)), bounds[id],
          reason: '$id must stay anchored');
      expect(
          tester
              .widget<Icon>(
                  find.descendant(of: menu(id), matching: find.byType(Icon)))
              .icon,
          icons[id]);
    }
    await tester.tap(menu('series'));
    await tester.pumpAndSettle();
    for (final id in ids) {
      expect(tester.getRect(menu(id)), bounds[id]);
    }
    await tester.tap(menu('settings'));
    await tester.pump();
    expect(find.byType(SettingsMenuScreen), findsOneWidget,
        reason:
            'A library-to-settings switch needs no intermediate Live frame');
    SettingsNavigation.maybeOf(tester.element(find.byType(SettingsMenuScreen)))!
        .onExit(SettingsAction.movies);
    await tester.pump();
    expect(find.byType(LibraryScreen), findsOneWidget,
        reason: 'Settings can open library UI in the same next frame');
    await tester.tap(menu('live'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(LibraryScreen), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-tab-TV');
    for (final id in ids) {
      expect(tester.getRect(menu(id)), bounds[id]);
    }
    expect(playback.played, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  for (final playing in [false, true]) {
    testWidgets(
        'Sports handoff preserves Live guide, categories and video: playing=$playing',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({});
      final storage = StorageService();
      await storage.init();
      await storage.setLiveCategoryFolders(false);
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final playlist = _RailPlaylist(storage, CatalogDatabase());
      playlist.fixtureChannels
        ..clear()
        ..addAll(List.generate(
            1000,
            (i) => Channel(
                id: 'demo::$i',
                rawId: '$i',
                playlistId: 'demo',
                name: 'Channel $i',
                group: 'Category $i',
                url: 'https://example.test/$i')));
      final playback = _Playback(storage, playlist);
      if (playing) {
        playback.currentChannel = playlist.fixtureChannels.first;
        playback.controller = player_fixture.Controller();
      }
      final epg = _DrillEpg(storage);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: const TvHomeScreen())));
      await tester.pumpAndSettle();
      final rail = find.byKey(const ValueKey('live-categories-rail'),
          skipOffstage: false);
      expect(
          find
              .byWidgetPredicate((w) => w.runtimeType.toString() == '_GroupRow')
              .evaluate()
              .length,
          lessThan(40),
          reason: 'Large catalogues only mount nearby categories.');
      final surface =
          playing ? tester.state(find.byType(VideoPlayerHdr)) : null;
      void checkSurface() {
        if (playing) {
          expect(tester.state(find.byType(VideoPlayerHdr)), same(surface),
              reason:
                  'Moving between Live and Sports must retain the native view');
        }
      }

      var original = tester.widget(rail);
      final homeContext = tester.element(find.byType(TvHomeScreen));
      final nav = Navigator.of(homeContext);
      for (var i = 0; i < 3; i++) {
        tester
            .widget<MainNavigationRail>(find.byType(MainNavigationRail))
            .onSelect('sports');
        await tester.pump();
        expect(tester.widget(rail), same(original),
            reason: 'Only the preview needs to change owners.');
        checkSurface();
        nav.pop('live');
        await tester.pumpAndSettle();
        expect(tester.widget(rail), same(original),
            reason: 'Returning must not rebuild unchanged Live columns.');
        checkSurface();
      }
      final all = find.byKey(const ValueKey('all-live-channels'));
      for (final destination in <String?>['live', null]) {
        await tester.tap(all);
        await tester.pumpAndSettle();
        tester
            .widget<MainNavigationRail>(find.byType(MainNavigationRail))
            .focusNodes['live']!
            .requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
            tester
                .getSize(find.byKey(const ValueKey('live-navigation-rail')))
                .width,
            0);
        expect(tester.getSize(rail).width, 0,
            reason:
                'Start with the menu and categories collapsed into the guide.');
        final categoryList =
            find.descendant(of: rail, matching: find.byType(CustomScrollView));
        final originalCategories = tester.widget(categoryList);
        tester
            .widget<MainNavigationRail>(find.byType(MainNavigationRail))
            .onSelect('sports');
        await tester.pump();
        nav.pop(destination);
        await tester.pumpAndSettle();
        expect(tester.widget(categoryList), same(originalCategories),
            reason:
                'Reopening the columns must preserve the category widgets.');
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-tab-TV');
        expect(
            tester
                .getSize(find.byKey(const ValueKey('live-navigation-rail')))
                .width,
            greaterThan(0));
        expect(tester.getSize(rail).width, greaterThan(0));
        expect(all.hitTestable(), findsOneWidget,
            reason: 'Both Back and Live TV return with categories accessible.');
      }
      await tester.tap(all);
      await tester.pumpAndSettle();
      original = tester.widget(rail);
      for (var i = 0; i < 4; i++) {
        await tester.tap(all);
        await tester.pumpAndSettle();
        expect(tester.widget(rail), same(original),
            reason:
                'Reselecting the same category preserves catalogue widgets.');
      }
      expect(playback.played, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      SportsChannelMatcher.disposeShared();
      playlist.dispose();
      playback.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  testWidgets('covering Live preserves its content widgets and data updates',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({});
    final storage = StorageService();
    await storage.init();
    await storage.setLiveCategoryFolders(false);
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _RailPlaylist(storage, CatalogDatabase());
    playlist.fixtureChannels
      ..clear()
      ..addAll(List.generate(
          40,
          (i) => Channel(
              id: 'demo::$i',
              rawId: '$i',
              playlistId: 'demo',
              name: 'Channel $i',
              group: 'Category $i',
              url: 'https://example.test/$i')));
    final playback = _Playback(storage, playlist);
    final epg = _DrillEpg(storage);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: const TvHomeScreen())));
    await tester.pumpAndSettle();
    final rail =
        find.byKey(const ValueKey('live-categories-rail'), skipOffstage: false);
    var original = tester.widget(rail);
    final homeContext = tester.element(find.byType(TvHomeScreen));
    final nav = Navigator.of(homeContext);
    for (var i = 0; i < 3; i++) {
      unawaited(nav.push(TopLevelTabRoute<void>(
          builder: (_) => const Scaffold(body: Text('Overlay')))));
      await tester.pumpAndSettle();
      expect(tester.widget(rail), same(original),
          reason: 'Route visibility alone must not rebuild the Live columns');
      nav.pop();
      await tester.pumpAndSettle();
      expect(tester.widget(rail), same(original));
      expect(
          FocusManager.instance.primaryFocus?.ancestors
              .any((n) => n.debugLabel == 'tv-tabs'),
          isTrue);
    }
    // Dialog visibility still guards background navigation, without rebuilding
    // the catalogue. Real provider changes must continue to reach Live.
    unawaited(showDialog<void>(
        context: homeContext,
        builder: (_) => const AlertDialog(content: Text('Dialog'))));
    await tester.pumpAndSettle();
    expect(tester.widget(rail), same(original));
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget(rail), isNot(same(original)),
        reason: 'Live remains visible and updates behind a dialog');
    original = tester.widget(rail);
    nav.pop();
    await tester.pumpAndSettle();
    unawaited(nav.push(TopLevelTabRoute<void>(
        builder: (_) => const Scaffold(body: Text('Another page')))));
    await tester.pumpAndSettle();
    playlist.fixtureChannels.add(Channel(
        id: 'new',
        rawId: 'new',
        playlistId: 'demo',
        name: 'New channel',
        group: 'New category',
        url: 'https://example.test/new'));
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget(rail), same(original),
        reason: 'Covered Live must defer catalogue layout until returning');
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    expect(tester.widget(rail), isNot(same(original)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  for (final entry in ['Favourites', 'History']) {
    testWidgets('TV category navigation after $entry has no scroll animation',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({});
      final storage = StorageService();
      await storage.init();
      await storage.setLiveCategoryFolders(false);
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final playlist = _RailPlaylist(storage, CatalogDatabase());
      playlist.fixtureChannels
        ..clear()
        ..addAll(List.generate(
            24,
            (i) => Channel(
                id: 'demo::$i',
                rawId: '$i',
                playlistId: 'demo',
                name: 'Channel $i',
                group: 'Category $i',
                url: 'https://example.test/$i')));
      final playback = _Playback(storage, playlist);
      playback.history.addAll(playlist.fixtureChannels.take(2));
      final epg = _DrillEpg(storage);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: const TvHomeScreen())));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      if (entry == 'History') {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump();
      final lists = find.descendant(
          of: find.byKey(const ValueKey('live-categories-rail')),
          matching: find.byType(Scrollable));
      final rail = tester.state<ScrollableState>(lists.first).position;
      final loads = playlist.catalogueLoads;
      var previous = FocusManager.instance.primaryFocus;
      for (var i = 0; i < 18; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        final focus = FocusManager.instance.primaryFocus!;
        expect(focus, isNot(same(previous)));
        previous = focus;
        expect(rail.isScrollingNotifier.value, isFalse);
        if (i == 0) expect(rail.pixels, 0);
        final viewport =
            tester.getRect(find.byKey(const ValueKey('live-categories-rail')));
        expect(focus.rect.top, greaterThanOrEqualTo(viewport.top));
        expect(focus.rect.bottom, lessThanOrEqualTo(viewport.bottom));
      }
      expect(rail.pixels, greaterThan(0));
      expect(playlist.catalogueLoads, loads);
      expect(playback.played, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  for (final fullVideo in [false, true]) {
    testWidgets(
        'Live column drills retain guide, focus and scroll fullVideo=$fullVideo',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      prefs.setGuideFullVideo(fullVideo);
      final playlist = _Playlist(storage, CatalogDatabase());
      playlist.fixtureChannels.addAll(List.generate(
          60,
          (i) => Channel(
              id: 'demo::extra$i',
              rawId: 'extra$i',
              playlistId: 'demo',
              name: 'Extra $i',
              group: 'Australian TV',
              url: 'https://example.test/$i')));
      final playback = _Playback(storage, playlist);
      final epg = _DrillEpg(storage);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: const TvHomeScreen())));
      await tester.pumpAndSettle();
      final time = find.byKey(const ValueKey('guide-time-scroll'));
      final guideWidget = tester.widget<SingleChildScrollView>(time);
      final horizontal = guideWidget.controller!;
      final vertical = tester
          .widget<ListView>(
              find.byKey(const ValueKey('guide-programme-scroll')))
          .controller!;
      final loads = playlist.catalogueLoads;
      double rail(String key) =>
          tester.getSize(find.byKey(ValueKey(key))).width;
      Future<void> key(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
      }

      Future<void> back() async {
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(rail('live-navigation-rail'), 132);
      expect(rail('live-categories-rail'), 208);
      await key(LogicalKeyboardKey.arrowRight);
      final categoryFocus = FocusManager.instance.primaryFocus;
      expect(rail('live-navigation-rail'), 0);
      expect(rail('live-categories-rail'), 208);
      await key(LogicalKeyboardKey.arrowRight);
      expect(rail('live-categories-rail'), 0);
      expect(horizontal.position.viewportDimension, greaterThan(700));
      // The newly exposed right edge must contain programme cells even though
      // the guide itself has not rebuilt. This catches stale viewport culling.
      final viewport = tester.getRect(time);
      final cells = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ProgramBlock');
      expect(
          cells.evaluate().any((e) {
            final rect = tester.getRect(find.byWidget(e.widget));
            return rect.left < viewport.right - 4 &&
                rect.right >= viewport.right - 4 &&
                rect.top >= viewport.top &&
                rect.top < viewport.bottom;
          }),
          isTrue);
      for (var i = 0; i < 18; i++) {
        await key(LogicalKeyboardKey.arrowDown);
      }
      await key(LogicalKeyboardKey.arrowRight);
      final guideFocus = FocusManager.instance.primaryFocus;
      final x = horizontal.offset;
      final y = vertical.offset;
      expect(y, greaterThan(0));
      expect(guideFocus?.ancestors.any((n) => n.debugLabel == 'timeline-grid'),
          isTrue);
      for (var i = 0; i < 4; i++) {
        await back();
        expect(FocusManager.instance.primaryFocus, same(categoryFocus));
        expect(rail('live-categories-rail'), 208);
        await back();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv-tab-TV');
        expect(rail('live-navigation-rail'), 132);
        expect(vertical.offset, closeTo(y, .1));
        expect(horizontal.offset, closeTo(x, .1));
        await key(LogicalKeyboardKey.arrowRight);
        await key(LogicalKeyboardKey.arrowRight);
        expect(FocusManager.instance.primaryFocus, same(guideFocus));
        expect(vertical.offset, closeTo(y, .1));
        expect(horizontal.offset, closeTo(x, .1));
      }
      expect(tester.widget<SingleChildScrollView>(time), same(guideWidget),
          reason: 'Column geometry must not recreate the guide subtree');
      expect(playlist.catalogueLoads, loads,
          reason: 'Pure focus changes must not restart catalogue preparation');
      // A nearby off-screen programme can reveal horizontally; a distant
      // retained block leaves the timeline alone. Neither may top-align the row.
      final rowTop = guideFocus!.rect.top;
      final offscreen = cells.evaluate().firstWhere((e) {
        final rect = tester.getRect(find.byWidget(e.widget));
        return rect.right <= tester.getRect(time).left &&
            (rect.top - rowTop).abs() < 5;
      });
      final focusWidget = tester.widget<Focus>(find
          .descendant(
              of: find.byWidget(offscreen.widget),
              matching: find
                  .byWidgetPredicate((w) => w is Focus && w.focusNode != null))
          .first);
      focusWidget.focusNode!.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(vertical.offset, closeTo(y, .1));
      expect(horizontal.offset, lessThanOrEqualTo(x));
      // A real catalogue update still reaches the retained guide.
      playlist.fixtureChannels.insert(
          0,
          Channel(
              id: 'demo::new',
              rawId: 'new',
              playlistId: 'demo',
              name: 'New channel',
              group: 'Australian TV',
              url: 'https://example.test/new'));
      playlist.notifyListeners();
      await tester.pumpAndSettle();
      expect(
          tester.widget<SingleChildScrollView>(time), isNot(same(guideWidget)));
      expect(find.text('New channel'), findsWidgets);
      expect(playlist.catalogueLoads, greaterThan(loads));
      expect(playback.played, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  for (final palette in AppConstants.cyberpunkPalettes) {
    for (final size in [const Size(390, 844), const Size(960, 540)]) {
      testWidgets('theme guide smoke ${palette.id} ${size.width}',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        setLayoutPreferences({});
        final storage = StorageService();
        await storage.init();
        await storage.setPaletteId(palette.id);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width > 600;
        final playlist = _Playlist(storage, CatalogDatabase());
        final playback = _Playback(storage, playlist);
        final epg = _Epg(storage);
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider<StorageService>.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<PlaybackService>.value(value: playback),
              ChangeNotifierProvider<EpgService>.value(value: epg),
            ],
            child: MaterialApp(
                theme: buildAppTheme(palette),
                navigatorObservers: [appRouteObserver],
                home: const TvHomeScreen())));
        await tester.pumpAndSettle();
        if (find.byKey(const ValueKey('guide-now')).evaluate().isEmpty) {
          await tester.tap(find.text('Australian TV').first);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('guide-now')));
        await tester.pumpAndSettle();
        expect(find.text('The World Today'), findsWidgets);
        expect(find.text('ABC HD'), findsWidgets);
        expect(playback.played, isEmpty);
        expect(tester.takeException(), isNull);
        await captureSports(tester, size, 'theme-guide-${palette.id}');
        await tester.pumpWidget(const SizedBox());
        playback.dispose();
        playlist.dispose();
        epg.dispose();
        prefs.dispose();
      });
    }
  }

  testWidgets(
      'multiview Sports selection returns a channel without preview playback',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(1280, 720);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            setLayoutPreferences({'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(['nhl']);
            await storage.setSportsLeagues(['nhl']);
            await storage.setSportsChannelFilter('all');
            const themeId = String.fromEnvironment('LAYOUT_THEME');
            if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            final playback = _Playback(storage, playlist);
            final epg = _Epg(storage);
            final scores = _PollingScores();
            Channel? selected;
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                ],
                child: MaterialApp(
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(
                        scores: scores,
                        selectionTitle: 'Sports · screen 2',
                        onChooseChannel: (c) async {
                          selected = c;
                        }))));
            await settleSports(tester);
            expect(find.text('Sports · screen 2'), findsOneWidget);
            expect(find.byType(PlayerControls), findsNothing);
            tester
                .widget<SportsFilterButton>(
                    find.byKey(const ValueKey('sport-picker')))
                .focusNode!
                .requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
            await tester.pump(const Duration(milliseconds: 700));
            await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
            await settleSports(tester);
            expect(find.byType(SportsChannelPickerDialog), findsOneWidget);
            final dialog = tester.widget<SportsChannelPickerDialog>(
                find.byType(SportsChannelPickerDialog));
            expect(dialog.allowMultiview, false);
            await tester.tap(find.text('Find another channel'));
            await settleSports(tester);
            final search = find.byKey(const ValueKey('sports-channel-search'));
            tester.widget<TextField>(search).focusNode!.requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pump();
            await tester.enterText(search, 'Fox');
            await tester.pump(const Duration(milliseconds: 250));
            await settleSports(tester);
            final chosenRow = tester
                .widget<SportsChannelRow>(find.byType(SportsChannelRow).first);
            await tester.tap(find.byKey(
                ValueKey('game-channel:${chosenRow.result.channel.id}')));
            await settleSports(tester);
            expect(selected, isNotNull);
            expect(playback.played, isEmpty);
            expect(playback.currentChannel, isNull);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await settleSports(tester);
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
            await tester.pump(const Duration(minutes: 2));
          }, () => MockClient((_) async => http.Response('{}', 200))));

  testWidgets(
      'pending Sports fullscreen cannot open over a newer route',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(1280, 720);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            setLayoutPreferences({'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(['nhl']);
            await storage.setSportsLeagues(['nhl']);
            await storage.setSportsChannelFilter('all');
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            playlist.fixtureChannels.add(Channel(
                id: 'demo::fixture',
                rawId: 'fixture',
                playlistId: 'demo',
                name: 'NHL: Boston Bruins vs Toronto Maple Leafs',
                group: 'Sports',
                url: 'https://example.test/live'));
            final playback = _Playback(storage, playlist)
              ..openGate = Completer<void>();
            final epg = _Epg(storage)..withoutGuide.add('fixture');
            final navigator = GlobalKey<NavigatorState>();
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                ],
                child: MaterialApp(
                    navigatorKey: navigator,
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(
                        scores: _RowScores(
                            counts: {'nhl': 1}, namedTeams: true)))));
            await settleSports(tester);
            final card = find.byKey(const ValueKey('card-nhl:row-0'));
            // A settled frame does not imply the matching isolate has replied.
            final matchedChannel = find.descendant(
                of: card,
                matching:
                    find.text('NHL: Boston Bruins vs Toronto Maple Leafs'));
            for (var i = 0; i < 200 && matchedChannel.evaluate().isEmpty; i++) {
              await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)));
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(matchedChannel, findsOneWidget);
            await tester.tap(card);
            await tester.pump();
            expect(playback.played, hasLength(1));
            // Repeated OK while the stream is opening must not stack fullscreen routes.
            await tester.tap(card);
            await tester.pump();
            await tester.tap(card);
            await tester.pump();
            unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
                builder: (_) =>
                    const Scaffold(body: Text('New destination')))));
            await tester.pumpAndSettle();
            playback.openGate!.complete();
            await tester.pumpAndSettle();
            expect(find.text('New destination'), findsOneWidget);
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
            expect(find.byType(SportsScreen), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            SportsChannelMatcher.disposeShared();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
            await tester.pump(const Duration(minutes: 2));
          }, () => MockClient((_) async => http.Response('{}', 200))));

  testWidgets(
      'TV sports remote reaches refresh and isolates card focus rebuilds',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(1280, 720);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            setLayoutPreferences({'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(['nhl']);
            await storage.setSportsLeagues(['nhl']);
            await storage.setSportsChannelFilter('all');
            const themeId = String.fromEnvironment('LAYOUT_THEME');
            if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            final playback = _Playback(storage, playlist);
            final epg = _Epg(storage);
            final scores = _PollingScores();
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                ],
                child: MaterialApp(
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(scores: scores))));
            await settleSports(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-refresh');
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-status-details');
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pumpAndSettle();
            expect(find.text('Events & channel status'), findsOneWidget);
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-status-details');
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-refresh');
            final calls = scores.calls;
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await settleSports(tester);
            expect(scores.calls, calls + 1);
            // Returning to the toolbar is explicit, including during refresh.
            tester
                .widget<SportsFilterButton>(
                    find.byKey(const ValueKey('sport-picker')))
                .focusNode!
                .requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                startsWith('sports-card-'));
            var screenBuilds = 0;
            final previous = debugOnRebuildDirtyWidget;
            debugOnRebuildDirtyWidget = (element, builtOnce) {
              if (element.widget is SportsScreen) screenBuilds++;
              previous?.call(element, builtOnce);
            };
            addTearDown(() => debugOnRebuildDirtyWidget = previous);
            for (var i = 0; i < 4; i++) {
              await tester.sendKeyEvent(i.isEven
                  ? LogicalKeyboardKey.arrowRight
                  : LogicalKeyboardKey.arrowLeft);
              await tester.pump();
            }
            expect(screenBuilds, 0,
                reason: 'Remote focus only updates preview and two cards');
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-sport:hockey');
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await settleSports(tester);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                startsWith('sports-card-'));
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-liveall');
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                startsWith('sports-card-'));
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            SportsChannelMatcher.disposeShared();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
          },
              () => MockClient(
                  (_) async => http.Response('{"events":[]}', 200))));

  testWidgets(
      'TV keeps the focused card visible through streamed sports and removals',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(960, 540);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            setLayoutPreferences({'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            final ids = [
              'nba',
              'eng.1',
              'nhl',
              'mma.ufc',
              'guide.poker',
              'rugby.180659',
              'tennis.atp'
            ];
            await storage.setSportsAddedLeagues(ids);
            await storage.setSportsLeagues(ids);
            await storage.setSportsChannelFilter('all');
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            final playback = _Playback(storage, playlist);
            final epg = _SlowGuide(storage);
            final scores = _HeldScores();
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                ],
                child: MaterialApp(
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(scores: scores))));
            Future<void> flush() async {
              for (var i = 0; i < 20; i++) {
                await tester.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 5)));
                await tester.pump(const Duration(milliseconds: 16));
              }
            }

            await flush();
            final fixtures = await _RowScores(
                    counts: {for (final id in ids) id: id == 'nhl' ? 40 : 2})
                .gamesForDay(ids.map((id) => sportsLeagueById(id)!).toList(),
                    DateTime.now());
            final first = fixtures
                .where((g) => g.league.id != 'nba' && g.league.id != 'eng.1')
                .toList();
            scores.publish!(first);
            await flush();
            final dynamic card =
                tester.widget(find.byKey(const ValueKey('card-nhl:row-0')));
            (card.focusNode as FocusNode).requestFocus();
            await tester.pump();
            for (var i = 0; i < 8; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            }
            await flush();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-card-nhl:row-8');
            final anchor = find.byKey(const ValueKey('card-nhl:row-8'));
            final position = tester.getTopLeft(anchor);
            scores.publish!(fixtures);
            await flush();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-card-nhl:row-8');
            expect(tester.getTopLeft(anchor), position,
                reason:
                    'Incoming sports above the browsed row must not move its focused card');
            expect(
                tester
                    .widgetList<ListView>(find.byWidgetPredicate((w) =>
                        w is ListView && w.scrollDirection == Axis.horizontal))
                    .length,
                lessThan(ids.length),
                reason: 'Offscreen rows are not rebuilt as scores arrive');
            scores.publish!(fixtures
                .where((g) =>
                    g.league.id != 'nhl' || int.parse(g.id.substring(4)) >= 9)
                .toList());
            await flush();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-card-nhl:row-9');
            final viewport = tester
                .getRect(find.byKey(const PageStorageKey('sports-events')));
            final rect = FocusManager.instance.primaryFocus!.rect;
            expect(rect.top, greaterThanOrEqualTo(viewport.top - 1));
            expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 1));
            expect(rect.left, greaterThanOrEqualTo(viewport.left - 1));
            expect(rect.right, lessThanOrEqualTo(viewport.right + 1));
            // A toolbar action while a lazy target is pending must cancel that target.
            for (var i = 0; i < 10; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
            await flush();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'sports-chip-refresh');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            scores.done.complete(fixtures);
            for (final request in epg.requests) {
              if (!request.isCompleted) request.complete([]);
            }
            SportsChannelMatcher.disposeShared();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
            await tester.pump();
          },
              () => MockClient(
                  (_) async => http.Response('{"events":[]}', 200))));

  testWidgets(
      'TV sports navigates uneven rows, lazy cards and every toolbar control',
      (tester) => http.runWithClient(() async {
            tester.view.physicalSize = const Size(960, 540);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            setLayoutPreferences({'sports_online_extras': false});
            final storage = StorageService();
            await storage.init();
            await storage.setSportsAddedLeagues(
                ['eng.1', 'mma.ufc', 'guide.poker', 'nba', 'nhl']);
            await storage.setSportsLeagues(
                ['eng.1', 'mma.ufc', 'guide.poker', 'nba', 'nhl']);
            await storage.setSportsChannelFilter('all');
            const themeId = String.fromEnvironment('LAYOUT_THEME');
            if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
            final prefs = AppPreferences(storage);
            await prefs.init();
            prefs.isTelevision = true;
            final playlist = _Playlist(storage, CatalogDatabase());
            final playback = _Playback(storage, playlist);
            final epg = _Epg(storage);
            final scores = _RowScores(upcoming: {
              'nba',
              'nhl'
            }, counts: {
              'eng.1': 1,
              'mma.ufc': 1,
              'guide.poker': 3,
              'nba': 1,
              'nhl': 20
            });
            await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                ],
                child: MaterialApp(
                    theme: buildAppTheme(prefs.palette),
                    navigatorObservers: [appRouteObserver],
                    home: SportsScreen(scores: scores))));
            await settleSports(tester);
            String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
            Future<void> press(LogicalKeyboardKey key) async {
              await tester.sendKeyEvent(key);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 20));
              final focus = FocusManager.instance.primaryFocus;
              if (focus?.debugLabel?.startsWith('sports-card-') ?? false) {
                final viewport = tester
                    .getRect(find.byKey(const PageStorageKey('sports-events')));
                expect(focus!.rect.top, greaterThanOrEqualTo(viewport.top - 1),
                    reason: 'Focused card is visible above');
                expect(
                    focus.rect.bottom, lessThanOrEqualTo(viewport.bottom + 1),
                    reason: 'Focused card is visible below');
                expect(focus.rect.left, greaterThanOrEqualTo(viewport.left - 1),
                    reason: 'Focused card is visible on left');
                expect(focus.rect.right, lessThanOrEqualTo(viewport.right + 1),
                    reason: 'Focused card is visible on right');
              }
            }

            final toolbar = [
              'view-events',
              'view-standings',
              'view-schedule',
              'view-replays',
              'view-highlights',
              'sport-picker',
              'league-picker',
              'live-only',
              'with-channel',
              'events-favourites-only',
              'day',
              'options'
            ];
            for (var i = 0; i < 5; i++) {
              await press(LogicalKeyboardKey.arrowLeft);
            }
            expect(focused(), 'sports-chip-view-events');
            for (final id in toolbar.skip(1)) {
              await press(LogicalKeyboardKey.arrowRight);
              expect(focused(), 'sports-chip-$id');
            }
            await press(LogicalKeyboardKey.arrowRight);
            expect(focused(), 'sports-chip-options',
                reason: 'No wrap into content');
            for (final id in toolbar.reversed.skip(1)) {
              await press(LogicalKeyboardKey.arrowLeft);
              expect(focused(), 'sports-chip-$id');
            }
            final previewBounds = tester
                .getRect(find.byKey(const ValueKey('sports-preview-column')));
            final sportBounds =
                tester.getRect(find.byKey(const ValueKey('sport-picker')));
            expect(sportBounds.left, closeTo(previewBounds.right + 12, .1));
            expect(
                tester
                    .getSize(find.byKey(const ValueKey('with-channel')))
                    .width,
                greaterThanOrEqualTo(88));
            for (final key in ['live-only', 'with-channel', 'sports-day']) {
              final bounds = tester.getRect(find.byKey(ValueKey(key)));
              expect(bounds.center.dy, closeTo(sportBounds.center.dy, 1));
              expect(bounds.right, lessThanOrEqualTo(940));
            }
            expect(find.byKey(const ValueKey('sports-event-filters')),
                findsNothing);
            tester.view.physicalSize = const Size(640, 540);
            await tester.pump();
            for (final id in [
              ...toolbar.take(7),
              'events-favourites-only',
              'event-filters',
              'day',
              'options'
            ].skip(1)) {
              await press(LogicalKeyboardKey.arrowRight);
              expect(focused(), 'sports-chip-$id',
                  reason: 'Clipped toolbar remains traversable');
            }
            for (final id in [
              ...toolbar.take(7),
              'events-favourites-only',
              'event-filters',
              'day',
              'options'
            ].reversed.skip(1)) {
              await press(LogicalKeyboardKey.arrowLeft);
              expect(focused(), 'sports-chip-$id');
            }
            tester.view.physicalSize = const Size(960, 540);
            await tester.pump();

            final rows = tester.widgetList<ListView>(find.byWidgetPredicate(
                (w) => w is ListView && w.scrollDirection == Axis.horizontal));
            expect(rows.length, lessThan(5),
                reason: 'Offscreen sports stay lazy');
            final firstKeys = [
              for (final id in [
                'nba',
                'eng.1',
                'nhl',
                'mma.ufc',
                'guide.poker'
              ])
                '$id:row-0'
            ];
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-${firstKeys.first}');
            for (final key in firstKeys.skip(1)) {
              await press(LogicalKeyboardKey.arrowDown);
              expect(focused(), 'sports-card-$key',
                  reason: 'Exactly one sport per Down');
            }
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-${firstKeys.last}');
            for (final key in firstKeys.reversed.skip(1)) {
              await press(LogicalKeyboardKey.arrowUp);
              expect(focused(), 'sports-card-$key');
            }
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-events');
            // Enter poker's third card, then cross a one-card row in each direction.
            final pokerRow =
                firstKeys.indexWhere((k) => k.startsWith('guide.poker:'));
            for (var i = 0; i <= pokerRow; i++) {
              await press(LogicalKeyboardKey.arrowDown);
            }
            await press(LogicalKeyboardKey.arrowRight);
            await press(LogicalKeyboardKey.arrowRight);
            expect(focused(), 'sports-card-guide.poker:row-2');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-card-${firstKeys[pokerRow - 1]}');
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-guide.poker:row-0');
            // Sport headings are reachable without being compulsory stops.
            await press(LogicalKeyboardKey.arrowLeft);
            expect(focused(), 'sports-chip-sport:poker');
            for (final sport in ['mma', 'hockey', 'soccer', 'basketball']) {
              await press(LogicalKeyboardKey.arrowUp);
              expect(focused(), 'sports-chip-sport:$sport');
            }
            // Burst through headings whose outer rows have not been built yet.
            for (var i = 0; i < 4; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            }
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(focused(), 'sports-chip-sport:poker');
            await press(LogicalKeyboardKey.arrowLeft);
            expect(focused(), 'sports-chip-refresh');
            await press(LogicalKeyboardKey.arrowRight);
            expect(focused(), 'sports-card-guide.poker:row-0');
            await press(LogicalKeyboardKey.contextMenu);
            expect(focused(), 'sports-chip-refresh');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-events');
            await press(LogicalKeyboardKey.arrowDown);
            expect(focused(), 'sports-card-guide.poker:row-0',
                reason: 'Resume browsing');
            // A long horizontal row must build and focus offscreen neighbours.
            final longRow = firstKeys.indexWhere((k) => k.startsWith('nhl:'));
            for (var i = pokerRow; i > longRow; i--) {
              await press(LogicalKeyboardKey.arrowUp);
            }
            // Remote events can accumulate while loading occupies a frame.
            // Preserve all intended steps through currently unbuilt cards.
            for (var i = 0; i < 8; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            }
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(focused(), 'sports-card-nhl:row-8',
                reason:
                    'Buffered arrows must not be swallowed by lazy mounting');
            for (var i = 0; i < 8; i++) {
              await press(LogicalKeyboardKey.arrowLeft);
            }
            for (var i = 1; i < 15; i++) {
              await press(LogicalKeyboardKey.arrowRight);
              expect(focused(),
                  'sports-card-${firstKeys[longRow].replaceFirst('row-0', 'row-$i')}');
            }
            await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            for (var i = 12; i >= 8; i--) {
              await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 20));
              expect(focused(),
                  'sports-card-${firstKeys[longRow].replaceFirst('row-0', 'row-$i')}');
            }
            await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-card-${firstKeys[longRow - 1]}');
            // Remember an Events-only filter, then replace its widget by
            // switching views. A detached node still has a context in Flutter.
            await press(LogicalKeyboardKey.contextMenu);
            await press(LogicalKeyboardKey.arrowUp);
            for (var i = 0; i < 5; i++) {
              await press(LogicalKeyboardKey.arrowRight);
            }
            expect(focused(), 'sports-chip-sport-picker');
            await press(LogicalKeyboardKey.arrowDown);
            await press(LogicalKeyboardKey.contextMenu);
            await press(LogicalKeyboardKey.arrowUp);
            await press(LogicalKeyboardKey.arrowLeft);
            await press(LogicalKeyboardKey.arrowLeft);
            expect(focused(), 'sports-chip-view-replays');
            await press(LogicalKeyboardKey.select);
            await settleSports(tester);
            await press(LogicalKeyboardKey.contextMenu);
            expect(focused(), 'replays-refresh');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-replays',
                reason: 'Do not focus the detached Events filter');
            await press(LogicalKeyboardKey.arrowRight);
            await press(LogicalKeyboardKey.select);
            await settleSports(tester);
            await press(LogicalKeyboardKey.contextMenu);
            expect(focused(), 'replays-refresh');
            await press(LogicalKeyboardKey.arrowUp);
            expect(focused(), 'sports-chip-view-highlights');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            SportsChannelMatcher.disposeShared();
            playback.dispose();
            playlist.dispose();
            epg.dispose();
            prefs.dispose();
          },
              () => MockClient(
                  (_) async => http.Response('{"events":[]}', 200))));

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets(
        'direct settings navigation preserves playback at ${size.width}',
        (tester) => http.runWithClient(() async {
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              setLayoutPreferences({'sports_online_extras': false});
              final storage = StorageService();
              await storage.init();
              await storage.setSportsAddedLeagues(['nhl']);
              await storage.setSportsLeagues(['nhl']);
              const themeId = String.fromEnvironment('LAYOUT_THEME');
              if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
              final prefs = AppPreferences(storage);
              await prefs.init();
              prefs.isTelevision = size.width > 600;
              final playlist = _Playlist(storage, CatalogDatabase());
              final playback = _Playback(storage, playlist);
              final epg = _Epg(storage);
              await playback.play(playlist.channels.first);
              await tester.pumpWidget(MultiProvider(
                  providers: [
                    Provider.value(value: storage),
                    ChangeNotifierProvider.value(value: prefs),
                    ChangeNotifierProvider<PlaylistManager>.value(
                        value: playlist),
                    ChangeNotifierProvider<PlaybackService>.value(
                        value: playback),
                    ChangeNotifierProvider<EpgService>.value(value: epg),
                  ],
                  child: MaterialApp(
                      theme: buildAppTheme(prefs.palette),
                      navigatorObservers: [appRouteObserver],
                      home: const TvHomeScreen())));
              await tester.pumpAndSettle();
              final channel = playback.currentChannel;
              final count = playback.played.length;
              final settings = size.width < 600
                  ? find.byKey(const ValueKey('bottom-settings'))
                  : find.text('Settings');
              await tester.tap(settings);
              await tester.pumpAndSettle();
              expect(find.byType(SettingsMenuScreen), findsOneWidget);
              expect(find.text('Search'), findsNothing);
              expect(find.text('Refresh playlists'), findsNothing);
              expect(find.text('Playlists & guide'), findsOneWidget);
              expect(playback.currentChannel, channel);
              if (size.width < 600) {
                await tester.tap(find.byKey(const ValueKey('bottom-sports')));
                await settleSports(tester);
                expect(find.byType(SportsScreen), findsOneWidget);
                await tester.tap(find.byKey(const ValueKey('bottom-settings')));
                await settleSports(tester);
                expect(find.byType(SettingsMenuScreen), findsOneWidget);
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
              } else {
                await tester.pageBack();
              }
              await settleSports(tester);
              expect(find.byType(SettingsMenuScreen), findsNothing);
              expect(find.byType(SportsScreen), findsNothing);
              expect(playback.currentChannel, channel);
              expect(playback.played.length, count);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
              SportsChannelMatcher.disposeShared();
              playback.dispose();
              playlist.dispose();
              epg.dispose();
              prefs.dispose();
            },
                () => MockClient(
                    (_) async => http.Response('{"events":[]}', 200))));
  }
  for (final (clock, label, expected) in [
    (DateTime(2026, 4, 5, 12), 'Tomorrow', DateTime(2026, 4, 6)),
    (DateTime(2026, 10, 5, 12), 'Yesterday', DateTime(2026, 10, 4)),
  ]) {
    testWidgets(
        'sports day picker follows calendar dates across DST: $label from $clock',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _Epg(storage);
      final scores = _CalendarScores();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores, clock: () => clock))));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.ensureVisible(find.byKey(const ValueKey('sports-day')));
      await tester.tap(find.byKey(const ValueKey('sports-day')));
      await tester.pump(const Duration(milliseconds: 200));
      if (clock.month == 4) {
        expect(find.text('Tue 7 Apr'), findsOneWidget,
            reason: 'dated labels use the same calendar as requested events');
      }
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 200));
      expect(scores.days.last, expected);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  for (final initialFailure in [true, false]) {
    testWidgets(
        'unexpected scores failure retains events and permits retry, initial=$initialFailure',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _Epg(storage);
      final scores = _RecoveringScores();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores))));
      Future<void> flush() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      final refresh = find.byKey(const ValueKey('sports-refresh'));
      await scores.firstBatch();
      await flush();
      if (!initialFailure) {
        scores.done.complete(scores.batch);
        await flush();
        await tester.tap(refresh);
        await tester.pump();
      }
      expect(sportsRefreshAction(tester), isNotNull,
          reason: 'A busy refresh stays focusable on TV');
      final pendingCalls = scores.retries.length;
      await tester.tap(refresh);
      await tester.pump();
      expect(scores.retries.length, pendingCalls,
          reason: 'Activating a busy refresh does not start another request');
      (initialFailure ? scores.done : scores.retries.last)
          .completeError(StateError('simulated unexpected feed failure'));
      await flush();
      expect(find.byKey(const ValueKey('card-nhl:poll-0')), findsOneWidget);
      expect(sportsRefreshAction(tester), isNotNull);
      expect(tester.takeException(), isNull);
      await tester.tap(refresh);
      await tester.pump();
      scores.retries.last.complete(scores.batch);
      await flush();
      expect(sportsRefreshAction(tester), isNotNull);
      expect(find.textContaining('Checked'), findsOneWidget);
      expect(find.byKey(const ValueKey('card-nhl:poll-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  for (final tv in [true, false]) {
    testWidgets(
        'inline standings retain preview, pause hidden work and restore browsing on ${tv ? "TV" : "phone"}',
        (tester) async {
      tester.view.physicalSize =
          tv ? const Size(960, 540) : const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      await storage.setSportsBrowseSelection('basketball', 'nba');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = tv;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      playback.currentChannel = playlist.fixtureChannels.first;
      final epg = _Epg(storage);
      final scores = _InlineScores();
      var appNow = scores.start;
      var requests = 0;
      final standings = SportsStandingsService(client: MockClient((_) async {
        requests++;
        return http.Response(standings_fixture.table(teams: 500), 200);
      }));
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(
                  scores: scores, standings: standings, clock: () => appNow))));
      Future<void> flush() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      await flush();
      expect(requests, 0);
      final player = tester.element(find.byType(VideoPlayerPane));
      final current = playback.currentChannel;
      await tester
          .ensureVisible(find.byKey(const ValueKey('sports-view-schedule')));
      await tester.tap(find.byKey(const ValueKey('sports-view-schedule')));
      await flush();
      expect(find.byType(SportsSchedulePanel), findsOneWidget);
      expect(
          tester
              .widget<SportsSchedulePanel>(find.byType(SportsSchedulePanel))
              .initialLeague
              ?.id,
          'nba',
          reason:
              'Schedule retains the explicit browsing selection independently of Events.');
      tester
          .widget<SportsSchedulePanel>(find.byType(SportsSchedulePanel))
          .onLeagueChanged!(sportsLeagueById('eng.1')!);

      expect(tester.element(find.byType(VideoPlayerPane)), same(player));
      if (!tv) {
        await tester.ensureVisible(
            find.byKey(const ValueKey('schedule-search-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('schedule-search-toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('schedule-search')), 'Team');
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pump();
        expect(find.byKey(const ValueKey('schedule-search')).hitTestable(),
            findsOneWidget);
        expect(tester.element(find.byType(VideoPlayerPane)), same(player));
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pump();
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
      }
      final schedulePolls = scores.calls;
      await tester.pump(const Duration(seconds: 31));
      await flush();
      expect(scores.calls, schedulePolls,
          reason: 'Schedule does not poll hidden Events');
      await Navigator.of(tester.element(find.byType(SportsScreen))).maybePop();
      await flush();
      expect(find.byType(SportsSchedulePanel), findsNothing);
      await tester
          .ensureVisible(find.byKey(const ValueKey('sports-view-standings')));
      await tester.tap(find.byKey(const ValueKey('sports-view-standings')));
      await flush();
      expect(find.byKey(const ValueKey('sports-inline-standings')),
          findsOneWidget);
      expect(
          tester
              .widget<SportsTeamsScreen>(find.byType(SportsTeamsScreen))
              .initialLeague
              ?.id,
          'eng.1');
      expect(storage.getSportsBrowseSelection(), ['soccer', 'eng.1']);
      await tester.tap(find.byKey(const ValueKey('standings-favourites-only')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sports-favourites-all')));
      await flush();

      expect(tester.element(find.byType(VideoPlayerPane)), same(player));
      expect(find.byKey(const PageStorageKey('sports-events')), findsNothing);
      expect(find.byType(StandingsTeamTile).evaluate().length, lessThan(25));
      expect(requests, 1);
      if (tv) {
        expect(
            tester
                .getTopLeft(find.byKey(const ValueKey('standings-league')))
                .dy,
            lessThan(tester
                .getTopLeft(find.byKey(const ValueKey('sports-preview-column')))
                .dy),
            reason: 'Standings selectors share the main Sports toolbar');
        final previewBounds =
            tester.getRect(find.byKey(const ValueKey('sports-preview-column')));
        final sportBounds =
            tester.getRect(find.byKey(const ValueKey('standings-sport')));
        expect(sportBounds.left, closeTo(previewBounds.right + 12, .1),
            reason: 'Primary selectors start at the results column');
      }
      final polls = scores.calls;
      await tester.pump(const Duration(seconds: 31));
      await flush();
      expect(scores.calls, polls, reason: 'Hidden events do not poll');
      if (tv) {
        final tab = tester.widget<TextButton>(
            find.byKey(const ValueKey('sports-view-standings')));
        tab.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-standings-search');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(
            tester
                .widget<SportsFilterButton>(
                    find.byKey(const ValueKey('standings-league')))
                .focusNode!
                .hasFocus,
            isTrue);
      }
      if (tv) {
        tester
            .widget<TextField>(find.byKey(const ValueKey('standings-search')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(
          find.byKey(const ValueKey('standings-search')), 'Team 1');
      await tester.pump();
      if (!tv) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pump();
        expect(find.byKey(const ValueKey('standings-search')).hitTestable(),
            findsOneWidget);
        expect(tester.element(find.byType(VideoPlayerPane)), same(player));
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pump();
      }
      final list = tester.widget<ListView>(find.descendant(
          of: find.byType(SportsTeamsScreen), matching: find.byType(ListView)));
      list.controller!.jumpTo(300);
      await tester.pump();
      final beforeReturnPolls = scores.calls;
      // The shared toolbar retains its horizontal offset across tabs.
      await tester
          .ensureVisible(find.byKey(const ValueKey('sports-view-events')));
      await tester.tap(find.byKey(const ValueKey('sports-view-events')));
      await flush();
      expect(find.byType(SportsTeamsScreen), findsNothing);
      expect(scores.calls, beforeReturnPolls,
          reason: 'Other tabs do not invalidate the retained Events scope.');
      expect(tester.element(find.byType(VideoPlayerPane)), same(player));
      await tester.tap(find.byKey(const ValueKey('sports-view-standings')));
      await flush();
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('standings-search')))
              .controller!
              .text,
          'Team 1');
      final restored = tester.widget<ListView>(find.descendant(
          of: find.byType(SportsTeamsScreen), matching: find.byType(ListView)));
      expect(restored.controller!.offset, closeTo(300, .1));
      expect(requests, 1, reason: 'Standings reuse the shared cache');
      final sameScopeCalls = scores.calls;
      await tester
          .ensureVisible(find.byKey(const ValueKey('sports-view-events')));
      await tester.tap(find.byKey(const ValueKey('sports-view-events')));
      await flush();
      expect(scores.calls, sameScopeCalls,
          reason:
              'Quick returns with unchanged scope reuse the score snapshot');
      await tester.tap(find.byKey(const ValueKey('sports-view-standings')));
      await flush();
      await tester.tap(find.byTooltip('Sports options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage favourite leagues'));
      await tester.pumpAndSettle();
      expect(find.byType(SportsLeagueManagerScreen), findsOneWidget);
      expect(tester.element(find.byType(VideoPlayerPane)), same(player));
      await Navigator.of(tester.element(find.byType(SportsLeagueManagerScreen)))
          .maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(SportsLeagueManagerScreen), findsNothing);
      await Navigator.of(tester.element(find.byType(SportsScreen))).maybePop();
      await flush();
      expect(find.byType(SportsTeamsScreen), findsNothing,
          reason: 'Back returns to Events');
      await tester.tap(find.byTooltip('Sports options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage favourite leagues'));
      await tester.pumpAndSettle();
      final overlayPolls = scores.calls;
      await tester.pump(const Duration(seconds: 31));
      await flush();
      expect(scores.calls, overlayPolls,
          reason: 'Event polling also pauses beneath management overlays');
      expect(tester.element(find.byType(VideoPlayerPane)), same(player));
      await tester.tap(find.byKey(const ValueKey('close-leagues')));
      await flush();
      expect(find.byType(SportsLeagueManagerScreen), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sports-view-standings')));
      await flush();
      appNow = appNow.add(const Duration(seconds: 31));
      final beforeStaleReturn = scores.calls;
      await tester.tap(find.byKey(const ValueKey('sports-view-events')));
      await flush();
      expect(scores.calls, beforeStaleReturn + 1,
          reason: 'Returning after the poll interval refreshes scores');
      expect(playback.currentChannel, same(current));
      expect(playback.played, isEmpty,
          reason: 'View changes never restart playback');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      standings.close();
      SportsChannelMatcher.disposeShared();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  testWidgets(
      'guide warms before scores and matches the first batch while other feeds wait',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _WarmGuide(storage);
    final scores = _HeldScores();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.reads, greaterThan(0),
        reason: 'guide cache loads before the first score feed');
    expect(epg.requests, isEmpty, reason: 'no speculative programme queries');
    final reads = epg.reads;
    await scores.firstBatch();
    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.requests, hasLength(1),
        reason: 'event guide search overlaps remaining score feeds');
    expect(epg.reads, reads,
        reason: 'the event search reuses the prepared guide');
    epg.requests.single.complete([]);
    await flush();
    expect(find.textContaining('Checked'), findsNothing,
        reason: 'the score feed is still visibly loading');
    expect(find.byKey(const ValueKey('card-nhl:poll-0')), findsOneWidget);
    scores.done.complete(scores.batch);
    await flush();
    expect(epg.requests, hasLength(1),
        reason: 'finishing scores does not repeat matching');
    expect(find.textContaining('Checked'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'guide events appear while known live fixture SQL is still pending',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl', 'guide.badminton']);
    await storage.setSportsChannelFilter('matched');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _SlowGuide(storage);
    final scores = _RowScores(counts: {'nhl': 1});
    epg.replays = [
      EpgProgram(
          channelId: playlist.fixtureChannels.first.epgId,
          title: 'Live Badminton World Tour',
          isLive: true,
          start: DateTime.now().subtract(const Duration(minutes: 10)),
          stop: DateTime.now().add(const Duration(hours: 2)))
    ];
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            builder: (context, child) => RepaintBoundary(child: child),
            home: SportsScreen(scores: scores, clock: () => scores.start))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    for (var i = 0; i < 15 && epg.requests.isEmpty; i++) {
      await flush();
    }
    expect(epg.requests, hasLength(1));
    expect(find.textContaining('Live Badminton World Tour'), findsWidgets,
        reason:
            'Exact guide bindings must pass With channel before fixture SQL finishes');
    epg.requests.single.complete([]);
    await flush();
    expect(find.textContaining('Live Badminton World Tour'), findsWidgets,
        reason: 'Guide events remain present after the fixture query finishes');
    expect(find.textContaining('Checked'), findsOneWidget);
    final scope = '${sportsCalendarDay(scores.start, 0).toIso8601String()}:'
        '${savedSportsLeagues(storage).map((l) => l.id).join(',')}';
    final snapshot = SportsBrowseCache.shared.read((
      storage,
      playlist,
      epg,
      scores,
      SportsSupplementService.instance,
      SportsChannelMatcher.shared(epg),
      false,
      storage.getActiveViewerId(),
      sportsCalendarDay(scores.start, 0),
      playlist.liveRevision,
      (epg.changeRevision, epg.currentGuideRevision, epg.lastUpdated),
    ), scores.start);
    expect(snapshot, isNotNull);
    final identities = snapshot!.restoreSession().identities;
    expect(identities.length, greaterThan(1),
        reason: 'The saved pass includes the newly discovered guide fixture');
    expect(
        snapshot.signature,
        (
          scope,
          scores.start.millisecondsSinceEpoch ~/ 60000,
          playlist.liveRevision,
          epg.changeRevision,
          epg.currentGuideRevision,
          epg.lastUpdated,
          identities,
        ),
        reason:
            'Queued work compares the completed inputs, not the initial ones');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'failed live query exposes guide-only coverage while a queued retry waits',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl', 'guide.badminton']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _SlowGuide(storage);
    final scores = _RowScores(counts: {'nhl': 1});
    epg.replays = [
      EpgProgram(
          channelId: playlist.fixtureChannels.first.epgId,
          title: 'Live Badminton World Tour',
          isLive: true,
          start: DateTime.now().subtract(const Duration(minutes: 10)),
          stop: DateTime.now().add(const Duration(hours: 2)))
    ];
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    for (var i = 0; i < 15 && epg.requests.isEmpty; i++) {
      await flush();
    }
    expect(epg.requests, hasLength(1));
    expect(find.textContaining('Live Badminton World Tour'), findsWidgets,
        reason: 'Guide discovery overlaps the pending fixture query');
    epg.requests.single.completeError(StateError('Guide query unavailable'));
    await flush();
    expect(find.textContaining('Live Badminton World Tour'), findsWidgets,
        reason: 'Guide events remain present after the fixture query finishes');
    expect(epg.requests, hasLength(2),
        reason:
            'the queued live retry is still blocked; discovery did not need it');
    expect(epg.requests.last.isCompleted, isFalse);
    epg.requests.last.complete([]);
    await flush();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  for (final leave in [false, true]) {
    testWidgets(
        'new live arrivals precede remaining later batches; leave=$leave',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _PriorityGuide(storage);
      final scores = _HeldScores();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores))));
      Future<void> flush() async {
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      await flush();
      final now = DateTime.now();
      SportsGame fixture(String id, {int hour = 0}) => SportsGame(
          id: id,
          league: sportsLeagueById('nhl')!,
          start: now.add(Duration(hours: hour)),
          state: hour == 0 ? GameState.live : GameState.pre,
          statusText: '',
          home: SportsTeam(
              id: 'home',
              name: id == 'urgent' ? 'Zebrafish United' : 'Boston Bruins',
              shortName: id == 'urgent' ? 'Zebrafish' : 'Bruins',
              abbreviation: ''),
          away: const SportsTeam(
              id: 'away',
              name: 'Toronto Maple Leafs',
              shortName: 'Maple Leafs',
              abbreviation: ''));
      final initial = [
        fixture('first'),
        for (var i = 0; i < 60; i++) fixture('later$i', hour: 4 + (i ~/ 24) * 8)
      ];
      scores.batch = initial;
      scores.publish!(initial);
      await flush();
      expect(epg.held, true);
      final latest = [...initial, fixture('urgent')];
      scores.batch = latest;
      scores.publish!(latest);
      await tester.pump();
      if (leave) await tester.pumpWidget(const SizedBox());
      epg.laterGate.complete();
      scores.done.complete(latest);
      await flush();
      if (leave) {
        expect(epg.order, ['later']);
      } else {
        expect(epg.order, contains('urgent'));
        expect(epg.order.indexOf('urgent'),
            lessThan(epg.order.lastIndexOf('later')));
        expect(find.byKey(const ValueKey('card-nhl:urgent')), findsOneWidget);
        expect(find.textContaining('Checked'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  testWidgets(
      'late sport rows slot alphabetically without losing focused event',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl', 'nba', 'tennis.atp']);
    await storage.setSportsLeagues(['nhl', 'nba', 'tennis.atp']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage, CatalogDatabase());
    playlist.fixtureChannels
      ..clear()
      ..add(Channel(
          id: 'weather',
          rawId: 'weather',
          playlistId: 'demo',
          name: 'Weather',
          group: 'News',
          epgIdOverride: 'weather',
          url: 'https://example.invalid/never-play'));
    final playback = _Playback(storage, playlist);
    final epg = _WarmGuide(storage);
    final scores = _HeldScores();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    final now = DateTime.now();
    SportsGame event(String league, {bool soon = false}) => SportsGame(
        id: league,
        league: sportsLeagueById(league)!,
        start: now.add(Duration(minutes: soon ? 15 : 0)),
        state: soon ? GameState.pre : GameState.live,
        statusText: soon ? 'Soon' : 'Live',
        home: const SportsTeam(
            id: 'a', name: 'Alpha', shortName: 'Alpha', abbreviation: 'A'),
        away: const SportsTeam(
            id: 'b', name: 'Beta', shortName: 'Beta', abbreviation: 'B'));
    final tennis = event('tennis.atp');
    scores.batch = [tennis];
    scores.publish!(scores.batch);
    await flush();
    final card = find.byKey(const ValueKey('card-tennis.atp:tennis.atp'));
    expect(card, findsOneWidget);
    final dynamic widget = tester.widget(card);
    (widget.focusNode as FocusNode).requestFocus();
    await tester.pump();
    scores.batch = [tennis, event('nhl'), event('nba', soon: true)];
    scores.publish!(scores.batch);
    await flush();
    final basketball = find.byKey(const ValueKey('sport-heading:basketball'));
    final hockey = find.byKey(const ValueKey('sport-heading:hockey'));
    final tennisHeading = find.byKey(const ValueKey('sport-heading:tennis'));
    expect(tester.getTopLeft(basketball).dy,
        lessThan(tester.getTopLeft(hockey).dy));
    expect(tester.getTopLeft(hockey).dy,
        lessThan(tester.getTopLeft(tennisHeading).dy));
    expect((widget.focusNode as FocusNode).hasFocus, true);
    epg.requests.first.complete([]);
    scores.done.complete(scores.batch);
    await flush();
    expect(tester.getTopLeft(basketball).dy,
        lessThan(tester.getTopLeft(tennisHeading).dy));
    expect((widget.focusNode as FocusNode).hasFocus, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'possible events appear before matching, then unmatched cards leave safely on TV',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('possible');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage, CatalogDatabase());
    playlist.fixtureChannels
      ..clear()
      ..add(Channel(
          id: 'weather',
          rawId: 'weather',
          playlistId: 'demo',
          name: 'Weather',
          group: 'News',
          epgIdOverride: 'weather',
          url: 'https://example.invalid/never-play'));
    final playback = _Playback(storage, playlist);
    final epg = _WarmGuide(storage);
    final scores = _HeldScores();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.reads, greaterThan(0),
        reason: 'guide cache loads before the first score feed');
    expect(epg.requests, isEmpty, reason: 'no speculative programme queries');
    final reads = epg.reads;
    await scores.firstBatch();
    await flush();
    expect(scores.done.isCompleted, false);
    expect(epg.requests, hasLength(1),
        reason: 'event guide search overlaps remaining score feeds');
    expect(epg.reads, reads,
        reason: 'the event search reuses the prepared guide');
    final card = find.byKey(const ValueKey('card-nhl:poll-0'));
    expect(card, findsOneWidget,
        reason: 'Scores are usable before guide search finishes');
    expect(find.text('Waiting for guide'), findsWidgets);
    final dynamic cardWidget = tester.widget(card);
    (cardWidget.focusNode as FocusNode).requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'sports-card-nhl:poll-0');
    epg.requests.single.complete([]);
    await flush();
    expect(find.textContaining('Checked'), findsNothing,
        reason: 'the score feed is still visibly loading');
    expect(card, findsNothing,
        reason: 'A completed empty result removes the pending card');
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        startsWith('sports-chip-'));
    scores.done.complete(scores.batch);
    await flush();
    expect(epg.requests, hasLength(1),
        reason: 'finishing scores does not repeat matching');
    expect(find.textContaining('Checked'), findsOneWidget);
    expect(card, findsNothing,
        reason: 'Finishing scores must not resurrect unmatched cards');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  for (final television in [false, true]) {
    testWidgets(
        'Possible filter renders a current-guide match before SQL finishes; TV=$television',
        (tester) async {
      tester.view.physicalSize =
          television ? const Size(1280, 720) : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('possible');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = television;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final scores = _RowScores(counts: {'nhl': 1}, namedTeams: true);
      final epg = _SlowGuide(storage);
      final programme = EpgProgram(
          channelId: playlist.fixtureChannels.first.epgId,
          title: 'NHL: Boston Bruins vs Toronto Maple Leafs',
          start: scores.start.subtract(const Duration(minutes: 10)),
          stop: scores.start.add(const Duration(hours: 2)));
      epg.replays = [programme];
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores, clock: () => scores.start))));
      final card = find.byKey(const ValueKey('card-nhl:row-0'));
      ChannelMatch? match() => card.evaluate().isEmpty
          ? null
          : (tester.widget(card) as dynamic).match as ChannelMatch?;
      for (var i = 0; i < 250 && match() == null; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(epg.requests, hasLength(1));
      expect(epg.requests.single.isCompleted, isFalse);
      expect(match()?.channel, same(playlist.fixtureChannels.first));
      expect(match()?.isConfident, isFalse);
      expect(find.textContaining('Possible · ABC HD'), findsOneWidget);
      final focus = (tester.widget(card) as dynamic).focusNode as FocusNode;
      focus.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focus));
      for (final request in epg.requests) {
        request.complete([programme]);
      }
      for (var i = 0; i < 100 && match()?.isConfident != true; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(match()?.isConfident, isTrue);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  testWidgets(
      'new live fixtures keep early confidence provisional until rechecked',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('possible');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final scores = _HeldScores();
    final epg = _SlowGuide(storage);
    final fixtures = _RowScores(counts: {'nhl': 1}, namedTeams: true);
    final first =
        (await fixtures.gamesForDay([sportsLeagueById('nhl')!], fixtures.start))
            .single;
    final late = SportsGame(
        id: 'late',
        league: first.league,
        start: first.start,
        state: GameState.live,
        statusText: 'Live',
        home: const SportsTeam(
            id: 'phl',
            name: 'Philadelphia Flyers',
            shortName: 'Flyers',
            abbreviation: 'PHI'),
        away: const SportsTeam(
            id: 'pit',
            name: 'Pittsburgh Penguins',
            shortName: 'Penguins',
            abbreviation: 'PIT'));
    final programme = EpgProgram(
        channelId: playlist.fixtureChannels.first.epgId,
        title: 'NHL: Boston Bruins vs Toronto Maple Leafs',
        start: first.start.subtract(const Duration(minutes: 10)),
        stop: first.start.add(const Duration(hours: 2)));
    epg.replays = [programme];
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores, clock: () => first.start))));
    Future<void> flushUntil(bool Function() ready) async {
      for (var i = 0; i < 250 && !ready(); i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(ready(), isTrue);
    }

    await flushUntil(() => scores.publish != null);
    scores.batch = [first];
    scores.publish!(scores.batch);
    final card = find.byKey(const ValueKey('card-nhl:row-0'));
    ChannelMatch? match() => card.evaluate().isEmpty
        ? null
        : (tester.widget(card) as dynamic).match as ChannelMatch?;
    await flushUntil(() => epg.requests.isNotEmpty && match() != null);
    scores.batch = [first, late];
    scores.publish!(scores.batch);
    await tester.pump();
    epg.requests.first.complete([programme]);
    await flushUntil(() => epg.requests.length == 2);
    expect(epg.requests.last.isCompleted, isFalse);
    expect(match()?.channel, same(playlist.fixtureChannels.first));
    expect(match()?.isConfident, isFalse,
        reason: 'The previous cohort cannot confirm a newly contested feed');
    epg.requests.last.complete([programme]);
    scores.done.complete(scores.batch);
    await flushUntil(() => match()?.isConfident == true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets(
      'slow channel checks survive score polls and publish completed events',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    await storage.setSportsAddedLeagues(['nhl']);
    await storage.setSportsLeagues(['nhl']);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _SlowGuide(storage);
    final scores = _PollingScores();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores))));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await flush();
    expect(epg.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 31));
    await flush();
    expect(scores.calls, 2);
    expect(epg.requests, hasLength(1),
        reason: 'poll must share the running search');
    epg.requests.first.complete([]);
    await flush();
    expect(epg.requests, hasLength(2));
    final activity =
        tester.widget<SportsActivityStatus>(find.byType(SportsActivityStatus));
    expect(activity.checkedCount, 216,
        reason: 'completed checks survive while the new event is pending');
    expect(activity.eventCount, 217);
    expect(find.byKey(const ValueKey('sports-status-channels')).hitTestable(),
        findsOneWidget);
    epg.requests.last.complete([]);
    await flush();
    expect(find.textContaining('Checked'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await flush();
    expect(epg.requests, hasLength(2),
        reason: 'score-only updates reuse channel results');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });

  testWidgets('recycled sport rows restore only their own horizontal offset',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    final leagues = <String, SportsLeague>{};
    for (final league in [...kSportsLeagues, ...kSportsLeagueBank]) {
      leagues.putIfAbsent(league.espnPath.split('/').first, () => league);
    }
    final selected = leagues.values.map((l) => l.id).toList();
    await storage.setSportsAddedLeagues(selected);
    await storage.setSportsLeagues(selected);
    await storage.setSportsChannelFilter('all');
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _Epg(storage);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: _RowScores()))));
    await settleSports(tester);
    final rows = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal);
    expect(rows.evaluate().length, greaterThanOrEqualTo(2));
    final first = tester.widget<ListView>(rows.at(0)).controller!;
    final second = tester.widget<ListView>(rows.at(1)).controller!;
    final outer = tester
        .widget<CustomScrollView>(
            find.byKey(const PageStorageKey('sports-events')))
        .controller!;
    expect(first.offset, 0);
    second.jumpTo(400);
    await tester.pump();
    for (var trip = 0; trip < 3; trip++) {
      outer.jumpTo(outer.position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(first.hasClients, false,
          reason: 'The actual phone list must recycle its offscreen rows');
      expect(second.hasClients, false);
      // Rebuild the first rows while the page is still partly scrolled.
      outer.jumpTo(200);
      await tester.pump();
      expect(first.offset, 0, reason: 'Untouched row must remain at the start');
      expect(second.offset, 400,
          reason: 'Each row must restore its own position, not another row');
      outer.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(first.offset, 0, reason: 'No delayed horizontal correction');
      expect(second.offset, 400);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final tv in [false, true]) {
    testWidgets(
        'reopening Sports and multiview selection reuses completed matches ${tv ? "TV" : "phone"}',
        (tester) async {
      tester.view.physicalSize =
          tv ? const Size(1280, 720) : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('matched');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = tv;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      // Only the explicitly supplied guide rows are evidence for these feeds.
      final epg = _SlowGuide(storage)
        ..withoutGuide.addAll([for (var i = 0; i < 24; i++) 'feed-$i']);
      final scores = _ReopenScores();
      final now = DateTime.now();
      playlist.fixtureChannels
        ..clear()
        ..addAll([
          for (var i = 0; i < 24; i++)
            Channel(
                id: 'feed-$i',
                rawId: 'feed-$i',
                playlistId: 'demo',
                name: 'Event feed $i',
                group: 'Sports',
                url: 'https://example.invalid')
        ]);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              navigatorKey: nav,
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: const Scaffold())));
      void open({bool picker = false}) {
        unawaited(nav.currentState!.push(PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => SportsScreen(
                scores: scores,
                clock: () => now,
                onChooseChannel: picker ? (_) async {} : null,
                selectionTitle: picker ? 'Sports · screen 2' : null))));
      }

      Future<void> flush() async {
        for (var i = 0; i < 25; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      final card = find.byKey(const ValueKey('card-nhl:browse-0'));
      open();
      await flush();
      expect(epg.requests, hasLength(1));
      epg.requests.first.complete(scores.rows());
      await flush();
      expect(card, findsOneWidget);
      final loads = playlist.catalogueLoads;
      Future<void> choose(String pickerKey, String id) async {
        tester
            .widget<SportsFilterButton>(find.byKey(ValueKey(pickerKey)))
            .onTap();
        await tester.pumpAndSettle();
        final choices =
            tester.widget<CompactChoiceList>(find.byType(CompactChoiceList));
        choices.choices.firstWhere((choice) => choice.id == id).onTap();
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final selection = storage.getSportsEventsSelection();
          final applied = id == '__all_sports__'
              ? selection[0].isEmpty
              : selection[pickerKey == 'sport-picker' ? 0 : 1] == id;
          if (applied) {
            await tester.pump();
            break;
          }
        }
      }

      for (final sport in ['basketball', 'soccer', 'hockey', '']) {
        await choose('sport-picker', sport);
        if (sport == 'hockey' || sport.isEmpty) {
          expect(card, findsOneWidget,
              reason: 'Filter return keeps matched cards on its first frame');
          final dynamic restored = tester.widget(card);
          expect((restored.match as ChannelMatch).isConfident, true);
        } else {
          expect(card, findsNothing);
        }
        await flush();
        expect(epg.requests, hasLength(1),
            reason:
                'Changing sport does not query the same guide evidence again');
      }
      await choose('league-picker', 'nhl');
      expect(card, findsOneWidget);
      await choose('league-picker', '__all_sports__');
      expect(card, findsOneWidget);
      await flush();
      for (final filter in [
        SportsFavouritesFilter.favourites,
        SportsFavouritesFilter.leagues,
        SportsFavouritesFilter.teams,
        SportsFavouritesFilter.all
      ]) {
        tester
            .widget<SportsFavouritesFilterButton>(
                find.byKey(const ValueKey('events-favourites-only')))
            .onChanged(filter);
        await tester.pump();
        expect(
            card,
            filter == SportsFavouritesFilter.teams
                ? findsNothing
                : findsOneWidget,
            reason:
                'Favourite filtering preserves existing matches without a worker round trip');
        await flush();
        expect(epg.requests, hasLength(1));
      }
      expect(playlist.catalogueLoads, loads);
      for (final picker in [false, true]) {
        nav.currentState!.pop();
        await tester.pump();
        expect(find.byType(SportsScreen), findsNothing);
        scores.pending = Completer<List<SportsGame>>();
        open(picker: picker);
        await tester.pump();
        expect(card, findsOneWidget,
            reason:
                'Known matches visible on the first frame before scores return');
        final dynamic restored = tester.widget(card);
        expect((restored.match as ChannelMatch).isConfident, true);
        await flush();
        expect(epg.requests, hasLength(1),
            reason: 'No repeated guide query on a warm visit');
        expect(playlist.catalogueLoads, loads,
            reason: 'No repeated catalogue preparation');
        scores.pending!.complete(scores.cached);
        await flush();
        scores.pending = null;
      }
      nav.currentState!.pop();
      await tester.pump();
      epg.notifyListeners(); // Real guide updates invalidate a saved match snapshot.
      open(picker: true);
      await tester.pump();
      expect(card, findsNothing);
      await flush();
      expect(epg.requests, hasLength(2));
      epg.notifyListeners(); // Another guide revision while matching is in flight.
      epg.requests.last.complete(scores.rows());
      await flush();
      expect(card, findsNothing,
          reason: 'An obsolete guide reply cannot become a completed match');
      expect(epg.requests, hasLength(3));
      epg.requests.last.complete(scores.rows());
      await flush();
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
      SportsChannelMatcher.disposeShared();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final tv in [false, true]) {
    testWidgets(
        'background matching preserves browsing position on ${tv ? "TV" : "phone"}',
        (tester) async {
      tester.view.physicalSize =
          tv ? const Size(1280, 720) : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': false});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['nhl']);
      await storage.setSportsLeagues(['nhl']);
      await storage.setSportsChannelFilter('matched');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = tv;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      // Only the explicitly supplied guide rows are evidence for these feeds.
      final epg = _SlowGuide(storage)
        ..withoutGuide.addAll([for (var i = 0; i < 24; i++) 'feed-$i']);
      // Keep the simulated refresh within the fixture day, with guide
      // programmes that also cover the matcher's wall clock.
      final fixtureNow = DateTime.now();
      final scores = _BrowseScores(
          start: DateTime(fixtureNow.year, fixtureNow.month, fixtureNow.day,
              fixtureNow.hour));
      var now = scores.start;
      playlist.fixtureChannels
        ..clear()
        ..addAll([
          for (var i = 0; i < 24; i++)
            Channel(
                id: 'feed-$i',
                rawId: 'feed-$i',
                playlistId: 'demo',
                name: 'Event feed $i',
                group: 'Sports',
                url: 'https://example.invalid')
        ]);
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(scores: scores, clock: () => now))));
      Future<void> flush() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      await flush();
      expect(epg.requests, hasLength(1));
      expect(find.byKey(const ValueKey('card-nhl:browse-0')), findsNothing,
          reason: 'With channel does not admit unchecked events');
      epg.requests.first.complete(scores.rows());
      await flush();
      if (!tv) {
        await tester.tap(find.byKey(const ValueKey('sport-heading:hockey')));
        await tester.pump();
      }
      final viewport = find.byKey(const PageStorageKey('sports-events'));
      final scrollTop = tester.getTopLeft(viewport).dy;
      final statusSlot = find.byKey(const ValueKey('sports-status-slot'));
      final statusHeight = tester.getSize(statusSlot).height;
      expect(statusHeight, lessThanOrEqualTo(48));
      final target = tv
          ? find
              .byWidgetPredicate(
                  (w) => w is ListView && w.scrollDirection == Axis.horizontal)
              .last
          : viewport;
      await tester.drag(
          target, tv ? const Offset(-1800, 0) : const Offset(0, -900));
      await tester.pumpAndSettle();
      final controller = tv
          ? tester.widget<ListView>(target).controller!
          : tester.widget<CustomScrollView>(viewport).controller!;
      final offset = controller.offset;
      expect(offset, greaterThan(100));
      final cards = find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('card-nhl:'));
      final anchor = cards
          .evaluate()
          .firstWhere((element) {
            final box = element.renderObject as RenderBox;
            final p = box.localToGlobal(Offset.zero);
            return tv
                ? p.dx >= 20 && p.dx < 900
                : p.dy >= scrollTop && p.dy < 700;
          })
          .widget
          .key!;
      final anchorFinder = find.byKey(anchor);
      if (tv) {
        final dynamic card = tester.widget(anchorFinder);
        (card.focusNode as FocusNode).requestFocus();
        await tester.pump(const Duration(milliseconds: 400));
      }
      final anchorPosition = tester.getTopLeft(anchorFinder);
      final settledOffset = controller.offset;
      // Invalidate the guide and refresh. The completed match stays visible
      // while the query is pending, then real removals above us are anchored.
      final sportsState = tester.state(find.byType(SportsScreen));
      final navigator = Navigator.of(tester.element(find.byType(SportsScreen)));
      unawaited(navigator.push(PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, __, ___) =>
              const Scaffold(body: Text('Floating player')))));
      await tester.pump(const Duration(milliseconds: 400));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      epg.notifyListeners();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      navigator.pop();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.state(find.byType(SportsScreen)), same(sportsState));
      await flush();
      expect(epg.requests, hasLength(2));
      expect(sportsChannelStatus(tester), contains('Guide'));
      expect(tester.getSize(statusSlot).height, statusHeight);
      expect(
          find.descendant(
              of: statusSlot, matching: find.byType(LinearProgressIndicator)),
          findsNothing);
      expect(
          find.descendant(
              of: statusSlot, matching: find.byType(CircularProgressIndicator)),
          findsNothing);
      expect(tester.getTopLeft(anchorFinder), anchorPosition);
      final dynamic retainedCard = tester.widget(anchorFinder);
      expect((retainedCard.match as ChannelMatch).isConfident, true);
      expect(
          find.descendant(
              of: anchorFinder, matching: find.byType(SportsEventMatchStatus)),
          findsNothing,
          reason:
              'Usable channels keep their programme details during a recheck');
      expect(
          find.descendant(
              of: anchorFinder, matching: find.byType(ChannelNowLabel)),
          findsOneWidget);
      expect((retainedCard.game as SportsGame).home.score, '2');
      epg.requests.last.complete(scores.rows(from: 3));
      await flush();
      expect(controller.offset, lessThan(settledOffset));
      expect(tester.getTopLeft(viewport).dy, scrollTop);
      expect(tester.getTopLeft(anchorFinder), anchorPosition);
      expect(find.byKey(const ValueKey('card-nhl:browse-0')), findsNothing);
      expect(find.byKey(const ValueKey('sports-apply-updates')), findsNothing);
      for (final element in cards.evaluate()) {
        final dynamic card = element.widget;
        expect((card.match as ChannelMatch).isConfident, true);
      }
      if (tv) {
        final dynamic card = tester.widget(anchorFinder);
        // Refresh button was tapped, so explicitly restore remote browsing.
        (card.focusNode as FocusNode).requestFocus();
        await tester.pump();
      }
      // A database failure is not a successful empty match result.
      epg.notifyListeners();
      await tester.tap(find.byKey(const ValueKey('sports-refresh')));
      await flush();
      expect(epg.requests, hasLength(3));
      epg.requests.last.completeError(StateError('simulated guide failure'));
      await flush();
      final dynamic keptAfterFailure = tester.widget(anchorFinder);
      expect((keptAfterFailure.match as ChannelMatch).isConfident, true);
      expect(sportsChannelStatus(tester), contains('Check failed'));
      expect(tester.getTopLeft(anchorFinder), anchorPosition);
      // Retry the failed lookup without a guide revision. The failed future
      // must have left the query cache. Remove the focused card this time.
      await tester.tap(find.byKey(const ValueKey('sports-refresh')));
      await flush();
      expect(epg.requests, hasLength(4));
      final anchorId = (anchor as ValueKey<String>).value.split('browse-').last;
      if (tv) {
        final dynamic card = tester.widget(anchorFinder);
        (card.focusNode as FocusNode).requestFocus();
        await tester.pump();
      }
      epg.requests.last.complete(scores
          .rows(from: 3)
          .where((p) => p.channelId != 'feed-$anchorId')
          .toList());
      await flush();
      expect(anchorFinder, findsNothing);
      if (tv) {
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'sports-card-nhl:browse-${int.parse(anchorId) + 1}');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
  }

  testWidgets(
      'nonempty supplemental events settle without an enrichment/rematch loop',
      (tester) async {
    await http.runWithClient(() async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({'sports_online_extras': true});
      final storage = StorageService();
      await storage.init();
      await storage.setSportsAddedLeagues(['tennis.atp']);
      await storage.setSportsLeagues(['tennis.atp']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = false;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _Epg(storage);
      final supplement = _Supplement();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              navigatorObservers: [appRouteObserver],
              home: SportsScreen(
                  supplement: supplement,
                  scores: SportsService.withClient(
                      MockClient((_) async => _tennisFixture()))))));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(supplement.loads, greaterThan(0));
      expect(supplement.warms, lessThanOrEqualTo(2));
      final warmCount = supplement.warms;
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(supplement.warms, warmCount);
      expect(find.byKey(const ValueKey('tennis-tournament-extra-demo')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      await tester.pump(const Duration(seconds: 31));
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    }, () => MockClient((_) async => _tennisFixture()));
  });
  testWidgets(
      'mobile landscape uses compact columns and guide rows without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    setLayoutPreferences({'sports_online_extras': false});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = false;
    final playlist = _Playlist(storage, CatalogDatabase());
    final playback = _Playback(storage, playlist);
    final epg = _Epg(storage);
    final capture = GlobalKey();
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
          ChangeNotifierProvider<PlaybackService>.value(value: playback),
          ChangeNotifierProvider<EpgService>.value(value: epg),
        ],
        child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: RepaintBoundary(key: capture, child: const TvHomeScreen()))));
    await tester.pump(const Duration(milliseconds: 300));
    final labels = find.byKey(const ValueKey('guide-channel-scroll'));
    expect(tester.widget<ListView>(labels).itemExtent, 36);
    expect(
        tester.getSize(find.byKey(const ValueKey('guide-search'))).height, 24);
    expect(tester.getTopLeft(labels).dx, lessThan(365));
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
      await tester.runAsync(() async {
        final image = await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/iptv-guide-landscape.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    playlist.fixtureChannels.add(Channel(
        id: 'demo::other',
        rawId: 'other',
        playlistId: 'demo',
        name: 'Other category channel',
        group: 'Other category',
        url: 'https://example.test/other'));
    playlist.notifyListeners();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('all-live-channels')));
    await settleSports(tester);
    expect(tester.widget<ListView>(labels).childrenDelegate.estimatedChildCount,
        10);
    await tester.tap(find.byKey(const ValueKey('live-categories-rail')));
    await settleSports(tester);
    await tester.tap(find.text('Australian TV'));
    await settleSports(tester);
    expect(tester.widget<ListView>(labels).childrenDelegate.estimatedChildCount,
        9);
    expect(tester.getTopLeft(labels).dx, lessThan(110));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    SportsChannelMatcher.disposeShared();
    await tester.pump(const Duration(seconds: 5));
    playback.dispose();
    playlist.dispose();
    epg.dispose();
    prefs.dispose();
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 720)
  ]) {
    testWidgets('guide card polish and late fixture priority at ${size.width}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      setLayoutPreferences({
        'sports_online_extras': false,
        'sports_events_selection': <String>['', '', 'all'],
      });
      final storage = StorageService();
      await storage.init();
      await storage.setSportsLeagues(['tennis.atp']);
      await storage.setSportsChannelFilter('all');
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width > 1000;
      final playlist = _Playlist(storage, CatalogDatabase());
      final playback = _Playback(storage, playlist);
      final epg = _Epg(storage);
      final scores = _HeldScores();
      const title =
          'Live Tennis: WTA Finals Riyadh — Singles semi-finals and doubles championship coverage';
      epg.replays = [
        EpgProgram(
          channelId: 'Fox Sports',
          title: title,
          description: 'Live tennis coverage from the WTA Finals.',
          isLive: true,
          start: scores.start.subtract(const Duration(minutes: 20)),
          stop: scores.start.add(const Duration(hours: 2)),
        )
      ];
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider<PlaybackService>.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: epg),
          ],
          child: MaterialApp(
            theme: buildAppTheme(prefs.palette),
            navigatorObservers: [appRouteObserver],
            home: SportsScreen(scores: scores, clock: () => scores.start),
          )));
      final titleFinder = find.byWidgetPredicate((w) =>
          w is Text &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>)
              .value
              .startsWith('guide-coverage-title-'));
      for (var i = 0; i < 80 && titleFinder.evaluate().isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(titleFinder, findsOneWidget);
      final text = tester.widget<Text>(titleFinder);
      expect(text.data, title.replaceFirst('Live Tennis: ', ''));
      expect(text.semanticsLabel, title);
      expect(text.maxLines, 2);
      expect(find.ancestor(of: titleFinder, matching: find.byType(Tooltip)),
          findsOneWidget);
      final card = find
          .ancestor(
              of: titleFinder,
              matching: find.byWidgetPredicate((w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('card-')))
          .first;
      final key = tester.widget(card).key!;
      final ink =
          find.descendant(of: card, matching: find.byType(InkWell)).first;
      final focus = tester.widget<InkWell>(ink).focusNode!;
      focus.requestFocus();
      await tester.pumpAndSettle();
      final before = tester.getSize(card);
      await captureSports(tester, size, 'guide-title-polish');
      final fixtures = [
        for (var i = 0; i < 3; i++)
          SportsGame(
            id: 'fixture-$i',
            league: sportsLeagueById('tennis.atp')!,
            start: scores.start,
            state: GameState.live,
            statusText: 'Set 2',
            home: SportsTeam(
                id: 'p$i',
                name: 'Player $i',
                shortName: 'Player $i',
                abbreviation: 'P$i'),
            away: const SportsTeam(
                id: 'other',
                name: 'Opponent',
                shortName: 'Opponent',
                abbreviation: 'O'),
            event:
                const SportsEventInfo(title: 'Tennis Open', session: 'Singles'),
          )
      ];
      scores.done.complete(fixtures);
      await settleSports(tester);
      expect(focus.hasFocus, true);
      expect(tester.getSize(find.byKey(key)), before);
      final row = tester.widget<ListView>(find
          .ancestor(of: find.byKey(key), matching: find.byType(ListView))
          .first);
      final delegate = row.childrenDelegate as SliverChildBuilderDelegate;
      expect(
          delegate.findChildIndexCallback!(
              const ValueKey('card-tennis.atp:fixture-0')),
          0);
      expect(delegate.findChildIndexCallback!(key), 3);
      final rect = tester.getRect(find.byKey(key));
      expect(rect.overlaps(Offset.zero & size), true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settleSports(tester);
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'sports-card-tennis.atp:fixture-2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settleSports(tester);
      expect(focus.hasFocus, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      SportsChannelMatcher.disposeShared();
      await tester.pump(const Duration(seconds: 5));
      playback.dispose();
      playlist.dispose();
      epg.dispose();
      prefs.dispose();
    });
    testWidgets('guide sports survive scores and refresh at ${size.width}',
        (tester) async {
      await http.runWithClient(() async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        setLayoutPreferences({'sports_online_extras': true});
        final storage = StorageService();
        await storage.init();
        await storage.setSportsLeagues(['nhl']);
        const themeId = String.fromEnvironment('LAYOUT_THEME');
        if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width > 1000;
        final playlist = _Playlist(storage, CatalogDatabase());
        final playback = _Playback(storage, playlist);
        final epg = _Epg(storage);
        final now = DateTime.now();
        epg.replays = [
          EpgProgram(
              channelId: 'Fox Sports',
              title: 'World Poker Tour',
              description:
                  'The final table. The world’s finest poker players compete.',
              start: now.subtract(const Duration(minutes: 20)),
              stop: now.add(const Duration(hours: 1)))
        ];
        final pending = Completer<http.Response>();
        var requests = 0;
        var failing = true;
        final supplement = _Supplement();
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<PlaybackService>.value(value: playback),
              ChangeNotifierProvider<EpgService>.value(value: epg),
            ],
            child: MaterialApp(
                theme: buildAppTheme(prefs.palette),
                navigatorObservers: [appRouteObserver],
                home: SportsScreen(
                    supplement: supplement,
                    scores: SportsService.withClient(MockClient((_) {
                      requests++;
                      return failing
                          ? pending.future
                          : Future.value(http.Response('{"events":[]}', 200));
                    }))))));
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('World Poker Tour'), findsWidgets,
            reason: 'Guide coverage appears before scores finish');
        expect(find.text('On air'), findsOneWidget);
        pending.complete(http.Response('Access denied by event source', 403));
        await settleSports(tester);
        expect(find.text('World Poker Tour'), findsWidgets);
        expect(find.text('Pick a channel'), findsNothing);
        final callsBeforeDetails = requests;
        final portrait = size.width < 600 && size.height > size.width;
        if (!portrait) {
          expect(
              find.byKey(const ValueKey('sports-feed-info')), findsOneWidget);
        }
        if (prefs.isTelevision) {
          tester
              .widget<TextButton>(find.byKey(const ValueKey('sports-refresh')))
              .focusNode!
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          expect(
              tester
                  .widget<IconButton>(
                      find.byKey(const ValueKey('sports-feed-info')))
                  .focusNode!
                  .hasFocus,
              isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else if (portrait) {
          await tester.tap(find.byKey(const ValueKey('sports-status-details')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Event feed error details'));
          await tester.tap(find.text('Event feed error details'));
        } else {
          await tester.tap(find.byKey(const ValueKey('sports-feed-info')));
        }
        await tester.pumpAndSettle();
        expect(find.text('Event feed details'), findsOneWidget);
        await tester.tap(find.byType(ExpansionTile).first);
        await tester.pumpAndSettle();
        expect(find.text('Access denied by event source'), findsOneWidget);
        expect(requests, callsBeforeDetails,
            reason: 'Diagnostics must not fetch again');
        await tester.tap(find.byTooltip('Close feed details'));
        await tester.pumpAndSettle();
        if (portrait) {
          await tester.tap(find.byTooltip('Close'));
          await tester.pumpAndSettle();
        }
        failing = false;
        await tester.tap(find.byKey(const ValueKey('sports-refresh')));
        await settleSports(tester);
        expect(find.text('World Poker Tour'), findsWidgets);
        expect(find.text('On air'), findsOneWidget);
        expect(requests, greaterThan(callsBeforeDetails));
        expect(find.byKey(const ValueKey('sports-feed-info')), findsNothing);
        await captureSports(tester, size, 'guide-sports');
        epg.replays = [
          for (final entry in [
            (
              'Fox Sports',
              'NBA: Boston Celtics v New York Knicks (Replay)',
              'Full game replay from 21 October 2026.'
            ),
            (
              'Seven',
              'World Poker Tour Highlights',
              'Highlights from the final table.'
            ),
            (
              'Nine',
              'Tennis: Alcaraz v Sinner (Replay)',
              'Full match replay from 20 October 2026.'
            ),
          ])
            EpgProgram(
                channelId: entry.$1,
                title: entry.$2,
                description: entry.$3,
                start: now.subtract(const Duration(minutes: 20)),
                stop: now.add(const Duration(hours: 1)))
        ];
        epg.notifyListeners();
        final videoBefore =
            tester.getRect(find.byKey(const ValueKey('sports-channel-box')));
        for (final tab in ['replays', 'highlights']) {
          await tester.ensureVisible(find.byKey(ValueKey('sports-view-$tab')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('sports-view-$tab')));
          await settleSports(tester);
          final video =
              tester.getRect(find.byKey(const ValueKey('sports-channel-box')));
          final browsing =
              tester.getRect(find.byKey(const ValueKey('replays-scroll')));
          expect(video, videoBefore);
          if (size.width > size.height) {
            expect(browsing.left, greaterThan(video.right));
            expect(browsing.top, closeTo(video.top, .1));
            expect(browsing.height, greaterThan(size.height * .75));
            final footer = tester
                .getRect(find.byKey(const ValueKey('sports-preview-footer')));
            expect(footer.bottom, closeTo(size.height, .1));
            expect(video.width, greaterThan((size.width - 40) * .36));
          } else {
            expect(browsing.top, greaterThan(video.bottom));
          }
          await captureSports(tester, size, 'sports-$tab');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        SportsChannelMatcher.disposeShared();
        await tester.pump(const Duration(seconds: 31));
        playback.dispose();
        playlist.dispose();
        epg.dispose();
        prefs.dispose();
      }, () => MockClient((_) async => http.Response('{"events":[]}', 200)));
    });
  }
  var scoreRequests = 0;
  for (final size in [
    const Size(960, 540),
    const Size(1280, 720),
    const Size(390, 844)
  ]) {
    testWidgets(
        'guide and navigation fit ${size.width} x ${size.height}',
        (tester) => http.runWithClient(() async {
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              setLayoutPreferences({'sports_online_extras': false});
              final storage = StorageService();
              await storage.init();
              await storage.setSportsLeagues(['nba', 'nhl', 'nfl']);
              await storage.setSportsChannelFilter('matched');
              // These layout fixtures deliberately reuse one demo channel for
              // several simultaneous games. Explicit picks establish that UI
              // setup; automatic matching must now flag shared feeds uncertain.
              await storage.setSportsChannelPicks(jsonEncode({
                'events': {
                  for (final league in ['nba', 'nhl', 'nfl'])
                    for (var i = 1; i < 5; i++)
                      '$league:$i': {
                        'c': 'demo::Fox Sports',
                        't': DateTime.now().millisecondsSinceEpoch
                      }
                },
                'teams': <String, String>{}
              }));
              const themeId = String.fromEnvironment('LAYOUT_THEME');
              if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
              final prefs = AppPreferences(storage);
              await prefs.init();
              prefs.isTelevision = size.width > 600;
              final playlist = _Playlist(storage, CatalogDatabase());
              final playback = _Playback(storage, playlist);
              final epg = _Epg(storage);
              final capture = GlobalKey();
              await tester.pumpWidget(MultiProvider(
                providers: [
                  Provider.value(value: storage),
                  ChangeNotifierProvider.value(value: prefs),
                  ChangeNotifierProvider<PlaylistManager>.value(
                      value: playlist),
                  ChangeNotifierProvider<PlaybackService>.value(
                      value: playback),
                  ChangeNotifierProvider<EpgService>.value(value: epg),
                ],
                child: RepaintBoundary(
                    child: MaterialApp(
                        debugShowCheckedModeBanner: false,
                        theme: buildAppTheme(prefs.palette),
                        navigatorObservers: [appRouteObserver],
                        home: RepaintBoundary(
                            key: capture, child: const TvHomeScreen()))),
              ));
              await tester.pump(const Duration(milliseconds: 300));
              expect(find.text('Movies'), findsOneWidget);
              expect(find.text('Series'), findsOneWidget);
              expect(find.text('Media Hub'), findsNothing);
              expect(find.text('Sports'), findsOneWidget);
              expect(find.text('ABC HD'), findsWidgets);
              expect(tester.takeException(), isNull);
              if (size.width > 600) {
                // Live TV -> groups -> programmes; programme navigation stays in grid.
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 300));
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 300));
                final first = FocusManager.instance.primaryFocus;
                expect(
                    first?.ancestors
                        .any((node) => node.debugLabel == 'timeline-grid'),
                    isTrue);
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
                await tester.pump(const Duration(milliseconds: 300));
                expect(FocusManager.instance.primaryFocus, isNot(first));
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 300));
                expect(
                    FocusManager.instance.primaryFocus?.ancestors
                        .any((node) => node.debugLabel == 'timeline-grid'),
                    isTrue);
              }
              if (size.width > 600) {
                // Tap the Now shortcut, then use the remote to move across
                // the toolbar and down into the guide again.
                await tester.tap(find.byKey(const ValueKey('guide-now')));
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump();
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'guide-now');
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
                await tester.pump();
                expect(
                    FocusManager.instance.primaryFocus?.ancestors
                        .any((n) => n.debugLabel == 'timeline-grid'),
                    isTrue);
              }
              expect(tester.takeException(), isNull);
              await tester.pump(const Duration(milliseconds: 200));
              if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
                await tester.runAsync(() async {
                  final boundary = capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
                  final image = await boundary.toImage();
                  final bytes =
                      await image.toByteData(format: ui.ImageByteFormat.png);
                  await File('/tmp/iptv-guide-${size.width.toInt()}.png')
                      .writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                });
              }
              if (size.width < 600) {
                // Touch scrolling must work on either column, including flings.
                final originalCount = playlist.fixtureChannels.length;
                playlist.fixtureChannels.addAll(List.generate(
                    100,
                    (i) => Channel(
                        id: 'demo::extra$i',
                        rawId: 'extra$i',
                        playlistId: 'demo',
                        name: [0, 30, 70, 98].contains(i)
                            ? '### Section $i ###'
                            : 'Extra $i',
                        group: 'Australian TV',
                        url: 'https://example.test/$i')));
                playlist.notifyListeners();
                await tester.pump(const Duration(milliseconds: 100));
                final labels =
                    find.byKey(const ValueKey('guide-channel-scroll'));
                final programmes =
                    find.byKey(const ValueKey('guide-programme-scroll'));
                ScrollController scroll(Finder finder) =>
                    tester.widget<ListView>(finder).controller!;
                await tester.fling(labels, const Offset(0, -220), 1200);
                await tester.pump(const Duration(milliseconds: 250));
                expect(scroll(labels).offset, greaterThan(150));
                expect(scroll(programmes).offset,
                    closeTo(scroll(labels).offset, .1));
                await tester.pump(const Duration(seconds: 2));
                final beforeGridDrag = scroll(programmes).offset;
                await tester.dragFrom(Offset(300, tester.getCenter(labels).dy),
                    const Offset(0, -150));
                await tester.pump(const Duration(milliseconds: 100));
                expect(scroll(programmes).offset,
                    closeTo(scroll(labels).offset, .1));
                expect(scroll(programmes).offset, greaterThan(beforeGridDrag));
                await playback.play(playlist.fixtureChannels[50]);
                await tester.pump();
                await tester
                    .tap(find.byKey(const ValueKey('guide-playing-channel')));
                await tester.pump();
                await tester.pump();
                expect(scroll(labels).offset, greaterThan(1500));
                expect(
                    find.text(playlist.fixtureChannels[50].name).hitTestable(),
                    findsWidgets);
                final time = find.byKey(const ValueKey('guide-time-scroll'));
                final horizontal =
                    tester.widget<SingleChildScrollView>(time).controller!;
                final now = horizontal.offset;
                horizontal.jumpTo(now + 300);
                await tester.pump();
                await tester.tap(find.byKey(const ValueKey('guide-now')));
                await tester.pump();
                expect(horizontal.offset, closeTo(now, .1));
                // Reopening search must focus the field, not retain focus on its button.
                for (var i = 0; i < 2; i++) {
                  await tester.tap(find.byKey(const ValueKey('guide-search')));
                  await tester.pump();
                  await tester.pump();
                  final field =
                      tester.widget<TextField>(find.byType(TextField));
                  expect(field.focusNode!.hasFocus, true);
                  expect(tester.testTextInput.isVisible, true);
                  await tester.enterText(find.byType(TextField), 'Extra 4');
                  await tester.pump();
                  expect(field.focusNode!.hasFocus, true);
                  await tester.tap(find.byTooltip('Close filter'));
                  await tester.pump();
                }
                // Search current EPG titles/descriptions as well as channel names.
                await tester.tap(find.byKey(const ValueKey('guide-search')));
                await tester.pump();
                await tester.pump();
                await tester.enterText(find.byType(TextField), 'World Today');
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 200));
                await tester.pump();
                expect(
                    tester
                        .widget<ListView>(labels)
                        .childrenDelegate
                        .estimatedChildCount,
                    playlist.fixtureChannels.length - 4);
                await tester.enterText(find.byType(TextField), 'not-a-show');
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 200));
                await tester.pump();
                expect(find.text('No channels found.'), findsOneWidget);
                expect(
                    find.byKey(const ValueKey('guide-search')), findsOneWidget);
                await tester.tap(find.byTooltip('Close filter'));
                await tester.pump();
                // Tap cycles headers; holding offers direct selection. No stream is opened.
                scroll(labels).jumpTo(0);
                await tester.pump();
                final playsBefore = playback.played.length;
                final sectionButton =
                    find.byKey(const ValueKey('guide-next-section'));
                for (final index in [
                  originalCount,
                  originalCount + 30,
                  originalCount + 70,
                  originalCount + 98,
                  originalCount
                ]) {
                  await tester.tap(sectionButton);
                  await tester.pump();
                  await tester.pump();
                  expect(
                      scroll(labels).offset,
                      closeTo(
                          (index * tester.widget<ListView>(labels).itemExtent!)
                              .clamp(
                                  0.0, scroll(labels).position.maxScrollExtent),
                          .1));
                }
                await tester.longPress(sectionButton);
                await tester.pump(const Duration(milliseconds: 300));
                expect(find.byKey(const ValueKey('guide-section-picker')),
                    findsOneWidget);
                expect(
                    tester
                        .widget<ListView>(find.descendant(
                            of: find
                                .byKey(const ValueKey('guide-section-picker')),
                            matching: find.byType(ListView)))
                        .itemExtent,
                    40);
                await captureSports(tester, size, 'guide-sections');
                await tester.tap(find
                    .byKey(ValueKey('guide-section-${originalCount + 70}')));
                await settleSports(tester);
                expect(
                    scroll(labels).offset,
                    closeTo(
                        (originalCount + 70) *
                            tester.widget<ListView>(labels).itemExtent!,
                        .1));
                expect(playback.played.length, playsBefore);
                // The same button supports a real remote hold (repeat + release),
                // without the held key selecting a popup item accidentally.
                await tester.tap(find.byKey(const ValueKey('guide-now')));
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump();
                await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
                await tester.pump(const Duration(milliseconds: 600));
                await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
                await settleSports(tester);
                await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
                await tester.pump();
                expect(find.byKey(const ValueKey('guide-section-picker')),
                    findsOneWidget);
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
                await settleSports(tester);
                expect(find.byKey(const ValueKey('guide-section-picker')),
                    findsNothing);
                expect(
                    scroll(labels).offset,
                    closeTo(
                        (originalCount + 30) *
                            tester.widget<ListView>(labels).itemExtent!,
                        .1));
                // History is a normal guide category, newest first, with EPG rows.
                playback.history.addAll(
                    [playlist.fixtureChannels[4], playlist.fixtureChannels[2]]);
                playback.notifyListeners();
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
                await tester.pump();
                await tester.tap(find.text('History'));
                await tester.pump();
                expect(find.byType(SimpleDialog), findsNothing);
                expect(find.text('History'), findsOneWidget);
                expect(
                    tester
                        .widget<ListView>(labels)
                        .childrenDelegate
                        .estimatedChildCount,
                    2);
                await tester.pump();
                expect(
                    find.text('The World Today').hitTestable(), findsWidgets);
                final rulerScroll = tester
                    .widget<SingleChildScrollView>(
                        find.byKey(const ValueKey('guide-ruler-scroll')))
                    .controller!;
                expect(horizontal.offset, closeTo(rulerScroll.offset, .1));
                if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
                  await tester.runAsync(() async {
                    final image = await (capture.currentContext!
                            .findRenderObject() as RenderRepaintBoundary)
                        .toImage();
                    final bytes =
                        await image.toByteData(format: ui.ImageByteFormat.png);
                    await File('/tmp/iptv-history-390.png')
                        .writeAsBytes(bytes!.buffer.asUint8List());
                    image.dispose();
                  });
                }
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
                await tester.pump();
                await tester.tap(find.text('Australian TV'));
                await tester.pump();
                playlist.fixtureChannels.removeRange(
                    originalCount, playlist.fixtureChannels.length);
                playlist.notifyListeners();
                await playback.stop();
                await tester.pump();
              }
              // The same active channel survives switching into Sports without a play/stop.
              final originalChannel = playlist.fixtureChannels.first;
              await playback.play(originalChannel);
              final playCount = playback.played.length;
              await tester.pump();
              epg.pending = Completer<List<EpgProgram>>();
              // TV hides passed columns; return through them before using tabs.
              for (var i = 0;
                  i < 2 &&
                      find
                          .byIcon(Icons.sports)
                          .hitTestable()
                          .evaluate()
                          .isEmpty;
                  i++) {
                await tester.binding.handlePopRoute();
                await tester.pumpAndSettle();
              }
              await tester.tap(find.byIcon(Icons.sports));
              await tester.pump(const Duration(milliseconds: 300));
              // Scoreboard parsing runs in an isolate, outside the fake test clock.
              await tester.runAsync(() async {
                await Future<void>.delayed(const Duration(milliseconds: 400));
              });
              await tester.pump(const Duration(milliseconds: 400));
              await tester.pump(const Duration(milliseconds: 200));
              for (var attempt = 0;
                  attempt < 20 && find.text('Celtics').evaluate().isEmpty;
                  attempt++) {
                await tester.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 50)));
                await tester.pump(const Duration(milliseconds: 100));
              }
              // Loading state never bypasses the confidence filter.
              expect(find.byKey(const ValueKey('sports-load-status')),
                  findsOneWidget);
              expect(find.byKey(const ValueKey('card-nba:0')), findsNothing);
              await captureSports(tester, size, 'sports-loading');
              epg.pending!.complete([]);
              epg.pending = null;
              // A quiet frame does not mean the matching isolate has replied.
              for (var attempt = 0;
                  attempt < 100 &&
                      find
                          .byKey(const ValueKey('card-nba:1'))
                          .evaluate()
                          .isEmpty;
                  attempt++) {
                await tester.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 10)));
                await tester.pump(const Duration(milliseconds: 16));
              }
              await settleSports(tester);
              await tester.pump(const Duration(milliseconds: 100));
              await tester.pump(const Duration(milliseconds: 100));
              if (find
                  .byKey(const ValueKey('event-filters'))
                  .evaluate()
                  .isEmpty) {
                expect(find.text('Matched'), findsOneWidget);
              } else {
                expect(
                    tester
                        .widget<IconButton>(
                            find.byKey(const ValueKey('event-filters')))
                        .tooltip,
                    contains(SportsChannelFilter.matched.label));
              }
              expect(find.text('NFL RedZone'), findsNothing);
              expect(playback.currentChannel, same(originalChannel));
              expect(playback.played.length, playCount);
              Future<void> finishRefresh(int expectedRequests) async {
                for (var attempt = 0; attempt < 30; attempt++) {
                  await tester.runAsync(() =>
                      Future<void>.delayed(const Duration(milliseconds: 50)));
                  await tester.pump(const Duration(milliseconds: 100));
                  if (scoreRequests >= expectedRequests &&
                      sportsRefreshAction(tester) != null) {
                    break;
                  }
                }
                expect(sportsRefreshAction(tester), isNotNull);
              }

              final beforeRefresh = scoreRequests;
              await tester.tap(find.byKey(const ValueKey('sports-refresh')));
              await tester.pump();
              expect(find.byKey(const ValueKey('card-nba:1')), findsOneWidget);
              await finishRefresh(beforeRefresh + 9);
              expect(scoreRequests, beforeRefresh + 9);
              if (size.width < 600) {
                await settleSports(tester);
                final beforePull = scoreRequests;
                final groups =
                    find.byKey(const PageStorageKey('sports-events'));
                tester.widget<ScrollView>(groups).controller!.jumpTo(0);
                await tester.pumpAndSettle();
                final pull = await tester.startGesture(
                    tester.getTopLeft(groups) + const Offset(100, 24));
                for (var step = 0; step < 6; step++) {
                  await pull.moveBy(const Offset(0, 50));
                  await tester.pump(const Duration(milliseconds: 50));
                }
                await captureSports(tester, size, 'sports-refresh');
                await pull.up();
                // Start the snap animation before advancing its fake clock.
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
                await finishRefresh(beforePull + 9);
                expect(scoreRequests, beforePull + 9);
              }
              expect(playback.currentChannel, same(originalChannel));
              expect(playback.played.length, playCount);
              expect(find.byType(VideoPlayerPane), findsOneWidget);
              final compactFilters =
                  find.byKey(const ValueKey('event-filters'));
              SportsTimeFilter currentTime() {
                if (compactFilters.evaluate().isEmpty) {
                  return tester
                      .widget<SportsTimeControl>(
                          find.byKey(const ValueKey('live-only')))
                      .value;
                }
                final tip = tester.widget<IconButton>(compactFilters).tooltip!;
                return SportsTimeFilter.values.singleWhere(
                    (mode) => tip.startsWith('Filters: ${mode.label} ·'));
              }

              SportsChannelFilter currentChannels() {
                if (compactFilters.evaluate().isNotEmpty) {
                  final tip =
                      tester.widget<IconButton>(compactFilters).tooltip!;
                  return SportsChannelFilter.values
                      .singleWhere((mode) => tip.endsWith('· ${mode.label}'));
                }
                return switch (tester
                    .widget<SportsFilterButton>(
                        find.byKey(const ValueKey('with-channel')))
                    .value) {
                  'Matched' => SportsChannelFilter.matched,
                  'Possible' => SportsChannelFilter.possible,
                  _ => SportsChannelFilter.all,
                };
              }

              Future<void> openFilter(String key) async {
                await tester.tap(compactFilters.evaluate().isNotEmpty
                    ? compactFilters
                    : find.byKey(ValueKey(key)));
                await tester.pumpAndSettle();
              }

              Future<void> finishFilter() async {
                if (find.text('Done').evaluate().isNotEmpty) {
                  await tester.tap(find.text('Done'));
                }
                await tester.pumpAndSettle();
              }

              expect(currentTime(), isNot(SportsTimeFilter.all));
              expect(currentChannels(), SportsChannelFilter.matched);
              expect(find.byKey(const ValueKey('card-nba:0')), findsNothing);
              // The wider lazy row mounts the upcoming card; on phones it is
              // beyond the viewport/cache extent until scrolled into view.
              if (size.width >= 600) {
                expect(
                    find.byKey(const ValueKey('card-nba:3')), findsOneWidget);
              }
              Future<void> chooseTime(String mode) async {
                await openFilter('live-only');
                await tester.tap(find.byKey(ValueKey('time-filter-$mode')));
                await finishFilter();
              }

              Future<void> toggleLive() => chooseTime(
                  currentTime() == SportsTimeFilter.live ? 'all' : 'live');
              final requestsBeforeTime = scoreRequests;
              await chooseTime('liveAndSoon');
              expect(currentTime(), SportsTimeFilter.liveAndSoon);
              expect(currentChannels(), SportsChannelFilter.matched);
              await captureSports(tester, size, 'sports-showing');
              await chooseTime('live');
              await settleSports(tester);
              expect(scoreRequests, requestsBeforeTime,
                  reason: 'Time filters must not fetch data');
              Future<void> chooseChannelFilter(String mode) async {
                await openFilter('with-channel');
                await tester.tap(find.byKey(ValueKey('channel-filter-$mode')));
                await finishFilter();
              }

              await chooseChannelFilter('possible');
              expect(storage.getSportsChannelFilter(), 'possible');
              expect(currentChannels(), SportsChannelFilter.possible);
              await openFilter('with-channel');
              await captureSports(tester, size, 'channel-filter');
              await tester
                  .tap(find.byKey(const ValueKey('channel-filter-matched')));
              await tester.pump(const Duration(milliseconds: 200));
              await finishFilter();
              // Capture lets the opening animation finish, so closing can
              // take longer than the partial animation in non-capture runs.
              await settleSports(tester);
              // Exercise the remaining filters starting from the unfiltered view.
              await playback.stop();
              await toggleLive();
              await chooseChannelFilter('all');
              await settleSports(tester);
              expect(find.byKey(const ValueKey('sports-channel-box')),
                  findsOneWidget);
              expect(playback.currentChannel, isNull);
              // An unmatched live fixture is visible until explicitly filtered.
              expect(find.byKey(const ValueKey('card-nba:0')), findsOneWidget);
              await chooseChannelFilter('matched');
              await tester.pump(const Duration(milliseconds: 200));
              expect(storage.getSportsWithChannel(), isTrue);
              expect(find.byKey(const ValueKey('card-nba:0')), findsNothing);
              expect(find.byKey(const ValueKey('card-nba:1')), findsOneWidget);
              await chooseChannelFilter('all');
              await tester.pump(const Duration(milliseconds: 200));
              expect(storage.getSportsWithChannel(), isFalse);
              expect(find.byKey(const ValueKey('card-nba:0')), findsOneWidget);
              expect(find.byKey(const ValueKey('sport-heading:basketball')),
                  findsOneWidget);
              expect(find.byKey(const ValueKey('sport-heading:hockey')),
                  findsOneWidget);
              if (size.width < 600) {
                expect(
                    tester
                        .getSize(
                            find.byKey(const ValueKey('sports-channel-box')))
                        .width,
                    greaterThan(340));
              }
              final overviewCard = find.descendant(
                  of: find.byKey(const ValueKey('card-nba:1')),
                  matching: find.byType(InkWell));
              tester.widget<InkWell>(overviewCard).focusNode!.requestFocus();
              await settleSports(tester);
              if (size.width > 600) {
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
                await settleSports(tester);
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nfl:1');
                await tester.ensureVisible(
                    find.byKey(const ValueKey('sport-heading:basketball')));
                await tester.tap(
                    find.byKey(const ValueKey('sport-heading:basketball')));
                await settleSports(tester);
                expect(find.byKey(const ValueKey('sport-heading:hockey')),
                    findsNothing);
                await tester.binding.handlePopRoute();
                await settleSports(tester);
                expect(find.byKey(const ValueKey('sport-heading:hockey')),
                    findsOneWidget);
                tester.widget<InkWell>(overviewCard).focusNode!.requestFocus();
                await settleSports(tester);
              }
              // Capture the default live/matched overview, then continue filter checks.
              await toggleLive();
              await chooseChannelFilter('matched');
              await settleSports(tester);
              final scrollable = find
                  .descendant(
                      of: find.byKey(const PageStorageKey('sports-events')),
                      matching: find.byType(Scrollable))
                  .first;
              tester.state<ScrollableState>(scrollable).position.jumpTo(0);
              await settleSports(tester);
              await captureSports(tester, size, 'sports');
              await tester
                  .ensureVisible(find.byKey(const ValueKey('league-picker')));
              await tester.tap(find.byKey(const ValueKey('league-picker')));
              await settleSports(tester);
              expect(
                  find.descendant(
                      of: find.byType(Dialog),
                      matching: find.text('American football')),
                  findsWidgets);
              await tester.tap(find.byType(TextField));
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.enterText(find.byType(TextField), 'NBA');
              await tester.pump();
              expect(find.text('Pro basketball'), findsOneWidget);
              await tester.enterText(find.byType(TextField), '');
              await tester.pump();
              await tester
                  .tap(find.byKey(const ValueKey('sports-picker-sort')));
              await settleSports(tester);
              expect(find.byKey(const ValueKey('sports-sort-top')),
                  findsOneWidget);
              await tester.tap(find.byKey(const ValueKey('sports-sort-live')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('sports-picker-sort')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('sports-sort-upcoming')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('sports-picker-sort')));
              await settleSports(tester);
              await tester.tap(find.byKey(const ValueKey('sports-sort-top')));
              await settleSports(tester);
              await captureSports(tester, size, 'sports-leagues');
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await settleSports(tester);
              await toggleLive();
              await chooseChannelFilter('all');
              await settleSports(tester);
              await toggleLive();
              await settleSports(tester);
              expect(find.byKey(const ValueKey('card-nba:3')), findsNothing);
              await toggleLive();
              await settleSports(tester);
              await tester.ensureVisible(
                  find.byKey(const ValueKey('sport-heading:basketball')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('sport-heading:basketball')));
              await settleSports(tester);
              expect(find.byKey(const ValueKey('sport-heading:hockey')),
                  findsNothing);
              expect(
                  find.byKey(const ValueKey('sport-picker')), findsOneWidget);
              // Sport/league pickers work without a scrolling toolbar.
              await tester
                  .ensureVisible(find.byKey(const ValueKey('sport-picker')));
              await tester.tap(find.byKey(const ValueKey('sport-picker')));
              await settleSports(tester);
              expect(find.text('Choose sport'), findsOneWidget);
              // The selected sport is revealed on open; All may be above the
              // viewport once configuration actions are included.
              await tester.scrollUntilVisible(
                  find.byKey(const ValueKey('')), -100,
                  scrollable: find
                      .descendant(
                          of: find.byType(Dialog),
                          matching: find.byType(Scrollable))
                      .last);
              await settleSports(tester);
              expect(
                  find.byWidgetPredicate((w) =>
                      w is SportsCounts && w.live == 9 && w.upcoming == 6),
                  findsOneWidget);
              await captureSports(tester, size, 'sports-picker');
              await tester.tap(find.byType(TextField));
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.enterText(find.byType(TextField), 'basket');
              await tester.pump();
              await tester.tap(find.text('Basketball').last);
              await settleSports(tester);
              expect(find.text('Basketball'), findsOneWidget);
              await tester
                  .ensureVisible(find.byKey(const ValueKey('league-picker')));
              await tester.tap(find.byKey(const ValueKey('league-picker')));
              await settleSports(tester);
              expect(find.text('Choose league'), findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await settleSports(tester);
              // Secondary controls remain available in the options menu.
              await tester.tap(find.byIcon(Icons.more_horiz));
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.text('Manage favourite leagues'), findsOneWidget);
              expect(find.text('My Teams'), findsNothing);
              expect(find.text('Standings').hitTestable(), findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pump(const Duration(milliseconds: 200));
              // Focusing a matched game fills the idle preview without playing.
              await chooseChannelFilter('matched');
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.text('Later today'), findsOneWidget);
              await toggleLive();
              await settleSports(tester);
              expect(find.text('Later today'), findsNothing);
              await tester
                  .ensureVisible(find.byKey(const ValueKey('sport-picker')));
              await tester.tap(find.byKey(const ValueKey('sport-picker')));
              await settleSports(tester);
              // Counts retain upcoming games even when Live-only is on.
              await tester.scrollUntilVisible(
                  find.byKey(const ValueKey('')), -100,
                  scrollable: find
                      .descendant(
                          of: find.byType(Dialog),
                          matching: find.byType(Scrollable))
                      .last);
              await settleSports(tester);
              expect(
                  find.byWidgetPredicate((w) =>
                      w is SportsCounts && w.live == 6 && w.upcoming == 6),
                  findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await settleSports(tester);
              await toggleLive();
              await settleSports(tester);
              final gameInk = find.descendant(
                  of: find.byKey(const ValueKey('card-nba:1')),
                  matching: find.byType(InkWell));
              tester.widget<InkWell>(gameInk).focusNode!.requestFocus();
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.text('Choose a game'), findsNothing);
              expect(playback.currentChannel, isNull);
              expect(
                  find.descendant(
                      of: find.byKey(const ValueKey('sports-channel-box')),
                      matching: find.text('Fox Sports')),
                  findsOneWidget);
              expect(find.text('Celtics'), findsWidgets);
              expect(tester.takeException(), isNull);
              if (size.width > 600) {
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nba:1');
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
                await tester.pump(const Duration(milliseconds: 200));
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nba:2');
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
                await tester.pump(const Duration(milliseconds: 200));
              }
              await tester.pump(const Duration(milliseconds: 200));
              if (const bool.fromEnvironment('CAPTURE_LAYOUT')) {
                await tester.runAsync(() async {
                  final boundary =
                      tester.firstRenderObject<RenderRepaintBoundary>(
                          find.byType(RepaintBoundary));
                  final image = await boundary.toImage();
                  final bytes =
                      await image.toByteData(format: ui.ImageByteFormat.png);
                  await File(
                          '/tmp/iptv-sports-detail-${size.width.toInt()}.png')
                      .writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                });
              }
              // Long-press presents channels once, with a clear preview action.
              await tester
                  .ensureVisible(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);
              await tester.longPress(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);
              expect(find.text('Watch on…'), findsOneWidget);
              expect(find.text('Find another channel'), findsOneWidget);
              expect(find.text('Play here'), findsNothing);
              expect(find.byKey(const ValueKey('sports-channel-dialog')),
                  findsOneWidget);
              expect(find.byType(BottomSheet), findsNothing);
              expect(find.textContaining('The World Today'), findsWidgets);
              await captureSports(tester, size, 'sports-channels');
              await tester.binding.handlePopRoute();
              await settleSports(tester);
              if (prefs.isTelevision) {
                expect(FocusManager.instance.primaryFocus?.debugLabel,
                    'sports-card-nba:1');
              }
              await tester.longPress(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);

              await tester.tap(
                  find.byKey(const ValueKey('game-channel:demo::Fox Sports')));
              await settleSports(tester);
              expect(find.text('Watch on…'), findsNothing);
              expect(playback.currentChannel?.name, 'Fox Sports');
              await playback.stop();
              await settleSports(tester);
              playback.played.clear();
              // A single tap on an unfocused card starts its matched channel.
              FocusManager.instance.primaryFocus?.unfocus();
              await tester.pump();
              await tester
                  .ensureVisible(find.byKey(const ValueKey('card-nba:1')));
              await settleSports(tester);
              await tester.tap(find.byKey(const ValueKey('card-nba:1')));
              await tester.pump(const Duration(milliseconds: 200));
              expect(playback.played, hasLength(1));
              expect(playback.currentChannel?.name, 'Fox Sports');
              await tester
                  .ensureVisible(find.byKey(const ValueKey('card-nba:2')));
              await settleSports(tester);
              if (size.width > 600) {
                final second = find.descendant(
                    of: find.byKey(const ValueKey('card-nba:2')),
                    matching: find.byType(InkWell));
                tester.widget<InkWell>(second).focusNode!.requestFocus();
                await settleSports(tester);
                expect(playback.played, hasLength(1));
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
              } else {
                await tester.tap(find.byKey(const ValueKey('card-nba:2')));
              }
              await tester.pump(const Duration(milliseconds: 200));
              expect(playback.played, hasLength(2));
              expect(find.byType(SportsScreen), findsOneWidget);
              // Back returns to the overview while the channel keeps playing.
              await tester.binding.handlePopRoute();
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'Fox Sports');
              await tester
                  .tap(find.byKey(const ValueKey('sport-heading:basketball')));
              await settleSports(tester);
              // Lazy phone rows release offscreen headers: scroll back before
              // opening the stats action, as a viewer would.
              if (size.width < 600) {
                tester
                    .widget<CustomScrollView>(find
                        .descendant(
                            of: find.byType(SportsScreen),
                            matching: find.byType(CustomScrollView))
                        .first)
                    .controller!
                    .jumpTo(0);
                await tester.pump();
              }
              // See all keeps the same filter after its own data refresh.
              await tester.ensureVisible(find.text('See all · stats'));
              await settleSports(tester);
              await tester.tap(find.text('See all · stats'));
              await tester.pump(const Duration(milliseconds: 300));
              await tester.runAsync(() =>
                  Future<void>.delayed(const Duration(milliseconds: 200)));
              await tester.pump(const Duration(milliseconds: 200));
              final liveRows = tester
                  .widgetList<InkWell>(find.byType(InkWell))
                  .where((w) =>
                      w.focusNode?.debugLabel?.startsWith('sports-live-') ??
                      false)
                  .map((w) => w.focusNode!.debugLabel)
                  .toList();
              expect(liveRows,
                  unorderedEquals(['sports-live-nba:1', 'sports-live-nba:2']));
              Navigator.of(tester.element(find.byType(SportsLiveListScreen)))
                  .pop();
              await tester.pump(const Duration(milliseconds: 300));
              await settleSports(tester);
              expect(storage.getSportsWithChannel(), isTrue);
              // Replays use direct guide mappings, keep the current preview,
              // and preserve the Events filters when switching back.
              final replayNow = DateTime.now();
              for (final entry in [
                ('Replay 1', 'NBA League Pass'),
                ('NFL Replay 1', 'NFL Sunday Ticket'),
                ('NFL Replay 2', 'NFL Sunday Ticket'),
                ('NFL Replay 3', 'NFL Sunday Ticket'),
                ('NHL Replay 1', 'NHL Center Ice'),
                ('NHL Replay 2', 'NHL Center Ice'),
                ('PL REPLAY 1 HD', 'Soccer Replay'),
                ('PL REPLAY 2 HD', 'Soccer Replay'),
              ]) {
                playlist.fixtureChannels.add(Channel(
                    id: 'demo::${entry.$1}',
                    rawId: entry.$1,
                    playlistId: 'demo',
                    name: entry.$1,
                    group: entry.$2,
                    url: 'https://example.test/no-stream'));
                epg.withoutGuide.add(entry.$1);
              }
              playlist.notifyListeners();
              epg.replays = [
                for (final entry in [
                  (
                    'Fox Sports',
                    'NBA: Boston Celtics v New York Knicks (Replay)',
                    'Full game replay from 21 October 2026. Madison Square Garden, New York.'
                  ),
                  (
                    'Fox Sports HD',
                    'NBA: Boston Celtics v New York Knicks (Replay)',
                    'Full game replay from 21 October 2026. Madison Square Garden, New York.'
                  ),
                  (
                    'ABC HD',
                    'NCAA Women’s Volleyball: Texas v Stanford (Replay)',
                    'Replay of the women’s college volleyball match.'
                  ),
                  (
                    'SBS HD',
                    'NCAA Women’s Soccer: Florida Atlantic v South Florida (Replay)',
                    'Full match replay from 21 October.'
                  ),
                  (
                    'Seven',
                    'Cricket: Australia v India — 2nd ODI',
                    'Coverage of the second one-day international.'
                  ),
                  (
                    'Nine',
                    'Formula 1: Australian Grand Prix (Replay)',
                    'Full race replay from 24 March 2024. Albert Park, Melbourne.'
                  ),
                ])
                  EpgProgram(
                      channelId: entry.$1,
                      title: entry.$2,
                      description: entry.$3,
                      start: replayNow.subtract(const Duration(minutes: 25)),
                      stop: replayNow.add(const Duration(minutes: 95))),
              ];
              epg.notifyListeners();
              final beforeReplays = playback.played.length;
              final livePreviewRect = tester
                  .getRect(find.byKey(const ValueKey('sports-channel-box')));
              final liveRefreshRect =
                  tester.getRect(find.byKey(const ValueKey('sports-refresh')));
              final livePlayerElement =
                  tester.element(find.byType(VideoPlayerPane));
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-replays')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 300));
              expect(find.textContaining('4 shown'), findsOneWidget);
              expect(
                  tester.getRect(
                      find.byKey(const ValueKey('sports-channel-box'))),
                  livePreviewRect);
              expect(
                  liveRefreshRect.right,
                  lessThanOrEqualTo(
                      prefs.isTelevision ? livePreviewRect.right : size.width));
              expect(
                  tester
                      .getRect(find.byKey(const ValueKey('replays-refresh')))
                      .right,
                  lessThanOrEqualTo(
                      prefs.isTelevision ? livePreviewRect.right : size.width),
                  reason:
                      'Refresh actions fit the TV preview column or phone header');
              expect(tester.element(find.byType(VideoPlayerPane)),
                  same(livePlayerElement));
              expect(
                  tester
                      .getBottomRight(
                          find.byKey(const ValueKey('replay-sport-picker')))
                      .dy,
                  lessThan(livePreviewRect.top));
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await captureSports(tester, size, 'replay-options');
              await tester.tap(find.text('Include possible replays'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              expect(find.text('21 Oct 2026'), findsWidgets);
              expect(find.byKey(const ValueKey('replay-view-toggle')),
                  findsNothing);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester.tap(find.text('Search replays'));
              await settleSports(tester);
              final searchField =
                  find.byKey(const ValueKey('replay-search-field'));
              expect(tester.widget<TextField>(searchField).focusNode!.hasFocus,
                  true);
              if (tester.widget<TextField>(searchField).readOnly) {
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
                await tester.pump();
              }
              await tester.enterText(searchField, 'new york');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              await captureSports(tester, size, 'replay-search');
              await tester.enterText(searchField, 'fox sports hd');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              await tester.enterText(searchField, 'Austrália India');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              await tester.enterText(searchField, 'no such event');
              await settleSports(tester);
              expect(find.textContaining('0 shown'), findsOneWidget);
              expect(find.text('Clear filters'), findsOneWidget);
              await tester.tap(find.text('Clear filters'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              await tester.tap(find.byTooltip('Close search'));
              await settleSports(tester);
              expect(searchField, findsNothing);
              expect(playback.played.length, beforeReplays);

              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              expect(find.text('Order within each sport'), findsOneWidget);
              await tester.tap(find.text('Ending soon'));
              await settleSports(tester);
              expect(find.text('Ending soon'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              await tester.tap(find.text('Recent events'));
              await settleSports(tester);
              expect(find.byKey(const ValueKey('replay-channel-directory')),
                  findsNothing);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester.tap(find.byWidgetPredicate(
                  (w) => w is PopupMenuItem<String> && w.value == 'likely'));
              await settleSports(tester);
              expect(find.textContaining('4 shown'), findsOneWidget);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester.tap(find.byWidgetPredicate(
                  (w) => w is PopupMenuItem<String> && w.value == 'likely'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-date-picker')));
              await settleSports(tester);
              await captureSports(tester, size, 'replay-browser');
              await tester.tap(find.text('Date unclear'));
              await settleSports(tester);
              expect(find.textContaining('3 shown'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-date-picker')));
              await settleSports(tester);
              await tester.tap(find.text('All dates'));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              expect(find.text('Past 4 weeks'), findsNothing);
              expect(find.text('By sport'), findsNothing);
              await tester.tap(find.text('Top leagues'));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sport-picker')));
              await settleSports(tester);
              await tester.tap(find.descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.text('Basketball')));
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              expect(playback.played.length, beforeReplays);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sport-picker')));
              await settleSports(tester);
              await tester.tap(find.descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.text('All sports')));
              await settleSports(tester);
              expect(find.textContaining('5 shown'), findsOneWidget);
              final catalogueLoads = playlist.catalogueLoads;
              await tester.tap(find.byKey(const ValueKey('replays-refresh')));
              await settleSports(tester);
              expect(playlist.catalogueLoads, catalogueLoads);
              final replayScroll = find.byKey(const ValueKey('replays-scroll'));
              final replayPull = await tester.startGesture(
                  tester.getTopLeft(replayScroll) + const Offset(20, 12));
              for (var i = 0; i < 8; i++) {
                await replayPull.moveBy(const Offset(0, 40));
                await tester.pump(const Duration(milliseconds: 40));
              }
              await replayPull.up();
              await settleSports(tester);
              expect(find.text('Couldn’t refresh'), findsNothing);
              expect(playlist.catalogueLoads, catalogueLoads);
              expect(playback.played.length, beforeReplays);
              expect(playback.currentChannel?.name, 'Fox Sports');
              expect(find.byType(VideoPlayerPane), findsOneWidget);
              expect(find.byKey(const ValueKey('replay-heading-basketball')),
                  findsOneWidget);
              await tester.pump(const Duration(seconds: 2));
              await settleSports(tester);
              await captureSports(tester, size, 'sports-replays');
              final replayCard = find.byWidgetPredicate((w) =>
                  w is InkWell &&
                  (w.key?.toString().contains('replay-demo::Fox Sports:') ??
                      false));
              expect(replayCard, findsOneWidget);
              await tester.longPress(replayCard);
              await settleSports(tester);
              expect(
                  find.text('Replay identified in the guide'), findsOneWidget);
              expect(
                  find.descendant(
                    of: find.byType(Dialog),
                    matching: find.textContaining('Madison Square Garden'),
                  ),
                  findsOneWidget);
              await captureSports(tester, size, 'sports-replay-channels');
              await tester.tap(find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('Fox Sports HD')));
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'Fox Sports HD');
              expect(playback.played.length, beforeReplays + 1);
              await tester
                  .tap(find.byKey(const ValueKey('replay-sport-picker')));
              await settleSports(tester);
              await tester.tap(find.descendant(
                  of: find.byType(SimpleDialog),
                  matching: find.text('Volleyball')));
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              expect(find.textContaining('NCAA Women’s Volleyball'),
                  findsOneWidget);
              // Remote OK tunes the exact programme channel once.
              final volleyball = find.byWidgetPredicate((w) =>
                  w is InkWell &&
                  (w.key?.toString().contains('replay-demo::ABC HD:') ??
                      false));
              tester.widget<InkWell>(volleyball).focusNode!.requestFocus();
              await tester.pump();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'ABC HD');
              expect(playback.played.length, beforeReplays + 2);
              // Missing guide listings are explicit, don't start streams when
              // opened, and only tune the channel the user actually chooses.
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              await tester
                  .tap(find.byKey(const ValueKey('replay-channel-directory')));
              await settleSports(tester);
              expect(find.textContaining('availability is unverified'),
                  findsOneWidget);
              expect(playback.played.length, beforeReplays + 2);
              await captureSports(tester, size, 'replay-directory');
              await tester.tap(find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('NFL Replay 1')));
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NFL Replay 1');
              expect(playback.played.length, beforeReplays + 3);
              // Highlights are a separate current-guide view; opening it
              // preserves playback, and its details/search never imply dates.
              for (final entry in [
                (
                  'NBA TV',
                  'NBA: Boston v New York Highlights',
                  'Highlights from the NBA season opener at Madison Square Garden.'
                ),
                (
                  'NBA TV HD',
                  'NBA: Boston v New York Highlights',
                  'Highlights from the NBA season opener at Madison Square Garden.'
                ),
                (
                  'Sky Sports Cricket',
                  '2nd Test Day 4: SA v AUS Hlts',
                  'Day four highlights from South Africa v Australia in Gqeberha.'
                ),
                (
                  'Sky Sport Select',
                  'A-League: Phoenix v Melbourne City Hls',
                  'Highlights from the opening round of the Women’s A-League in Wellington.'
                ),
              ]) {
                playlist.fixtureChannels.add(Channel(
                    id: 'demo::${entry.$1}',
                    rawId: entry.$1,
                    playlistId: 'demo',
                    name: entry.$1,
                    group: 'Sports',
                    url: 'https://example.test/no-stream'));
                epg.replays.add(EpgProgram(
                    channelId: entry.$1,
                    title: entry.$2,
                    description: entry.$3,
                    start: replayNow.subtract(const Duration(minutes: 8)),
                    stop: replayNow.add(const Duration(minutes: 22))));
              }
              playlist.notifyListeners();
              epg.notifyListeners();
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-highlights')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(
                  find.byWidgetPredicate(
                      (w) => w is SportsReplaysPanel && w.highlights),
                  findsOneWidget);
              expect(find.textContaining('3 shown'), findsOneWidget);
              expect(playback.currentChannel?.name, 'NFL Replay 1');
              expect(playback.played.length, beforeReplays + 3);
              expect(find.text('Date unclear'), findsNothing);
              expect(find.text('Likely replay'), findsNothing);
              await captureSports(tester, size, 'sports-highlights');
              await tester
                  .tap(find.byKey(const ValueKey('replay-sort-picker')));
              await settleSports(tester);
              expect(find.text('Sort highlights'), findsOneWidget);
              expect(find.text('Event date'), findsNothing);
              expect(find.text('Recent events'), findsNothing);
              await tester.tap(find.text('Top leagues').last);
              await settleSports(tester);
              await tester.tap(find.byKey(const ValueKey('replay-options')));
              await settleSports(tester);
              expect(find.text('Include possible replays'), findsNothing);
              await tester.tap(find.text('Search highlights'));
              await settleSports(tester);
              final highlightSearch =
                  find.byKey(const ValueKey('replay-search-field'));
              if (tester.widget<TextField>(highlightSearch).readOnly) {
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
                await tester.pump();
              }
              await tester.enterText(highlightSearch, 'Boston');
              await settleSports(tester);
              expect(find.textContaining('1 shown'), findsOneWidget);
              final highlightCard = find.byWidgetPredicate((w) =>
                  w is InkWell &&
                  (w.key?.toString().contains('replay-demo::NBA TV:') ??
                      false));
              if (size.width >= 600) {
                tester.widget<InkWell>(highlightCard).focusNode!.requestFocus();
                await tester.pump();
                await tester.sendKeyEvent(LogicalKeyboardKey.select);
              } else {
                await tester.tap(highlightCard);
              }
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NBA TV');
              await tester.tap(find.descendant(
                  of: highlightCard,
                  matching: find.byTooltip('Programme details and channels')));
              await settleSports(tester);
              expect(find.text('Original guide'), findsOneWidget);
              expect(find.text('Original guide & date source'), findsNothing);
              await captureSports(tester, size, 'highlight-channels');
              await tester.tap(find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('NBA TV HD')));
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NBA TV HD');
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-replays')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(find.textContaining('4 shown'), findsOneWidget);
              expect(playback.currentChannel?.name, 'NBA TV HD');
              tester
                  .widget<TextButton>(
                      find.byKey(const ValueKey('sports-view-events')))
                  .focusNode!
                  .requestFocus();
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await settleSports(tester);
              expect(playback.currentChannel?.name, 'NBA TV HD');
              expect(
                  find.byWidgetPredicate(
                      (w) => w is SportsReplaysPanel && !w.highlights),
                  findsNothing);
              expect(tester.takeException(), isNull);
              epg.replays = [];
              // An empty matched-channel result stays useful and can be cleared.
              playlist.fixtureChannels.clear();
              playlist.notifyListeners();
              await tester
                  .ensureVisible(find.byKey(const ValueKey('sports-day')));
              await tester.tap(find.byKey(const ValueKey('sports-day')));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.tap(find.text('Tomorrow'));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.runAsync(() =>
                  Future<void>.delayed(const Duration(milliseconds: 400)));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.tap(find.byKey(const ValueKey('sports-day')));
              await tester.pump(const Duration(milliseconds: 200));
              await tester
                  .ensureVisible(find.byKey(const ValueKey('sports-day')));
              await tester.tap(find.text('Today'));
              await tester.pump(const Duration(milliseconds: 200));
              await tester.runAsync(() =>
                  Future<void>.delayed(const Duration(milliseconds: 200)));
              await tester.pump(const Duration(milliseconds: 200));
              await settleSports(tester);
              expect(
                  find.text('No games with a matched channel'), findsOneWidget);
              await chooseChannelFilter('all');
              await tester.pump(const Duration(milliseconds: 200));
              expect(find.byKey(const ValueKey('card-nba:0')), findsOneWidget);
              expect(tester.takeException(), isNull);
              if (size.width < 600) {
                expect(
                    find.byKey(const ValueKey('bottom-live')), findsOneWidget);
                await tester.tap(find.byKey(const ValueKey('bottom-settings')));
                await tester.tap(find.byKey(const ValueKey('bottom-settings')));
                await settleSports(tester);
                expect(find.byType(SportsScreen), findsNothing);
                expect(playback.currentChannel?.name, 'NBA TV HD');
                expect(find.text('Settings'), findsWidgets);
                await tester.tap(find.byKey(const ValueKey('bottom-sports')));
                await settleSports(tester);
                final beforeReturn = playback.played.length;
                expect(playback.currentChannel?.name, 'NBA TV HD');
                await tester.tap(find.byKey(const ValueKey('bottom-live')));
                await settleSports(tester);
                expect(playback.played.length, beforeReturn);
                expect(playback.currentChannel?.name, 'NBA TV HD');
                expect(find.byType(SportsScreen), findsNothing);
                expect(
                    find.byKey(const ValueKey('bottom-live')), findsOneWidget);
              }
              await tester.pumpWidget(const SizedBox());
              SportsChannelMatcher.disposeShared();
              await tester.pump(const Duration(seconds: 31));
              prefs.dispose();
              playlist.dispose();
              playback.dispose();
              epg.dispose();
            },
                () => MockClient((request) async {
                      if (request.url.path.contains('/tennis/')) {
                        return _tennisFixture();
                      }
                      if (!['/nba/', '/nhl/', '/nfl/']
                          .any(request.url.path.contains)) {
                        return http.Response('{"events":[]}', 200);
                      }
                      if (request.url.path.endsWith('/scoreboard')) {
                        scoreRequests++;
                      }
                      return http.Response(
                          jsonEncode({
                            'events': [
                              for (var i = 0; i < 5; i++)
                                {
                                  'id': '$i',
                                  'date':
                                      DateTime.now().toUtc().toIso8601String(),
                                  'competitions': [
                                    {
                                      'status': {
                                        'type': {
                                          'state': i < 3 ? 'in' : 'pre',
                                          'shortDetail':
                                              i < 3 ? 'Q3 06:24' : 'Tonight'
                                        }
                                      },
                                      'broadcasts': [
                                        if (i != 0)
                                          {
                                            'names': ['Fox Sports']
                                          }
                                      ],
                                      'competitors': [
                                        {
                                          'homeAway': 'home',
                                          'score': '84',
                                          'team': {
                                            'id': 'b$i',
                                            'displayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Buffalo Bills'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Vancouver Canucks'
                                                    : 'Boston Celtics',
                                            'shortDisplayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Bills'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Canucks'
                                                    : 'Celtics',
                                            'abbreviation': request.url.path
                                                    .contains('/football/')
                                                ? 'BUF'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'VAN'
                                                    : 'BOS'
                                          }
                                        },
                                        {
                                          'homeAway': 'away',
                                          'score': '78',
                                          'team': {
                                            'id': 'l$i',
                                            'displayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Kansas City Chiefs'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Edmonton Oilers'
                                                    : 'Los Angeles Lakers',
                                            'shortDisplayName': request.url.path
                                                    .contains('/football/')
                                                ? 'Chiefs'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'Oilers'
                                                    : 'Lakers',
                                            'abbreviation': request.url.path
                                                    .contains('/football/')
                                                ? 'KC'
                                                : request.url.path
                                                        .contains('/hockey/')
                                                    ? 'EDM'
                                                    : 'LAL'
                                          }
                                        },
                                      ],
                                    }
                                  ],
                                }
                            ],
                          }),
                          200);
                    })));
  }
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540),
    const Size(1280, 720)
  ]) {
    testWidgets('tennis tournament cards fit ${size.width}', (tester) async {
      await http.runWithClient(() async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        setLayoutPreferences({'sports_online_extras': false});
        final storage = StorageService();
        await storage.init();
        await storage.setSportsAddedLeagues(['tennis.atp']);
        await storage.setSportsLeagues(['tennis.atp']);
        await storage.setSportsChannelFilter('all');
        const themeId = String.fromEnvironment('LAYOUT_THEME');
        if (themeId.isNotEmpty) await storage.setPaletteId(themeId);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width >= 960;
        final playlist = _Playlist(storage, CatalogDatabase());
        playlist.fixtureChannels.add(Channel(
            id: 'demo::tennis',
            rawId: 'tennis',
            playlistId: 'demo',
            name: 'Bu vs Ruud - ATP European Open',
            group: 'Tennis',
            url: 'https://example.invalid/never-opened'));
        final otherTennis = Channel(
            id: 'demo::other-tennis',
            rawId: 'other-tennis',
            playlistId: 'demo',
            name: 'ATP Tennis - another match',
            group: 'Tennis',
            url: 'https://example.invalid/never-opened');
        playlist.fixtureChannels.add(otherTennis);
        final playback = _Playback(storage, playlist);
        final epg = _Epg(storage);
        epg.replays.add(EpgProgram(
            channelId: 'tennis',
            title: 'ATP Tennis: European Open',
            description: 'Live from Brussels, Court 2.',
            start: DateTime.now().subtract(const Duration(minutes: 20)),
            stop: DateTime.now().add(const Duration(hours: 3))));
        await tester.pumpWidget(MultiProvider(
            providers: [
              Provider.value(value: storage),
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
              ChangeNotifierProvider<PlaybackService>.value(value: playback),
              ChangeNotifierProvider<EpgService>.value(value: epg),
            ],
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildAppTheme(prefs.palette),
                navigatorObservers: [appRouteObserver],
                home: const TvHomeScreen())));
        await settleSports(tester);
        await tester.tap(find.byIcon(Icons.sports));
        for (var i = 0;
            i < 30 &&
                find
                    .byKey(const ValueKey('tennis-tournament-tennis-demo'))
                    .evaluate()
                    .isEmpty;
            i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settleSports(tester);
        expect(find.byKey(const ValueKey('tennis-tournament-tennis-demo')),
            findsOneWidget);
        expect(find.text('BNP Paribas Fortis European Open'), findsWidgets);
        expect(find.text('ATP · Round 2'), findsOneWidget);
        final eventCard = find.descendant(
            of: find.byKey(const ValueKey('card-tennis.atp:tennis-demo')),
            matching: find.byType(InkWell));
        tester.widget<InkWell>(eventCard).focusNode!.requestFocus();
        await settleSports(tester);
        final video =
            tester.getRect(find.byKey(const ValueKey('sports-channel-box')));
        final activity =
            tester.getRect(find.byKey(const ValueKey('sports-status-slot')));
        final summary =
            tester.getRect(find.byKey(const ValueKey('sports-preview-title')));
        if (size.width < 600) {
          expect(activity.left, greaterThan(summary.right));
          expect(activity.top, greaterThanOrEqualTo(video.bottom));
          expect(video.height, closeTo((size.width - 24) * 9 / 16, .1));
        } else {
          expect(summary.left, closeTo(video.left, .1));
          expect(summary.top, greaterThan(video.bottom));
          expect(activity.top, greaterThan(summary.bottom));
          expect(activity.right, lessThanOrEqualTo(video.right + .1));
          expect(activity.bottom, closeTo(size.height - 4, .1));
          expect(video.width, greaterThan((size.width - 40) * .36));
          final card = tester.getRect(
              find.byKey(const ValueKey('card-tennis.atp:tennis-demo')));
          expect(card.left, greaterThan(video.right));
          expect(card.top, lessThan(video.bottom));
        }
        expect(tester.takeException(), isNull);
        await captureSports(tester, size, 'tennis');
        if (size.width == 390) {
          // Another tennis stream may appear among broad alternatives, but
          // must not displace this event's recommendation or get its badge.
          await playback.play(otherTennis);
          await settleSports(tester);
          await tester.longPress(
              find.byKey(const ValueKey('card-tennis.atp:tennis-demo')));
          await settleSports(tester);
          final initialPicker =
              tester.widget<SportsChannelList>(find.byType(SportsChannelList));
          final options = initialPicker.rows;
          expect(options.any((row) => row.channel.id == otherTennis.id), true);
          expect(options.first.channel.id, isNot(otherTennis.id));
          expect(initialPicker.playingId, isNull);
          expect(find.textContaining('Playing'), findsNothing);
          final chosenId = options.first.channel.id;
          await tester.tap(find.byKey(ValueKey('game-channel:$chosenId')));
          await settleSports(tester);
          expect(playback.currentChannel?.id, chosenId);
          final saved = jsonDecode(storage.getSportsChannelPicks()!) as Map;
          expect(saved['events']['tennis.atp:tennis-demo']['c'], chosenId,
              reason:
                  'explicitly choosing even the first suggestion is remembered');
          await tester.longPress(
              find.byKey(const ValueKey('card-tennis.atp:tennis-demo')));
          await settleSports(tester);
          final reopened =
              tester.widget<SportsChannelList>(find.byType(SportsChannelList));
          expect(reopened.rows.first.channel.id, chosenId);
          expect(reopened.playingId, chosenId);
          expect(reopened.selectedId, chosenId);
          await captureSports(tester, size, 'sports-playing-channel');
          await tester.binding.handlePopRoute();
          await settleSports(tester);
          expect(tester.takeException(), isNull);
        }

        await tester.pumpWidget(const SizedBox());
        SportsChannelMatcher.disposeShared();
        await tester.pump(const Duration(seconds: 31));
        playback.dispose();
        playlist.dispose();
        epg.dispose();
        prefs.dispose();
      }, () => MockClient((_) async => _tennisFixture()));
    });
  }
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'sports balanced header keeps selected names readable at ${size.width}',
        (tester) => http.runWithClient(() async {
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              setLayoutPreferences({'sports_online_extras': false});
              final storage = StorageService();
              await storage.init();
              await storage.setSportsAddedLeagues(['eng.1', 'uefa.champions']);
              await storage.setSportsLeagues(['eng.1', 'uefa.champions']);
              await storage.setSportsChannelFilter('possible');
              final prefs = AppPreferences(storage);
              await prefs.init();
              prefs.isTelevision = size.width >= 960;
              final playlist = _Playlist(storage, CatalogDatabase());
              final playback = _Playback(storage, playlist);
              final epg = _Epg(storage);
              await tester.pumpWidget(MultiProvider(
                  providers: [
                    Provider.value(value: storage),
                    ChangeNotifierProvider.value(value: prefs),
                    ChangeNotifierProvider<PlaylistManager>.value(
                        value: playlist),
                    ChangeNotifierProvider<PlaybackService>.value(
                        value: playback),
                    ChangeNotifierProvider<EpgService>.value(value: epg),
                  ],
                  child: MaterialApp(
                      theme: buildAppTheme(prefs.palette),
                      navigatorObservers: [appRouteObserver],
                      home: SportsScreen(
                          scores: _RowScores(
                              counts: {'eng.1': 1, 'uefa.champions': 1})))));
              await settleSports(tester);
              if (size.width < 600) {
                for (final view in [
                  'events',
                  'standings',
                  'schedule',
                  'replays',
                  'highlights'
                ]) {
                  final tab = find.byKey(ValueKey('sports-view-$view'));
                  expect(tab.hitTestable(), findsOneWidget);
                  final rect = tester.getRect(tab);
                  expect(rect.left, greaterThanOrEqualTo(0));
                  expect(rect.right, lessThanOrEqualTo(size.width));
                }
              }
              await tester.tap(find.byKey(const ValueKey('sport-picker')));
              await settleSports(tester);
              await tester.tap(find.byType(TextField));
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.enterText(find.byType(TextField), 'soccer');
              await tester.pump(const Duration(milliseconds: 300));
              await tester.tap(find.byKey(const ValueKey('soccer')));
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(const ValueKey('league-picker')));
              await tester.pumpAndSettle();
              await tester.tap(find.byType(TextField));
              await tester.sendKeyEvent(LogicalKeyboardKey.select);
              await tester.pump();
              await tester.enterText(
                  find.byType(TextField), 'Champions League');
              await tester.pump(const Duration(milliseconds: 300));
              await tester.tap(find.byKey(const ValueKey('uefa.champions')));
              await settleSports(tester);
              await tester.pump(const Duration(milliseconds: 350));
              await tester.pumpAndSettle();
              await captureSports(tester, size, 'balanced-events');
              expect(find.byType(Dialog), findsNothing);
              for (final key in [
                'sport-picker',
                'league-picker',
                if (prefs.isTelevision) 'with-channel'
              ]) {
                final finder = find.byKey(ValueKey(key));
                final value = tester.widget<SportsFilterButton>(finder).value;
                final text = find.descendant(
                    of: finder,
                    matching: find.byWidgetPredicate(
                        (w) => w is RichText && w.text.toPlainText() == value));
                if (const String.fromEnvironment('LAYOUT_FONT_DIR')
                    .isNotEmpty) {
                  expect(
                      tester
                          .renderObject<RenderParagraph>(text)
                          .didExceedMaxLines,
                      isFalse,
                      reason: '$value should fit, not truncate');
                }
                expect(
                    find
                        .descendant(
                            of: finder, matching: find.byType(TextButton))
                        .hitTestable(),
                    findsOneWidget);
              }
              final day = find.byKey(const ValueKey('sports-day'));
              final actions =
                  find.byKey(const ValueKey('sports-toolbar-actions'));
              final overflow = find.byTooltip('Sports options');
              expect(day.hitTestable(), findsOneWidget);
              expect(
                  find.descendant(of: actions, matching: day), findsOneWidget);
              final dayRect = tester.getRect(day);
              final moreRect = tester.getRect(overflow);
              expect(dayRect.right, closeTo(moreRect.left, .1));
              expect(dayRect.center.dy, closeTo(moreRect.center.dy, .1));
              if (prefs.isTelevision) {
                final when = find.descendant(
                    of: find.byKey(const ValueKey('live-only')),
                    matching: find.byType(SportsFilterButton));
                expect(when, findsOneWidget);
                if (const String.fromEnvironment('LAYOUT_FONT_DIR')
                    .isNotEmpty) {
                  final text = find.descendant(
                      of: when,
                      matching: find.byWidgetPredicate((w) =>
                          w is RichText &&
                          w.text.toPlainText() == 'Live + soon'));
                  expect(
                      tester
                          .renderObject<RenderParagraph>(text)
                          .didExceedMaxLines,
                      isFalse);
                }
              }
              if (!prefs.isTelevision) {
                expect(
                    find.byKey(const ValueKey('event-filters')).hitTestable(),
                    findsOneWidget);
                expect(
                    tester
                        .getSize(find.byKey(const ValueKey('event-filters')))
                        .width,
                    greaterThanOrEqualTo(32));
              }
              await captureSports(tester, size, 'balanced-events');
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
              // Logo-cache SQLite work must finish outside the fake frame clock.
              await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 50)));
              await tester.pump(const Duration(seconds: 11));
              await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 50)));
              await tester.pump();
              SportsChannelMatcher.disposeShared();
              playback.dispose();
              playlist.dispose();
              epg.dispose();
              prefs.dispose();
            },
                () => MockClient(
                    (_) async => http.Response('{"events":[]}', 200))));
  }
}
