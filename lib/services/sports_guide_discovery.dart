part of 'sports_channel_matcher.dart';

/// A cumulative, immutable view of the guide scan. Exact programme bindings
/// are usable immediately; a partial update never completes the fixture pass.
class SportsGuideDiscovery {
  const SportsGuideDiscovery(this.games, this.matches,
      {required this.complete, this.evidenceVersion, this.validUntil});
  final List<SportsGame> games;
  final Map<String, List<ChannelMatch>> matches;
  final bool complete;
  final Object? evidenceVersion;
  final DateTime? validUntil;
}

Future<void> _prepareGuideCatalogue(
    SportsChannelMatcher matcher, List<Channel> channels) async {
  final byId = <String, int>{}, byGuide = <String, List<int>>{};
  final excluded = <int>{};
  final slice = Stopwatch()..start();
  for (var i = 0; i < channels.length; i++) {
    final channel = channels[i];
    byId[channel.id] = i;
    if (channel.name.trimLeft().startsWith('###') ||
        !Channel.isLiveId(channel.rawId)) {
      excluded.add(i);
    } else {
      (byGuide[normalizeEpgId(channel.epgId)] ??= []).add(i);
    }
    if (slice.elapsedMilliseconds >= matcher._workSliceMs) {
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
  }
  matcher._channels = channels;
  matcher._byId = byId;
  matcher._byEpgId = byGuide;
  matcher._excluded = excluded;
  matcher._names = List.filled(channels.length, '');
  matcher._channelNameFlags = Uint8List(channels.length);
  matcher._hints.clear();
  matcher._groupNames.clear();
  matcher._guideClassifications.clear();
  matcher._discoveryKey = null;
  matcher._preparedFor = 'guide:${identityHashCode(channels)}';
  if (matcher._epg is _WorkerGuide) {
    matcher._epg.reads.configure(byGuide.keys);
  }
}

const _guideSportNames = {
  'football': 'American football',
  'horse-racing': 'Horse racing',
  'rodeo': 'Rodeo',
  'racing': 'Motorsport',
  'tennis': 'Tennis',
  'golf': 'Golf',
  'cricket': 'Cricket',
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
  'padel': 'Padel',
  'pickleball': 'Pickleball',
  'taekwondo': 'Taekwondo',
  'sambo': 'Sambo',
  'sailing': 'Sailing',
  'triathlon': 'Triathlon',
  'cycling': 'Cycling',
  'field-hockey': 'Field hockey',
  'sumo': 'Sumo',
  'skating': 'Ice skating',
  'skiing': 'Skiing',
  'basketball': '3×3 basketball',
  'hockey': 'Ice hockey',
  'australian-football': 'Aussie rules',
  'soccer': 'Football / Soccer',
  'wrestling': 'Wrestling',
  'climbing': 'Climbing',
  'gymnastics': 'Gymnastics',
};
// These broadcasts frequently repeat old sessions without a replay label.
// Require explicit live evidence before placing them beside score-backed games.
const _guideLiveOnlySports = {
  'football',
  'horse-racing',
  'rodeo',
  'cricket',
  'tennis',
  'golf',
  'mma',
  'boxing',
  'racing',
  'sumo',
  'skating',
  'skiing',
  'basketball',
  'padel',
  'pickleball',
  'taekwondo',
  'sambo',
  'sailing',
  'triathlon',
  'hockey',
  'australian-football',
  'soccer',
  'wrestling',
  'climbing',
  'gymnastics',
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

/// No provider requests or SQL. Production runs this in a worker isolate
/// after its cached guide snapshot is ready. Only guide IDs
/// already indexed for visible live channels are visited, not 80k channels for
/// every score poll. Unchanged snapshots reuse the same result until a boundary.
Future<List<SportsGame>> _discoverGuideEvents(SportsChannelMatcher m,
    {void Function(SportsGuideDiscovery)? onProgress,
    SportsMatchPicks? picks,
    Future<void>? resumeAfterPreview}) async {
  void publish(List<SportsGame> games, {required bool complete}) {
    if (onProgress == null) return;
    final decisions = picks ?? _WorkerPicks(const {});
    final visible = complete
        ? games
        : games
            .where((g) =>
                !g.id.startsWith('guide:motor:') ||
                g.event?.session?.isNotEmpty == true)
            .toList(growable: false);
    if (!complete && visible.isEmpty) return;
    onProgress(SportsGuideDiscovery(
        visible,
        {
          for (final game in visible)
            SportsChannelPicks.eventKey(game):
                _exactGuideMatches(m, game, decisions, trackEvidence: false)
                    .where((match) => !m._rejectedMatch(decisions, game, match))
                    .take(8)
                    .toList(growable: false),
        },
        complete: complete,
        validUntil: complete ? m._discoveryUntil : null));
  }

  final now = m._clock();
  final key = (m._preparedFor, m._epg.changeRevision, m._epg.lastUpdated);
  if (key == m._discoveryKey && now.isBefore(m._discoveryUntil ?? now)) {
    publish(m._discovered, complete: true);
    return m._discovered;
  }
  var until = now.add(const Duration(minutes: 5));
  final groups = <String, (String, List<EpgProgram>)>{};
  final classifications = <(String, int), (String, String, String, String?)>{};
  final slice = Stopwatch()..start();
  final publication = Stopwatch()..start();
  final earlyWork = Stopwatch()..start();
  var published = false, dirty = false, previewJoined = false;
  final candidates = <(String, List<int>, EpgProgram, int)>[];
  for (final entry in m._byEpgId.entries) {
    if (slice.elapsedMilliseconds >= m._workSliceMs) {
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
    if (entry.key.isEmpty) continue;
    // Discovery can overlap a scorer awaiting SQL in the same worker. Its
    // catalogue-wide reads are not evidence used to score that fixture batch.
    final guide = m._epg;
    final current = guide is _WorkerGuide
        ? guide.current[entry.key]
        : guide.getCurrentProgram(entry.key);
    final next = guide is _WorkerGuide
        ? guide.next[entry.key]
        : guide.getNextProgram(entry.key);
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
      candidates.add((entry.key, entry.value, p, candidates.length));
    }
  }
  // Coalesced coverage IDs include a chronological group ordinal. Discovering
  // earlier slots later would renumber already visible cards and move focus.
  // Collect cheap references first; only expensive classification is streamed.
  candidates.sort((a, b) {
    final start = a.$3.start.compareTo(b.$3.start);
    return start != 0 ? start : a.$4.compareTo(b.$4);
  });
  earlyWork.reset();
  for (final (guideId, indices, p, _) in candidates) {
    if (dirty && onProgress != null && publication.elapsedMilliseconds >= 100) {
      publish(_guideGamesFromGroups(groups, now), complete: false);
      published = true;
      dirty = false;
      publication.reset();
    }
    if (slice.elapsedMilliseconds >= m._workSliceMs) {
      // Offer the first guide card promptly, then let the first fixture preview
      // finish. A sparse guide cannot monopolise its worker while finding it.
      if (!previewJoined &&
          resumeAfterPreview != null &&
          (published || earlyWork.elapsedMilliseconds >= 100)) {
        previewJoined = true;
        await resumeAfterPreview;
      }
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
    final upcoming = p.start.isAfter(now);
    final title = p.title.trim(), description = p.description ?? '';
    // Unconditional advertisement rejection precedes sport classification.
    // Large PPV catalogues contain thousands of these repeated empty slots.
    if (description.trim().isEmpty && _rollingSlotLabel.hasMatch(title)) {
      continue;
    }
    final channel = m._channels[indices.first];
    final classificationKey = (guideId, p.start.millisecondsSinceEpoch);
    final previous = m._guideClassifications[classificationKey];
    final sport = previous != null &&
            previous.$1 == title &&
            previous.$2 == description &&
            previous.$3 == channel.name
        ? previous.$4
        : extendedGuideSport(title, description,
            channelName: channel.name, includeSessionCoverage: true);
    classifications[classificationKey] =
        (title, description, channel.name, sport);
    if (sport == null || sport == 'rugby') continue;
    if (sport == 'cricket' && !hasNamedTestCricketFixture(title, description)) {
      continue;
    }
    final languageTitle = sportsLanguageText(title);
    if (_guideUnavailable.hasMatch(languageTitle) ||
        _guideStudio.hasMatch(languageTitle)) {
      continue;
    }
    final liveOnly = _guideLiveOnlySports.contains(sport) ||
        (sport == 'cycling' &&
            (cyclocrossPattern.hasMatch(title) ||
                cyclocrossPattern.hasMatch(description)));
    if (upcoming && !liveOnly) {
      continue;
    }
    final poker = sport == 'poker';
    if (liveOnly && !isLiveSportsProgramme(p)) {
      continue;
    }
    if (poker
        ? _pokerReplayLabel.hasMatch(languageTitle)
        : _guideReplay.hasMatch(languageTitle)) {
      continue;
    }
    if (sport == 'racing' &&
        (p.stop.difference(p.start) > const Duration(hours: 26) ||
            _guideReplay.hasMatch(sportsLanguageText(description)))) {
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
    final oldYear =
        _guideOldYear.allMatches(title).any((v) => int.parse(v[0]!) < now.year);
    if (oldYear) continue;
    // Usually a channel-name placeholder. Poker can use its show name here;
    // require a substantive programme description and a finite ordinary slot.
    if (indices.any((i) =>
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
    final leagueKey = sport == 'cricket'
        ? 'test-cricket'
        : sport == 'racing'
            ? enduranceLeagueId(title, description) ?? sport
            : sport == 'baseball'
                ? asianBaseballLeague(title, description) ??
                    asianBaseballLeague(channel.name, '') ??
                    'baseball'
                : sport == 'mma'
                    ? combatGuideLeague(title, description) ?? sport
                    : additionalGuideCompetition(sport, title, description) ??
                        sport;
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
    dirty = true;
    if (onProgress != null &&
        (!published || publication.elapsedMilliseconds >= 100)) {
      publish(_guideGamesFromGroups(groups, now), complete: false);
      published = true;
      dirty = false;
      publication.reset();
    }
  }
  final combined = _guideGamesFromGroups(groups, now);
  m._discoveryKey = key;
  m._guideClassifications = classifications;
  m._discoveryUntil = until;
  m._discovered = combined;
  publish(combined, complete: true);
  return combined;
}

List<SportsGame> _guideGamesFromGroups(
    Map<String, (String, List<EpgProgram>)> groups, DateTime now) {
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
  return List.unmodifiable(combined);
}

/// Programme-to-channel identity is stronger than fuzzy sport/name scoring.
/// Keep all quality variants for the picker, but only while this exact slot is
/// still current. Manual picks remain explicit user choices.
List<ChannelMatch> _exactGuideMatches(
    SportsChannelMatcher m, SportsGame game, SportsMatchPicks picks,
    {bool trackEvidence = true}) {
  final now = m._clock();
  if (game.guideProgrammes.isEmpty ||
      (game.end != null && !game.end!.isAfter(now))) {
    return const [];
  }
  final found = <String, ChannelMatch>{};
  for (final p in game.guideProgrammes) {
    final next = game.state == GameState.pre && p.start.isAfter(now);
    final guide = m._epg;
    final current = !trackEvidence && guide is _WorkerGuide
        ? (next ? guide.next : guide.current)[normalizeEpgId(p.channelId)]
        : next
            ? guide.getNextProgram(p.channelId)
            : guide.getCurrentProgram(p.channelId);
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
          programme: !trackEvidence && m._epg is _WorkerGuide
              ? (m._epg).current[normalizeEpgId(channel.epgId)]
              : m._epg.getCurrentProgram(channel.epgId));
    }
  }
  return m._rankMatches(found.values);
}
