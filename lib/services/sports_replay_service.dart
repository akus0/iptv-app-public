import '../models/channel.dart';
import '../utils/extended_sports.dart';
import '../models/epg_program.dart';
import '../utils/replay_event_date.dart';
import '../utils/replay_presentation.dart';
import 'epg_service.dart';

enum ReplayEvidence { labelled, historical, likely }

class ReplayClassification {
  const ReplayClassification(
      this.sport, this.title, this.evidence, this.reason);
  final String sport, title, reason;
  final ReplayEvidence evidence;
}

/// A replay identified by its current guide slot and/or dedicated channel.
/// It never borrows an opponent, result or channel match from a live scoreboard.
class SportsReplay {
  const SportsReplay(
      {required this.sport,
      required this.title,
      required this.broadcasts,
      this.eventDate,
      this.evidence = ReplayEvidence.labelled,
      this.reason = 'Guide replay label'});
  final String sport;
  final String title;
  final List<ReplayBroadcast> broadcasts;
  final ReplayEvidence evidence;
  final ReplayEventDate? eventDate;
  final String reason;
  String get id => broadcasts.first.id;
}

class ReplayBroadcast {
  const ReplayBroadcast(this.channel, this.programme);
  final Channel channel;
  final EpgProgram programme;
  String get id => '${channel.id}:${programme.start.millisecondsSinceEpoch}';
}

class ReplaySnapshot {
  const ReplaySnapshot(this.events, this.channelsWithGuide,
      {this.unscheduled = const [], this.highlights = const []});
  final List<SportsReplay> events;

  /// Explicit highlight programmes from the same current-guide scan.
  final List<SportsReplay> highlights;
  final int channelsWithGuide;

  /// Dedicated replay channels with no usable event in the current guide.
  /// These are a directory, never advertised as confirmed events airing now.
  final List<ReplayChannel> unscheduled;
}

class ReplayChannel {
  const ReplayChannel(this.channel, this.sport);
  final Channel channel;
  final String sport;
}

// These caches analyse programme content without a channel argument. Identical
// simulcast listings can share that work; channel-specific fallback analysis
// remains separate. Timing and LIVE changes still invalidate the result.
typedef _ProgrammeKey = (DateTime, DateTime, String, String?, bool);
_ProgrammeKey _programmeKey(EpgProgram p) =>
    (p.start, p.stop, p.title, p.description, p.isLive);

/// Conservative, local-only discovery. Index once per playlist revision and
/// scan the already loaded current guide, never 80k channel queries or streams.
class SportsReplayService {
  SportsReplayService(this.epg);
  final EpgService epg;
  static final _shared = Expando<SportsReplayService>();
  static SportsReplayService shared(EpgService epg) =>
      _shared[epg] ??= SportsReplayService(epg);

  Map<String, List<Channel>> _channels = {};
  Map<String, ReplayChannel> _dedicated = {};
  Set<String> _eventSlots = {};
  Object? _revision;
  final _analysis = <_ProgrammeKey, ReplayClassification?>{};
  final _highlightAnalysis = <_ProgrammeKey, (bool, ReplayClassification?)>{};
  final _dateAnalysis = <_ProgrammeKey, ReplayEventDate?>{};
  final _channelSportContext = <String, bool>{};
  bool _hasSportContext(String name) =>
      _channelSportContext.putIfAbsent(name, () {
        final sports = _sportsIn(name);
        if (sports.contains('table-tennis')) sports.remove('tennis');
        if (sports.contains('field-hockey')) sports.remove('hockey');
        return sports.length == 1;
      });

  ReplayClassification? _classify(EpgProgram p) {
    final key = _programmeKey(p);
    if (_analysis.containsKey(key)) return _analysis[key];
    return _analysis[key] = classifySportsReplay(p, allowLikely: true);
  }

  (bool, ReplayClassification?) _highlights(EpgProgram p) =>
      _highlightAnalysis.putIfAbsent(_programmeKey(p), () {
        final candidate = _highlightLabel.hasMatch(p.title) ||
            _highlightIntro.hasMatch(p.description ?? '') ||
            _knownHighlights(p);
        return (candidate, candidate ? classifySportsHighlights(p) : null);
      });
  ReplayEventDate? _eventDate(EpgProgram p) {
    final key = _programmeKey(p);
    if (_dateAnalysis.containsKey(key)) return _dateAnalysis[key];
    return _dateAnalysis[key] = replayEventDate(p);
  }

  ReplaySnapshot? _cached;
  int _guideRevision = -1;
  int _guideRowsRevision = -1;
  DateTime? _expires;
  Future<void> _queue = Future.value();

  Future<ReplaySnapshot> load(List<Channel> channels,
      {required Object revision, DateTime? at, bool force = false}) {
    final result = _queue
        .then((_) => _load(channels, revision, at ?? DateTime.now(), force));
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  // Collect the oldest keys once. Repeated keys.first calls restart iteration
  // over deleted map slots, making a large eviction unnecessarily expensive.
  static void _trimOldest<K, V>(Map<K, V> cache, int limit) {
    final excess = cache.length - limit;
    if (excess <= 0) return;
    for (final key in cache.keys.take(excess).toList(growable: false)) {
      cache.remove(key);
    }
  }

  Future<ReplaySnapshot> _load(
      List<Channel> channels, Object revision, DateTime now, bool force) async {
    final slice = Stopwatch()..start();
    if (_revision != revision) {
      final index = <String, List<Channel>>{};
      final dedicated = <String, ReplayChannel>{};
      final eventSlots = <String>{};
      for (var i = 0; i < channels.length; i++) {
        final c = channels[i];
        if (Channel.isLiveId(c.rawId) && !c.name.trimLeft().startsWith('###')) {
          (index[normalizeEpgId(c.epgId)] ??= []).add(c);
          final sport = replayChannelSport(c);
          if (sport != null) dedicated[c.id] = ReplayChannel(c, sport);
          if (_eventSlot(c)) eventSlots.add(c.id);
        }
        if (i % 16 == 0 && slice.elapsedMilliseconds >= 3) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      _channels = index;
      _dedicated = dedicated;
      _eventSlots = eventSlots;
      _revision = revision;
      _cached = null;
    }
    final guideRevision = epg.changeRevision;
    final guideRowsRevision = epg.guideRowsLoaded.value;
    if (!force &&
        _cached != null &&
        _guideRevision == guideRevision &&
        _guideRowsRevision == guideRowsRevision &&
        _expires != null &&
        now.isBefore(_expires!)) {
      return _cached!;
    }
    final groups = <String, List<ReplayBroadcast>>{};
    final highlightGroups = <String, List<ReplayBroadcast>>{};
    final highlightLabels = <String, ReplayClassification>{};
    final labels = <String, ReplayClassification>{};
    final unscheduled = Map<String, ReplayChannel>.of(_dedicated);
    var withGuide = 0;
    var expires = now.add(const Duration(seconds: 30));
    var count = 0, mappedCount = 0;
    final current = <EpgProgram>[];
    final liveFixtures = <String>{};
    for (final programme in epg.cachedCurrentProgrammes(now)) {
      current.add(programme);
      if (isLiveSportsProgramme(programme)) {
        final key = _fixtureKey(programme.title);
        if (key != null) liveFixtures.add(key);
      }
      if (current.length % 8 == 0 && slice.elapsedMilliseconds >= 3) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    // Some provider copies omit the sport/category text entirely. Borrow
    // only the sport from a matching, detailed current guide narrative and
    // title. Do not borrow replay evidence, dates, opponents or live state.
    final classified = <EpgProgram, ReplayClassification?>{};
    final copySports = <String, Set<String>>{};
    var inspected = 0;
    for (final programme in current) {
      if (!_channels.containsKey(normalizeEpgId(programme.channelId))) continue;
      final value = _classify(programme);
      classified[programme] = value;
      if (value != null) {
        final key = _guideCopyKey(programme);
        if (key.isNotEmpty) (copySports[key] ??= {}).add(value.sport);
      }
      if (++inspected % 8 == 0 && slice.elapsedMilliseconds >= 3) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    for (final programme in current) {
      if (++count % 8 == 0 && slice.elapsedMilliseconds >= 3) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
      final mapped = _channels[normalizeEpgId(programme.channelId)];
      if (mapped == null || !programme.isNowPlaying(now)) continue;
      withGuide += mapped.length;
      if (programme.stop.isBefore(expires)) expires = programme.stop;
      var explicit = classified[programme];
      if (explicit == null) {
        final sports = copySports[_guideCopyKey(programme)];
        if (sports?.length == 1) {
          explicit = classifySportsReplay(programme,
              matchingGuideSport: sports!.single, allowLikely: true);
        }
      }
      final (highlightCandidate, highlight) = _highlights(programme);
      final fallbacks = <(String, String?), ReplayClassification?>{};
      for (final channel in mapped) {
        if (++mappedCount % 8 == 0 && slice.elapsedMilliseconds >= 3) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
        final clip = highlight ??
            (highlightCandidate && _hasSportContext(channel.name)
                ? classifySportsHighlights(programme, channel: channel)
                : null);
        if (clip != null &&
            !_information.hasMatch(channel.name) &&
            !_unavailable.hasMatch(channel.name)) {
          final key =
              '${clip.sport}|${_normalize(clip.title)}|${_normalize(programme.description ?? '')}';
          highlightLabels[key] = clip;
          (highlightGroups[key] ??= [])
              .add(ReplayBroadcast(channel, programme));
          unscheduled.remove(channel.id);
          continue;
        }
        // Information/highlight channels and explicitly inactive slots never
        // become replay suggestions, even when their guide mentions a sport.
        if (_excludedChannel(channel) ||
            _unavailable.hasMatch(programme.title)) {
          unscheduled.remove(channel.id);
          continue;
        }
        final dedicatedSport = _dedicated[channel.id]?.sport;
        if (explicit == null &&
            dedicatedSport == null &&
            !_hasSportContext(channel.name)) {
          continue;
        }
        final classification = dedicatedSport == null && explicit != null
            ? explicit
            : fallbacks.putIfAbsent(
                (channel.name, dedicatedSport),
                () => classifySportsReplay(programme,
                    channel: channel,
                    dedicatedSport: dedicatedSport,
                    allowLikely: true));
        if (classification == null) {
          // Missing/generic guide: keep the dedicated channel in the clearly
          // labelled directory. A real non-replay programme takes it out.
          if (!_genericProgramme(programme, channel)) {
            unscheduled.remove(channel.id);
          }
          continue;
        }
        // Event slots often retain yesterday's fixture in a rolling guide.
        // An old date or missing LIVE flag is not evidence of replay playback.
        if (_eventSlots.contains(channel.id) &&
            classification.evidence != ReplayEvidence.labelled) {
          unscheduled.remove(channel.id);
          continue;
        }
        // A missing live flag on a simulcast must not turn it into a replay.
        if (classification.evidence == ReplayEvidence.likely &&
            liveFixtures.contains(_fixtureKey(programme.title))) {
          continue;
        }
        unscheduled.remove(channel.id);
        // Exact programme identity only. Keep different dates, divisions and
        // descriptions separate rather than guessing which fixture they mean.
        final key =
            '${classification.sport}|${_normalize(classification.title)}|'
            '${_normalize(programme.description ?? '')}';
        if (labels[key] == null ||
            labels[key]!.evidence.index > classification.evidence.index) {
          labels[key] = classification;
        }
        final broadcasts = groups[key] ??= [];
        broadcasts.add(ReplayBroadcast(channel, programme));
      }
    }
    final events = <SportsReplay>[];
    for (final entry in groups.entries) {
      final broadcasts = entry.value
        ..sort((a, b) {
          if (a.channel.isFavorite != b.channel.isFavorite) {
            return a.channel.isFavorite ? -1 : 1;
          }
          final start = b.programme.start.compareTo(a.programme.start);
          return start != 0 ? start : a.channel.name.compareTo(b.channel.name);
        });
      final label = labels[entry.key]!;
      events.add(SportsReplay(
          sport: label.sport,
          title: label.title,
          evidence: label.evidence,
          reason: label.reason,
          eventDate: _eventDate(broadcasts.first.programme),
          broadcasts: List.unmodifiable(broadcasts)));
    }
    events.sort((a, b) {
      final sport = a.sport.compareTo(b.sport);
      if (sport != 0) return sport;
      final start = b.broadcasts.first.programme.start
          .compareTo(a.broadcasts.first.programme.start);
      return start != 0 ? start : a.title.compareTo(b.title);
    });
    // Providers sometimes append different category/premiere metadata to the
    // same detailed synopsis. Share dates only across an exact event title
    // and narrative, and only when the dated copies agree.
    String narrativeKey(SportsReplay event) {
      final narrative = replaySynopsisForDisplay(
          event.broadcasts.first.programme.description ?? '');
      final explicitFixtureDate = _matchup.hasMatch(event.title) &&
          event.eventDate?.day != null &&
          !event.eventDate!.isGuideDate &&
          !event.eventDate!.isPossible &&
          narrative.length >= 12;
      return narrative.length < 60 && !explicitFixtureDate
          ? ''
          : '${event.sport}|${_normalTitle(event.title)}|${_normalize(narrative)}';
    }

    final dated = <String, Map<String, ReplayEventDate>>{};
    for (final event in events) {
      final date = event.eventDate;
      final key = narrativeKey(event);
      if (key.isNotEmpty && date?.day != null && !date!.isPossible) {
        (dated[key] ??= {})[date.day!.toIso8601String()] = date;
      }
    }
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      final dates = dated[narrativeKey(event)];
      if (event.eventDate != null || dates?.length != 1) continue;
      final date = dates!.values.single;
      events[i] = SportsReplay(
          sport: event.sport,
          title: event.title,
          broadcasts: event.broadcasts,
          evidence: event.evidence,
          reason: event.reason,
          eventDate: ReplayEventDate(date.precision, date.label,
              '${date.source}. Same event title and detailed synopsis on another guide listing.',
              day: date.day, year: date.year, isGuideDate: date.isGuideDate));
    }
    // Consolidate alternate guide copies only when the exact detailed
    // narrative and full calendar date agree. Unknown dates stay separate.
    final merged = <String, SportsReplay>{};
    for (final event in events) {
      final narrative = narrativeKey(event);
      final key = narrative.isNotEmpty &&
              event.eventDate?.day != null &&
              !event.eventDate!.isPossible
          ? '$narrative|${event.eventDate!.day}'
          : event.id;
      final previous = merged[key];
      if (previous == null) {
        merged[key] = event;
        continue;
      }
      final broadcasts = [...previous.broadcasts, ...event.broadcasts]
        ..sort((a, b) {
          if (a.channel.isFavorite != b.channel.isFavorite) {
            return a.channel.isFavorite ? -1 : 1;
          }
          final start = b.programme.start.compareTo(a.programme.start);
          return start != 0 ? start : a.channel.name.compareTo(b.channel.name);
        });
      final strongest =
          event.evidence.index < previous.evidence.index ? event : previous;
      merged[key] = SportsReplay(
          sport: strongest.sport,
          title: strongest.title,
          broadcasts: List.unmodifiable(broadcasts),
          evidence: strongest.evidence,
          reason: strongest.reason,
          eventDate: strongest.eventDate);
    }
    // Reuse analysis across refreshes while bounding retained guide text.
    // Corrections to title, synopsis, timing or LIVE status change the key.
    for (final cache in [_analysis, _highlightAnalysis, _dateAnalysis]) {
      _trimOldest(cache, 4096);
    }
    _trimOldest(_channelSportContext, 8192);
    _guideRevision = guideRevision;
    _guideRowsRevision = guideRowsRevision;
    _expires = expires;
    // Preserve the provider's numeric channel/league order within each sport.
    final directory = unscheduled.values.indexed.toList()
      ..sort((a, b) {
        final sport = a.$2.sport.compareTo(b.$2.sport);
        return sport != 0 ? sport : a.$1.compareTo(b.$1);
      });
    return _cached = ReplaySnapshot(List.unmodifiable(merged.values), withGuide,
        unscheduled: List.unmodifiable(directory.map((e) => e.$2)),
        highlights: List.unmodifiable([
          for (final entry in highlightGroups.entries)
            SportsReplay(
                sport: highlightLabels[entry.key]!.sport,
                title: highlightLabels[entry.key]!.title,
                reason: highlightLabels[entry.key]!.reason,
                // Roundups can cover multiple games. Never invent a single
                // fixture date or send these programmes to score matching.
                broadcasts: List.unmodifiable(entry.value
                  ..sort((a, b) => a.channel.isFavorite != b.channel.isFavorite
                      ? (a.channel.isFavorite ? -1 : 1)
                      : a.channel.name.compareTo(b.channel.name)))),
        ]));
  }
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

String _normalTitle(String title) =>
    _normalize(title).replaceAll(RegExp(r'\s*:\s*|\s+[-–—]\s+'), ':');

String _guideCopyKey(EpgProgram programme) {
  if (!_matchup.hasMatch(programme.title) &&
      !_eventForm.hasMatch(programme.title)) {
    return '';
  }
  final narrative = replaySynopsisForDisplay(programme.description ?? '');
  return narrative.length < 60
      ? ''
      : '${_normalTitle(programme.title)}|${_normalize(narrative)}';
}

final _replayTitle = RegExp(
    r'\b(nba playback|replay|replays|repeat|repeated|rerun|re-run|rebroadcast|re-broadcast|re[ -]?airs?|encore|wiederholung|rediffusion)\b|\[(?:r|rpt)\]|\((?:r|rpt)\)',
    caseSensitive: false);
final _replayDescription = RegExp(
    r'^(?:watch (?:a |the )?)?(?:(?:a |the |full |match |game |race |event |extended )*)(?:replay|repeat|rebroadcast|re-broadcast|rerun|encore)\b|\b(?:full|match|game|race|event) replay (?:of|from)\b',
    caseSensitive: false);
final _notEvent = RegExp(
    r'\b(highlights?|hlts|hls|h/l|final score|soccer saturday|news|previews?|podcast|breakdown|bloopers|award show|round-up|pre-game|pregame|post-game|postgame|magazine|documentary|documentaries|analysis|press conference|sportscenter|sports centre|sportscentre|talk show)\b',
    caseSensitive: false);
final _live = RegExp(r'(^|[\s:\[\(])live([\s:\]\)]|$)', caseSensitive: false);
final _unavailable = RegExp(
    r'\b(off[ -]?air|offline|no (?:event|game|match|broadcast)|not (?:broadcasting|available)|stream (?:ended|offline)|event (?:ended|finished|over)|coming soon|to be announced|tba|test (?:card|channel))\b|(?:^|[\s|:\[(])(?:end|ended|finished|next|upcoming)(?=\s*(?:[|:\]\)–-]|$))',
    caseSensitive: false);
final _eventSlotName = RegExp(
    r'\b(?:ppv|pay[ -]per[ -]view)\b|\b(?:event|match|game)\s*\d+\b',
    caseSensitive: false);
bool _eventSlot(Channel c) =>
    _eventSlotName.hasMatch('${c.name} ${c.group}') ||
    _matchup.hasMatch(c.name);
final _information = RegExp(r'\b(info|information|channel guide|schedule)\b',
    caseSensitive: false);
// A dedicated service name, not a dated PPV listing that happens to contain
// "full event replay". Those stale names cannot establish what's on now.
final _dedicatedName = RegExp(
    r'\b(?:replay|replays|repeat|rebroadcast)(?:\s+(?:(?:channel|english|spanish)\s*)?\d+|\s+24\s*/\s*7)?(?:\s+(?:hd|fhd|uhd|sd|4k|raw|ᴿᴬᵂ))*\s*$',
    caseSensitive: false);
final _genericTitle = RegExp(
    r'^(?:sports?|program(?:me)?(?: information)?|no (?:epg|guide|program(?:me)?)(?: (?:data|information|available))?|no information|unknown|to be announced|tba|replays?|repeat|encore|\-+)$',
    caseSensitive: false);
final _genericReplayTitle = RegExp(
    r'^(?:(?:nfl|nba|nhl|pl|efl[ -]?(?:l1|l2|ch)|laliga|seriea|spfl|national league|sports?|soccer|tennis)\s+)?(?:replays?|repeat|encore)(?:\s+(?:channel\s*)?\d+)?(?:\s+(?:hd|fhd|uhd|sd|4k|raw|ᴿᴬᵂ))*\s*$',
    caseSensitive: false);
final _baseReplaySports = <String, RegExp>{
  'volleyball':
      RegExp(r'\b(volleyball|volley ball|vnl|cev)\b', caseSensitive: false),
  'basketball': RegExp(
      r'\b(basketball|nba|wnba|nbl|euroleague|fiba|raptors in 30)\b',
      caseSensitive: false),
  'football': RegExp(
      r'\b(american football|college football|high school football|nfl|ncaaf|cfl|gridiron)\b',
      caseSensitive: false),
  'soccer': RegExp(
      r'\b(soccer|fútbol|conmebol|sudamericana|libertadores|s[uü]per lig|premier league|la liga|laliga|bundesliga|serie ?a|ligue 1|uefa|fifa|mls|a-league|nwsl|champions league|europa league|fa cup|efl|spfl|scottish premiership|ucl|eredivisie|women.s super league|liverpool.*the match)\b',
      caseSensitive: false),
  'tennis': RegExp(
      r'\b(tennis|atp|wta|wimbledon|davis cup|billie jean king cup)\b',
      caseSensitive: false),
  'hockey': RegExp(r'\b(ice hockey|hockey|nhl|ahl|whl|ohl|iihf)\b',
      caseSensitive: false),
  'cricket': RegExp(r'\b(cricket|ashes|wbbl|ipl|bbl|t20|odi|test match)\b',
      caseSensitive: false),
  'rugby': RegExp(r'\b(rugby|nrl|epcr|urc|six nations|state of origin)\b',
      caseSensitive: false),
  'australian-football': RegExp(
      r'\b(afl|aflw|aussie rules|australian football)\b',
      caseSensitive: false),
  'golf': RegExp(r'\b(golf|pga|lpga|ryder cup|dp world tour)\b',
      caseSensitive: false),
  'racing': RegExp(
      '${motorsportGuidePattern.pattern}|\\btrans am (?:racing|series)\\b',
      caseSensitive: false),
  'pickleball': RegExp(r'\bpickleball\b', caseSensitive: false),
  'action-sports': RegExp(
      r'\b(?:ifsc|sport climbing|climbing world (?:cup|series|championship))\b',
      caseSensitive: false),
  'mma': RegExp(r'\b(mma|ufc|pfl|bellator|one championship)\b',
      caseSensitive: false),
  'boxing': RegExp(r'\bboxing\b', caseSensitive: false),
  'cycling': RegExp(r'\b(cycling|tour de france|giro d.italia|vuelta)\b',
      caseSensitive: false),
  'netball': RegExp(r'\bnetball\b', caseSensitive: false),
  'horse-racing':
      RegExp(r'\b(horse racing|racing replay)\b', caseSensitive: false),
  'billiards':
      RegExp(r'\b(billiards?|snooker|ultimate pool)\b', caseSensitive: false),
  'lacrosse': RegExp(r'\blacrosse\b', caseSensitive: false),
  'softball': RegExp(r'\bsoftball\b', caseSensitive: false),
  'table-tennis': RegExp(r'\btable tennis\b', caseSensitive: false),
  'triathlon': RegExp(r'\btriathlon\b', caseSensitive: false),
  'rodeo': RegExp(r'\brodeo\b', caseSensitive: false),
  'wrestling': RegExp(r'\b(wrestling|wwe|aew)\b', caseSensitive: false),
  'baseball': RegExp(r'\b(baseball|mlb|npb|kbo)\b', caseSensitive: false),
};

// Add discovery vocabulary without replacing established replay aliases (IPL,
// T20, Vuelta, MLB, etc.). Build the small union once, never per programme.
final _sports = <String, RegExp>{
  ..._baseReplaySports,
  for (final e in extendedSportsPatterns.entries)
    e.key: _baseReplaySports.containsKey(e.key)
        ? RegExp(
            '(?:${_baseReplaySports[e.key]!.pattern})|(?:${e.value.pattern})',
            caseSensitive: false)
        : e.value,
};

Set<String> _sportsIn(String text) => {
      for (final e in _sports.entries)
        if (e.value.hasMatch(text)) e.key,
    };

bool _excludedChannel(Channel channel) =>
    !Channel.isLiveId(channel.rawId) ||
    channel.name.trimLeft().startsWith('###') ||
    _notEvent.hasMatch(channel.name) ||
    _information.hasMatch(channel.name) ||
    _unavailable.hasMatch(channel.name);

/// Sport context is only borrowed from a clearly dedicated replay service.
/// A generic sports group, an entertainment Encore channel, or a past event
/// in a dated PPV channel name cannot create a replay event.
String? replayChannelSport(Channel channel) {
  if (!_dedicatedName.hasMatch(channel.name) || _excludedChannel(channel)) {
    return null;
  }
  var sports = _sportsIn(channel.name);
  if (sports.isEmpty) sports = _sportsIn(channel.group);
  return sports.length == 1 ? sports.single : null;
}

bool _genericProgramme(EpgProgram programme, Channel? channel) {
  final title = programme.title.trim();
  return title.isEmpty ||
      _genericTitle.hasMatch(title) ||
      _genericReplayTitle.hasMatch(title) ||
      (channel != null && _normalize(title) == _normalize(channel.name));
}

bool isUnscheduledReplayChannel(Channel channel, EpgProgram? current) =>
    replayChannelSport(channel) != null &&
    (current == null ||
        (!_unavailable.hasMatch(current.title) &&
            _genericProgramme(current, channel)));

String _plainGuideText(String text) =>
    text.replaceAll('ᴸᶦᵛᵉ', ' Live ').replaceAll('ᴺᵉʷ', '').trim();

bool isLiveSportsProgramme(EpgProgram programme) =>
    programme.isLive ||
    _live.hasMatch(_plainGuideText(programme.title)) ||
    RegExp(r'(?:^|\n)\s*live\s+(?:coverage|action|broadcast|from|at)\b',
            caseSensitive: false)
        .hasMatch((programme.description ?? '').trim());

final _matchup =
    RegExp(r'\s(?:v\.?|vs\.?|versus|at|@|c\.)\s', caseSensitive: false);
final _eventForm = RegExp(
    r'\b(finals?|semi[ -]?finals?|quarter[ -]?finals?|demi[ -]?finale|grand prix|round \d|(?:first|second|third|fourth|final) round|practice [123]|qualifying|\d\w* test|game \d|fight night|(?:ufc|glory|lion fight|lfa|bkfc|cage warriors) \d+|classics?|championship|nationals|gala)\b',
    caseSensitive: false);
final _participants = RegExp(r'\b(?:faces?|hosts?|meets?|take on|takes on)\b',
    caseSensitive: false);
final _futureSlot = RegExp(
    r'^(?:upcoming|next (?:game|event|match)|sign off|this is\b)|\bno streams? available\b',
    caseSensitive: false);

String? _fixtureKey(String title) {
  var value = _plainGuideText(title).replaceAll(_live, '').trim();
  if (!_matchup.hasMatch(value)) return null;
  // Strip competition prefixes only; preserve all team/division/date words.
  final match = _matchup.firstMatch(value)!;
  final prefix = value.substring(0, match.start);
  final separators = RegExp(r':\s*|\s[-–]\s').allMatches(prefix).toList();
  if (separators.isNotEmpty) value = value.substring(separators.last.end);
  value = value.replaceAll(_matchup, ' v ');
  return _normalize(value.replaceAll(RegExp(r'[^\w\s]'), ' '));
}

DateTime? _validDate(int year, int month, int day) {
  final d = DateTime.utc(year, month, day);
  return d.year == year && d.month == month && d.day == day ? d : null;
}

/// Only dates referring to this programme, not arbitrary dates mentioned in
/// a team's history. A 36-hour margin admits yesterday's completed coverage
/// after midday UTC, without treating an overnight live match as a replay.
String? _historicalEvidence(EpgProgram p, String title, String description) {
  final airing = p.start.toUtc();
  bool old(DateTime? date) =>
      date != null && airing.difference(date) >= const Duration(hours: 36);
  final date = replayEventDate(p);
  if (date != null && !date.isPossible) {
    if (old(date.day)) return 'Guide event date: ${date.label}';
    if (date.day == null &&
        date.year != null &&
        (date.seasonEnd ?? date.year!) < airing.year) {
      return 'Event from ${date.label}';
    }
  }
  // UK guide descriptions use an event-date suffix such as (23.08).
  // Require an unambiguous day (>12); don't guess US vs UK date ordering.
  final short = RegExp(r'\((\d{2})\.(\d{2})\)\s*$').firstMatch(description);
  if (short != null &&
      int.parse(short[1]!) > 12 &&
      old(_validDate(
          airing.year, int.parse(short[2]!), int.parse(short[1]!)))) {
    return 'Guide event date: ${short[1]}.${short[2]}';
  }
  if (RegExp(r'\bclassics?\b', caseSensitive: false).hasMatch(title) ||
      description.toLowerCase().contains('classic sport event')) {
    return 'Classic event in the guide';
  }
  return null;
}

/// Evaluate the current programme itself across every visible live channel.
/// Missing LIVE alone is never sufficient: inferred entries also need a sport
/// and a recognisable match/session, and remain visibly marked as likely.
ReplayClassification? classifySportsReplay(EpgProgram programme,
    {Channel? channel,
    String? dedicatedSport,
    String? matchingGuideSport,
    bool allowLikely = false}) {
  final title = _plainGuideText(programme.title);
  if (extendedSportsPatterns['poker']!.hasMatch(title) &&
      isExtendedSportFiction(title, programme.description ?? '')) {
    return null;
  }
  final description = (programme.description ?? '').trim();
  final lineEnd = description.indexOf('\n');
  final firstLine =
      lineEnd < 0 ? description : description.substring(0, lineEnd);
  final generic = _genericProgramme(programme, channel);
  final describedEvent = generic &&
      (_matchup.hasMatch(firstLine) ||
          _eventForm.hasMatch(firstLine) ||
          _datedSubtitle.hasMatch(firstLine)) &&
      _sportsIn(title).isNotEmpty;
  // A generic replay label can still carry a specific match in its synopsis.
  // Ordinary "no guide"/channel-name placeholders remain unavailable.
  final describedReplay = _replayTitle.hasMatch(title) &&
      replaySynopsisMatch(title, description) != null;
  if (_knownHighlights(programme) ||
      _notEvent.hasMatch(title) ||
      _information.hasMatch(title) ||
      _unavailable.hasMatch(title) ||
      _futureSlot.hasMatch(title) ||
      isLiveSportsProgramme(programme) ||
      (generic && !describedReplay && !describedEvent)) {
    return null;
  }
  if (RegExp(r'^(?:(?:a|the) )?(?:preview|pre[ -]?game|post[ -]?game|studio discussion|analysis)\b',
              caseSensitive: false)
          .hasMatch(description) ||
      RegExp(r'\bif necessary\b', caseSensitive: false).hasMatch(description) ||
      RegExp(r'^(?:extended |match |game |race )?highlights\b',
              caseSensitive: false)
          .hasMatch(description) ||
      RegExp(r'\bhighlights,? reaction and analysis\b', caseSensitive: false)
          .hasMatch(description) ||
      RegExp(r'\b(?:explore|look back (?:at|on))\b.*\b(?:best races|career|greatest moments)\b',
              caseSensitive: false)
          .hasMatch(description)) {
    return null;
  }
  final recordedPoker =
      _recordedPokerEpisode(title, description, channel?.name);
  final explicit = recordedPoker ||
      _replayTitle.hasMatch(title) ||
      (_replayTitle.hasMatch(firstLine) &&
          RegExp(r'^(?:(?:19|20)\d{2}:|S\d+\s+E\d+|(?:Day|Round|Game) \d+)',
                  caseSensitive: false)
              .hasMatch(firstLine)) ||
      (isCondensedReplay(title, description) &&
          (_matchup.hasMatch(title) ||
              _eventForm.hasMatch(title) ||
              replaySynopsisMatch(title, description) != null)) ||
      _replayDescription.hasMatch(description) ||
      RegExp(r'^(?:another chance to (?:watch|see)|relive\b|replays of\b)',
              caseSensitive: false)
          .hasMatch(description);
  dedicatedSport ??= channel == null ? null : replayChannelSport(channel);
  final titleEvent = _matchup.hasMatch(title) || _eventForm.hasMatch(title);
  final datedSession = RegExp(r'^(?:19|20)\d{2}:\s*\S').hasMatch(firstLine);
  final synopsisEvent = _matchup.hasMatch(description) ||
      _eventForm.hasMatch(description) ||
      _participants.hasMatch(description) ||
      datedSession ||
      recordedPoker;
  // A host mentioning a game/final is not itself event coverage. Providers
  // often append an old series-premiere date to these studio programmes.
  if (!titleEvent &&
      (_nonCoverage.hasMatch(description) ||
          _notEvent.hasMatch(description) ||
          RegExp(r'\b(countdown|sports talk|behind.the.scenes|round.up)\b',
                  caseSensitive: false)
              .hasMatch(description))) {
    return null;
  }
  if (!explicit && dedicatedSport == null && !titleEvent && !synopsisEvent) {
    return null;
  }
  var sports = _sportsIn(title);
  final sportInTitle = sports.isNotEmpty;
  if (sports.isEmpty) {
    sports = _sportsIn(
        description.length > 600 ? description.substring(0, 600) : description);
  }
  // This provider labels some Big 12 condensed games simply "Football".
  // Require both the sport and a named college conference; bare football
  // remains ambiguous internationally and must not turn soccer into NFL.
  if (sports.isEmpty &&
      RegExp(r'\bfootball\b', caseSensitive: false).hasMatch(description) &&
      RegExp(r'\b(?:big 12|big ten|acc|sec)\b', caseSensitive: false)
          .hasMatch('$title $description')) {
    sports = {'football'};
  }
  if (sports.contains('table-tennis')) sports.remove('tennis');
  if (sports.contains('field-hockey')) sports.remove('hockey');
  if (sports.isEmpty && channel != null) sports = _sportsIn(channel.name);
  if (sports.isEmpty && matchingGuideSport != null) {
    sports = {matchingGuideSport};
  }
  if (sports.isEmpty && dedicatedSport != null) sports = {dedicatedSport};
  if (sports.length != 1) return null;
  if (!explicit && dedicatedSport != null && dedicatedSport != sports.single) {
    return null;
  }
  final historical = explicit || dedicatedSport != null
      ? null
      : _historicalEvidence(programme, title, description);
  final eventShape = titleEvent ||
      recordedPoker ||
      ((sportInTitle || describedEvent) && synopsisEvent);
  final ReplayEvidence evidence;
  final String reason;
  if (explicit || dedicatedSport != null) {
    evidence = ReplayEvidence.labelled;
    reason = recordedPoker
        ? 'Recorded poker episode listed in the guide'
        : explicit
            ? 'Replay identified in the guide'
            : 'Dedicated replay channel';
  } else if (historical != null && eventShape) {
    evidence = ReplayEvidence.historical;
    reason = historical;
  } else if ((channel != null || allowLikely) && eventShape) {
    evidence = ReplayEvidence.likely;
    reason =
        'Sports event with no live marker in the guide; replay unconfirmed';
  } else {
    return null;
  }
  final cleaned = title
      .replaceFirst(
          RegExp(r'^\s*(?:replay|repeat|rebroadcast|encore)\s*[:\-–]\s*',
              caseSensitive: false),
          '')
      .replaceAll(
          RegExp(r'\s*[\[(](?:replay|repeat|r|rpt)[\])]\s*',
              caseSensitive: false),
          ' ')
      .trim();
  return ReplayClassification(
      sports.single, cleaned.isEmpty ? title : cleaned, evidence, reason);
}

final _highlightLabel = RegExp(
    r'\b(highlights?|hlts|hls|h/l|recaps?|round[ -]?up|best of|greatest hits)\b',
    caseSensitive: false);
final _highlightExcluded = RegExp(
    r'\b(news|sportscenter|sports ?centre|previews?|podcast|documentar(?:y|ies)|press conference|talk show)\b',
    caseSensitive: false);
final _highlightIntro = RegExp(
    r'^(?:(?:watch |catch |all |the |extended |match |game |race |daily |weekly |best |action[ -]packed )*)highlights\b|^(?:recapping|catch up on)\b.{0,120}\b(?:action|recap)\b.{0,80}\bhighlights?\b|^[^.!?]{0,65}\bfeatures? (?:action[ -]packed |match |game |the |best |weekly )*highlights\b|^catch up on.{0,100}\bcondensed,? highlight[ -]driven version of the game\b',
    caseSensitive: false);

final _quickPitch = RegExp(r'^quick pitch(?:\s*[-:]|$)', caseSensitive: false);
final _baseballHighlight =
    RegExp(r'\b(baseball|mlb|major league)\b', caseSensitive: false);
final _matchOfTheDay =
    RegExp(r'^match of the day(?: 2)?(?:\s*[-:]|$)', caseSensitive: false);
final _tourReview = RegExp(r'^(?:ATP|WTA)(?: Tour)? Review(?:\s*[:–-]|$)',
    caseSensitive: false);
final _collegeFinal =
    RegExp(r'^College Football Final(?:\s|$)', caseSensitive: false);
final _highlightRecap = RegExp(
    r'\b(?:looks? back (?:at|on)|recaps?|recapping|breaks? down)\b[^.!?]{0,160}\bhighlights?\b',
    caseSensitive: false);
final _nonCoverage = RegExp(
    r'\b(?:showcasing|explores?|rediscovers?|tours?)\b[^.!?]{0,120}\b(?:golf club|course|layout|history|career)\b|\b(?:championship (?:golf )?(?:course|layout)|instruction|golf lessons)\b',
    caseSensitive: false);
final _datedSubtitle = RegExp(r'^(?:19|20)\d{2}:\s*\S');
final _pokerEpisode =
    RegExp(r'\bS\d{1,4}\s*E\d+\b|\bSeason \d+\b', caseSensitive: false);
final _pokerShow = RegExp(
    r'\b(?:poker after dark|high stakes poker|world poker tour|world series of poker|triton poker|poker masters|pokerstars)\b',
    caseSensitive: false);
final _pokerPlay = RegExp(
    r'\b(?:cash games?|final table|main event|poker players|no[ -]?limit|NLH)\b',
    caseSensitive: false);
bool _recordedPokerEpisode(String title, String description, String? channel) =>
    _pokerShow.hasMatch('$title ${channel ?? ''}') &&
    _pokerEpisode.hasMatch('$title $description') &&
    _pokerPlay.hasMatch(description) &&
    !isExtendedSportFiction(title, description);

bool _mixedSportsHighlights(EpgProgram p) =>
    RegExp(r'^Gotta See It$', caseSensitive: false).hasMatch(p.title.trim()) &&
    RegExp(r'^must[ -]see moments from the world of sports',
            caseSensitive: false)
        .hasMatch((p.description ?? '').trim());

bool _knownHighlights(EpgProgram p) =>
    _mixedSportsHighlights(p) ||
    _tourReview.hasMatch(_plainGuideText(p.title)) ||
    (_collegeFinal.hasMatch(p.title) &&
        RegExp(r'\bpostgame highlights\b', caseSensitive: false)
            .hasMatch(p.description ?? '')) ||
    (!isLiveSportsProgramme(p) &&
        _highlightRecap.hasMatch(p.description ?? '')) ||
    (_quickPitch.hasMatch(p.title) &&
        _baseballHighlight.hasMatch(p.description ?? '')) ||
    _matchOfTheDay.hasMatch(p.title);

/// Explicit highlight coverage only, never a passing mention in a live match,
/// general news or a channel name. Dates of compilation shows are not game dates.
ReplayClassification? classifySportsHighlights(EpgProgram programme,
    {Channel? channel}) {
  final title = _plainGuideText(programme.title);
  if (extendedSportsPatterns['poker']!.hasMatch(title) &&
      isExtendedSportFiction(title, programme.description ?? '')) {
    return null;
  }
  final description = (programme.description ?? '').trim();
  if (title.isEmpty ||
      _highlightExcluded.hasMatch(title) ||
      _information.hasMatch(title) ||
      _unavailable.hasMatch(title) ||
      _futureSlot.hasMatch(title) ||
      _genericProgramme(programme, channel)) {
    return null;
  }
  final labelled =
      _highlightLabel.hasMatch(title) || _knownHighlights(programme);
  // An explicit highlights synopsis outweighs a stale provider LIVE flag.
  // The anchored pattern does not match incidental "includes highlights"
  // prose inside an otherwise live competition description.
  if (!labelled && !_highlightIntro.hasMatch(description)) {
    return null;
  }
  var sports = _sportsIn(title);
  if (sports.isEmpty && _tourReview.hasMatch(title)) sports = {'tennis'};
  if (sports.isEmpty) {
    sports =
        _sportsIn(description.substring(0, description.length.clamp(0, 600)));
  }
  if (sports.isEmpty && channel != null) sports = _sportsIn(channel.name);
  // These sports are also common dedicated highlight shows in the guide.
  for (final sport in ['archery', 'padel']) {
    if (RegExp('\\b$sport\\b', caseSensitive: false)
        .hasMatch('$title $description')) {
      sports.add(sport);
    }
  }
  if (sports.contains('table-tennis')) sports.remove('tennis');
  if (sports.contains('field-hockey')) sports.remove('hockey');
  if (sports.isEmpty && _mixedSportsHighlights(programme)) sports = {'sports'};
  if (sports.length != 1) return null;
  return ReplayClassification(
      sports.single,
      title,
      ReplayEvidence.labelled,
      labelled
          ? 'Highlights listed in the current guide'
          : 'Guide describes a highlights roundup');
}
