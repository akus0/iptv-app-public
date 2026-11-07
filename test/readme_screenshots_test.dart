import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/models/sports_progress.dart';
import 'package:nox_iptv/models/xtream_series.dart';
import 'package:nox_iptv/screens/library_screen.dart';
import 'package:nox_iptv/screens/settings/settings_workspace.dart';
import 'package:nox_iptv/screens/sports_screen.dart';
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/services/sports_service.dart';
import 'package:nox_iptv/services/sports_standings_service.dart';
import 'package:nox_iptv/services/sports_supplement_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/route_observer.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/main_navigation_rail.dart';
import 'player_polish_test.dart' as player;
import 'library_test.dart' as library_fixture;

const _output = String.fromEnvironment('README_SCREENSHOT_DIR');
const _emojiFont = String.fromEnvironment('README_EMOJI_FONT');
const _symbolFont = String.fromEnvironment('README_SYMBOL_FONT');
const _titles = [
  'Beyond the Blue',
  'After the Rain',
  'The Last Light',
  'Wild Horizon',
  'Midnight Express',
  'Little Wonders',
  'North of Home',
  'City of Echoes',
  'The Long Way',
  'Golden Summer',
  'Ocean Deep',
  'Silent Orbit',
  'Paper Planes',
  'Second Sunrise',
  'Mountain Roads',
  'The Night Garden',
  'Hidden Worlds',
  'Open Water',
  'A Different Sky',
  'Everyday Heroes',
  'The Quiet Coast',
  'New Beginnings',
  'Across the Valley',
  'Winter Song',
];
const _clubs = [
  'Arsenal',
  'Liverpool',
  'Manchester City',
  'Chelsea',
  'Newcastle United',
  'Aston Villa',
  'Brighton',
  'Bournemouth',
  'Tottenham',
  'Crystal Palace',
  'Brentford',
  'Fulham',
  'Everton',
  'West Ham',
  'Nottingham Forest',
  'Leeds United',
  'Burnley',
  'Sunderland',
  'Wolves',
  'Manchester United',
];
const _teams = {
  'eng.1': _clubs,
  'nba': [
    'Boston Celtics',
    'New York Knicks',
    'Denver Nuggets',
    'Los Angeles Lakers',
    'Golden State Warriors',
    'Phoenix Suns',
    'Miami Heat',
    'Chicago Bulls',
    'Dallas Mavericks',
    'Houston Rockets',
    'Cleveland Cavaliers',
    'Milwaukee Bucks'
  ],
  'nhl': [
    'Toronto Maple Leafs',
    'Boston Bruins',
    'Edmonton Oilers',
    'Vancouver Canucks',
    'New York Rangers',
    'Pittsburgh Penguins',
    'Dallas Stars',
    'Colorado Avalanche',
    'Montreal Canadiens',
    'Ottawa Senators',
    'Winnipeg Jets',
    'Calgary Flames'
  ],
  'aus.1': [
    'Wellington Phoenix',
    'Sydney FC',
    'Melbourne Victory',
    'Melbourne City',
    'Adelaide United',
    'Perth Glory',
    'Auckland FC',
    'Brisbane Roar',
    'Newcastle Jets',
    'Central Coast Mariners',
    'Western Sydney Wanderers',
    'Macarthur FC'
  ],
  'tennis.atp': [
    'Carlos Alcaraz',
    'Jannik Sinner',
    'Novak Djokovic',
    'Alexander Zverev',
    'Alex de Minaur',
    'Taylor Fritz',
    'Casper Ruud',
    'Daniil Medvedev',
    'Ben Shelton',
    'Andrey Rublev',
    'Lorenzo Musetti',
    'Holger Rune'
  ],
};
const _colors = [
  Color(0xFF557C97),
  Color(0xFFB36C54),
  Color(0xFF6C789A),
  Color(0xFF69866E),
  Color(0xFFB39463),
  Color(0xFF8A6E8F)
];
String _badge(int i) => 'https://example.invalid/badge/$i.png';
String _poster(int i) => 'https://example.invalid/poster/$i.png';
String _initials(String name) =>
    name.split(' ').map((s) => s[0]).take(3).join();
SportsTeam _team(String name, int i, {String? score}) => SportsTeam(
    id: 'sample-$i',
    name: name,
    shortName: name,
    abbreviation: _initials(name),
    logoUrl: 'https://example.invalid/team/$i.png',
    color: '557C97',
    score: score);

List<SportsGame> _games(DateTime now, {bool schedule = false}) => [
      for (final (leagueIndex, entry) in _teams.entries.indexed)
        for (var i = 0; i < 6; i++)
          SportsGame(
            id: '${entry.key}-$i',
            league: sportsLeagueById(entry.key)!,
            start: now.add(Duration(
                minutes:
                    schedule ? 20 + leagueIndex * 12 + i * 45 : -35 + i * 3)),
            state: schedule ? GameState.pre : GameState.live,
            statusText: schedule
                ? 'Scheduled'
                : entry.key == 'nba'
                    ? 'Q3 6:42'
                    : entry.key == 'nhl'
                        ? '2nd 12:15'
                        : entry.key == 'tennis.atp'
                            ? '2nd Set'
                            : '37′',
            home: _team(entry.value[i * 2], leagueIndex * 20 + i * 2,
                score: schedule
                    ? null
                    : entry.key == 'nba'
                        ? '${68 + i * 3}'
                        : '${i % 3}'),
            away: _team(entry.value[i * 2 + 1], leagueIndex * 20 + i * 2 + 1,
                score: schedule
                    ? null
                    : entry.key == 'nba'
                        ? '${64 + i * 4}'
                        : '${(i + 1) % 2}'),
            event: entry.key == 'tennis.atp'
                ? const SportsEventInfo(title: 'ATP Tour · Centre Court')
                : null,
          ),
    ];

class _Scores extends SportsService {
  _Scores(this.now)
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  final DateTime now;
  late final games = _games(now);
  @override
  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      games;
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
          {bool forceRefresh = false,
          void Function(List<SportsGame>)? onProgress,
          void Function(SportsWorkProgress)? onStatus}) async =>
      games;
  @override
  Future<List<SportsGame>> gamesForDayWhileActive(
          List<SportsLeague> leagues, DateTime day,
          {required bool Function() shouldContinue,
          bool forceRefresh = false,
          void Function(List<SportsGame>)? onProgress,
          void Function(SportsWorkProgress)? onStatus}) async =>
      games;
  @override
  List<SportsGame> cachedScheduleDay(
          List<SportsLeague> leagues, DateTime day) =>
      _games(now, schedule: true);
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleDay(
          List<SportsLeague> leagues, DateTime day,
          {bool Function()? shouldContinue,
          void Function(List<SportsGame>)? onProgress}) async =>
      (games: _games(now, schedule: true), incomplete: false);
  @override
  Future<({List<SportsGame> games, bool incomplete})> scheduleGames(
          SportsLeague league, DateTime from, DateTime through,
          {bool Function()? shouldContinue}) async =>
      (
        games: _games(now, schedule: true)
            .where((g) => g.league.id == league.id)
            .toList(),
        incomplete: false
      );
}

class _Supplement extends SportsSupplementService {
  _Supplement()
      : super.withClient(MockClient((_) async => http.Response('{}', 200)));
  @override
  Future<List<SportsGame>> gamesForDay(List<SportsLeague> leagues, DateTime day,
          {bool Function()? cancelled}) async =>
      [];
  @override
  List<SportsGame> cachedGamesForDay(
          List<SportsLeague> leagues, DateTime day) =>
      [];
  @override
  Future<void> warmBroadcasts(List<SportsGame> games,
      {required bool Function() cancelled}) async {}
}

class _Standings extends SportsStandingsService {
  _Standings()
      : super(client: MockClient((_) async => http.Response('{}', 200))) {
    lastLeagueId = 'eng.1';
  }
  @override
  Future<LeagueStandings> load(SportsLeague league,
          {bool refresh = false, bool rememberSelection = true}) async =>
      LeagueStandings(season: '2026–27', tables: [
        StandingTable('Premier League', [
          for (final (i, club) in _clubs.indexed)
            StandingTeam(
                _team(club, i),
                {
                  'gamesPlayed': '12',
                  'wins': '${10 - i ~/ 2}',
                  'ties': '${2 - i % 2}',
                  'losses': '${i ~/ 2 + i % 2}',
                  'points': '${(10 - i ~/ 2) * 3 + 2 - i % 2}',
                  'pointsFor': '${35 - i}',
                  'pointsAgainst': '${10 + i}',
                  'pointDifferential': '${25 - 2 * i}',
                },
                i + 1)
        ])
      ]);
}

class _Catalogue extends library_fixture.MemoryDb {
  @override
  Future<LibraryPage> libraryPage(
      {required String playlistId,
      required String category,
      required bool series,
      String query = '',
      LibrarySort sort = LibrarySort.provider,
      int offset = 0,
      int limit = 60}) async {
    final ids = List.generate(_titles.length, (i) => i)
        .where((i) => _titles[i].toLowerCase().contains(query.toLowerCase()))
        .skip(offset)
        .take(limit);
    return LibraryPage(
        total: _titles.length,
        movies: series
            ? []
            : [
                for (final i in ids)
                  Channel(
                      id: 'one::xt_vod_$i',
                      rawId: 'xt_vod_$i',
                      playlistId: 'one',
                      name: _titles[i],
                      group: category,
                      url: 'https://example.invalid/never-play',
                      logoUrl: _poster(i),
                      providerPosterUrl: _poster(i),
                      rating: (7 + (i % 18) / 10).toStringAsFixed(1),
                      releaseDate: DateTime(2025 - i % 5))
              ],
        series: !series
            ? []
            : [
                for (final i in ids)
                  XtreamSeries(
                      seriesId: i,
                      playlistId: 'one',
                      name: _titles[i],
                      categoryId: category,
                      coverUrl: _poster(i),
                      rating: '8.2',
                      releaseDate: DateTime(2026))
              ]);
  }
}

class _Playlist extends library_fixture.Manager {
  _Playlist(StorageService storage, this.db, this.games) : super(storage, db) {
    for (final (i, _) in games.indexed) {
      channels.add(Channel(
          id: 'one::sport$i',
          rawId: 'sport$i',
          playlistId: 'one',
          name: 'Arena ${i + 1} HD',
          group: 'Sports',
          logoUrl: _badge(i),
          url: 'https://example.invalid/never-play'));
    }
    for (var i = 0; i < 24; i++) {
      channels.add(Channel(
          id: 'one::review$i',
          rawId: 'review$i',
          playlistId: 'one',
          name: 'Arena Review ${i + 1}',
          group: 'Sports',
          logoUrl: _badge(i + 30),
          url: 'https://example.invalid/never-play'));
    }
    for (final (index, group) in [
      'News',
      'Entertainment',
      'Documentaries',
      'Movies',
      'Kids & family',
      'Music',
      'Lifestyle',
      'International'
    ].indexed) {
      for (var i = 0; i < 6; i++) {
        final n = index * 6 + i;
        channels.add(Channel(
            id: 'one::channel$n',
            rawId: 'channel$n',
            playlistId: 'one',
            name: '${[
              'World',
              'City',
              'Coast',
              'Vista',
              'Bright',
              'Discovery'
            ][i]} ${group == 'Kids & family' ? 'Kids' : group}',
            group: group,
            logoUrl: _badge(n + 40),
            url: 'https://example.invalid/never-play'));
      }
    }
  }
  final _Catalogue db;
  final List<SportsGame> games;
  @override
  final channels = <Channel>[];
  @override
  bool get hasLiveChannels => true;
  @override
  List<PlaylistProfile> get profiles => [
        PlaylistProfile(
            id: 'one',
            name: 'Sample collection',
            mode: 'm3u',
            sortOrder: 0,
            createdAt: DateTime(2026))
      ];
  @override
  List<M3uGroup> get tvGroups => [
        for (final group in channels.map((c) => c.group).toSet())
          M3uGroup(
              title: group,
              playlistId: 'one',
              channels: channels.where((c) => c.group == group).toList())
      ];
  @override
  List<M3uGroup> get vodGroups => [
        for (final name in [
          'Featured films',
          'Adventure',
          'Drama',
          'Documentaries',
          'Family',
          'Science fiction',
          'Thrillers'
        ])
          M3uGroup(title: name, playlistId: 'one', channels: [])
      ];
  @override
  List<M3uGroup> get seriesGroups => [
        for (final name in [
          'Featured series',
          'Drama',
          'Comedy',
          'Documentaries',
          'Crime',
          'Family'
        ])
          M3uGroup(title: name, playlistId: 'one', channels: [])
      ];
  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      groupTitle == null
          ? channels
          : channels.where((c) => c.group == groupTitle).toList();
  @override
  List<Channel> get favoriteLiveChannelsWithGroups => channels.take(6).toList();
  @override
  Future<void> ensureLiveChannelsLoaded() async {}
  @override
  Set<String> favoritedGroupsFor(String playlistId) => {};
  @override
  Future<LibraryPage> searchLibraryPage(String query,
          {required bool series,
          LibrarySort sort = LibrarySort.provider,
          int offset = 0,
          int limit = 60}) =>
      db.libraryPage(
          playlistId: 'one',
          category: series ? 'Featured series' : 'Featured films',
          series: series,
          query: query,
          sort: sort,
          offset: offset,
          limit: limit);
}

class _Guide extends EpgService {
  _Guide(super.storage, this.playlist, this.now);
  final _Playlist playlist;
  final DateTime now;
  @override
  List<EpgProgram> getPrograms(String channelId) {
    final index = playlist.channels.indexWhere((c) => c.epgId == channelId);
    final game = index >= 0 && index < playlist.games.length
        ? playlist.games[index]
        : null;
    if (index >= 30 && index < 54) {
      final i = index - 30;
      final teams = _teams.values.elementAt(i ~/ 6);
      final league = ['Premier League', 'NBA', 'NHL', 'A-League'][i ~/ 6];
      final title =
          '$league: ${teams[i % 6]} vs ${teams[(i % 6 + 3) % teams.length]}';
      return [
        for (var slot = -1; slot < 5; slot++)
          EpgProgram(
              channelId: channelId,
              title: '$title (${i.isEven ? 'Replay' : 'Highlights'})',
              description: i.isEven
                  ? 'Full match replay from the previous round.'
                  : 'Match highlights from the previous round.',
              start: now
                  .subtract(const Duration(minutes: 35))
                  .add(Duration(hours: slot * 2)),
              stop: now
                  .subtract(const Duration(minutes: 35))
                  .add(Duration(hours: (slot + 1) * 2)))
      ];
    }
    return [
      for (var slot = -1; slot < 5; slot++)
        EpgProgram(
            channelId: channelId,
            title: slot == 0 && game != null
                ? '${game.league.shortName}: ${game.title}'
                : [
                    'Weekend Roundup',
                    'World in Focus',
                    'Matchday Review',
                    'The Big Interview',
                    'Coast to Coast',
                    'Evening Edition'
                  ][(slot + 1 + (index < 0 ? 0 : index)) % 6],
            description: slot == 0 && game != null
                ? 'Live coverage of ${game.title}. Build-up, expert analysis and all the action from ${game.league.name}.'
                : 'Stories, interviews and highlights from across the world. Discover the people and places behind today’s headlines.',
            start: now
                .subtract(const Duration(minutes: 35))
                .add(Duration(hours: slot * 2)),
            stop: now
                .subtract(const Duration(minutes: 35))
                .add(Duration(hours: (slot + 1) * 2)))
    ];
  }

  @override
  EpgProgram? getCurrentProgram(String id) => getPrograms(id)[1];
  @override
  EpgProgram? getNextProgram(String id) => getPrograms(id)[2];
  @override
  Iterable<EpgProgram> cachedCurrentProgrammes(DateTime _) =>
      playlist.channels.map((c) => getCurrentProgram(c.epgId)!);
  @override
  Future<List<EpgProgram>> findProgrammesByTitle(
          DateTime from, DateTime to, List<String> terms,
          {List<String>? channelIds}) async =>
      [
        for (final c in playlist.channels)
          if (channelIds == null || channelIds.contains(c.epgId))
            for (final p in getPrograms(c.epgId))
              if (p.start.isBefore(to) &&
                  p.stop.isAfter(from) &&
                  terms.any(
                      (t) => p.title.toLowerCase().contains(t.toLowerCase())))
                p
      ];
  @override
  Future<List<EpgProgram>> findSportsProgrammesForChannels(
          List<String> ids, DateTime from, DateTime to) async =>
      [
        for (final id in ids)
          for (final p in getPrograms(id))
            if (p.start.isBefore(to) && p.stop.isAfter(from)) p
      ];
}

class _Cache extends Fake implements BaseCacheManager {
  _Cache(this.dir);
  final Directory dir;
  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    final uri = Uri.parse(url);
    final id = int.tryParse(uri.pathSegments.last.split('.').first) ?? 0;
    final poster = uri.path.contains('/poster/');
    final team = uri.path.contains('/team/');
    final file = const LocalFileSystem().file(
        '${dir.path}/${poster ? 'poster-${id % _titles.length}' : '${team ? 'team' : 'badge'}-${id % 100}'}.png');
    yield FileInfo(file, FileSource.Cache, DateTime(2030), url);
  }
}

class _Controller extends player.Controller {
  @override
  int get textureId => 42;
}

class _Video extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}
  @override
  Widget buildView(int playerId) => const CustomPaint(painter: _Pitch());
}

class _Pitch extends CustomPainter {
  const _Pitch();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 960, size.height / 540);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 960, 540),
        Paint()..color = const Color(0xFF172A35));
    for (var i = 0; i < 8; i++) {
      final left = 80.0 + i * 100;
      canvas.drawRect(
          Rect.fromLTWH(left, 100, 100, 360),
          Paint()
            ..color =
                i.isEven ? const Color(0xFF477A58) : const Color(0xFF3F7050));
    }
    final line = Paint()
      ..color = const Color(0xFFBDD3BA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(const Rect.fromLTWH(80, 100, 800, 360), line);
    canvas.drawLine(const Offset(480, 100), const Offset(480, 460), line);
    canvas.drawCircle(const Offset(480, 280), 63, line);
    canvas.drawRect(const Rect.fromLTWH(80, 180, 130, 200), line);
    canvas.drawRect(const Rect.fromLTWH(750, 180, 130, 200), line);
    for (var i = 0; i < 22; i++) {
      final x = 130.0 + (i * 137 % 700), y = 140.0 + (i * 89 % 280);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(x + 3, y + 5), width: 15, height: 6),
          Paint()..color = Colors.black26);
      canvas.drawCircle(
          Offset(x, y),
          5,
          Paint()
            ..color =
                i.isEven ? const Color(0xFFE7ECEE) : const Color(0xFFBD5262));
    }
    final tp = TextPainter(
        text: const TextSpan(
            text: 'SAMPLE PREVIEW',
            style: TextStyle(
                fontFamily: 'Roboto',
                fontSize: 14,
                color: Color(0xFF91A5AE),
                letterSpacing: 3)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, const Offset(40, 32));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Pitch oldDelegate) => false;
}

Future<void> _art(Directory dir) async {
  for (var i = 0; i < 200 + _titles.length; i++) {
    final poster = i >= 200, team = i >= 100 && i < 200;
    final index = poster
        ? i - 200
        : team
            ? i - 100
            : i;
    final size = poster ? const Size(400, 600) : const Size(100, 100);
    final rec = ui.PictureRecorder();
    // Each bitmap is original fixture artwork, rendered before mounting the app.
    final canvas = Canvas(rec), color = _colors[index % _colors.length];
    if (poster) {
      canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..shader = LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color, const Color(0xFF101C2B)])
                .createShader(Offset.zero & size));
      canvas.drawCircle(Offset(100 + index % 4 * 55, 190), 100,
          Paint()..color = Colors.white.withValues(alpha: .13));
      for (var j = 0; j < 5; j++) {
        final path = Path()
          ..moveTo(0, 230.0 + j * 35)
          ..lineTo(120.0 + j * 30, 130.0 + j * 40)
          ..lineTo(400, 300.0 + j * 40)
          ..lineTo(400, 600)
          ..lineTo(0, 600)
          ..close();
        canvas.drawPath(
            path,
            Paint()
              ..color =
                  Color.lerp(color, const Color(0xFF0B1420), .35 + j * .13)!);
      }
      final title = TextPainter(
          text: TextSpan(
              text: _titles[index].toUpperCase(),
              style: const TextStyle(
                  fontFamily: 'Roboto',
                  fontSize: 42,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 2)),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: 340);
      title.paint(canvas, Offset(30, 540 - title.height));
    } else {
      canvas.drawCircle(const Offset(50, 50), 47, Paint()..color = color);
      final title = TextPainter(
          text: TextSpan(
              text: team &&
                      index ~/ 20 < _teams.length &&
                      index % 20 < _teams.values.elementAt(index ~/ 20).length
                  ? _initials(_teams.values.elementAt(index ~/ 20)[index % 20])
                  : '${index + 1}',
              style: const TextStyle(
                  fontFamily: 'Roboto',
                  fontSize: 34,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
          textDirection: TextDirection.ltr)
        ..layout();
      title.paint(canvas, Offset(50 - title.width / 2, 50 - title.height / 2));
    }
    final picture = rec.endRecording();
    final image =
        await picture.toImage(size.width.toInt(), size.height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
            '${dir.path}/${poster ? 'poster' : team ? 'team' : 'badge'}-$index.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory art;
  setUpAll(() async {
    if (_output.isEmpty) return;
    await Directory(_output).create(recursive: true);
    const fonts = String.fromEnvironment('LAYOUT_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'Ahem': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf'
    }.entries) {
      await (FontLoader(entry.key)
            ..addFont(File('$fonts/${entry.value}')
                .readAsBytes()
                .then(ByteData.sublistView)))
          .load();
    }
    await (FontLoader('Readme Emoji')
          ..addFont(File(_emojiFont).readAsBytes().then(ByteData.sublistView)))
        .load();
    await (FontLoader('Readme Symbols')
          ..addFont(File(_symbolFont).readAsBytes().then(ByteData.sublistView)))
        .load();
    art = await Directory.systemTemp.createTemp('iptv-readme-art-');
    await _art(art);
    CachedNetworkImageProvider.defaultCacheManager = _Cache(art);
    VideoPlayerPlatform.instance = _Video();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('iptv-app/playback-timeline'),
            (call) async => call.method == 'configureRecovery'
                ? true
                : <String, dynamic>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => art.path);
  });
  for (final (label, size) in [
    ('tv', const Size(960, 540)),
    ('phone', const Size(390, 844)),
    ('landscape', const Size(844, 390))
  ]) {
    testWidgets('README screenshots $label', (tester) async {
      await http.runWithClient(() async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({'sports_online_extras': false});
        final storage = library_fixture.MemoryStorage();
        await storage.init();
        await storage.setSportsLeagues(_teams.keys.toList());
        await storage.setSportsChannelFilter('all');
        await storage.setSportsBrowseSelection(null, null);
        await storage.setLiveCategoryFolders(false);
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = label == 'tv';
        final now = DateTime.now(),
            db = _Catalogue(),
            scores = _Scores(DateTime.now());
        final playlist = _Playlist(storage, db, scores.games);
        final guide = _Guide(storage, playlist, now);
        final playback = player.Playback(storage, playlist)
          ..currentChannel = playlist.channels.first
          ..controller = _Controller();
        final standings = _Standings(), supplement = _Supplement();
        final capture = GlobalKey();
        Future<void> settle() async {
          for (var i = 0; i < 30; i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 30)));
            await tester.pump(const Duration(milliseconds: 30));
          }
        }

        Future<void> mount(Widget screen) async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          SportsChannelMatcher.disposeShared();
          final theme = buildAppTheme(prefs.palette);
          await tester.pumpWidget(MultiProvider(
              providers: [
                Provider<StorageService>.value(value: storage),
                Provider<CatalogDatabase>.value(value: db),
                ChangeNotifierProvider<AppPreferences>.value(value: prefs),
                ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
                ChangeNotifierProvider<EpgService>.value(value: guide),
                ChangeNotifierProvider<PlaybackService>.value(value: playback),
              ],
              child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: theme.copyWith(
                      textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
                      primaryTextTheme:
                          theme.primaryTextTheme.apply(fontFamily: 'Roboto')),
                  navigatorObservers: [appRouteObserver],
                  builder: (_, child) =>
                      RepaintBoundary(key: capture, child: child),
                  home: screen)));
          await settle();
        }

        Future<void> save(String name) async {
          await settle();
          // The test engine's unnamed fallback is Ahem. Android uses Roboto
          // and its emoji fallback even for explicit, family-less button styles.
          // Resolve those fonts before layout/capture; leave the app widgets intact.
          InlineSpan fontSpan(InlineSpan value, [TextStyle? inherited]) {
            if (value is! TextSpan) return value;
            final style = (inherited ?? const TextStyle()).merge(value.style);
            if (style.fontFamily == 'MaterialIcons') return value;
            final children = <InlineSpan>[];
            final runs = <String>[];
            bool? previousEmoji;
            for (final rune in (value.text ?? '').runes) {
              final emoji = (rune >= 0x1f000 && rune <= 0x1faff) ||
                  (rune >= 0x2600 && rune <= 0x27bf) ||
                  rune == 0xfe0f;
              if (emoji != previousEmoji) runs.add('');
              runs[runs.length - 1] += String.fromCharCode(rune);
              previousEmoji = emoji;
            }
            for (final run in runs) {
              final rune = run.runes.first;
              final emoji = (rune >= 0x1f000 && rune <= 0x1faff) ||
                  (rune >= 0x2600 && rune <= 0x27bf) ||
                  rune == 0xfe0f;
              children.add(TextSpan(
                  text: run,
                  style: style.copyWith(
                      fontFamily: rune == 0x2605
                          ? 'Readme Symbols'
                          : emoji
                              ? 'Readme Emoji'
                              : 'Roboto')));
            }
            children
                .addAll(value.children?.map((c) => fontSpan(c, style)) ?? []);
            return TextSpan(
                style: style.copyWith(fontFamily: 'Roboto'),
                children: children);
          }

          void androidFonts(RenderObject object) {
            if (object is RenderParagraph) object.text = fontSpan(object.text);
            object.visitChildren(androidFonts);
          }

          androidFonts(capture.currentContext!.findRenderObject()!);
          await tester.pump();
          expect(tester.takeException(), isNull, reason: name);
          await tester.runAsync(() async {
            final image = await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await File('$_output/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        if (label != 'landscape') {
          await mount(const TvHomeScreen());
          await save(label == 'tv' ? 'live-tv' : 'live-tv-phone');
          if (label == 'tv') {
            tester
                .widget<MainNavigationRail>(find.byType(MainNavigationRail))
                .focusNodes['live']!
                .requestFocus();
            await settle();
            for (var i = 0; i < 2; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
              await settle();
            }
            for (final key in [
              'live-navigation-rail',
              'live-categories-rail'
            ]) {
              expect(tester.getSize(find.byKey(ValueKey(key))).width, 0);
            }
            await save('live-tv-expanded');
          }
        }
        await mount(SportsScreen(
            scores: scores, supplement: supplement, standings: standings));
        await save('sports-$label');
        for (final tab in ['schedule', 'standings', 'replays', 'highlights']) {
          await tester.ensureVisible(find.byKey(ValueKey('sports-view-$tab')));
          await tester.tap(find.byKey(ValueKey('sports-view-$tab')));
          await settle();
          if (tab == 'replays' || tab == 'highlights') {
            expect(find.text('No $tab found on air'), findsNothing);
            expect(find.textContaining('Arena Review'), findsWidgets);
          }
          await save('$tab-$label');
        }
        if (label != 'landscape') {
          await mount(const LibraryScreen());
          await save('movies-$label');
          await mount(const LibraryScreen(initialSeries: true));
          await save('series-$label');
          await mount(const SettingsWorkspace());
          await save('settings-$label');
        }
        await tester.pumpWidget(const SizedBox());
        SportsChannelMatcher.disposeShared();
        playback.dispose();
        await tester.pump(const Duration(seconds: 31));
        playlist.dispose();
        guide.dispose();
        prefs.dispose();
        standings.close();
      }, () => MockClient((_) async => http.Response('{"events":[]}', 200)));
    }, skip: _output.isEmpty);
  }
}
