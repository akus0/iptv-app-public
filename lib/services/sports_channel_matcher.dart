import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../utils/extended_sports.dart';
import '../utils/endurance_racing.dart';
import '../utils/motorsport_coverage.dart';
import '../utils/sports_guide_coverage.dart';
import 'sports_replay_service.dart';
import 'dart:isolate';
import 'package:flutter/widgets.dart';
import 'sports_match_inputs.dart';
import 'dart:math' as math;

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/sports.dart';
import '../models/sports_progress.dart';
import '../utils/channel_name_matching.dart';
import '../utils/formula_one.dart';
import '../utils/combat_sports.dart';
import 'epg_service.dart';
import 'storage_service.dart';
import '../l10n/l10n.dart';

part 'sports_matching_worker.dart';
part 'sports_guide_discovery.dart';

/// Why a channel was suggested for a game — shown next to it so the user
/// can judge a match at a glance.
enum MatchReason {
  pick,
  name,
  guide,
  network,
  listing,
  tournament,
  league,
  sport
}

extension MatchReasonLabel on MatchReason {
  String get shortLabel => switch (this) {
        MatchReason.pick => tr('Your pick'),
        MatchReason.name => tr('Event name'),
        MatchReason.guide => tr('EPG match'),
        MatchReason.tournament => tr('Tournament coverage'),
        MatchReason.network => tr('Broadcaster'),
        MatchReason.listing => 'Event TV listing',
        MatchReason.league => tr('Possible league channel'),
        MatchReason.sport => tr('Possible sport channel'),
      };
  String get label => switch (this) {
        MatchReason.pick => tr('Your pick'),
        MatchReason.name => tr('Found by its name'),
        MatchReason.guide => tr('Found in the guide'),
        MatchReason.network => tr('Listed broadcaster'),
        MatchReason.listing => 'Event TV listing',
        MatchReason.tournament => tr('Tournament coverage'),
        MatchReason.league => tr('Possible league channel'),
        MatchReason.sport => tr('Possible sport channel'),
      };
}

class ChannelMatch {
  const ChannelMatch(this.channel, this.reason, this.score,
      {this.detail, this.programme, this.supportingBroadcasts = const []});
  final Channel channel;
  final MatchReason reason;
  final int score;
  final List<String> supportingBroadcasts;

  /// Guide programme title / network name that produced the match.
  final String? detail;
  final EpgProgram? programme;

  /// Event-specific evidence, as opposed to general coverage suggestions.
  bool get isConfident => switch (reason) {
        MatchReason.pick ||
        MatchReason.name ||
        MatchReason.guide ||
        MatchReason.network ||
        MatchReason.listing =>
          true,
        _ => false,
      };
}

class ChannelSearchResult {
  const ChannelSearchResult(this.channel,
      {this.match, this.programme, this.programmeSearchHit = false});
  final Channel channel;
  final ChannelMatch? match;
  final EpgProgram? programme;

  /// True only when programme text contributed to this manual search result.
  /// Retained event evidence alone is not a match for the typed search query.
  final bool programmeSearchHit;
}

/// The user's own game -> channel choices, per viewer. A pick for one game
/// (`events`) wins over a pick for a team (`teams`, "always use TSN 1 for
/// the Canadiens"). Event-named channels are renumbered by providers every
/// day, so those are only ever remembered for the one game.
class SportsChannelPicks implements SportsMatchPicks {
  SportsChannelPicks._(this._storage, this._events, this.teams);

  factory SportsChannelPicks.load(StorageService storage) {
    final events = <String, _EventPick>{};
    final teams = <String, String>{};
    final raw = storage.getSportsChannelPicks();
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final cutoff = DateTime.now()
            .subtract(const Duration(days: 7))
            .millisecondsSinceEpoch;
        (m['events'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
          final p =
              _EventPick((v as Map)['c'] as String, (v['t'] as num).toInt());
          if (p.savedAtMs > cutoff) events[k] = p;
        });
        (m['teams'] as Map<String, dynamic>? ?? {})
            .forEach((k, v) => teams[k] = v as String);
      } catch (_) {
        // Corrupt prefs read back as "no picks", like the other JSON prefs.
      }
    }
    return SportsChannelPicks._(storage, events, teams);
  }

  final StorageService _storage;
  final Map<String, _EventPick> _events;
  final Map<String, String> teams;

  static String eventKey(SportsGame g) => '${g.league.id}:${g.id}';
  static String teamKey(SportsGame g, SportsTeam t) => '${g.league.id}:${t.id}';

  /// Event sports' "always for this series" pick (Sky Sports F1 for every
  /// F1 session). Stored with the team picks, under an empty team id.
  static String seriesKey(SportsGame g) => '${g.league.id}:*';

  /// Channel id the user chose for [g], game pick first, then either team
  /// (event sports: the series).
  @override
  String? channelIdFor(SportsGame g) =>
      _events[eventKey(g)]?.channelId ??
      (g.league.kind != SportsKind.team
          ? teams[seriesKey(g)]
          : teams[teamKey(g, g.first)] ?? teams[teamKey(g, g.second)]);

  Future<void> pickForSeries(SportsGame g, String channelId) {
    _reloadBeforeEdit();
    teams[seriesKey(g)] = channelId;
    _events.remove(eventKey(g));
    return _save();
  }

  Future<void> pickForGame(SportsGame g, String channelId) {
    _reloadBeforeEdit();
    _events[eventKey(g)] =
        _EventPick(channelId, DateTime.now().millisecondsSinceEpoch);
    return _save();
  }

  Future<void> pickForTeam(SportsGame g, SportsTeam t, String channelId) {
    _reloadBeforeEdit();
    teams[teamKey(g, t)] = channelId;
    // A fresh team pick should win over an older pick for this game.
    _events.remove(eventKey(g));
    return _save();
  }

  /// The NFL RedZone pill's chosen channel (hold the pill). Stored with the
  /// team picks under a key no league/team id can produce; null = automatic.
  static const _redZoneKey = 'redzone';
  String? get redZoneChannelId => teams[_redZoneKey];

  Future<void> setRedZone(String? channelId) {
    _reloadBeforeEdit();
    if (channelId == null) {
      teams.remove(_redZoneKey);
    } else {
      teams[_redZoneKey] = channelId;
    }
    return _save();
  }

  Future<void> clearFor(SportsGame g) {
    _reloadBeforeEdit();
    _events.remove(eventKey(g));
    final c = teams[teamKey(g, g.first)];
    final d = teams[teamKey(g, g.second)];
    if (c != null) teams.remove(teamKey(g, g.first));
    if (d != null) teams.remove(teamKey(g, g.second));
    teams.remove(seriesKey(g));
    return _save();
  }

  // Separate Sports routes can retain older pick objects. Read the shared
  // preference immediately before editing, including removals, so a later
  // save cannot discard another route's choice or resurrect a cleared one.
  // SharedPreferences updates its memory synchronously before persisting.
  void _reloadBeforeEdit() {
    final latest = SportsChannelPicks.load(_storage);
    _events
      ..clear()
      ..addAll(latest._events);
    teams
      ..clear()
      ..addAll(latest.teams);
  }

  Future<void> _save() => _storage.setSportsChannelPicks(jsonEncode({
        'events': _events
            .map((k, v) => MapEntry(k, {'c': v.channelId, 't': v.savedAtMs})),
        'teams': teams,
      }));
}

class _EventPick {
  const _EventPick(this.channelId, this.savedAtMs);
  final String channelId;
  final int savedAtMs;
}

/// Lower-case, accent-free, punctuation as spaces, single-spaced and padded
/// with a space each side — so `' red wings '` matches a whole phrase and
/// never the inside of another word.
String sportsNormalize(String s) {
  final buffer = StringBuffer(' ');
  var lastSpace = true;
  // Code-unit checks, not a RegExp per character: this runs over every
  // channel name (tens of thousands) when the tab opens.
  for (final rune in s.toLowerCase().runes) {
    // Decomposed accents must not split a player's name into two words.
    if (rune >= 0x300 && rune <= 0x36f) continue;
    final isAscii = (rune >= 0x61 && rune <= 0x7a) ||
        (rune >= 0x30 && rune <= 0x39) ||
        rune == 0x2b;
    String? ch = isAscii ? String.fromCharCode(rune) : null;
    if (ch == null && rune > 0x7f) ch = _foldAccents[String.fromCharCode(rune)];
    if (ch != null) {
      buffer.write(ch);
      lastSpace = false;
    } else if (!lastSpace) {
      buffer.write(' ');
      lastSpace = true;
    }
  }
  if (!lastSpace) buffer.write(' ');
  return buffer.toString();
}

// "Bruins @ Leafs" is a fixture; "Tennis @ Oct 22" is a date label.
// Keep this separate from general search/canonical channel normalization.
final _fixtureAt = RegExp(
    r'\s*@(?!\s*(?:(?:(?:mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\s+)?(?:\d|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*\d)))\s*',
    caseSensitive: false);
final _fixtureTextCache = <String, String>{};
String _fixtureText(String text) {
  final cached = _fixtureTextCache[text];
  if (cached != null) return cached;
  final value = sportsNormalize(
      text.contains('@') ? text.replaceAll(_fixtureAt, ' vs ') : text);
  // Regional/quality copies repeat the same programme thousands of times.
  // Bound retained text, including unexpectedly large provider titles.
  if (text.length <= 1024) {
    if (_fixtureTextCache.length >= 2048) {
      _fixtureTextCache.remove(_fixtureTextCache.keys.first);
    }
    _fixtureTextCache[text] = value;
  }
  return value;
}

const Map<String, String> _foldAccents = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ç': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ñ': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ß': 'ss',
  'č': 'c',
  'ć': 'c',
  'ď': 'd',
  'đ': 'd',
  'ě': 'e',
  'ğ': 'g',
  'ı': 'i',
  'ł': 'l',
  'ń': 'n',
  'ň': 'n',
  'ř': 'r',
  'š': 's',
  'ś': 's',
  'ť': 't',
  'ů': 'u',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'æ': 'ae',
  'œ': 'oe',
  // Remaining upstream Balkan/Turkish/Polish/Hungarian spellings. Retain
  // our existing single-pass normalizer and decomposed-accent handling.
  'ş': 's',
  'ą': 'a',
  'ę': 'e',
  'ő': 'o',
  'ű': 'u',
  'ț': 't',
  'ș': 's',
  'ă': 'a',
};

/// Streaming-only services ESPN lists that have no linear channel to find.
const Set<String> _streamingOnly = {
  'ESPN+',
  'PEACOCK',
  'PRIME VIDEO',
  'APPLE TV',
  'APPLE TV+',
  'PARAMOUNT+',
  'NETFLIX',
  'DAZN',
  'NFL+',
  'NBA LEAGUE PASS',
  'NHL.TV',
  'MLB.TV',
  'MAX',
  'YOUTUBE',
  'FUBO',
  'ESPN UNLMTD',
};

const Set<String> _englishTags = {
  'us',
  'usa',
  'ca',
  'uk',
  'au',
  'aus',
  'nz',
  'en',
  'english'
};

/// Country/language tags providers put in channel names. Two-letter tags
/// only count as whole words (names are normalized and split on spaces).
const Set<String> _foreignTags = {
  'es',
  'se',
  'fi',
  'de',
  'fr',
  'nl',
  'it',
  'pt',
  'pl',
  'ru',
  'ar',
  'tr',
  'br',
  'mx',
  'dk',
  'no',
  'gr',
  'ro',
  'hu',
  'cz',
  'al',
  'rs',
  'hr',
  'bg',
  'espanol',
  'beisbol',
  'latino',
  'latam',
  'arabic',
  'francais',
};

const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'sept': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Finds IPTV channels using local metadata, strongest evidence first:
/// saved picks; both opponents/event in a channel name or overlapping guide
/// entry; tournament coverage; league/broadcaster; dedicated sport channels.
/// Broad coverage remains explicitly labelled as a suggestion. Event slots
/// naming different opponents, stale dates and dummy headers are not fallbacks.
///
/// Build once per channel list ([prepare]), then [matchDay] per day shown.
class SportsChannelMatcher {
  SportsChannelMatcher(this._epg, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  static SportsChannelMatcher? _shared;

  /// One matcher for the whole app (Sports hub, live list, player side
  /// panel): its channel index and guide-scan cache then survive leaving
  /// Sports — a new one per visit re-indexed every channel and re-ran the
  /// guide scan each time the hub was reopened.
  static SportsChannelMatcher shared(EpgService epg) {
    final m = _shared;
    if (m != null && identical(m._epg, epg)) return m;
    m?.dispose();
    return _shared = SportsChannelMatcher.background(epg);
  }

  factory SportsChannelMatcher.background(EpgService epg,
          {DateTime Function()? clock}) =>
      _BackgroundSportsMatcher(epg, clock: clock);

  static void disposeShared() {
    _shared?.dispose();
    _shared = null;
  }

  void dispose() {}

  final SportsMatchGuide _epg;

  List<Channel> _channels = const [];
  List<String> _names = const [];
  Map<String, List<int>> _tokenIndex = {};
  Map<String, List<int>> _byCanonical = {};
  Map<String, List<int>> _byEpgId = {};
  Map<String, int> _byId = {};
  Set<int> _excluded = {};
  final Map<int, _ChannelHints> _hints = {};
  final Map<String, List<Channel>> _searchCache = {};
  final Map<String, String> _groupNames = {};
  final _manualCache = <String, List<ChannelSearchResult>>{};
  final _relatedCache = <String, (List<int>, DateTime)>{};
  String? _preparedFor;
  Object? _discoveryKey;
  DateTime? _discoveryUntil;
  List<SportsGame> _discovered = const [];
  Map<(String, int), (String, String, String, String?)> _guideClassifications =
      {};
  Future<List<SportsGame>> discoverGuideEvents(
      {void Function(SportsWorkProgress)? onStatus}) async {
    await _prepareQueue;
    return _discoverGuideEvents(this);
  }

  List<ChannelMatch> _guideMatches(SportsGame game, SportsMatchPicks picks) =>
      _exactGuideMatches(this, game, picks);
  Future<void> _prepareQueue = Future.value();
  final Map<String, (Map<String, List<ChannelMatch>>, DateTime)> _matchCache =
      {};
  final Map<String, List<ChannelMatch>> _eventMatchCache = {};
  DateTime? _evidenceBoundary;
  List<String> _tennisGuideIds = const [];
  final _tennisGuideCache = <String, Future<List<EpgProgram>>>{};
  final _tennisGuideCoverage = <String, List<EpgProgram>>{};

  String? guideStatusFor(SportsGame game) {
    if (game.league.kind != SportsKind.tennis || _tennisGuideIds.isEmpty) {
      return null;
    }
    final at = _guideReference(game, _clock());
    if (_tennisGuideCoverage.values.any((rows) =>
        rows.any((p) => !p.start.isAfter(at) && p.stop.isAfter(at)))) {
      return null;
    }
    return 'Tennis guide unavailable for this time';
  }

  void _expireAt(DateTime date, DateTime now) {
    if (date.isAfter(now) &&
        (_evidenceBoundary == null || date.isBefore(_evidenceBoundary!))) {
      _evidenceBoundary = date;
    }
  }

  Channel? channelById(String id) {
    final i = _byId[id];
    return i == null ? null : _channels[i];
  }

  List<Channel> get channels => _channels;
  Iterable<Channel> get skyTennisChannels sync* {
    for (final name in const ['Sky Sports Tennis', 'Sky Sports Main Event']) {
      for (final i in _byCanonical[_networkKey(name)] ?? const <int>[]) {
        if (!_excluded.contains(i)) yield _channels[i];
      }
    }
  }

  /// Only verified UK linear services. Plus feeds and ambiguous regions are
  /// never mapped by a number or a broad substring.
  static String? skyTennisServiceFor(Channel c) {
    if (!_listingCountryFits(
        'United Kingdom', sportsNormalize(c.name), sportsNormalize(c.group))) {
      return null;
    }
    final key = _networkKey(c.name);
    if (key == _networkKey('Sky Sports Tennis')) return '1705';
    if (key == _networkKey('Sky Sports Main Event')) return '1701';
    return null;
  }

  /// Prepare reusable guide state before event feeds arrive. The direct matcher
  /// already reads the local cache; the background implementation snapshots it.
  /// This never performs speculative title queries or changes match results.
  Future<void> primeGuide({void Function(SportsWorkProgress)? onStatus}) =>
      _prepareQueue;

  /// Indexes [channels] (tens of thousands on big providers). Yields to the
  /// event loop in short time slices so a weak box keeps drawing.
  Future<void> prepare(List<Channel> channels,
          {void Function(SportsWorkProgress)? onStatus}) =>
      _prepareQueue = _prepareQueue.then((_) => _prepare(channels, onStatus));

  Future<void> _prepare(List<Channel> channels,
      void Function(SportsWorkProgress)? onStatus) async {
    final progress = SportsProgressReporter(onStatus);
    progress.report(SportsWorkStage.channelIndex, total: channels.length);
    // Check every entry: replacing a middle channel with the same list
    // length used to leave an obsolete index. Yield by elapsed work, not by
    // thousands of rows (which can block a slow TV for many frames).
    final slice = Stopwatch()..start();
    var hash = channels.length;
    for (var i = 0; i < channels.length; i++) {
      final c = channels[i];
      hash = Object.hash(hash, identityHashCode(c), c.epgId);
      if (i % 256 == 0 && slice.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    final signature = '$hash|${channels.length}';
    if (_preparedFor == signature) return;
    final tokenIndex = <String, List<int>>{};
    final byCanonical = <String, List<int>>{};
    final byEpgId = <String, List<int>>{};
    final byId = <String, int>{};
    final excluded = <int>{};
    final names = List<String>.filled(channels.length, '');
    for (var i = 0; i < channels.length; i++) {
      if (i % 32 == 0 && slice.elapsedMilliseconds >= 4) {
        progress.report(SportsWorkStage.channelIndex,
            completed: i, total: channels.length);
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
      final c = channels[i];
      final norm = _fixtureText(c.name);
      names[i] = norm;
      byId[c.id] = i;
      if (c.name.trimLeft().startsWith('###') || !Channel.isLiveId(c.rawId)) {
        excluded.add(i);
        continue;
      }
      for (final t in norm.trim().split(' ')) {
        if (t.length < 2) continue;
        final list = tokenIndex[t] ??= <int>[];
        if (list.isEmpty || list.last != i) list.add(i);
      }
      final canon = _networkKey(c.name);
      if (canon.isNotEmpty) (byCanonical[canon] ??= <int>[]).add(i);
      (byEpgId[normalizeEpgId(c.epgId)] ??= <int>[]).add(i);
    }
    // Publish a complete index atomically; concurrent callers await it.
    _channels = channels;
    _names = names;
    _tokenIndex = tokenIndex;
    _byCanonical = byCanonical;
    _byEpgId = byEpgId;
    _byId = byId;
    _excluded = excluded;
    _hints.clear();
    _searchCache.clear();
    _manualCache.clear();
    _relatedCache.clear();
    _groupNames.clear();
    _guideClassifications.clear();
    _preparedFor = signature;
    // Title reads are scoped to this catalogue in the background worker.
    // A newly enabled playlist can add guide IDs to an otherwise identical
    // time/keyword query, so its old result is no longer complete.
    _guideCache.clear();
    _matchCache.clear();
    _eventMatchCache.clear();
    _tennisGuideCache.clear();
    _tennisGuideCoverage.clear();
    _tennisGuideIds = {
      for (final i in _channelsNaming([' tennis ', ' atp ', ' wta ']))
        if (!_excluded.contains(i) && _channels[i].epgId.isNotEmpty)
          normalizeEpgId(_channels[i].epgId)
    }.take(512).toList();
  }

  /// Name phrases a channel or programme title may use for [t] — nickname
  /// and full name. City names alone are skipped (two New York teams).
  static List<String> _teamPhrases(SportsTeam t, {bool college = false}) {
    final out = <String>{};
    for (final s in [
      t.shortName,
      t.name,
      if (college) ...[t.location ?? '', t.abbreviation],
    ]) {
      final n = sportsNormalize(s);
      if (n.trim().length >= (college ? 3 : 4)) out.add(n);
    }
    if (college) {
      for (final aliases in _schoolAliases) {
        if (aliases.any((a) => out.contains(' $a '))) {
          out.addAll(aliases.map((a) => ' $a '));
        }
      }
      for (final n in out.toList()) {
        // Keep the full form too: retrieval must find either spelling.
        final short = n
            .replaceAll(' saint ', ' st ')
            .replaceAll(' state ', ' st ')
            .replaceAll(' university ', ' univ ');
        out.add(short);
        out.add(n.replaceAll(' s ', 's '));
        out.add(short.replaceAll(' s ', 's '));
        if (n.startsWith(' st ')) {
          final saint = n.replaceFirst(' st ', ' saint ');
          out.add(saint);
          out.add(saint.replaceAll(' s ', 's '));
        }
      }
    }
    return out.toList();
  }

  /// The name groups a channel name or guide title must all contain (one
  /// phrase from each). Team sports: the two teams. Fights: the two
  /// fighters (tennis: players), by full or last name — event channels say
  /// "Allen vs Duncan".
  /// Golf/racing: the event alone ("singapore grand prix").
  static List<List<String>> _nameGroups(SportsGame g) {
    switch (g.league.kind) {
      case SportsKind.team:
        final college = _isCollege(g.league);
        final first = _teamPhrases(g.home, college: college);
        final second = _teamPhrases(g.away, college: college);
        final shared = first.toSet().intersection(second.toSet());
        return [
          first.where((p) => !shared.contains(p)).toList(),
          second.where((p) => !shared.contains(p)).toList(),
        ];
      case SportsKind.fight:
      case SportsKind.tennis:
        final first = _fighterPhrases(g.home);
        final second = _fighterPhrases(g.away);
        final shared = first.toSet().intersection(second.toSet());
        // One mention of "Williams" cannot prove both Williams sisters.
        return [
          first.where((p) => !shared.contains(p)).toList(),
          second.where((p) => !shared.contains(p)).toList(),
        ];
      case SportsKind.broadcast:
      case SportsKind.golf:
      case SportsKind.racing:
        if (g.isScheduleOnly && g.league.kind == SportsKind.racing) {
          return [
            (g.event?.matchingNames ?? const <String>[])
                .map(sportsNormalize)
                .where((n) => n.trim().length >= 5)
                .toList(),
            g.league.seriesPhrases.map(sportsNormalize).toList(),
          ];
        }
        final title = sportsNormalize(g.event?.title ?? g.home.name);
        if (g.league.kind == SportsKind.racing &&
            [g.league.name, g.league.shortName, ...g.league.seriesPhrases]
                .any((name) => sportsNormalize(name) == title)) {
          return [];
        }
        final out = <String>{if (title.trim().length >= 6) title};
        // Sponsors pad the names ("Singapore Airlines Singapore Grand
        // Prix", "Butterfield Bermuda Championship"); guides use the core.
        final words = title.trim().split(' ');
        final gp = title.indexOf(' grand prix ');
        if (gp > 0) {
          final before = title.substring(0, gp).trim().split(' ').last;
          out.add(' $before grand prix ');
        } else if (g.league.kind == SportsKind.golf && words.length > 2) {
          final core = words.sublist(words.length - 2);
          if (core.any((word) => !_MatchTerms._generic.contains(word))) {
            out.add(' ${core.join(' ')} ');
          }
        }
        return [out.toList()];
    }
  }

  static const _nameSuffixes = {'jr', 'sr', 'ii', 'iii', 'iv'};

  static List<String> _fighterPhrases(SportsTeam t) {
    final full = sportsNormalize(t.name);
    final words =
        full.trim().split(' ').where((w) => !_nameSuffixes.contains(w));
    final last = words.isEmpty ? null : words.last;
    final parts = words.toList();
    return {
      if (full.trim().length >= 4) full,
      // Providers often write "Bu, Yunchaokete" or "Struff, Jan-Lennard".
      if (parts.length > 1)
        ' ${parts.last} ${parts.take(parts.length - 1).join(' ')} ',
      if (last != null && last.length >= 2) ' $last ',
      if (parts.length > 1 && last!.length >= 2) ...[
        ' ${parts.first[0]} $last ',
        ' $last ${parts.first[0]} ',
      ],
      if (sportsNormalize(t.shortName).trim().length >= 4)
        sportsNormalize(t.shortName),
    }.toList();
  }

  static DateTime _guideReference(SportsGame game, DateTime now) {
    if (isF1BuildUp(game, now)) return now;
    if (game.league.kind == SportsKind.tennis &&
        game.state == GameState.live &&
        now.difference(game.start).abs() < const Duration(hours: 12)) {
      return now;
    }
    if (game.state == GameState.live &&
        now.isAfter(game.start) &&
        now.isBefore(game.end ?? game.start.add(const Duration(hours: 12)))) {
      return now;
    }
    return game.start;
  }

  /// When a guide programme for [g] may start: around a game's start; a
  /// fight card's main event comes hours after the prelims; a golf round
  /// runs all day, so its day (today's, while it's on).
  (DateTime, DateTime) _guideWindow(SportsGame g) {
    if (g.league.kind == SportsKind.racing && g.end != null) {
      return (g.start.subtract(const Duration(hours: 2)), g.end!);
    }
    if (g.end != null) {
      final time = _clock().toUtc();
      final now = DateTime.utc(time.year, time.month, time.day, time.hour);
      final from = now.isAfter(g.start) &&
              now.isBefore(g.end!.add(const Duration(days: 1)))
          ? now.subtract(const Duration(hours: 2))
          : g.start;
      return (from, from.add(const Duration(hours: 24)));
    }
    // Tennis times are "not before": a match often starts hours late.
    final after = switch (g.league.kind) {
      SportsKind.fight => const Duration(hours: 5),
      SportsKind.tennis => const Duration(hours: 4),
      _ => const Duration(minutes: 30),
    };
    final reference = _guideReference(g, _clock().toUtc());
    final latest = g.start.add(after);
    final liveLatest = reference.add(const Duration(minutes: 30));
    return (
      g.start.subtract(const Duration(minutes: 60)),
      liveLatest.isAfter(latest) ? liveLatest : latest
    );
  }

  /// Channel indexes whose name contains one of [phrases] as whole words.
  Set<int> _channelsNaming(List<String> phrases) {
    return _naming(phrases, _names, _tokenIndex);
  }

  /// A date written in an event channel's name ("Oct 13", "13 Oct",
  /// "2026-10-13"), or null. Lets yesterday's leftover event channels — and the
  /// next meeting of the same two teams — be told apart from today's.
  static ({int? year, int month, int day, bool ambiguous})? _dateInName(
      String norm) {
    final m1 = RegExp(
            r' (jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]* (\d{1,2}) ')
        .firstMatch(norm);
    if (m1 != null) {
      return (
        year: null,
        month: _months[m1.group(1)]!,
        day: int.parse(m1.group(2)!),
        ambiguous: false
      );
    }
    final m2 = RegExp(
            r' (\d{1,2}) (jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]* ')
        .firstMatch(norm);
    if (m2 != null) {
      return (
        year: null,
        month: _months[m2.group(2)]!,
        day: int.parse(m2.group(1)!),
        ambiguous: false
      );
    }
    // ISO "2026-10-13" (normalized to " 2026 10 13 ").
    final m3 = RegExp(r' (20\d\d) (\d{1,2}) (\d{1,2}) ').firstMatch(norm);
    if (m3 != null) {
      final month = int.parse(m3.group(2)!);
      final day = int.parse(m3.group(3)!);
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return (
          year: int.parse(m3.group(1)!),
          month: month,
          day: day,
          ambiguous: false
        );
      }
    }
    final numeric = RegExp(r' (\d{1,2}) (\d{1,2}) (20\d\d) ').firstMatch(norm);
    if (numeric != null) {
      final first = int.parse(numeric[1]!);
      final second = int.parse(numeric[2]!);
      if (first >= 1 &&
          first <= 31 &&
          second >= 1 &&
          second <= 31 &&
          (first <= 12 || second <= 12)) {
        return (
          year: int.parse(numeric[3]!),
          month: second <= 12 ? second : first,
          day: second <= 12 ? first : second,
          ambiguous: first <= 12 && second <= 12
        );
      }
    }
    return null;
  }

  static bool _dateFits(
      ({int? year, int month, int day, bool ambiguous}) d, DateTime startUtc) {
    // The name's date may be the provider's local date, Eastern time, or
    // Europe's next day for an evening game — any of start-1d..start+1d.
    for (final offset in const [-1, 0, 1]) {
      final day = startUtc.add(Duration(days: offset));
      if (d.year != null && day.year != d.year) continue;
      if (day.month == d.month && day.day == d.day) return true;
      if (d.ambiguous && day.month == d.day && day.day == d.month) return true;
    }
    return false;
  }

  bool _dateFitsEvent(({int? year, int month, int day, bool ambiguous}) date,
          SportsGame game) =>
      _dateFits(
          date,
          game.end == null
              ? game.start
              : _guideReference(game, _clock().toUtc()));

  /// Providers carry the same game in many languages; the app's audience
  /// watches North American / English feeds, so those rank first and
  /// obviously foreign ones (country tags in the name) sink. Only reorders —
  /// nothing is dropped except for network matches.
  int _regionBias(int index) {
    final tokens = _names[index].trim().split(' ');
    var bias = 0;
    for (final t in tokens) {
      if (_englishTags.contains(t)) bias = math.max(bias, 10);
      if (_foreignTags.contains(t)) return -30;
    }
    return bias;
  }

  _ChannelHints _channelHints(int i) => _hints.putIfAbsent(i, () {
        final c = _channels[i];
        final name = _names[i];
        final date = _dateInName(name);
        final persistent = date == null &&
            !_fixtureSeparator.hasMatch(name) &&
            !_placeholder.hasMatch(name) &&
            !_idleWords.hasMatch(name) &&
            !RegExp(r' (?:ppv|day|court|round|next|end|live) ')
                .hasMatch(name) &&
            name.trim().split(' ').length <= 9;
        return _ChannelHints(
            _groupNames.putIfAbsent(c.group, () => sportsNormalize(c.group)),
            date,
            _regionBias(i),
            persistent,
            _networkKey(c.name));
      });

  bool _eligible(int i, SportsGame game) {
    if (_excluded.contains(i)) return false;
    final name = _names[i];
    if (_idleWords.hasMatch(name)) return false;
    if (game.state != GameState.post &&
        (_replayWords.hasMatch(name) || name.startsWith(' end '))) {
      return false;
    }
    final date = _channelHints(i).date;
    return date == null || _dateFitsEvent(date, game);
  }

  /// Only exact, current programme evidence may supersede a stale dynamic
  /// slot's display name. Headers/non-live IDs remain excluded; an idle or
  /// recorded current guide never qualifies. Name/coverage matching is unchanged.
  bool _exactGuideEligible(int i, SportsGame game, EpgProgram p) {
    if (_eligible(i, game)) return true;
    if (_excluded.contains(i)) return false;
    final date = _channelHints(i).date;
    if (date == null || _dateFitsEvent(date, game)) return false;
    if (game.league.kind != SportsKind.tennis) {
      // Rotating PPV slot names can be weeks old even in a freshly downloaded
      // playlist. A current guide fixture is stronger evidence than that label.
      // The caller has already checked opponents/event, sport and session.
      final reference = _guideReference(game, _clock());
      final title = _fixtureText(p.title);
      final listedDate = _dateInName(title);
      return !p.start.isAfter(reference) &&
          p.stop.isAfter(reference) &&
          !_nonLiveCoverage(p) &&
          (listedDate == null || _dateFitsEvent(listedDate, game));
    }
    if (game.league.kind != SportsKind.tennis ||
        _idleWords.hasMatch(_names[i]) ||
        _replayWords.hasMatch(_names[i]) ||
        _names[i].startsWith(' end ')) {
      return false;
    }
    return tennisProgrammeIsExact(game, p, requireTournament: true);
  }

  /// Shared by the local guide and optional first-party linear schedules.
  /// One player pair, or an explicit tournament + single-court guide slot.
  /// A numbered channel is never treated as a court assignment.
  static bool tennisProgrammeIsExact(SportsGame game, EpgProgram p,
      {bool requireTournament = false}) {
    if (game.league.kind != SportsKind.tennis || _nonLiveCoverage(p)) {
      return false;
    }
    final title = _fixtureText(p.title);
    // SQL uses bounded synopses. A boundary-length value may omit a second
    // fixture; it cannot establish an exact match from introductory copy.
    if (!_otherFixture(title) &&
        ((p.description?.length ?? 0) >= 640 || p.description?.length == 320)) {
      return false;
    }
    final text = _otherFixture(title)
        ? title
        : '$title${sportsNormalize(_guideDescription(p))}';
    final terms = _MatchTerms(game);
    if (terms.conflicts(game, text) || _idleWords.hasMatch(text)) {
      return false;
    }
    if (requireTournament && !terms.event.any(text.contains)) return false;
    final date = _dateInName(text);
    if (date != null && !_dateFits(date, game.start)) return false;
    final court = _MatchTerms._court(sportsNormalize(game.event?.court ?? ''));
    if (court != null &&
        court == _MatchTerms._court(text) &&
        terms.event.any(text.contains) &&
        // Tennis Channel's "Center Court" show covers multiple tournaments.
        // Its title is not evidence of a dedicated centre-court feed.
        !_tennisCourtBrand.hasMatch(title) &&
        !text.contains(' around the world ') &&
        !_otherFixture(text) &&
        !_tennisPair.hasMatch(text) &&
        !RegExp(r' court (?:no )?\d+ (?:and|to|or|\d)').hasMatch(text) &&
        !_multiTennis.hasMatch(text)) {
      return true;
    }
    if (!_opponentsFit(game, _nameGroups(game), text)) return false;
    // Require a single relational phrase. An introductory matchup in a title
    // can be trusted independently of incidental historical synopsis copy.
    final pairs = _tennisPair.allMatches(text).toList();
    if (pairs.length != 1 || _multiTennis.hasMatch(text)) return false;
    final separator = pairs.single;
    final before = '${text.substring(0, separator.start)} ';
    final after = ' ${text.substring(separator.end)}';
    final groups = _nameGroups(game);
    // A different explicit initial must not fall back to the shared surname.
    for (final player in [game.home, game.away]) {
      final words = sportsNormalize(player.name).trim().split(' ');
      if (words.length < 2) continue;
      final initials = RegExp(' ([a-z]) ${RegExp.escape(words.last)} ')
          .allMatches(text)
          .map((m) => m[1]);
      if (initials.isNotEmpty &&
          !initials.contains(words.first[0]) &&
          !text.contains(sportsNormalize(player.name))) {
        return false;
      }
    }
    return (groups[0].any(before.contains) && groups[1].any(after.contains)) ||
        (groups[1].any(before.contains) && groups[0].any(after.contains));
  }

  /// Manual search chips use the same event metadata as automatic matching.
  static bool tennisListingFits(
      SportsGame game, String title, String tournament) {
    if (game.league.kind != SportsKind.tennis) return false;
    final terms = _MatchTerms(game);
    final text = sportsNormalize(title);
    if (_replayWords.hasMatch(text) || terms.conflicts(game, text)) {
      return false;
    }
    if (_otherFixture(text)) {
      return _opponentsFit(game, _nameGroups(game), text) &&
          (tournament.isEmpty ||
              terms.event.any(sportsNormalize(tournament).contains));
    }
    return terms.event.any(text.contains);
  }

  static List<String> searchSuggestions(SportsGame game) {
    String player(SportsTeam t) {
      final words = t.name.split(RegExp(r'\s+'));
      return words.last.length >= 3 ? words.last : t.name;
    }

    final terms = _MatchTerms(game);
    final suggestions = <String>[
      if (!game.league.isField) ...[
        game.league.kind == SportsKind.team
            ? game.first.shortName
            : player(game.first),
        game.league.kind == SportsKind.team
            ? game.second.shortName
            : player(game.second),
      ],
      game.league.shortName,
      if (game.event?.title.isNotEmpty == true) game.event!.title,
      ...terms.event
          .where((p) => p.trim().split(' ').length == 1)
          .map((p) => p.trim()),
      ...terms.sport.map((p) => p.trim()),
      ...game.broadcasts.take(4),
    ];
    final seen = <String>{};
    return suggestions
        .where((s) => s.trim().isNotEmpty && seen.add(sportsNormalize(s)))
        .toList();
  }

  /// Share the paged guide lookup across concurrent callers and reuse its
  /// results for 15 minutes. The exact scorer still checks each programme's
  /// time window; a score/clock tick does not need another database scan.
  final Map<String, (Future<List<EpgProgram>>, DateTime)> _guideCache = {};
  int get _guideQueryRevision =>
      _epg is _WorkerGuide ? _epg.queryRevision : _epg.changeRevision;

  Future<List<EpgProgram>> _guideHits(
      DateTime from, DateTime to, Set<String> terms) {
    // Live reference times advance on every score tick. Query a stable hour
    // envelope, then apply precise programme windows in the scorer below.
    from = DateTime.fromMillisecondsSinceEpoch(
        from.millisecondsSinceEpoch ~/ 3600000 * 3600000,
        isUtc: true);
    to = DateTime.fromMillisecondsSinceEpoch(
        (to.millisecondsSinceEpoch ~/ 3600000 + 1) * 3600000,
        isUtc: true);
    // A guide refresh changes lastUpdated: rescan at once, not after 15 min.
    final key =
        '${_epg.lastUpdated?.millisecondsSinceEpoch}|$_guideQueryRevision|'
        '${from.millisecondsSinceEpoch}|${to.millisecondsSinceEpoch}|'
        '${(terms.toList()..sort()).join('\u0001')}';
    final now = _clock();
    _guideCache.removeWhere(
        (_, v) => now.difference(v.$2) > const Duration(minutes: 15));
    final hit = _guideCache[key];
    if (hit != null) return hit.$1;
    late final Future<List<EpgProgram>> future;
    future = _epg
        .findProgrammesByTitle(from, to, terms.toList())
        .catchError((Object error, StackTrace stack) {
      if (identical(_guideCache[key]?.$1, future)) _guideCache.remove(key);
      Error.throwWithStackTrace(error, stack);
    });
    _guideCache[key] = (future, now);
    while (_guideCache.length > 8) {
      _guideCache.remove(_guideCache.keys.first);
    }
    return future;
  }

  /// Suggestions for every game in [games], keyed by
  /// [SportsChannelPicks.eventKey], best first, at most [limit] each.
  // Retain bounded scoreboard identities across progressive/rematch batches.
  final _knownTennisTerms = <String, DateTime>{};

  /// Inputs that affect channel evidence. Score/clock updates deliberately do
  /// not invalidate matching; fixture, broadcast and manual-pick changes do.
  static String matchingIdentity(SportsGame g, SportsMatchPicks picks,
          {bool includeBroadcasts = true, bool includePick = true}) =>
      jsonEncode([
        g.league.id,
        g.id,
        g.start.millisecondsSinceEpoch,
        g.end?.millisecondsSinceEpoch,
        g.home.name,
        g.home.shortName,
        g.home.location,
        g.home.abbreviation,
        g.away.name,
        g.away.shortName,
        g.away.location,
        g.away.abbreviation,
        g.event?.title,
        g.event?.venue,
        g.event?.court,
        g.event?.session,
        g.event?.matchingNames,
        g.state.name,
        if (g.guideProgrammes.isNotEmpty)
          [
            for (final p in g.guideProgrammes)
              [
                p.channelId,
                p.start.millisecondsSinceEpoch,
                p.stop.millisecondsSinceEpoch,
                p.title,
                p.description,
                p.isLive
              ]
          ],
        if (includeBroadcasts) g.broadcasts,
        if (includeBroadcasts)
          [for (final listing in g.onlineBroadcasts) listing.evidenceKey],
        if (includePick) picks.channelIdFor(g)
      ]);

  Future<Map<String, List<ChannelMatch>>> matchDay(
      List<SportsGame> games, SportsMatchPicks picks,
      {int limit = 8,
      bool includeGuide = true,
      bool includePossible = false,
      void Function(Map<String, List<ChannelMatch>> matches)? onProgress,
      void Function(SportsWorkProgress)? onStatus}) async {
    final progress = SportsProgressReporter(onStatus);
    progress.report(
        includeGuide ? SportsWorkStage.guide : SportsWorkStage.matching);
    await _prepareQueue;
    final now = _clock();
    if (_evidenceBoundary != null && !now.isBefore(_evidenceBoundary!)) {
      _matchCache.clear();
      _eventMatchCache.clear();
      _evidenceBoundary = null;
    }
    for (final g in games) {
      if (g.isGuideEvent && g.end != null) _expireAt(g.end!, now);
      for (final p in g.guideProgrammes) {
        _expireAt(p.start, now);
        _expireAt(p.stop, now);
      }
      if (isFormulaOne(g)) {
        _expireAt(g.start.subtract(f1BuildUpLead(g)), now);
        _expireAt(g.start, now);
        _expireAt(
            g.end ?? g.start.add(f1SessionDuration(g.event?.session)), now);
      }
      for (final b in g.onlineBroadcasts) {
        if (b.expiresAt != null) _expireAt(b.expiresAt!, now);
        if (b.programme != null) {
          _expireAt(b.programme!.start, now);
          _expireAt(b.programme!.stop, now);
        }
      }
    }
    final allGames = games;
    _knownTennisTerms
        .removeWhere((_, at) => now.difference(at) > const Duration(hours: 24));
    for (final g in games.where((g) => g.league.kind == SportsKind.tennis)) {
      for (final term in _MatchTerms._eventTerms(g)) {
        _knownTennisTerms[term] = now;
      }
    }
    while (_knownTennisTerms.length > 256) {
      _knownTennisTerms.remove(_knownTennisTerms.keys.first);
    }
    final tennisTerms = _knownTennisTerms.keys.toList()..sort();
    final tennisIdentity = jsonEncode(tennisTerms);
    final generation = jsonEncode([
      now.millisecondsSinceEpoch ~/ 300000,
      _preparedFor,
      _epg.lastUpdated?.millisecondsSinceEpoch,
      _epg.changeRevision,
      limit,
      includePossible,
    ]);
    final eventKeys = {
      for (final g in games)
        SportsChannelPicks.eventKey(g):
            '$generation:${g.league.kind == SportsKind.tennis ? tennisIdentity : ''}:${matchingIdentity(g, picks)}',
    };
    final cacheKey = eventKeys.values.join('\u0001');
    final fullHit = _matchCache['full:$cacheKey'];
    final hit =
        fullHit ?? (includeGuide ? null : _matchCache['quick:$cacheKey']);
    if (hit != null && now.difference(hit.$2) < const Duration(minutes: 15)) {
      return hit.$1;
    }
    final indexVersion = _preparedFor;
    final out = <String, List<ChannelMatch>>{};
    if (games.isEmpty) return out;
    final missing = <SportsGame>[];
    for (final game in games) {
      final id = SportsChannelPicks.eventKey(game);
      final key = eventKeys[id]!;
      if (game.isGuideEvent) {
        out[id] = _guideMatches(game, picks).take(math.max(0, limit)).toList();
        continue;
      }
      final cached = _eventMatchCache['full:$key'] ??
          (includeGuide ? null : _eventMatchCache['quick:$key']);
      if (cached != null) {
        out[id] = cached;
      } else {
        missing.add(game);
      }
    }
    if (missing.isEmpty) {
      final resolved = _resolveFeedConflicts(out, allGames);
      _matchCache['${includeGuide ? 'full' : 'quick'}:$cacheKey'] =
          (resolved, now);
      while (_matchCache.length > 8) {
        _matchCache.remove(_matchCache.keys.first);
      }
      return resolved;
    }
    // Tennis confidence depends on all simultaneous fixtures. Publish those
    // together after conflict resolution, never expose an early false certainty.
    final tennisKeys = allGames
        .where((g) => g.league.kind == SportsKind.tennis)
        .map(SportsChannelPicks.eventKey)
        .toSet();
    final liveSingleKeys = allGames
        .where((g) => g.state == GameState.live && !g.league.isField)
        .map(SportsChannelPicks.eventKey)
        .toSet();
    final progressClock = Stopwatch()..start();
    void publishProgress() {
      if (onProgress == null) return;
      final checked = _resolveFeedConflicts(out, allGames);
      final incomplete = out.length < allGames.length;
      List<ChannelMatch> progressMatches(
          String key, List<ChannelMatch> matches) {
        bool pending(ChannelMatch m) =>
            m.reason == MatchReason.network || m.reason == MatchReason.listing;
        if (!incomplete ||
            !liveSingleKeys.contains(key) ||
            !matches.any(pending)) {
          return matches;
        }
        return [
          for (final match in matches)
            if (pending(match))
              ChannelMatch(
                  match.channel, MatchReason.league, math.min(match.score, 300),
                  detail: 'Checking other live fixtures',
                  programme: match.programme,
                  supportingBroadcasts: match.supportingBroadcasts)
            else
              match
        ];
      }

      onProgress({
        for (final entry in checked.entries)
          if (!tennisKeys.contains(entry.key))
            entry.key: progressMatches(entry.key, entry.value)
      });
      progressClock.reset();
    }

    if (out.isNotEmpty) publishProgress();
    games = missing;

    final contexts = {for (final g in games) g: _MatchTerms(g, tennisTerms)};
    final groupsByGame = {for (final g in games) g: _nameGroups(g)};
    // Query the local guide once, with deduplicated discriminating words.
    // Unlike whole SQL phrases, these also find punctuation/reversed names.
    final raw = <String>{};
    for (final g in games) {
      final groups = groupsByGame[g]!;
      for (final phrase in [
        ...groups.expand((group) => group),
        ...contexts[g]!.all,
      ]) {
        final words = phrase
            .trim()
            .split(' ')
            .where((w) => w.length >= 3)
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
        if (words.isNotEmpty) raw.add(words.first);
      }
      // SQLite LIKE does not fold accents. Keep the original surname too.
      for (final name in [g.home.name, g.home.shortName]) {
        final last = name.toLowerCase().split(RegExp(r'[\s-]+')).last;
        if (last.length >= 3) raw.add(last);
      }
    }
    final byLength = raw.toList()..sort((a, b) => a.length.compareTo(b.length));
    final terms = <String>{};
    for (final t in byLength) {
      if (!terms.any(t.contains)) terms.add(t);
    }
    var earliest = _guideWindow(games.first).$1;
    var latest = _guideWindow(games.first).$2;
    for (final g in games) {
      final (from, to) = _guideWindow(g);
      if (from.isBefore(earliest)) earliest = from;
      if (to.isAfter(latest)) latest = to;
    }
    progress.report(SportsWorkStage.guide);
    final List<EpgProgram> titleProgrammes = !includeGuide || _byEpgId.isEmpty
        ? const []
        : await _guideHits(earliest, latest, terms);
    var tennisProgrammes = const <EpgProgram>[];
    if (includeGuide &&
        _tennisGuideIds.isNotEmpty &&
        games.any((g) => g.league.kind == SportsKind.tennis)) {
      progress.report(SportsWorkStage.tennisGuide);
      final key = '$_preparedFor|$_guideQueryRevision|${_epg.lastUpdated}|'
          '${earliest.millisecondsSinceEpoch ~/ 3600000}|'
          '${latest.millisecondsSinceEpoch ~/ 3600000}|'
          '${now.millisecondsSinceEpoch ~/ 600000}';
      try {
        tennisProgrammes = await (_tennisGuideCache[key] ??=
            _epg.findSportsProgrammesForChannels(
                _tennisGuideIds,
                DateTime.fromMillisecondsSinceEpoch(
                    earliest.millisecondsSinceEpoch ~/ 3600000 * 3600000),
                DateTime.fromMillisecondsSinceEpoch(
                    (latest.millisecondsSinceEpoch ~/ 3600000 + 1) * 3600000)));
      } catch (_) {
        _tennisGuideCache.remove(key);
        rethrow;
      }
      while (_tennisGuideCache.length > 4) {
        _tennisGuideCache.remove(_tennisGuideCache.keys.first);
      }
      _tennisGuideCoverage.clear();
      for (final p in tennisProgrammes) {
        (_tennisGuideCoverage[p.channelId] ??= []).add(p);
      }
    }
    // Current synopses are already cached (and sent once to the worker).
    // Include their bounded fixture text without another database/network scan.
    final synopsisProgrammes = <EpgProgram>[];
    if (includeGuide && games.any((g) => g.league.kind == SportsKind.team)) {
      final slice = Stopwatch()..start();
      for (final id in _byEpgId.keys) {
        final p = _epg.getCurrentProgram(id);
        if (p != null &&
            p.description?.isNotEmpty == true &&
            p.stop.isAfter(earliest) &&
            p.start.isBefore(latest)) {
          final title = _fixtureText(p.title);
          if (_guideIdentity(p, title) != title) synopsisProgrammes.add(p);
        }
        if (slice.elapsedMilliseconds >= 4) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
    }
    final programmes = <String, EpgProgram>{
      for (final p in [
        ...titleProgrammes,
        ...tennisProgrammes,
        ...synopsisProgrammes
      ])
        if (_byEpgId.containsKey(normalizeEpgId(p.channelId)))
          '${p.channelId}|${p.start.millisecondsSinceEpoch}': p,
    }.values.toList();
    if (indexVersion != _preparedFor) {
      return matchDay(allGames, picks,
          limit: limit,
          includeGuide: includeGuide,
          includePossible: includePossible,
          onProgress: onProgress,
          onStatus: onStatus);
    }
    final titles = <String>[];
    final guideIdentities = <String>[];
    final coverageKinds = <EpgProgram, bool>{};
    final programmesByChannel = <String, List<EpgProgram>>{};
    bool recorded(EpgProgram p) =>
        coverageKinds.putIfAbsent(p, () => _nonLiveCoverage(p));
    final titleIndex = <String, List<int>>{};
    final courtIndex = <String, List<int>>{};
    final slice = Stopwatch()..start();
    progress.report(SportsWorkStage.programmes, total: programmes.length);
    for (final (i, programme) in programmes.indexed) {
      if (i % 128 == 0) {
        progress.report(SportsWorkStage.programmes,
            completed: i, total: programmes.length);
      }
      (programmesByChannel[normalizeEpgId(programme.channelId)] ??= [])
          .add(programme);
      _expireAt(programme.start, now);
      _expireAt(programme.stop, now);
      final title = _fixtureText(programme.title);
      titles.add(title);
      final identity = _tennisGuideCoverage.containsKey(programme.channelId) &&
              !_otherFixture(title)
          ? '$title${sportsNormalize(_guideDescription(programme))}'
          : _guideIdentity(programme, title);
      guideIdentities.add(identity);
      final court = _MatchTerms._court(identity);
      if (court != null) (courtIndex[court] ??= []).add(i);
      for (final word in identity.trim().split(' ').toSet()) {
        if (word.length >= 2) (titleIndex[word] ??= []).add(i);
      }
      if (slice.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        if (indexVersion != _preparedFor) {
          return matchDay(allGames, picks,
              limit: limit,
              includeGuide: includeGuide,
              includePossible: includePossible,
              onProgress: onProgress,
              onStatus: onStatus);
        }
        slice.reset();
      }
    }
    // A busy tournament shares context/postings between all its matches.
    // Score changes reuse the whole result; no games × entire-guide scan.
    final nameHits = <String, Set<int>>{};
    final guideHits = <String, Set<int>>{};
    Set<int> candidates(List<String> phrases, {bool guide = false}) {
      final cache = guide ? guideHits : nameHits;
      return cache.putIfAbsent(
          phrases.join('\u0001'),
          () => guide
              ? _naming(phrases, guideIdentities, titleIndex)
              : _channelsNaming(phrases));
    }

    final sharedCoverage =
        <String, ({List<ChannelMatch> matches, Set<int> blocked})>{};
    progress.report(SportsWorkStage.matching,
        completed: out.length, total: allGames.length);
    for (final g in games) {
      if (slice.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        if (indexVersion != _preparedFor) {
          return matchDay(allGames, picks,
              limit: limit,
              includeGuide: includeGuide,
              includePossible: includePossible,
              onProgress: onProgress,
              onStatus: onStatus);
        }
        slice.reset();
      }
      final found = <String, ChannelMatch>{};
      void add(int index, MatchReason reason, int score,
          [String? detail, EpgProgram? programme]) {
        if (_excluded.contains(index)) return;
        final c = _channels[index];
        final existing = found[c.id];
        if (existing == null || existing.score < score) {
          found[c.id] = ChannelMatch(c, reason, score,
              detail: detail, programme: programme);
        }
      }

      final picked = picks.channelIdFor(g);
      if (picked != null) {
        final i = _byId[picked];
        if (i != null) add(i, MatchReason.pick, 1000);
      }
      final groups = groupsByGame[g]!;
      final context = contexts[g]!;
      Set<int>? named;
      for (final group in groups) {
        final hits = candidates(group);
        named = named == null ? hits : named.intersection(hits);
        if (named.isEmpty) break;
      }
      final exact = <int>{};
      for (final i in named ?? const <int>{}) {
        if (!_eligible(i, g) ||
            context.conflicts(g, _names[i]) ||
            !_opponentsFit(g, groups, _names[i])) {
          continue;
        }
        if (g.league.kind == SportsKind.tennis &&
            !tennisProgrammeIsExact(
                g,
                EpgProgram(
                    channelId: '',
                    title: _channels[i].name,
                    start: g.start,
                    stop: g.start.add(const Duration(hours: 12))))) {
          continue;
        }
        final hints = _channelHints(i);
        exact.add(i);
        final fullNames = groups
            .where((group) => group.any((phrase) =>
                phrase
                        .trim()
                        .split(' ')
                        .where((word) => word.length > 1)
                        .length >
                    1 &&
                _names[i].contains(phrase)))
            .length;
        add(i, MatchReason.name,
            420 + (hints.date != null ? 20 : 0) + fullNames * 10 + hints.bias);
      }
      final (_, to) = _guideWindow(g);
      final reference = _guideReference(g, now);
      final sharedKey = jsonEncode([
        g.league.id,
        g.start.millisecondsSinceEpoch,
        g.end?.millisecondsSinceEpoch,
        g.state.name,
        context.all,
        g.event?.court,
        g.event?.session,
      ]);
      var shared = sharedCoverage[sharedKey];
      if (shared == null) {
        final common = <String, ChannelMatch>{};
        final blocked = <int>{};
        void addCommon(int i, MatchReason reason, int score,
            [String? detail, EpgProgram? programme]) {
          final channel = _channels[i];
          if (score > (common[channel.id]?.score ?? -1)) {
            common[channel.id] = ChannelMatch(channel, reason, score,
                detail: detail, programme: programme);
          }
        }

        for (final i in candidates(context.all)) {
          if (slice.elapsedMilliseconds >= 4) {
            await Future<void>.delayed(Duration.zero);
            if (indexVersion != _preparedFor) {
              return matchDay(allGames, picks,
                  limit: limit,
                  includeGuide: includeGuide,
                  includePossible: includePossible,
                  onProgress: onProgress,
                  onStatus: onStatus);
            }
            slice.reset();
          }
          if (!_eligible(i, g)) continue;
          final hints = _channelHints(i);
          final coverage = context.coverage(g, _names[i],
              group: hints.group,
              guide: false,
              persistent: hints.persistent,
              allowTeamCoverage: includePossible);
          if (coverage != null) {
            final sameDay = hints.date != null &&
                hints.date!.month == g.start.month &&
                hints.date!.day == g.start.day;
            addCommon(
                i,
                coverage.reason,
                coverage.score +
                    hints.bias +
                    (hints.date == null
                        ? 0
                        : sameDay
                            ? 15
                            : -35),
                coverage.reason == MatchReason.tournament
                    ? g.event?.title
                    : null);
          }
        }
        for (final pIndex in candidates(context.all, guide: true)) {
          if (slice.elapsedMilliseconds >= 4) {
            await Future<void>.delayed(Duration.zero);
            if (indexVersion != _preparedFor) {
              return matchDay(allGames, picks,
                  limit: limit,
                  includeGuide: includeGuide,
                  includePossible: includePossible,
                  onProgress: onProgress,
                  onStatus: onStatus);
            }
            slice.reset();
          }
          final p = programmes[pIndex];
          final start = p.start.toUtc();
          if (start.isAfter(reference.add(const Duration(minutes: 30))) ||
              !p.stop.toUtc().isAfter(reference)) {
            continue;
          }
          final title = (g.league.kind == SportsKind.team ||
                  g.league.kind == SportsKind.tennis ||
                  g.league.kind == SportsKind.racing)
              ? guideIdentities[pIndex]
              : titles[pIndex];
          final indices =
              _byEpgId[normalizeEpgId(p.channelId)] ?? const <int>[];
          if ((g.state != GameState.post && recorded(p)) ||
              context.conflicts(g, title) ||
              _otherFixture(title)) {
            blocked.addAll(indices);
            continue;
          }
          for (final i in indices) {
            if (!_eligible(i, g)) continue;
            final hints = _channelHints(i);
            final coverage = context.coverage(g, title,
                group: '${hints.group}${_names[i]}',
                guide: true,
                persistent: true,
                allowTeamCoverage: includePossible);
            if (coverage == null) continue;
            final diff = start.isBefore(g.start)
                ? 0
                : start.difference(g.start).inMinutes;
            addCommon(
                i,
                coverage.reason,
                coverage.score - math.min(diff, 60) ~/ 6 + hints.bias,
                p.title,
                p);
          }
        }
        common.removeWhere(
            (_, match) => blocked.contains(_byId[match.channel.id]));
        shared = (
          matches:
              _rankMatches(common.values).take(math.max(0, limit)).toList(),
          blocked: blocked
        );
        sharedCoverage[sharedKey] = shared;
      }
      for (final match in shared.matches) {
        add(_byId[match.channel.id]!, match.reason, match.score, match.detail,
            match.programme);
      }
      // Only opponent/event-specific postings need examining per individual
      // match. General tournament and sport coverage was scored once above.
      final eventProgrammes = <int>{
        ...candidates(groups.isEmpty ? [] : groups.first, guide: true),
        if (context.fightCard != null)
          ...candidates(context.event, guide: true),
        if (g.league.kind == SportsKind.tennis)
          ...courtIndex[
                  _MatchTerms._court(sportsNormalize(g.event?.court ?? ''))] ??
              const <int>[],
      };
      for (final pIndex in eventProgrammes) {
        if (slice.elapsedMilliseconds >= 4) {
          await Future<void>.delayed(Duration.zero);
          if (indexVersion != _preparedFor) {
            return matchDay(allGames, picks,
                limit: limit,
                includeGuide: includeGuide,
                includePossible: includePossible,
                onProgress: onProgress,
                onStatus: onStatus);
          }
          slice.reset();
        }
        final p = programmes[pIndex];
        final start = p.start.toUtc();
        if (!p.stop.toUtc().isAfter(reference) || !start.isBefore(to)) continue;
        final title = titles[pIndex];
        final identity = (g.league.kind == SportsKind.team ||
                g.league.kind == SportsKind.tennis ||
                g.league.kind == SportsKind.racing)
            ? guideIdentities[pIndex]
            : title;
        if (g.league.kind != SportsKind.tennis) {
          final date = _dateInName(title);
          if (date != null && !_dateFitsEvent(date, g)) continue;
          if (g.league.kind == SportsKind.team &&
              identity != title &&
              !context.synopsisNamesFixture(_guideDescription(p))) {
            continue;
          }
        }
        final sameFightCard = context.fightCard != null &&
            context.fightCard == _numberedFightCard(title);
        if ((!sameFightCard &&
                (g.league.kind == SportsKind.tennis
                    ? !tennisProgrammeIsExact(g, p)
                    : groups.isEmpty || !_opponentsFit(g, groups, identity))) ||
            context.conflicts(g, identity) ||
            (g.state != GameState.post && recorded(p))) {
          continue;
        }
        if (g.league.kind == SportsKind.tennis &&
            !_opponentsFit(g, groups, identity) &&
            tennisTerms.any((term) =>
                !context.event.contains(term) && identity.contains(term))) {
          // A combined session naming another known tournament cannot
          // identify a single court feed, even when our tournament is named.
          continue;
        }
        for (final i
            in _byEpgId[normalizeEpgId(p.channelId)] ?? const <int>[]) {
          if (!_exactGuideEligible(i, g, p)) continue;
          final diff = g.end != null || start.isBefore(g.start)
              ? 0
              : start.difference(g.start).inMinutes.abs();
          add(
              i,
              g.state == GameState.live && start.isAfter(reference)
                  ? (g.league.kind == SportsKind.team
                      ? MatchReason.league
                      : MatchReason.tournament)
                  : MatchReason.guide,
              (start.isAfter(reference.add(const Duration(minutes: 30)))
                      ? 380
                      : 500) +
                  (exact.contains(i) ? 60 : 0) -
                  (identity == title ? 0 : 15) -
                  math.min(diff, 60) ~/ 6 +
                  _channelHints(i).bias,
              identity == title ? p.title : _guideDescription(p),
              p);
        }
      }
      // Only broadcasters explicitly supplied by the scoreboard. Quality
      // labels and ESPN 2/ESPN2 normalize; ESPN+ never turns into ESPN.
      for (final network in g.broadcasts) {
        if (_streamingOnly.contains(network.toUpperCase())) continue;
        for (final i in _byCanonical[_networkKey(network)] ?? const <int>[]) {
          if (!_eligible(i, g)) continue;
          final bias = _channelHints(i).bias;
          if (bias < 0) continue;
          // ESPN tennis broadcasters cover the tournament, not every court.
          add(
              i,
              g.league.kind == SportsKind.tennis
                  ? MatchReason.league
                  : MatchReason.network,
              180 + bias,
              network);
        }
      }
      // Event-specific web listings corroborate evidence, never override a
      // saved pick. Country must agree: rights differ between regional feeds.
      final localEvidence = Map<String, ChannelMatch>.of(found);
      for (final listing in g.onlineBroadcasts) {
        if (listing.expiresAt != null && !now.isBefore(listing.expiresAt!)) {
          continue;
        }
        final scheduled = listing.programme;
        if (scheduled != null &&
            (scheduled.start.isAfter(reference) ||
                !scheduled.stop.isAfter(reference))) {
          continue;
        }
        var name = listing.name;
        if (listing.country.isNotEmpty) {
          name = name.replaceAll(
              RegExp(RegExp.escape(listing.country), caseSensitive: false), '');
        }
        for (final i in _byCanonical[_networkKey(name)] ?? const <int>[]) {
          if (!_eligible(i, g) ||
              !_listingCountryFits(
                  listing.country, _names[i], _channelHints(i).group)) {
            continue;
          }
          final channel = _channels[i];
          final old = localEvidence[channel.id];
          final previous = found[channel.id];
          if (old?.reason == MatchReason.pick) continue;
          final evidence =
              '${listing.name} · ${listing.source}${listing.country.isEmpty || listing.name.toLowerCase().contains(listing.country.toLowerCase()) ? '' : ' · ${listing.country}'}';
          final stronger = old != null &&
              (old.score >= 400 || (listing.tournamentOnly && old.isConfident));
          final candidate = ChannelMatch(
              channel,
              stronger
                  ? old.reason
                  : listing.tournamentOnly
                      ? MatchReason.tournament
                      : MatchReason.listing,
              stronger
                  ? old.score + 25
                  : (listing.tournamentOnly ? 330 : 360) +
                      _channelHints(i).bias,
              detail: stronger
                  ? old.detail
                  : listing.tournamentOnly
                      ? g.event?.title
                      : null,
              programme: old?.programme ?? scheduled,
              supportingBroadcasts: [evidence]);
          final winner = previous != null &&
                  (previous.isConfident && !candidate.isConfident ||
                      previous.isConfident == candidate.isConfident &&
                          previous.score > candidate.score)
              ? previous
              : candidate;
          found[channel.id] = ChannelMatch(channel, winner.reason, winner.score,
              detail: winner.detail,
              programme: winner.programme,
              supportingBroadcasts:
                  {...?previous?.supportingBroadcasts, evidence}.toList());
        }
      }
      // A dedicated full-coverage F1 broadcaster is useful during build-up,
      // even when its EPG only says "Live F1". Indexed lookup, never a playlist
      // scan per session. FAST channels and dated PPV placeholders do not qualify.
      if (isF1CoverageWindow(g, now)) {
        for (final i
            in candidates(const [' f1 ', ' formula 1 ', ' formula one '])) {
          if (!_eligible(i, g) || f1FeedKind(_channels[i]) != F1Feed.main) {
            continue;
          }
          final p = _epg.getCurrentProgram(_channels[i].epgId);
          if (p != null && p.isNowPlaying(reference)) {
            final text = _guideIdentity(p, _fixtureText(p.title));
            if (recorded(p) ||
                context.conflicts(g, text) ||
                f1ProgrammeConflicts(g, text) ||
                (!context.league.any(text.contains) &&
                    !context.event.any(text.contains))) {
              continue;
            }
          }
          add(i, MatchReason.network, 365 + _channelHints(i).bias,
              'Dedicated F1 coverage · scheduled session', p);
        }
      }
      // The same current slot shown by the guide UI is authoritative. Raw
      // query rows may overlap an older provider entry; use them only when the
      // current cache does not cover this fixture's reference time.
      found.removeWhere((_, match) {
        if (match.reason == MatchReason.pick) return false;
        bool contradicts(EpgProgram p) {
          final title = (g.league.kind == SportsKind.team ||
                  g.league.kind == SportsKind.tennis ||
                  g.league.kind == SportsKind.racing)
              ? _guideIdentity(p, _fixtureText(p.title))
              : _fixtureText(p.title);
          return context.conflicts(g, title) ||
              f1ProgrammeConflicts(g, title) ||
              (g.state != GameState.post && recorded(p)) ||
              (_otherFixture(title) && !_opponentsFit(g, groups, title));
        }

        final programme = _epg.getCurrentProgram(match.channel.epgId);
        if (programme != null) _expireAt(programme.stop, now);
        final next = _epg.getNextProgram(match.channel.epgId);
        if (next != null) _expireAt(next.start, now);
        if (programme != null &&
            !programme.start.isAfter(reference) &&
            programme.stop.isAfter(reference)) {
          return contradicts(programme);
        }
        return (programmesByChannel[normalizeEpgId(match.channel.epgId)] ??
                const <EpgProgram>[])
            .any((p) =>
                !p.start.isAfter(reference) &&
                p.stop.isAfter(reference) &&
                contradicts(p));
      });
      // Auxiliary feeds are deliberately browsable but never replace the
      // main programme automatically. A saved camera choice remains a pick.
      for (final match in _guideMatches(g, picks)) {
        final previous = found[match.channel.id];
        if (previous == null || previous.score < match.score) {
          found[match.channel.id] = match;
        }
      }
      if (isFormulaOne(g)) {
        for (final m in found.values.toList()) {
          final role = f1FeedKind(m.channel);
          if (m.reason != MatchReason.pick &&
              role != null &&
              role != F1Feed.main &&
              role != F1Feed.other) {
            found[m.channel.id] = ChannelMatch(
                m.channel, MatchReason.league, math.min(m.score, 190),
                detail: f1FeedLabel(role),
                programme: m.programme,
                supportingBroadcasts: m.supportingBroadcasts);
          }
        }
      }
      out[SportsChannelPicks.eventKey(g)] =
          _rankMatches(found.values).take(math.max(0, limit)).toList();
      progress.report(SportsWorkStage.matching,
          completed: out.length, total: allGames.length);
      // Result batches rebuild visible cards; counters have their own cheap
      // notifier. Bound the expensive updates to the same cadence as status.
      if (progressClock.elapsedMilliseconds >= 350) publishProgress();
    }
    if (indexVersion != _preparedFor) {
      return matchDay(allGames, picks,
          limit: limit,
          includeGuide: includeGuide,
          includePossible: includePossible,
          onProgress: onProgress,
          onStatus: onStatus);
    }
    for (final game in games) {
      final id = SportsChannelPicks.eventKey(game);
      _eventMatchCache['${includeGuide ? 'full' : 'quick'}:${eventKeys[id]}'] =
          out[id]!;
    }
    while (_eventMatchCache.length > 2048) {
      _eventMatchCache.remove(_eventMatchCache.keys.first);
    }
    progress.report(SportsWorkStage.verifying,
        completed: out.length, total: allGames.length);
    final resolved = _resolveFeedConflicts(out, allGames);
    _matchCache['${includeGuide ? 'full' : 'quick'}:$cacheKey'] =
        (resolved, now);
    while (_matchCache.length > 8) {
      _matchCache.remove(_matchCache.keys.first);
    }
    return resolved;
  }

  Map<String, List<ChannelMatch>> _resolveFeedConflicts(
      Map<String, List<ChannelMatch>> raw, List<SportsGame> allGames) {
    final live = allGames
        .where((g) => g.state == GameState.live && !g.league.isField)
        .toList();
    String feed(ChannelMatch m) => m.channel.epgId.isEmpty
        ? m.channel.id
        : normalizeEpgId(m.channel.epgId);
    final owners = <String, Map<String, int>>{};
    for (final g in live) {
      final id = SportsChannelPicks.eventKey(g);
      for (final m in raw[id] ?? const <ChannelMatch>[]) {
        if (!m.isConfident || m.reason == MatchReason.pick) continue;
        final evidence =
            (m.reason == MatchReason.guide || m.reason == MatchReason.name)
                ? 2
                : 1;
        final events = owners[feed(m)] ??= {};
        events[id] = math.max(events[id] ?? 0, evidence);
      }
    }
    final disputed = <String, String?>{};
    for (final entry in owners.entries) {
      if (entry.value.length < 2) continue;
      final exact = entry.value.entries.where((e) => e.value == 2).toList();
      // A unique explicit event/guide match beats weaker network listings.
      // Equally specific conflicting assignments remain uncertain.
      disputed[entry.key] = exact.length == 1 ? exact.single.key : null;
    }
    if (disputed.isEmpty) return raw;
    final out = Map<String, List<ChannelMatch>>.of(raw);
    for (final g in live) {
      final id = SportsChannelPicks.eventKey(g);
      final rows = raw[id];
      if (rows == null ||
          !rows.any((m) =>
              m.reason != MatchReason.pick &&
              m.isConfident &&
              disputed.containsKey(feed(m)) &&
              disputed[feed(m)] != id)) {
        continue;
      }
      out[id] = _rankMatches([
        for (final m in rows)
          if (m.reason != MatchReason.pick &&
              m.isConfident &&
              disputed.containsKey(feed(m)) &&
              disputed[feed(m)] != id)
            ChannelMatch(
                m.channel,
                g.league.kind == SportsKind.team
                    ? MatchReason.league
                    : MatchReason.tournament,
                math.min(m.score, 300),
                detail: 'Shared feed · match uncertain',
                programme: m.programme,
                supportingBroadcasts: m.supportingBroadcasts)
          else
            m,
      ]);
    }
    return out;
  }

  List<ChannelMatch> _rankMatches(Iterable<ChannelMatch> matches) {
    final sorted = matches.toList()
      ..sort((a, b) {
        if (a.isConfident != b.isConfident) return a.isConfident ? -1 : 1;
        final score = b.score.compareTo(a.score);
        if (score != 0) return score;
        final name = a.channel.name.compareTo(b.channel.name);
        return name != 0 ? name : a.channel.id.compareTo(b.channel.id);
      });
    // Diversify only ties. A weaker feed must never jump ahead of stronger
    // event/guide evidence merely because the better feed has HD variants.
    final list = <ChannelMatch>[];
    for (var start = 0; start < sorted.length;) {
      var end = start + 1;
      while (end < sorted.length &&
          sorted[end].score == sorted[start].score &&
          sorted[end].isConfident == sorted[start].isConfident) {
        end++;
      }
      final seen = <String>{};
      final duplicates = <ChannelMatch>[];
      for (final match in sorted.sublist(start, end)) {
        if (seen.add(_channelHints(_byId[match.channel.id]!).canonical)) {
          list.add(match);
        } else {
          duplicates.add(match);
        }
      }
      list.addAll(duplicates);
      start = end;
    }
    return list;
  }

  /// Picker-only discovery. Never used to select a channel automatically or
  /// to admit events to "With channel". All relevant live-channel entries are
  /// returned; the event grid deliberately keeps its small, verified shortlist.
  Future<List<ChannelMatch>> alternativesFor(SportsGame game,
      {List<ChannelMatch> matches = const [],
      bool Function()? isCancelled}) async {
    await _prepareQueue;
    if (game.isGuideEvent) {
      return _rankMatches({
        for (final match in _guideMatches(game, _WorkerPicks(const {})))
          match.channel.id: match,
        for (final match in matches.where((m) => m.reason == MatchReason.pick))
          match.channel.id: match,
      }.values);
    }
    final now = _clock(), version = _preparedFor;
    final terms = _MatchTerms(game, _knownTennisTerms.keys.toList());
    final sport = game.league.espnPath.split('/').first;
    final broadTerms = <String>{
      ...terms.sport,
      if (isFormulaOne(game)) ...[' f1 ', ' formula 1 ', ' formula one '],
      if (sport == 'tennis') ...[
        ' atp ',
        ' wta ',
        ' itf ',
        ' utr ',
        ' tenis ',
        ' tenisz ',
        ' tennischannel '
      ],
    };
    bool related(String text) {
      if (sport == 'tennis' &&
          (text.contains(' table tennis ') || text.contains(' ping pong '))) {
        return false;
      }
      if (sport == 'soccer' &&
          (text.contains(' american football ') ||
              text.contains(' nfl ') ||
              text.contains(' college football '))) {
        return false;
      }
      return broadTerms.any(text.contains);
    }

    final guideText = <String,
        ({
      EpgProgram? current,
      String text,
      EpgProgram? next,
      String nextText
    })>{};
    DateTime until = now.add(const Duration(minutes: 1));
    ({EpgProgram? current, String text, EpgProgram? next, String nextText})
        slots(String id) {
      final saved = guideText[id];
      if (saved != null) return saved;
      final a = _epg.getCurrentProgram(id), b = _epg.getNextProgram(id);
      final current = a?.isNowPlaying(now) == true ? a : null;
      final next =
          b != null && b.start.isAfter(now) && b.stop.isAfter(now) ? b : null;
      for (final boundary in [current?.stop, next?.start]) {
        if (boundary != null && boundary.isBefore(until)) until = boundary;
      }
      final row = (
        current: current,
        text: current == null
            ? ''
            : '${_fixtureText(current.title)}${sportsNormalize(_guideDescription(current))}',
        next: next,
        nextText: next == null
            ? ''
            : '${_fixtureText(next.title)}${sportsNormalize(_guideDescription(next))}'
      );
      // Keep no per-channel empty entries for an 80k playlist with sparse EPG.
      if (current != null || next != null) guideText[id] = row;
      return row;
    }

    final key =
        '$version|${_epg.changeRevision}|${_epg.lastUpdated}|$sport|${isFormulaOne(game)}';
    final cached = _relatedCache[key];
    List<int> candidates;
    final slice = Stopwatch()..start();
    if (cached != null && now.isBefore(cached.$2)) {
      candidates = cached.$1;
    } else {
      candidates = [];
      final groups = <String, bool>{};
      for (var i = 0; i < _channels.length; i++) {
        if (i % 64 == 0 && slice.elapsedMilliseconds >= 4) {
          await Future<void>.delayed(Duration.zero);
          if (isCancelled?.call() == true) return const [];
          if (version != _preparedFor) {
            return alternativesFor(game,
                matches: matches, isCancelled: isCancelled);
          }
          slice.reset();
        }
        if (_excluded.contains(i)) continue;
        final c = _channels[i];
        final p = slots(c.epgId);
        if (related(_names[i]) ||
            groups.putIfAbsent(
                c.group, () => related(sportsNormalize(c.group))) ||
            related(p.text) ||
            related(p.nextText)) {
          candidates.add(i);
        }
      }
      _relatedCache[key] = (candidates, until);
      while (_relatedCache.length > 4) {
        _relatedCache.remove(_relatedCache.keys.first);
      }
    }
    // Also discover narrowly named event feeds even if they lack a sport tag.
    final broad = candidates.toSet();
    final selected = <int>{
      ...broad,
      ..._channelsNaming([
        ...terms.event,
        ...terms.league,
        ..._nameGroups(game).expand((g) => g)
      ])
    };
    final found = {
      for (final m in matches)
        if (_byId.containsKey(m.channel.id)) m.channel.id: m
    };
    for (final m in _guideMatches(game, _WorkerPicks(const {}))) {
      final existing = found[m.channel.id];
      if (existing == null || existing.score < m.score) found[m.channel.id] = m;
    }
    final nameGroups = _nameGroups(game);
    for (final i in selected) {
      if (_excluded.contains(i)) continue;
      if (slice.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled?.call() == true) return const [];
        if (version != _preparedFor) {
          return alternativesFor(game,
              matches: matches, isCancelled: isCancelled);
        }
        slice.reset();
      }
      final c = _channels[i], p = slots(_channels[i].epgId);
      final name = _names[i];
      final currentRelated = related(p.text);
      final eventNow = terms.event.any(p.text.contains);
      final eventName = terms.event.any(name.contains);
      final namedEvent =
          nameGroups.isNotEmpty && _opponentsFit(game, nameGroups, name);
      if (!broad.contains(i) &&
          !eventName &&
          !namedEvent &&
          !terms.league.any(name.contains)) {
        continue;
      }
      final exactNow = p.current != null &&
          (sport == 'tennis'
              ? tennisProgrammeIsExact(game, p.current!)
              : nameGroups.isNotEmpty &&
                  _opponentsFit(game, nameGroups, p.text));
      final programmeDate = p.current == null
          ? null
          : _dateInName(_fixtureText(p.current!.title));
      final datedProgramme =
          programmeDate != null && !_dateFitsEvent(programmeDate, game);
      final idleProgramme = _idleWords.hasMatch(p.text);
      final coverage = p.current == null
          ? null
          : terms.coverage(game, p.text,
              group: sportsNormalize(c.group),
              guide: true,
              persistent: true,
              allowTeamCoverage: true);
      final currentConflict = p.current != null &&
          (datedProgramme ||
              idleProgramme ||
              terms.conflicts(game, p.text) ||
              f1ProgrammeConflicts(game, p.text) ||
              _nonLiveCoverage(p.current!) ||
              (_otherFixture(p.text) &&
                  !_opponentsFit(game, nameGroups, p.text)));
      final inactive = _idleWords.hasMatch(name);
      final dated = _dateInName(name);
      final staleName = dated != null && !_dateFitsEvent(dated, game);
      final bool eventCoverage =
          !currentConflict && (eventNow || eventName || namedEvent || exactNow);
      var score = !currentConflict && exactNow
          ? 390
          : !currentConflict && eventNow
              ? (coverage?.score ?? 280) + _channelHints(i).bias
              : !currentConflict && (namedEvent || eventName)
                  ? 250
                  : currentRelated && !currentConflict
                      ? 170
                      : currentRelated
                          ? 90
                          : related(name)
                              ? 65
                              : related(p.nextText)
                                  ? 40
                                  : 30;
      String detail = !currentConflict && exactNow
          ? 'Event evidence · additional suggestion'
          : eventCoverage
              ? 'Related event coverage'
              : currentRelated
                  ? 'Other coverage · check the current programme'
                  : related(p.nextText)
                      ? 'Related programme coming up'
                      : 'Sport-related channel · current match unverified';
      if (inactive ||
          idleProgramme ||
          datedProgramme ||
          (staleName && !currentRelated && !exactNow)) {
        score = 5;
        detail = inactive || idleProgramme
            ? 'Possibly inactive · check the channel listing'
            : datedProgramme
                ? 'Dated programme listing · current match unverified'
                : 'Dated channel listing · current match unverified';
      }
      final old = found[c.id];
      if (old == null || (!old.isConfident && score > old.score)) {
        found[c.id] = ChannelMatch(c,
            eventCoverage ? MatchReason.tournament : MatchReason.sport, score,
            detail: detail, programme: p.current ?? p.next);
      }
    }
    if (isCancelled?.call() == true) return const [];
    return _rankMatches(found.values);
  }

  /// Manual search uses only the loaded playlist and cached now/next guide.
  /// Work is time-sliced, cancellable and bounded to [limit] best results.
  Future<List<ChannelSearchResult>> searchWithGuide(String query,
      {List<ChannelMatch> matches = const [],
      int limit = 200,
      bool Function()? isCancelled}) async {
    await _prepareQueue;
    final normalized = sportsNormalize(query).trim();
    if (normalized.isEmpty || limit <= 0) return const [];
    final version = _preparedFor;
    final now = DateTime.now();
    final cacheKey = jsonEncode([
      version,
      normalized,
      limit,
      _epg.changeRevision,
      now.millisecondsSinceEpoch ~/ 60000,
      for (final match in matches)
        [match.channel.id, match.score, match.reason.index]
    ]);
    final cached = _manualCache[cacheKey];
    if (cached != null) return cached;
    final words = normalized.split(' ');
    final known = {for (final match in matches) match.channel.id: match};
    final guide = <String, List<({EpgProgram programme, String title})>>{};
    final found = <({ChannelSearchResult result, int score, int index})>[];
    int compare(({ChannelSearchResult result, int score, int index}) a,
        ({ChannelSearchResult result, int score, int index}) b) {
      int evidenceTier(ChannelMatch? match) => match == null
          ? 0
          : match.reason == MatchReason.pick
              ? 3
              : match.isConfident
                  ? 2
                  : 1;
      final evidence =
          evidenceTier(b.result.match).compareTo(evidenceTier(a.result.match));
      if (evidence != 0) return evidence;
      final score = b.score.compareTo(a.score);
      return score != 0 ? score : a.index.compareTo(b.index);
    }

    final slice = Stopwatch()..start();
    for (var i = 0; i < _channels.length; i++) {
      if (i % 32 == 0 && slice.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled?.call() == true) return const [];
        if (version != _preparedFor) {
          return searchWithGuide(query,
              matches: matches, limit: limit, isCancelled: isCancelled);
        }
        slice.reset();
      }
      if (_excluded.contains(i)) continue;
      final channel = _channels[i];
      final name = _names[i];
      var slots = guide[channel.epgId];
      if (slots == null) {
        final current = _epg.getCurrentProgram(channel.epgId);
        final next = _epg.getNextProgram(channel.epgId);
        slots = [
          for (final p in [current, next])
            if (p != null && p.stop.isAfter(now))
              (programme: p, title: _fixtureText(p.title))
        ];
        // Do not retain tens of thousands of empty guide entries on TV boxes.
        if (slots.isNotEmpty) guide[channel.epgId] = slots;
      }
      final nameHit = words.every(name.contains);
      final slot = slots
          .where((p) =>
              words.any(p.title.contains) &&
              words.every((w) => name.contains(w) || p.title.contains(w)))
          .firstOrNull;
      if (!nameHit && slot == null) continue;
      final match = known[channel.id];
      final score = (match == null ? 0 : 2000 + match.score) +
          (slot == null
              ? 0
              : slot.programme.isNowPlaying(now)
                  ? 160
                  : 80) +
          (name.trim() == normalized
              ? 120
              : name.contains(' $normalized ')
                  ? 60
                  : 0);
      found.add((
        result: ChannelSearchResult(channel,
            match: match,
            programme: slot?.programme ?? match?.programme,
            programmeSearchHit: slot != null),
        score: score,
        index: i
      ));
      if (found.length >= limit * 2) {
        found.sort(compare);
        found.removeRange(limit, found.length);
      }
    }
    if (isCancelled?.call() == true) return const [];
    found.sort(compare);
    final results = found.take(limit).map((r) => r.result).toList();
    _manualCache[cacheKey] = results;
    while (_manualCache.length > 12) {
      _manualCache.remove(_manualCache.keys.first);
    }
    return results;
  }

  /// Channels whose name contains every word of [query] — the manual
  /// "Pick channel" search. Empty query = nothing.
  List<Channel> search(String query, {int limit = 200}) {
    final key = '${sportsNormalize(query)}|$limit';
    final cached = _searchCache[key];
    if (cached != null) return cached;
    final words = sportsNormalize(query)
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    final out = <Channel>[];
    for (var i = 0; i < _names.length && out.length < limit; i++) {
      if (_excluded.contains(i)) continue;
      final n = _names[i];
      if (words.every((w) => n.contains(w))) out.add(_channels[i]);
    }
    _searchCache[key] = out;
    if (_searchCache.length > 24) _searchCache.remove(_searchCache.keys.first);
    return out;
  }
}

// Metadata below is derived only from the already-loaded scoreboard/playlist.
// No stream probing, provider calls, broadcast-rights service or extra API calls.
final _formatMarkers = RegExp(
    r'\b(?:2160|1080|720|576|480)[pi]\d*\b|\b[48]k\b|\b\d{2,3}fps\b',
    caseSensitive: false);
final _networkNumber = RegExp(r'\b(espn|tsn|sportsnet|bein sports)\s+(\d+)\b',
    caseSensitive: false);
String _networkKey(String name) {
  final key = canonicalChannelKey(name
      .replaceAll(_formatMarkers, '')
      .replaceAllMapped(_networkNumber, (m) => '${m[1]}${m[2]}'));
  // Explicit, unambiguous NHL network abbreviations only. Generic SN and
  // streaming-only services must not become a guessed regional channel.
  return _networkAliases[key] ?? key;
}

final _networkAliases = {
  for (final entry in const {
    'SNO': 'Sportsnet Ontario',
    'SNE': 'Sportsnet East',
    'SNP': 'Sportsnet Pacific',
    'SNW': 'Sportsnet West',
    'SN1': 'Sportsnet One',
    'SPORTSNET1': 'Sportsnet One',
    'SN360': 'Sportsnet360',
    'NHLN': 'NHL Network',
    'NESN BOSTON': 'NESN',
    'TVAS': 'TVA Sports',
    'TVAS2': 'TVA Sports 2',
  }.entries)
    canonicalChannelKey(entry.key): canonicalChannelKey(entry.value),
};

class _ChannelHints {
  _ChannelHints(
      this.group, this.date, this.bias, this.persistent, this.canonical);
  final String group, canonical;
  final ({int? year, int month, int day, bool ambiguous})? date;
  final int bias;
  final bool persistent;
}

// A numbered card identifies the whole broadcast, including its prelims;
// requiring the headline fighters alone misses guides such as "UFC 333".
String? _numberedFightCard(String text) {
  final id = combatCardIdentity(text);
  return id == null ? null : ' $id ';
}

final _fixtureSeparator = RegExp(r' (?:vs|v|versus|at) ');
final _tennisPair = RegExp(
    r' (?:vs|v|versus|against|faces|meets|plays|takes on|taking on|take on|head to head with) ');
final _multiTennis = RegExp(
    r' (?:followed by|also featuring|also in action|matches include|line up|lineup|plus|later today|later on|and then) ');
final _tennisCourtBrand = RegExp(r'^ (?:centre|center) court ');
final _coverageOpponent = RegExp(
    r' (?:vs|v|versus) (?:day|early round|round|coverage|semifinals?|finals?|court|session|qualifying) ');
final _replayWords = RegExp(
    r' (?:replays?|repeat|re air(?:s)?|reairs?|rebroadcast|highlights?|hlts|hls|h l|condensed|recap|roundup|round up|classic|interviews|documentary|magazine|best of|top \d+|shots of) ');
// Guide titles can name the exact opponents while the synopsis reveals
// highlights or a repeat. Only introductory coverage copy is evidence;
// mentioning a previous meeting later in a live description is not.
final _nonLiveIntro = RegExp(
    r'^(?:(?:watch|a|the|full|extended|match|game|race|event) )*(?:highlights?|replay|repeat|rebroadcast|re air|condensed)\b|^(?:another chance to (?:watch|see)|relive)\b');
final _recordedRaceSession = RegExp(
    r'^[^.]{0,100}\b(?:race|practice|qualifying|shootout)\s+(?:\d+\s+)?(?:replay|repeat|highlights)\b',
    caseSensitive: false);
bool _nonLiveCoverage(EpgProgram programme) {
  final title = _fixtureText(programme.title);
  return _unavailableGuide.hasMatch(title) ||
      _nonEventGuide.hasMatch(title) ||
      _replayWords.hasMatch(title) ||
      _nonLiveIntro
          .hasMatch(sportsNormalize(_guideDescription(programme)).trim()) ||
      _recordedRaceSession.hasMatch(_guideDescription(programme));
}

// Provider-generated two-hour slots are still labelled End/No event long
// after a broadcast. Their XMLTV time span alone never proves availability.
final _nonEventGuide = RegExp(
    r' (?:previews?|post ?game|post ?match|post ?race|press conference) ');
final _unavailableGuide = RegExp(
    r'^ (?:end|ended) | (?:offline|off air|no events?|no match|no game|to be announced|coming soon) ');

final _idleWords = RegExp(
    r' (?:offline|off air|no event|no events|tba|to be announced|coming soon) ');
final _placeholder = RegExp(r'^ (?:tennis|atp|wta|golf|nba|nhl|nfl) \d+ $');

bool _otherFixture(String title) =>
    _fixtureSeparator.hasMatch(title) && !_coverageOpponent.hasMatch(title);

bool _isCollege(SportsLeague league) =>
    league.id.contains('ncaa') || league.espnPath.contains('college');

// School identities, not mascot guesses. Aliases are only used for college
// events, and still require both opponents and compatible sport/division.
const _schoolAliases = [
  ['app state', 'appalachian state'],
  ['southern miss', 'southern mississippi'],
  ['uconn', 'connecticut'],
  ['ole miss', 'mississippi'],
  ['umass', 'massachusetts'],
  ['fau', 'florida atlantic'],
  ['usf', 'south florida'],
  ['ucf', 'central florida'],
  ['lsu', 'louisiana state'],
];
final _schoolPrefix = RegExp(
    r'(?: north| south| east| west| northern| southern| eastern| western| central| mount| saint| st| uc| cal) $');
final _schoolSuffix =
    RegExp(r'^ (?:state|st|tech|a m|oh|fl|ny|pa|united|city) ');

bool _opponentsFit(SportsGame game, List<List<String>> groups, String text) {
  if (groups.isEmpty || !groups.every((g) => g.any(text.contains))) {
    return false;
  }
  if (game.league.kind != SportsKind.team) return true;
  final college = _isCollege(game.league);
  List<(int, int)> spans(List<String> phrases) {
    final result = <(int, int)>[];
    for (final phrase in phrases) {
      var from = 0;
      while (from < text.length) {
        final start = text.indexOf(phrase, from);
        if (start < 0) break;
        final end = start + phrase.length;
        from = start + 1;
        if (college &&
            (_schoolPrefix.hasMatch(text.substring(0, start + 1)) ||
                _schoolSuffix.hasMatch(text.substring(end - 1)))) {
          continue;
        }
        result.add((start + 1, end - 1));
      }
    }
    return result;
  }

  final first = spans(groups[0]), second = spans(groups[1]);
  // "Michigan State" cannot count as both Michigan and Michigan State.
  return first.any((a) => second.any((b) => a.$2 <= b.$1 || b.$2 <= a.$1));
}

final _explicitSports = RegExp(
    r' (volleyball|basketball|baseball|softball|soccer|tennis|hockey|rugby|golf|american football|college football|nfl|ncaaf) ');
final _slotSportLabel =
    RegExp(r' (?:soccer|football|tennis|volleyball) ppv \d+ ');
String _guideDescription(EpgProgram programme) {
  final description = programme.description?.trim() ?? '';
  return description.substring(0, math.min(description.length, 640));
}

final _synopsisOtherTime = RegExp(
    r' (?:tomorrow|yesterday|last (?:week|month|season|year)|next (?:week|month|season|year)|previous meeting|highlights|replay) ');
final _teamSynopsisConnector = RegExp(
    r' (?:vs|v|versus|at|against|faces|meets|plays|takes on|take on|hosts|visits) ');
final _guideSportContext = RegExp(
    r' (?:volleyball|basketball|baseball|softball|soccer|football|hockey|rugby|golf|nfl|ncaaf|premier league|laliga|la liga|uefa|ncaa) ');

final _guideIdentityCache = <(String, String), String>{};
String _guideIdentity(EpgProgram programme, String title) {
  if (_otherFixture(title)) return title;
  final description = _guideDescription(programme);
  final key = (title, description);
  final cached = _guideIdentityCache[key];
  if (cached != null) return cached;
  final result = _guideIdentityText(title, description);
  if (title.length <= 1024) {
    if (_guideIdentityCache.length >= 2048) {
      _guideIdentityCache.remove(_guideIdentityCache.keys.first);
    }
    _guideIdentityCache[key] = result;
  }
  return result;
}

final _synopsisCoverageTitle = RegExp(
    r' (?:tennis|atp|wta|supercars|supercar|motogp|moto gp|moto2|moto3|formula 1|formula one|formula e|nascar|indycar|wec|imsa|world superbike|worldsbk|motorsport|motor racing) ');
String _guideIdentityText(String title, String synopsis) {
  // Generic "College Soccer" titles often put the actual opponents in the
  // synopsis. Inspect only the already-retrieved, bounded text. An explicit
  // different fixture in the title always wins over incidental synopsis text.
  final description = sportsNormalize(synopsis.replaceAll('@', ' at '));
  // Bounded synopsis indexing happens once, not per match or database row.
  if (_synopsisCoverageTitle.hasMatch(title)) {
    return '$title$description';
  }
  if (!_guideSportContext.hasMatch(title) &&
      !_explicitSports.hasMatch(description)) {
    return title;
  }
  if (!_teamSynopsisConnector.hasMatch(description)) return title;
  return '$title$description';
}

final _women = RegExp(
    r' (?:women|womens|female|ladies)(?: s)? | (?:soccer|volleyball|basketball|tennis) w | w (?:soccer|volleyball|basketball|tennis) ');
final _men = RegExp(
    r' (?:men|mens|male)(?: s)? | (?:soccer|volleyball|basketball|tennis) m | m (?:soccer|volleyball|basketball|tennis) ');

class _MatchTerms {
  _MatchTerms(SportsGame game, [this.tennisTerms = const []])
      : _game = game,
        sport = _sportTerms(game.league).map(sportsNormalize).toList(),
        event = _eventTerms(game),
        league = {
          game.league.name,
          if (game.league.shortName.length >= 3) game.league.shortName,
          ...game.league.seriesPhrases,
        }.map(sportsNormalize).where((p) {
          final sport = _sportTerms(game.league);
          return !sport.any((s) =>
              p == sportsNormalize(s) || p == sportsNormalize('$s channel'));
        }).toList();
  final SportsGame _game;
  late final String? fightCard = _game.league.espnPath.startsWith('mma/')
      ? _numberedFightCard(sportsNormalize(_game.event?.title ?? ''))
      : null;
  late final RegExp? _synopsisPair = _buildSynopsisPair();
  RegExp? _buildSynopsisPair() {
    final groups = SportsChannelMatcher._nameGroups(_game);
    if (groups.length != 2 || groups.any((g) => g.isEmpty)) return null;
    String side(List<String> group) =>
        '(?:${group.map((p) => RegExp.escape(p.trim())).join('|')})';
    const separator =
        r' (?:vs|v|versus|at|against|faces|meets|plays|takes on|take on|hosts|visits) ';
    return RegExp(' (?:${side(groups[0])}$separator${side(groups[1])}|'
        '${side(groups[1])}$separator${side(groups[0])}) ');
  }

  bool synopsisNamesFixture(String description) {
    final text = sportsNormalize(description.replaceAll('@', ' at '));
    final pair = _synopsisPair?.firstMatch(text);
    if (pair == null || _multiTennis.hasMatch(text)) return false;
    // A schedule preview or recap can mention today's opponents together.
    // Inspect nearby qualifiers, not unrelated history later in a synopsis.
    final local = text.substring(
        math.max(0, pair.start - 32), math.min(text.length, pair.end + 48));
    return !_synopsisOtherTime.hasMatch(local);
  }

  late final _sportKey = _game.league.espnPath.split('/').first;
  late final _identity =
      sportsNormalize('${_game.league.id} ${_game.league.name}');
  late final _female = _women.hasMatch(_identity) ||
      _game.league.id == 'wnba' ||
      _game.league.id == 'golf.lpga' ||
      _game.league.id.contains('.w.') ||
      _game.league.id == 'tennis.wta';
  late final _male = (!_female &&
          (_game.league.kind == SportsKind.team ||
              _game.league.kind == SportsKind.golf)) ||
      _men.hasMatch(_identity) ||
      _game.league.id.contains('.m.') ||
      _game.league.id == 'tennis.atp';
  late final _ownCourt = _court(sportsNormalize(_game.event?.court ?? ''));
  late final _ownRound = _round(sportsNormalize(_game.event?.session ?? ''));
  late final _familyIdentity = sportsNormalize(
      '${_game.league.id} ${_game.league.name} ${_game.league.shortName}');
  final List<String> sport, event, league;
  final List<String> tennisTerms;
  List<String> get all => [...event, ...league, ...sport];

  static List<String> _sportTerms(SportsLeague league) =>
      switch (league.espnPath.split('/').first) {
        'tennis' => ['tennis'],
        'soccer' => ['soccer', 'football'],
        'football' => ['american football'],
        'basketball' => ['basketball'],
        'hockey' => ['hockey', 'ice hockey'],
        'baseball' => ['baseball'],
        'golf' => ['golf'],
        'mma' => ['mma', 'mixed martial arts'],
        'racing' => ['motorsport', 'motor racing'],
        'rugby' => ['rugby'],
        'australian-football' => ['aussie rules', 'australian football'],
        'volleyball' => ['volleyball'],
        'poker' => ['poker', 'pokergo', 'wsop', 'world poker tour'],
        'darts' => ['darts', 'pdc'],
        'esports' => [
            'esports',
            'e sports',
            'counter strike',
            'dota 2',
            'valorant',
            'league of legends'
          ],
        'action-sports' => [
            'x games',
            'dew tour',
            'skateboarding',
            'snowboarding',
            'bmx',
            'surfing'
          ],
        'billiards' => ['snooker', 'billiards', 'ultimate pool'],
        'bowling' => ['bowling'],
        'badminton' => ['badminton'],
        'table-tennis' => ['table tennis'],
        _ => [],
      };

  static const _generic = {
    'open',
    'masters',
    'championship',
    'championships',
    'world',
    'tour',
    'international',
    'tournament',
    'finals',
    'final',
    'tennis',
    'golf',
    'grand',
    'prix',
    'the',
    'atp',
    'wta',
    'pga',
    'lpga',
    'ladies',
    'women',
    'womens',
    'men',
    'mens',
    'female',
    'male',
    'round',
    'series',
    'bank',
    'group',
    'cup',
    'singles',
    'doubles',
    'qualifying',
  };
  static List<String> _eventTerms(SportsGame game) {
    final title = sportsNormalize(game.event?.title ?? '')
        .replaceFirst(RegExp(r' (?:presented by|powered by) .*'), ' ');
    if (title.trim().length < 6) return [];
    final out = <String>{
      title,
      if (game.league.espnPath.startsWith('mma/'))
        if (_numberedFightCard(title) case final card?) card,
      for (final name in game.event?.matchingNames ?? const <String>[])
        if (sportsNormalize(name).trim().length >= 4 &&
            !_generic.contains(sportsNormalize(name).trim()))
          sportsNormalize(name),
    };
    final words = title.trim().split(' ');
    // Sponsor-prefixed tournaments: "Rolex Shanghai Masters" ->
    // "Shanghai Masters" / "Shanghai". Short aliases require sport/league
    // context later, so "US Open" golf cannot become an ATP match.
    if (game.league.kind == SportsKind.tennis ||
        game.league.kind == SportsKind.golf) {
      if (words.length >= 2) {
        final lastTwo = words.sublist(words.length - 2);
        if (lastTwo.any(
            (w) => !_generic.contains(w) && !RegExp(r'^\d+$').hasMatch(w))) {
          out.add(' ${lastTwo.join(' ')} ');
        }
        if (_generic.contains(words.last)) {
          final core = words[words.length - 2];
          if (core.length >= 4 && !_generic.contains(core)) out.add(' $core ');
        }
      }
    }
    final venue = sportsNormalize(game.event?.venue ?? '');
    if (venue.trim().length >= 8 && venue.trim().contains(' ')) out.add(venue);
    return out.toList();
  }

  static String? _court(String text) {
    final courts = <String>{};
    for (final match in _courtPattern.allMatches(text)) {
      final number = match[1] ?? match[2];
      courts.add(number == null ? 'centre' : 'court ${int.parse(number)}');
    }
    // A programme covering several courts cannot identify one match.
    return courts.length == 1 ? courts.single : null;
  }

  static final _courtPattern = RegExp(
      r'\b(?:court (?:no )?(\d{1,2})|no (\d{1,2}) court|(?:centre|center|central) court|court (?:central|centre|center))\b');

  static String? _round(String text) {
    if (RegExp(r' (?:quarterfinals?|quarter finals?|qf) ').hasMatch(text)) {
      return 'qf';
    }
    if (RegExp(r' (?:semifinals?|semi finals?|sf) ').hasMatch(text)) {
      return 'sf';
    }
    if (text.contains(' final ') && !text.contains(' finals ')) return 'final';
    return null;
  }

  static final _raceSessionWords = RegExp(
      r' (sprint (?:qualifying|qualification|shootout|shoot out)|top (?:ten|10) shootout|ttso|(?:free )?practice(?: ?[123])?|fp ?[123]|qualifying|qualification|sprint|race) ');
  static String? _raceSession(String text) {
    // The title precedes the synopsis. Its explicit session takes precedence
    // over boilerplate description text copied from an earlier session.
    final word = _raceSessionWords.firstMatch(text)?.group(1);
    if (word == null) return null;
    if (word.startsWith('sprint ')) return 'sprint qualifying';
    if (word.startsWith('top ') || word == 'ttso') return 'shootout';
    if (word.contains('practice') || word.startsWith('fp')) return 'practice';
    if (word.startsWith('qual')) return 'qualifying';
    return word;
  }

  static final _supercarsSupport = RegExp(
      r' (?:supports?|support races?|carrera cup|aussie racing cars|superutes) ');
  static final _f1Support = RegExp(
      r' (?:formula [23]|formula two|formula three|f[23]|f1 academy|porsche supercup) ');
  static final _namedRaceSeries = RegExp(
      r' (?:formula 1|formula one|formula 2|formula two|formula 3|formula three|f1|f2|f3|f1 academy|motogp|moto2|moto3|supercars|carrera cup|aussie racing cars|superutes|gt world challenge|igtc|dtm|super gt|worldsbk|worldssp|imsa|nascar|indycar|wec|elms) ');
  static final _raceNumber = RegExp(r' race (\d+) ');
  static final _practiceNumber = RegExp(r' (?:practice|fp) ?(\d+) ');
  late final _ownRaceNumber = _raceNumber
      .firstMatch(sportsNormalize(_game.event?.session ?? ''))
      ?.group(1);
  late final _ownPracticeNumber = _practiceNumber
      .firstMatch(sportsNormalize(_game.event?.session ?? ''))
      ?.group(1);
  late final _ownRaceSession =
      _raceSession(sportsNormalize(_game.event?.session ?? ''));
  late final _ownGolfRound =
      _golfRound(sportsNormalize(_game.event?.session ?? ''));
  static String? _golfRound(String text) =>
      RegExp(r' round ([1-4]) ').firstMatch(text)?[1];

  bool conflicts(SportsGame game, String text) {
    if (fightCard != null) {
      final other = _numberedFightCard(text);
      if (other != null && other != fightCard) return true;
    }
    final sport = _sportKey;
    // Some providers append "US: SOCCER PPV 4" to every kind of event.
    // Treat the event's sport as evidence, not that routing-slot label.
    final eventText = text.replaceAll(_slotSportLabel, ' ');
    final namedSports = _explicitSports
        .allMatches(eventText)
        .map((m) => switch (m[1]!) {
              'american football' ||
              'college football' ||
              'nfl' ||
              'ncaaf' =>
                'football',
              final name => name,
            })
        .toSet();
    if (namedSports.isNotEmpty && !namedSports.contains(sport)) return true;
    if (game.league.kind == SportsKind.racing) {
      // Distinguish Le Mans cars/bikes/supports and other endurance series
      // before a shared venue can contribute matching evidence.
      final otherEndurance = enduranceSeriesPatterns.containsKey(game.league.id)
          ? enduranceLeagueId(eventText, '')
          : null;
      if (otherEndurance != null &&
          otherEndurance != game.league.id &&
          enduranceSeriesPatterns.containsKey(game.league.id)) {
        // Spa 24h is legitimately both GTWC Europe and IGTC.
        if (!const {'racing.gtwc', 'racing.igtc'}
            .containsAll({game.league.id, otherEndurance})) {
          return true;
        }
      }
      // Shared weekend coverage is not evidence for the headline race.
      if (game.isScheduleOnly &&
          ((game.league.id == 'racing.supercars' &&
                  _supercarsSupport.hasMatch(eventText)) ||
              (game.league.id == 'racing.f1' &&
                  _f1Support.hasMatch(eventText)))) {
        return true;
      }
      // Calendar venues can host several series. A different named series or
      // session number must not become an exact match for the same circuit.
      if (game.isScheduleOnly) {
        final ownSeries = league.any(eventText.contains);
        if (!ownSeries && _namedRaceSeries.hasMatch(eventText)) return true;
      }
      final otherRace = _raceNumber.firstMatch(eventText)?.group(1);
      final otherPractice = _practiceNumber.firstMatch(eventText)?.group(1);
      if ((_ownRaceNumber != null &&
              otherRace != null &&
              _ownRaceNumber != otherRace) ||
          (_ownPracticeNumber != null &&
              otherPractice != null &&
              _ownPracticeNumber != otherPractice)) {
        return true;
      }
      final session = _raceSession(eventText);
      if (_ownRaceSession != null &&
          session != null &&
          session != _ownRaceSession) {
        return true;
      }
    }
    if (game.league.kind == SportsKind.golf) {
      final round = _golfRound(eventText);
      if (_ownGolfRound != null && round != null && round != _ownGolfRound) {
        return true;
      }
    }
    final female = _female, male = _male;
    if ((female && _men.hasMatch(eventText) && !_women.hasMatch(eventText)) ||
        (male && _women.hasMatch(eventText) && !_men.hasMatch(eventText))) {
      return true;
    }
    if (game.league.kind == SportsKind.tennis) {
      // Compare only identities supplied by this scoreboard batch. Mixed
      // tournament coverage is allowed when our tournament is also named.
      if (!event.any(text.contains) && tennisTerms.any(text.contains)) {
        return true;
      }
      final court = _ownCourt;
      final listedCourt = _court(text);
      if (court != null &&
          listedCourt != null &&
          !_tennisCourtBrand.hasMatch(text) &&
          court != listedCourt) {
        return true;
      }
      final round = _ownRound;
      final listedRound = _round(text);
      if (round != null && listedRound != null && round != listedRound) {
        return true;
      }
      if (text.contains(' doubles ') ||
          text.contains(' juniors ') ||
          text.contains(' junior ') ||
          text.contains(' qualifying ') ||
          text.contains(' challenger ') ||
          text.contains(' itf ') ||
          text.contains(' table tennis ') ||
          text.contains(' ping pong ') ||
          text.contains(' collegiate ') ||
          text.contains(' college ')) {
        return true;
      }
      if (game.league.id == 'tennis.atp' &&
          text.contains(' wta ') &&
          !text.contains(' atp ')) {
        return true;
      }
      if (game.league.id == 'tennis.wta' &&
          text.contains(' atp ') &&
          !text.contains(' wta ')) {
        return true;
      }
    }
    if (sport == 'soccer' &&
        (text.contains(' american football ') ||
            text.contains(' nfl ') ||
            text.contains(' college football '))) {
      return true;
    }
    const families = {
      'basketball': ['nba', 'wnba', 'college basketball', 'ncaa basketball'],
      'hockey': ['nhl', 'college hockey'],
      'football': ['nfl', 'college football', 'ncaaf'],
      'baseball': ['mlb', 'college baseball'],
      'golf': ['pga', 'lpga', 'liv golf', 'dp world tour'],
    };
    final siblings = families[sport];
    if (siblings != null) {
      final own = _familyIdentity;
      final named = siblings.where((s) => text.contains(' $s ')).toList();
      if (named.isNotEmpty && !named.any((s) => own.contains(' $s '))) {
        return true;
      }
    }
    return false;
  }

  ({int score, MatchReason reason})? coverage(SportsGame game, String text,
      {String group = '',
      required bool guide,
      required bool persistent,
      bool allowTeamCoverage = false}) {
    // Routing labels such as "US: SOCCER PPV 8" also host tennis, gymnastics
    // and empty slots. They cannot supply sport evidence for a generic title.
    text = text.replaceAll(_slotSportLabel, ' ');
    if (conflicts(game, text) || _otherFixture(text)) return null;
    // A linear tennis/golf channel can cover an ongoing tournament. A team
    // sport channel alone cannot identify which of many simultaneous games
    // it is showing; do not present it as a matched event.
    if (game.league.kind == SportsKind.team && !allowTeamCoverage) return null;
    final byLeague = league.any(text.contains);
    final bySport = sport.any(text.contains);
    final context = byLeague || bySport || sport.any(group.contains);
    if (event.any((term) =>
        text.contains(term) &&
        ((game.isScheduleOnly ? byLeague : context) ||
            (!game.isScheduleOnly &&
                game.league.isField &&
                term.trim().contains(' '))))) {
      final ownCourt = _ownCourt;
      final ownRound = _ownRound;
      final tennis = game.league.kind == SportsKind.tennis;
      final mixedTennis = tennis &&
          (text.contains(' around the world ') ||
              _multiTennis.hasMatch(text) ||
              tennisTerms
                  .any((term) => !event.contains(term) && text.contains(term)));
      // "Center Court Live" is a programme brand, not a court assignment.
      // A programme dedicated to this tournament is a better suggestion than
      // a round-up switching between several venues, even with the same round.
      final brandedCourt = _tennisCourtBrand.hasMatch(text);
      final detailBonus = game.league.kind == SportsKind.tennis
          ? (ownCourt != null &&
                      !mixedTennis &&
                      !brandedCourt &&
                      ownCourt == _court(text)
                  ? 20
                  : 0) +
              (ownRound != null && ownRound == _round(text) ? 8 : 0) -
              (mixedTennis ? 50 : 0)
          : 0;
      return (
        score: (guide ? 310 : 280) + detailBonus,
        reason: MatchReason.tournament
      );
    }
    if (guide || persistent) {
      if (byLeague) {
        return (score: guide ? 210 : 150, reason: MatchReason.league);
      }
      if (bySport) return (score: guide ? 120 : 80, reason: MatchReason.sport);
    }
    return null;
  }
}

Set<int> _naming(
    List<String> phrases, List<String> texts, Map<String, List<int>> index) {
  final hits = <int>{};
  for (final phrase in phrases) {
    final words = phrase.trim().split(' ').where((w) => w.length >= 2);
    if (words.isEmpty) continue;
    List<int>? best;
    for (final word in words) {
      final list = index[word];
      if (list == null) {
        best = null;
        break;
      }
      if (best == null || list.length < best.length) best = list;
    }
    if (best == null) continue;
    for (final i in best) {
      if (texts[i].contains(phrase)) hits.add(i);
    }
  }
  return hits;
}

bool _listingCountryFits(String country, String name, String group) {
  if (country.isEmpty) return true;
  const tags = {
    'united kingdom': ['uk', 'gb', 'british', 'united kingdom'],
    'united states': ['us', 'usa', 'united states'],
    'australia': ['au', 'aus', 'australia', 'australian'],
    'canada': ['ca', 'can', 'canada', 'canadian'],
    'france': ['fr', 'france', 'french'],
    'germany': ['de', 'germany', 'german'],
    'spain': ['es', 'spain', 'spanish'],
    'italy': ['it', 'italy', 'italian'],
    'new zealand': ['nz', 'new zealand'],
  };
  final normalizedCountry = sportsNormalize(country).trim();
  final expected = tags[normalizedCountry] ?? [normalizedCountry];
  for (final region in tags.entries) {
    if (region.key == normalizedCountry) continue;
    if (region.value.any((tag) => name.contains(' $tag '))) return false;
  }
  final text = ' $name $group ';
  return expected.any((tag) => text.contains(' $tag '));
}
