part of 'sports_channel_matcher.dart';

const _guideSportNames = {
  'racing': 'Motorsport',
  'mma': 'MMA',
  'boxing': 'Boxing',
  'poker': 'Poker',
  'darts': 'Darts',
  'esports': 'Esports',
  'action-sports': 'Action sports',
  'billiards': 'Snooker & pool',
  'bowling': 'Bowling',
  'badminton': 'Badminton',
  'table-tennis': 'Table tennis',
  'baseball': 'Asian baseball',
  'netball': 'Netball',
  'handball': 'Handball',
  'squash': 'Squash',
  'cycling': 'Cycling',
  'field-hockey': 'Field hockey',
};
final _guideUnavailable = RegExp(
    r'\b(off[ -]?air|offline|no (?:event|programme|program|information|epg)|coming soon|to be announced|tba|test card|stream ended|event ended|event finished|not broadcasting)\b|(?:^|[|:])\s*(?:ended|finished|upcoming|next)\s*(?:$|[|:])',
    caseSensitive: false);
final _guideReplay = RegExp(
    r'\b(replay|repeat|rebroadcast|encore|highlights?|recaps?|round[ -]?up|trending moments|best of|classic|compilation|top moments|years of)\b',
    caseSensitive: false);
// "Live" is also part of studio-show brands, including delayed EPG repeats.
// It does not establish that a race/session is taking place now.
final _guideStudio = RegExp(
    r'\b(paddock live|paddock pass|chequered flag|checkered flag|ted[’\x27]?s notebook|the f1 show|f1 show|race (?:review|reaction)|post[ -]?(?:race|game|match)|pre[ -]?(?:race|game|match)|pre gara|post gara|warm[ -]?up show|preview show|studio (?:show|discussion)|press conference)\b',
    caseSensitive: false);
final _embeddedGuideStop =
    RegExp(r'\bstop:(\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d)', caseSensitive: false);
// Some providers re-wrap slot/channel advertisements in rolling two-hour
// XMLTV windows. Without a synopsis, these are not evidence of an airing event.
final _rollingSlotLabel = RegExp(
    r'\b(?:ppv|pdc (?:event|board)|flsp|espn\+)\s*\d+',
    caseSensitive: false);
final _pokerReplayLabel =
    RegExp(r'\b(replay|repeat|rebroadcast|encore)\b', caseSensitive: false);
final _guideOldYear = RegExp(r'(?<![\d$€£])\b(?:19|20)\d{2}\b');

bool _sameGuideSlot(EpgProgram a, EpgProgram b) =>
    normalizeEpgId(a.channelId) == normalizeEpgId(b.channelId) &&
    a.start == b.start &&
    a.stop == b.stop &&
    a.title == b.title &&
    a.description == b.description &&
    a.isLive == b.isLive;

/// No provider requests or SQL. Production invokes this inside the existing
/// matching isolate, after its cached guide snapshot is ready. Only guide IDs
/// already indexed for visible live channels are visited, not 80k channels for
/// every score poll. Unchanged snapshots reuse the same result until a boundary.
Future<List<SportsGame>> _discoverGuideEvents(SportsChannelMatcher m) async {
  final now = m._clock();
  final key = (m._preparedFor, m._epg.changeRevision, m._epg.lastUpdated);
  if (key == m._discoveryKey && now.isBefore(m._discoveryUntil ?? now)) {
    return m._discovered;
  }
  var until = now.add(const Duration(minutes: 5));
  final groups = <String, (String, List<EpgProgram>)>{};
  final classifications = <(String, int), (String, String, String, String?)>{};
  final slice = Stopwatch()..start();
  for (final entry in m._byEpgId.entries) {
    if (slice.elapsedMilliseconds >= 3) {
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
    if (entry.key.isEmpty) continue;
    final current = m._epg.getCurrentProgram(entry.key);
    final next = m._epg.getNextProgram(entry.key);
    if (next != null && next.start.isAfter(now) && next.start.isBefore(until)) {
      until = next.start;
    }
    final soonBoundary = next?.start.subtract(const Duration(minutes: 45));
    if (soonBoundary != null &&
        soonBoundary.isAfter(now) &&
        soonBoundary.isBefore(until)) {
      until = soonBoundary;
    }
    for (final p in [
      current,
      if (next != null &&
          next.start.isAfter(now) &&
          next.start.difference(now) <= const Duration(minutes: 45))
        next
    ]) {
      if (p == null) continue;
      final upcoming = p.start.isAfter(now);
      if (!upcoming && !p.isNowPlaying(now)) continue;
      if (p.stop.isBefore(until)) until = p.stop;
      final title = p.title.trim(), description = p.description ?? '';
      final channel = m._channels[entry.value.first];
      final classificationKey = (entry.key, p.start.millisecondsSinceEpoch);
      final previous = m._guideClassifications[classificationKey];
      final sport = previous != null &&
              previous.$1 == title &&
              previous.$2 == description &&
              previous.$3 == channel.name
          ? previous.$4
          : extendedGuideSport(title, description, channelName: channel.name);
      classifications[classificationKey] =
          (title, description, channel.name, sport);
      if (sport == null ||
          sport == 'cricket' ||
          sport == 'rugby' ||
          _guideUnavailable.hasMatch(title) ||
          _guideStudio.hasMatch(title)) {
        continue;
      }
      if (description.trim().isEmpty && _rollingSlotLabel.hasMatch(title)) {
        continue;
      }
      if (upcoming &&
          sport != 'mma' &&
          sport != 'boxing' &&
          sport != 'racing') {
        continue;
      }
      final poker = sport == 'poker';
      // Combat replays run all day on specialist channels. Only a current
      // programme explicitly marked live belongs beside score-backed cards.
      if ((sport == 'mma' || sport == 'boxing' || sport == 'racing') &&
          !isLiveSportsProgramme(p)) {
        continue;
      }
      if (poker
          ? _pokerReplayLabel.hasMatch(title)
          : _guideReplay.hasMatch(title)) {
        continue;
      }
      if (sport == 'racing' &&
          (p.stop.difference(p.start) > const Duration(hours: 26) ||
              _guideReplay.hasMatch(description))) {
        continue;
      }
      // Provider PPV placeholders can repeat an old event inside a new XMLTV
      // slot. A day of tolerance avoids guessing the embedded timestamp's zone.
      final embedded = _embeddedGuideStop.firstMatch(title);
      final stop = embedded == null
          ? null
          : DateTime.tryParse('${embedded[1]!.replaceFirst(' ', 'T')}Z');
      if (stop != null && now.difference(stop) > const Duration(days: 1)) {
        continue;
      }
      final oldYear = _guideOldYear
          .allMatches(title)
          .any((v) => int.parse(v[0]!) < now.year);
      if (oldYear) continue;
      // Usually a channel-name placeholder. Poker can use its show name here;
      // require a substantive programme description and a finite ordinary slot.
      if (entry.value.any((i) =>
              sportsNormalize(m._channels[i].name) == sportsNormalize(title)) &&
          !(poker &&
              p.stop.difference(p.start) <= const Duration(hours: 8) &&
              hasSpecificPokerProgramme(description))) {
        continue;
      }
      if (classifySportsHighlights(p, channel: channel) != null) continue;
      final replay = classifySportsReplay(p, channel: channel);
      if (replay != null &&
          replay.evidence != ReplayEvidence.likely &&
          !(poker && replay.reason.startsWith('Classic event'))) {
        continue;
      }
      // Generic poker programmes can still be "On air" without claiming a
      // live tournament. Known recordings belong to Replays. "Poker Classic"
      // alone can be a tournament name, not evidence of an old recording.
      final leagueKey = sport == 'racing'
          ? enduranceLeagueId(title, description) ?? sport
          : sport == 'baseball'
              ? asianBaseballLeague(title, description) ??
                  asianBaseballLeague(channel.name, '') ??
                  'baseball'
              : sport == 'mma'
                  ? combatGuideLeague(title, description) ?? sport
                  : sport;
      // Exact text + synopsis + airing interval: don't collapse different poker
      // tables, rounds or regional broadcasts merely because the sport matches.
      final identity = jsonEncode([
        leagueKey,
        title.toLowerCase(),
        description,
        p.start.millisecondsSinceEpoch,
        p.stop.millisecondsSinceEpoch,
        p.isLive
      ]);
      (groups[identity] ??= (leagueKey, <EpgProgram>[])).$2.add(p);
    }
  }
  final games = <SportsGame>[];
  for (final entry in groups.entries) {
    final (leagueKey, programmes) = entry.value;
    final p = programmes.first;
    final knownLeague =
        sportsLeagueById(leagueKey) ?? sportsLeagueById('guide.$leagueKey');
    final sport = knownLeague?.espnPath.split('/').first ??
        (const {'npb', 'kbo', 'cpbl'}.contains(leagueKey)
            ? 'baseball'
            : const {'one', 'muay-thai'}.contains(leagueKey)
                ? 'mma'
                : leagueKey);
    final name = knownLeague?.shortName ??
        (switch (leagueKey) {
          'npb' => 'NPB',
          'kbo' => 'KBO',
          'cpbl' => 'CPBL',
          'one' => 'ONE Championship',
          'muay-thai' => 'Muay Thai & kickboxing',
          _ => _guideSportNames[sport]!
        });
    final league = knownLeague ??
        SportsLeague(
            id: 'guide.$leagueKey',
            espnPath: '$sport/guide',
            name: '$name on TV',
            shortName: name,
            logoUrl: '',
            kind: SportsKind.broadcast,
            hasStandings: false,
            source: 'Channel guide');
    final team =
        SportsTeam(id: '', name: p.title, shortName: p.title, abbreviation: '');
    games.add(SportsGame(
        id: 'guide:${sha256.convert(utf8.encode(entry.key)).toString().substring(0, 24)}',
        league: league,
        start: p.start,
        end: p.stop,
        state: p.start.isAfter(now) ? GameState.pre : GameState.live,
        statusText: p.start.isAfter(now)
            ? 'Starting soon · guide'
            : isLiveSportsProgramme(p)
                ? 'Live · guide'
                : 'On air',
        home: team,
        away: team,
        source: 'Channel guide',
        event: SportsEventInfo(title: p.title),
        guideProgrammes: List.unmodifiable(programmes)));
  }
  final combined =
      coalesceOtherGuideCoverage(coalesceMotorsportCoverage(games));
  combined.sort((a, b) {
    final start = a.start.compareTo(b.start);
    return start != 0 ? start : a.id.compareTo(b.id);
  });
  m._discoveryKey = key;
  // Retain only the current/next slots visited in this snapshot. Most TV-guide
  // rows are unchanged at a boundary; avoid reclassifying all their synopses.
  m._guideClassifications = classifications;
  m._discoveryUntil = until;
  return m._discovered = List.unmodifiable(combined);
}

/// Programme-to-channel identity is stronger than fuzzy sport/name scoring.
/// Keep all quality variants for the picker, but only while this exact slot is
/// still current. Manual picks remain explicit user choices.
List<ChannelMatch> _exactGuideMatches(
    SportsChannelMatcher m, SportsGame game, SportsMatchPicks picks) {
  final now = m._clock();
  if (game.guideProgrammes.isEmpty ||
      (game.end != null && !game.end!.isAfter(now))) {
    return const [];
  }
  final found = <String, ChannelMatch>{};
  for (final p in game.guideProgrammes) {
    final current = game.state == GameState.pre && p.start.isAfter(now)
        ? m._epg.getNextProgram(p.channelId)
        : m._epg.getCurrentProgram(p.channelId);
    if (current == null ||
        (!current.isNowPlaying(now) &&
            !(game.state == GameState.pre &&
                current.start.isAfter(now) &&
                current.start.difference(now) <=
                    const Duration(minutes: 45))) ||
        !_sameGuideSlot(current, p)) {
      continue;
    }
    for (final i in m._byEpgId[normalizeEpgId(p.channelId)] ?? const <int>[]) {
      if (m._excluded.contains(i)) continue;
      final channel = m._channels[i];
      final role = game.league.espnPath.startsWith('racing/')
          ? f1FeedKind(channel)
          : null;
      final auxiliary =
          role != null && role != F1Feed.main && role != F1Feed.other;
      found[channel.id] = ChannelMatch(
          channel,
          auxiliary ? MatchReason.league : MatchReason.guide,
          auxiliary ? 190 : 950,
          programme: current,
          detail: auxiliary
              ? f1FeedLabel(role)
              : game.state == GameState.pre
                  ? 'Upcoming coverage · channel guide'
                  : 'Airing this programme · channel guide');
    }
  }
  final picked = picks.channelIdFor(game);
  final i = picked == null ? null : m._byId[picked];
  if (picked != null && i != null) {
    if (!m._excluded.contains(i)) {
      final channel = m._channels[i];
      found[picked] = ChannelMatch(channel, MatchReason.pick, 1000,
          programme: m._epg.getCurrentProgram(channel.epgId));
    }
  }
  return m._rankMatches(found.values);
}
