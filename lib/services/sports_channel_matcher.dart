import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/sports.dart';
import '../models/sports_progress.dart';
import '../utils/bounded_index_cache.dart';
import '../utils/channel_name_matching.dart';
import '../utils/combat_sports.dart';
import '../utils/endurance_racing.dart';
import '../utils/extended_sports.dart';
import '../utils/formula_one.dart';
import '../utils/guide_read_tracker.dart';
import '../utils/motorsport_coverage.dart';
import '../utils/sports_date_matcher.dart';
import '../utils/sports_guide_coverage.dart';
import '../utils/sports_language.dart';
import '../utils/sports_team_vocabulary.dart';
import '../utils/sports_team_aliases.dart';
import '../utils/sports_programme_time_index.dart';
import '../utils/sports_title_matcher.dart';
import 'epg_service.dart';
import 'sports_channel_text_cache.dart';
import 'sports_match_disk_cache.dart';
import 'sports_match_inputs.dart';
import 'sports_replay_service.dart';
import 'sports_work_queue.dart';
import 'storage_service.dart';

part 'sports_matching_worker.dart';
part 'sports_guide_discovery.dart';
part 'sports_programme_index.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _GuideQuery {
  const _GuideQuery(this.generation, this.from, this.to, this.terms,
      this.result, this.fetchedAt);
  final Object generation;
  final DateTime from, to, fetchedAt;
  final Set<String> terms;
  final Future<List<EpgProgram>> result;
}

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
class SportsChannelPicks implements SportsMatchPicks, SportsMatchRejections {
  SportsChannelPicks._(this._storage, this._events, this.teams, this._rejected);

  factory SportsChannelPicks.load(StorageService storage) {
    final events = <String, _EventPick>{};
    final teams = <String, String>{};
    final rejected = <String, Map<String, int>>{};
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
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final entry in (m['rejected'] as Map<String, dynamic>? ?? {})
            .entries
            .take(128)) {
          final active = <String, int>{};
          for (final decision in (entry.value as Map).entries.take(64)) {
            if (decision.value is int &&
                decision.value > now &&
                decision.value <=
                    now + const Duration(hours: 12).inMilliseconds) {
              active[decision.key as String] = decision.value as int;
            }
          }
          if (active.isNotEmpty) rejected[entry.key] = active;
        }
        (m['teams'] as Map<String, dynamic>? ?? {})
            .forEach((k, v) => teams[k] = v as String);
      } catch (_) {
        // Corrupt prefs read back as "no picks", like the other JSON prefs.
      }
    }
    return SportsChannelPicks._(storage, events, teams, rejected);
  }

  final StorageService _storage;
  final Map<String, _EventPick> _events;
  final Map<String, String> teams;
  final Map<String, Map<String, int>> _rejected;
  @override
  int decisionsRevision = 0;
  static String _decisionScope(SportsGame g) =>
      '${eventKey(g)}:${g.start.millisecondsSinceEpoch}';
  @override
  Set<String> rejectedKeysFor(SportsGame game) {
    final decisions = _rejected[_decisionScope(game)];
    if (decisions == null) return const {};
    final now = DateTime.now().millisecondsSinceEpoch;
    final count = decisions.length;
    decisions.removeWhere((_, until) => until <= now);
    if (decisions.length != count) decisionsRevision++;
    return decisions.keys.toSet();
  }

  Future<void> rejectForGame(
      SportsGame game, Channel channel, EpgProgram? programme) {
    _reloadBeforeEdit();
    final now = DateTime.now();
    final limit = now.add(programme == null
        ? const Duration(hours: 1)
        : const Duration(hours: 12));
    final until = programme != null && programme.stop.isBefore(limit)
        ? programme.stop
        : limit;
    if (!until.isAfter(now)) return Future.value();
    final decisions = _rejected.putIfAbsent(_decisionScope(game), () => {});
    decisions[sportsRejectionKey(channel.id, programme)] =
        until.millisecondsSinceEpoch;
    while (decisions.length > 64) {
      decisions.remove(decisions.keys.first);
    }
    while (_rejected.length > 128) {
      _rejected.remove(_rejected.keys.first);
    }
    if (_events[eventKey(game)]?.channelId == channel.id) {
      _events.remove(eventKey(game));
    }
    return _save();
  }

  Future<void> restoreForGame(
      SportsGame game, Channel channel, EpgProgram? programme) {
    _reloadBeforeEdit();
    _rejected[_decisionScope(game)]
        ?.remove(sportsRejectionKey(channel.id, programme));
    return _save();
  }

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
    _rejected.remove(_decisionScope(g));
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
    decisionsRevision++;
    final latest = SportsChannelPicks.load(_storage);
    _events
      ..clear()
      ..addAll(latest._events);
    teams
      ..clear()
      ..addAll(latest.teams);
    _rejected
      ..clear()
      ..addAll(latest._rejected);
  }

  Future<void> _save() => _storage.setSportsChannelPicks(jsonEncode({
        'events': _events
            .map((k, v) => MapEntry(k, {'c': v.channelId, 't': v.savedAtMs})),
        'teams': teams,
        'rejected': _rejected,
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
String sportsNormalize(String s) => normalizeSportsName(s);

// "Bruins @ Leafs" is a fixture; "Tennis @ Oct 22" is a date label.
// Keep this separate from general search/canonical channel normalization.
final _fixtureAt = RegExp(
    r'\s*@(?!\s*(?:(?:(?:mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\s+)?(?:\d|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*\d)))\s*',
    caseSensitive: false);

// Keep a useful working set across regional copies without retaining a whole
// guide. The character budget bounds long synopses as well as entry count.
class _SportsTextCache<K, V> {
  _SportsTextCache({this.budget = 1024 * 1024});
  final int budget;
  final _rows = <K, (V, int)>{};
  int _units = 0;
  V? operator [](K key) => _rows[key]?.$1;
  void put(K key, V value, int cost) {
    if (cost > budget) return;
    final previous = _rows.remove(key);
    if (previous != null) _units -= previous.$2;
    while (
        _rows.isNotEmpty && (_rows.length >= 8192 || _units + cost > budget)) {
      // Amortised eviction: don't repeatedly scan the Map's deleted prefix.
      for (final oldest in _rows.keys.take(512).toList(growable: false)) {
        _units -= _rows.remove(oldest)!.$2;
      }
    }
    _rows[key] = (value, cost);
    _units += cost;
  }
}

final _fixtureTextCache = _SportsTextCache<String, String>();
final _nameApostrophe = RegExp(sportsJoiningApostrophePattern);
final _dottedTeamInitials = RegExp(r'\b(?:[A-Za-z]\.\s*)+[A-Za-z]\.');
final _initialsSeparators = RegExp(r'[.\s]');
final _fixtureLabelBoundary = RegExp(r'\||(?<!\d):(?!\d)|:(?=\s)');
final _spacedFixtureDash = RegExp(r'\s+[-–—]\s+');
final _fixtureFormatting = RegExp(r"[@|:'’]|\s[-–—]\s");
String _playerText(String text) =>
    sportsNormalize(text.replaceAll(_nameApostrophe, ''));

String _fixtureText(String text) {
  final cached = _fixtureTextCache[text];
  if (cached != null) return cached;
  final language = sportsLanguageText(text);
  final value = _fixtureFormatting.hasMatch(language)
      ? _structuredFixtureText(language)
      : sportsNormalize(language);
  // Regional/quality copies repeat the same programme thousands of times.
  // Bound retained text, including unexpectedly large provider titles.
  if (text.length <= 1024) {
    _fixtureTextCache.put(text, value, text.length + value.length);
  }
  return value;
}

String _structuredFixtureText(String text) {
  final fixture =
      (text.contains('@') ? text.replaceAll(_fixtureAt, ' vs ') : text)
          .replaceAll(_nameApostrophe, '');
  // Preserve label boundaries and spaced matchup separators without splitting
  // times or hyphenated surnames. These markers are never search keywords.
  final parts = fixture
      .split(_fixtureLabelBoundary)
      .where((part) => part.trim().isNotEmpty)
      .map((part) => part
          .split(_spacedFixtureDash)
          .where((part) => part.trim().isNotEmpty)
          .map(sportsNormalize)
          .join('~'));
  return parts.isEmpty ? ' ' : parts.join('|');
}

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
  'ACCNX',
  'ACC NETWORK EXTRA',
  'SECN+',
  'SEC NETWORK+',
  'SEC NETWORK +',
  'ESPN3',
  'B1G+',
  'BTN+',
  'BIG TEN PLUS',
  'COUPANGPLAY',
  'COUPANG PLAY',
  'K LEAGUE TV',
  'KLEAGUE TV',
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

typedef _PickerAlternativesKey = ({
  int generation,
  String? catalogue,
  int revision,
  DateTime? updated,
  String evidence,
  String fixture,
});

/// Finds IPTV channels using local metadata, strongest evidence first:
/// saved picks; both opponents/event in a channel name or overlapping guide
/// entry; tournament coverage; league/broadcaster; dedicated sport channels.
/// Broad coverage remains explicitly labelled as a suggestion. Event slots
/// naming different opponents, stale dates and dummy headers are not fallbacks.
///
/// Build once per channel list ([prepare]), then [matchDay] per day shown.
class SportsChannelMatcher {
  SportsChannelMatcher(this._epg,
      {DateTime Function()? clock, SportsChannelTextCache? channelTextCache})
      : _clock = clock ?? DateTime.now,
        _channelTextCache = channelTextCache;
  final DateTime Function() _clock;
  SportsChannelTextCache? _channelTextCache;

  // The dedicated isolate does not render frames. Tiny UI-sized slices add
  // thousands of timer round trips there; keep yielding for messages, but
  // amortise that cost. Main-isolate callers retain the tighter frame budget.
  int get _workSliceMs => _epg is _WorkerGuide ? 16 : 4;

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
          {DateTime Function()? clock, String? cachePath}) =>
      _BackgroundSportsMatcher(epg, clock: clock, cachePath: cachePath);

  static void disposeShared() {
    _shared?.dispose();
    _shared = null;
  }

  void dispose() {
    ++_pickerGeneration;
    _pickerAlternatives.clear();
    _pickerPending.clear();
    _pickerOrders.clear();
  }

  // Keep picker discovery outside the worker's idle lifetime. A closed dialog
  // stops observing the task, not the task itself, so reopening can reuse it.
  final _pickerAlternatives =
      <_PickerAlternativesKey, (DateTime, DateTime, List<ChannelMatch>)>{};
  final _pickerPending = <Object, Future<List<ChannelMatch>>>{};
  int _pickerGeneration = 0;

  // Presentation identities only: a manual choice must not reshuffle the menu.
  // Current evidence still supplies every row, so this cannot restore a removed
  // channel, expired programme or a rejected match. Nothing runs at startup.
  final _pickerOrders = <Object, (DateTime, List<String>)>{};
  List<ChannelMatch> keepPickerOrder(SportsGame game, List<ChannelMatch> rows,
      {String? selectedId}) {
    if (rows.isEmpty) return rows;
    final now = _clock();
    _pickerOrders.removeWhere((_, entry) =>
        now.isBefore(entry.$1) ||
        now.difference(entry.$1) >= const Duration(minutes: 15));
    final key = (
      _preparedFor,
      game.league.id,
      game.id,
      game.start,
      game.home.name,
      game.away.name
    );
    final remembered = _pickerOrders.remove(key);
    // Until a viewer makes a choice, enrichment still ranks stronger evidence
    // first. Once they start comparing channels, retain the order they saw.
    final previous = selectedId == null ? null : remembered;
    final ids = previous?.$2.toList() ?? <String>[];
    final seen = ids.toSet();
    final current = {for (final row in rows) row.channel.id: row};
    // A channel found through manual search may be absent from the old list.
    // Put it beside the original suggestion, keeping all known choices in order.
    if (previous != null &&
        selectedId != null &&
        current.containsKey(selectedId) &&
        seen.add(selectedId)) {
      ids.insert(ids.isEmpty ? 0 : 1, selectedId);
    }
    for (final row in rows) {
      if (seen.add(row.channel.id)) ids.add(row.channel.id);
    }
    final result = <ChannelMatch>[
      for (final id in ids)
        if (current[id] case final row?) row,
    ];
    _pickerOrders[key] = (now, ids.take(6000).toList(growable: false));
    while (_pickerOrders.length > 24 ||
        _pickerOrders.values.fold<int>(0, (n, e) => n + e.$2.length) > 6000) {
      _pickerOrders.remove(_pickerOrders.keys.first);
    }
    return result;
  }

  _PickerAlternativesKey _pickerKey(SportsGame game) => (
        generation: _pickerGeneration,
        catalogue: _preparedFor,
        revision: _epg.changeRevision,
        updated: _epg.lastUpdated,
        evidence:
            matchingIdentity(game, _WorkerPicks(const {}), includePick: false),
        fixture: jsonEncode(
            [game.league.id, game.id, game.home.name, game.away.name]),
      );

  List<ChannelMatch>? cachedPickerAlternatives(SportsGame game) {
    final now = _clock();
    _pickerAlternatives.removeWhere((_, entry) =>
        now.isBefore(entry.$1) ||
        now.difference(entry.$1) >= const Duration(minutes: 15));
    final key = _pickerKey(game);
    final entry = _pickerAlternatives[key];
    if (entry == null || !now.isBefore(entry.$2)) return null;
    _pickerAlternatives.remove(key);
    _pickerAlternatives[key] = entry;
    return entry.$3;
  }

  /// Retain discovered channel identities while evidence is refreshed. Expired
  /// programme text and confidence never survive a guide/fixture revision.
  List<ChannelMatch>? retainedPickerAlternatives(SportsGame game) {
    final fresh = cachedPickerAlternatives(game);
    if (fresh != null) return fresh;
    final key = _pickerKey(game);
    for (final previous in _pickerAlternatives.keys.toList().reversed) {
      if (previous.generation == key.generation &&
          previous.catalogue == key.catalogue &&
          previous.fixture == key.fixture) {
        return [
          for (final row in _pickerAlternatives[previous]!.$3)
            ChannelMatch(row.channel, MatchReason.sport, 0,
                detail: 'Previous suggestion · checking current guide'),
        ];
      }
    }
    return null;
  }

  Future<List<ChannelMatch>> loadPickerAlternatives(SportsGame game,
      {List<ChannelMatch> matches = const []}) {
    final cached = cachedPickerAlternatives(game);
    if (cached != null) return Future.value(cached);
    final key = _pickerKey(game);
    return _pickerPending.putIfAbsent(key, () async {
      final started = _clock();
      try {
        // Saved choices are applied by the picker, never retained as evidence
        // for a future visit after the viewer chooses a different channel.
        final rows = await Future<List<ChannelMatch>>.sync(() =>
            alternativesFor(game,
                matches: matches
                    .where((m) => m.reason != MatchReason.pick)
                    .toList()));
        final now = _clock();
        var until = started.add(const Duration(minutes: 3));
        void boundary(DateTime? at) {
          if (at != null && at.isAfter(started) && at.isBefore(until)) {
            until = at;
          }
        }

        final slice = Stopwatch()..start();
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          boundary(row.programme?.start);
          boundary(row.programme?.stop);
          boundary(_epg.getCurrentProgram(row.channel.epgId)?.stop);
          boundary(_epg.getNextProgram(row.channel.epgId)?.start);
          if (i % 128 == 0 && slice.elapsedMilliseconds >= 2) {
            await Future<void>.delayed(Duration.zero);
            slice.reset();
          }
        }
        final result = List<ChannelMatch>.unmodifiable(rows);
        if (key == _pickerKey(game) &&
            until.isAfter(now) &&
            result.length <= 6000) {
          _pickerAlternatives.removeWhere((k, _) =>
              k.generation == key.generation &&
              k.catalogue == key.catalogue &&
              k.fixture == key.fixture);
          _pickerAlternatives[key] = (now, until, result);
          while (_pickerAlternatives.length > 6 ||
              _pickerAlternatives.values
                      .fold<int>(0, (n, e) => n + e.$3.length) >
                  6000) {
            _pickerAlternatives.remove(_pickerAlternatives.keys.first);
          }
        }
        return result;
      } finally {
        _pickerPending.remove(key);
      }
    });
  }

  final SportsMatchGuide _epg;

  List<Channel> _channels = const [];
  List<String> _names = const [];
  // Name-only facts, filled lazily and replaced with every channel index.
  // Dates, game state and current programme evidence are checked separately.
  Uint8List _channelNameFlags = Uint8List(0);
  static const _nameChecked = 1, _nameIdle = 2, _nameReplay = 4;
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
  String? _catalogueFingerprint;
  SportsMatchDiskCache? _diskCache;
  Object? _discoveryKey;
  DateTime? _discoveryUntil;
  List<SportsGame> _discovered = const [];
  Map<(String, int), (String, String, String, String?)> _guideClassifications =
      {};
  Future<List<SportsGame>> discoverGuideEvents(
      {void Function(SportsWorkProgress)? onStatus,
      void Function(SportsGuideDiscovery)? onProgress}) async {
    await _prepareQueue;
    return _discoverGuideEvents(this, onProgress: onProgress);
  }

  List<ChannelMatch> _guideMatches(SportsGame game, SportsMatchPicks picks) =>
      _exactGuideMatches(this, game, picks)
          .where((m) => !_rejectedMatch(picks, game, m))
          .toList();

  bool _rejectedMatch(
          SportsMatchPicks picks, SportsGame game, ChannelMatch m) =>
      picks is SportsMatchRejections &&
      sportsChannelRejected(
          (picks as SportsMatchRejections).rejectedKeysFor(game),
          m.channel.id,
          m.programme ?? _epg.getCurrentProgram(m.channel.epgId));
  Future<void> _prepareQueue = Future.value();
  final Map<String, (Map<String, List<ChannelMatch>>, DateTime, DateTime)>
      _matchCache = {};
  final Map<String, List<ChannelMatch>> _eventMatchCache = {};
  final _eventMatchAge = <String, DateTime>{};
  final _eventMatchUntil = <String, DateTime>{};
  final _eventGuideEvidence = <String, GuideReadEvidence>{};

  void _guideSnapshotChanged(Uint32List? changes,
      {required bool reset, required bool synopsisChanged}) {
    _matchCache.clear();
    final affected = <GuideReadEvidence, bool>{};
    var removed = 0;
    _eventMatchCache.removeWhere((key, _) {
      final evidence = _eventGuideEvidence[key];
      final remove = reset ||
          evidence == null ||
          affected.putIfAbsent(
              evidence,
              () => evidence.affectedBy(changes,
                  synopsisChanged: synopsisChanged));
      if (remove) {
        _eventGuideEvidence.remove(key);
        _eventMatchAge.remove(key);
        _eventMatchUntil.remove(key);
        removed++;
      }
      return remove;
    });
    if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
      debugPrint('IPTV_SPORTS evidence retained=${_eventMatchCache.length} '
          'invalidated=$removed reset=$reset synopsis=$synopsisChanged');
    }
  }

  List<String> _tennisGuideIds = const [];
  final _tennisGuideCache = <String, Future<List<EpgProgram>>>{};
  final _tennisGuideCoverage = <String, List<EpgProgram>>{};
  Object? _synopsisSnapshotKey;
  DateTime? _synopsisSnapshotUntil;
  Future<List<EpgProgram>>? _synopsisSnapshot;

  Future<List<EpgProgram>> _synopsisProgrammes(DateTime now) {
    final key = (_preparedFor, _epg.changeRevision, _epg.lastUpdated);
    if (_synopsisSnapshotKey == key &&
        _synopsisSnapshotUntil?.isAfter(now) == true &&
        _synopsisSnapshot != null) {
      return _synopsisSnapshot!;
    }
    _synopsisSnapshotKey = key;
    _synopsisSnapshotUntil = now.add(const Duration(minutes: 5));
    return _synopsisSnapshot = () async {
      final rows = <EpgProgram>[];
      final slice = Stopwatch()..start();
      for (final id in _byEpgId.keys) {
        for (final p in [_epg.getCurrentProgram(id), _epg.getNextProgram(id)]) {
          if (p == null) continue;
          for (final boundary in [p.start, p.stop]) {
            if (boundary.isAfter(now) &&
                boundary.isBefore(_synopsisSnapshotUntil!)) {
              _synopsisSnapshotUntil = boundary;
            }
          }
          if (p.description?.isNotEmpty != true) continue;
          final title = _fixtureText(p.title);
          if (_guideIdentity(p, title) != title) rows.add(p);
        }
        if (slice.elapsedMilliseconds >= _workSliceMs) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      return rows;
    }();
  }

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

  // Reuse pure text analysis across quality copies and coalesced batches.
  // No channel, timing or confidence decisions live here. The worker's idle
  // and memory-pressure lifecycle releases it with the other matching caches.
  final _programmeIndexes = BoundedIndexCache<_PreparedProgrammes>(
      costOf: (index) => index.rows.length, maxCost: 160000);
  final _programmeTexts =
      _SportsTextCache<(String, String, bool), _ProgrammeTextFacts>(
          budget: 4 * 1024 * 1024);
  DateTime _gameBoundary(SportsGame game, DateTime now) {
    var until = now.add(const Duration(minutes: 5));
    void boundary(DateTime? date) {
      if (date != null && date.isAfter(now) && date.isBefore(until)) {
        until = date;
      }
    }

    boundary(game.end);
    for (final p in game.guideProgrammes) {
      boundary(p.start);
      boundary(p.stop);
    }
    if (isFormulaOne(game)) {
      boundary(game.start.subtract(f1BuildUpLead(game)));
      boundary(game.start);
      boundary(
          game.end ?? game.start.add(f1SessionDuration(game.event?.session)));
    }
    for (final b in game.onlineBroadcasts) {
      boundary(b.expiresAt);
      boundary(b.programme?.start);
      boundary(b.programme?.stop);
    }
    return until;
  }

  Channel? channelById(String id) {
    final i = _byId[id];
    return i == null ? null : _channels[i];
  }

  // Expand only a listed broadcaster, using existing exact channel buckets.
  // Keep stored canonical names unchanged: aliases need no catalogue rebuild,
  // extra guide read or scan, and still pass the normal region/guide vetoes.
  Iterable<int> _listedNetworkChannels(String name) {
    final key = _networkKey(name);
    final aliases = _listedNetworkKeys[key];
    if (aliases == null) return _byCanonical[key] ?? const <int>[];
    return aliases.expand((alias) {
      final channels = _byCanonical[alias] ?? const <int>[];
      if (alias == key) return channels;
      // These synonyms describe US services. For example, Australian Fox
      // Sports 1 is not FS1. Preserve exact matches, but require region evidence
      // before adding a differently named service to a broadcaster's results.
      return channels.where((i) => _listingCountryFits(
          'United States', _names[i], _channelHints(i).group));
    });
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
          {void Function(SportsWorkProgress)? onStatus,
          void Function(SportsGuideDiscovery)? onGuideProgress}) =>
      _prepareQueue = _prepareQueue.then((_) async {
        await _prepare(channels, onStatus);
        if (onGuideProgress != null) {
          await _discoverGuideEvents(this, onProgress: onGuideProgress);
        }
      });

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
      if (i % 256 == 0 && slice.elapsedMilliseconds >= _workSliceMs) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    final signature = '$hash|${channels.length}';
    if (_preparedFor == signature) return;
    final textCache = _channelTextCache;
    await textCache?.load();
    textCache?.retainNames({for (final channel in channels) channel.name});
    var reusedNames = 0;
    final catalogueDigest = _DigestSink();
    final catalogueSink = _diskCache == null
        ? null
        : sha256.startChunkedConversion(catalogueDigest);
    final tokenIndex = <String, List<int>>{};
    final byCanonical = <String, List<int>>{};
    final byEpgId = <String, List<int>>{};
    final byId = <String, int>{};
    final excluded = <int>{};
    final names = List<String>.filled(channels.length, '');
    for (var i = 0; i < channels.length; i++) {
      if (i % 32 == 0 && slice.elapsedMilliseconds >= _workSliceMs) {
        progress.report(SportsWorkStage.channelIndex,
            completed: i, total: channels.length);
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
      final c = channels[i];
      catalogueSink?.add(
          utf8.encode(jsonEncode([c.id, c.rawId, c.name, c.group, c.epgId])));
      final storedText = textCache?[c.name];
      if (storedText != null) reusedNames++;
      final norm = storedText?.$1 ?? _fixtureText(c.name);
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
      final canon = storedText?.$2 ?? _networkKey(c.name);
      textCache?.remember(c.name, norm, canon);
      if (canon.isNotEmpty) (byCanonical[canon] ??= <int>[]).add(i);
      (byEpgId[normalizeEpgId(c.epgId)] ??= <int>[]).add(i);
    }
    catalogueSink?.close();
    _catalogueFingerprint = catalogueDigest.value.toString();
    // Publish a complete index atomically; concurrent callers await it.
    _channels = channels;
    _names = names;
    _channelNameFlags = Uint8List(names.length);
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
    _programmeIndexes.clear();
    _matchCache.clear();
    _eventMatchCache.clear();
    _eventMatchAge.clear();
    _eventMatchUntil.clear();
    _eventGuideEvidence.clear();
    if (_epg is _WorkerGuide) {
      _epg.reads.configure(_byEpgId.keys);
    }
    _tennisGuideCache.clear();
    _tennisGuideCoverage.clear();
    _tennisGuideIds = {
      for (final i in _channelsNaming([' tennis ', ' atp ', ' wta ']))
        if (!_excluded.contains(i) && _channels[i].epgId.isNotEmpty)
          normalizeEpgId(_channels[i].epgId)
    }.take(512).toList();
    if (textCache != null) unawaited(textCache.flush());
    if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
      debugPrint('IPTV_SPORTS channel_text reused=$reusedNames '
          'total=${channels.length}');
    }
  }

  /// Name phrases a channel or programme title may use for [t] — nickname
  /// and full name. City names alone are skipped (two New York teams).
  static ({Set<String> primary, Set<String> all}) _teamPhrases(SportsTeam t,
      {required SportsLeague league}) {
    final college = _isCollege(league), soccer = league.soccer;
    final out = <String>{};
    for (final s in [
      t.shortName,
      t.name,
      if (college) t.location ?? '',
      if (t.abbreviation.trim().length >= 3) t.abbreviation,
    ]) {
      final n = sportsClubIdentity(sportsNormalize(s));
      if (n.trim().length >= (college || s == t.abbreviation ? 3 : 4)) {
        out.add(n);
        if (_nameApostrophe.hasMatch(s)) {
          out.add(sportsClubIdentity(_playerText(s)));
        }
        if (s.contains('.') && _dottedTeamInitials.hasMatch(s)) {
          final compact = sportsClubIdentity(_playerText(s.replaceAllMapped(
              _dottedTeamInitials,
              (m) => '${m[0]!.replaceAll(_initialsSeparators, '')} ')));
          // D.C. United / DC United retain the complete club identity. Do not
          // introduce bare initials from a dotted name with no other words.
          if (compact.trim().contains(' ')) out.add(compact);
        }
      }
    }
    if (soccer) {
      for (final name in out.toList()) {
        out.addAll(sportsSoccerClubAliases(name));
        final country = _koreanNationalTeam.firstMatch(name);
        if (country != null) {
          final aliases = const {'north korea', 'korea dpr', 'dpr korea'}
                  .contains(country[1])
              ? const ['north korea', 'korea dpr', 'dpr korea']
              : const ['south korea', 'korea republic', 'republic of korea'];
          for (final alias in aliases) {
            out.add(' $alias${country[2] ?? ''} ');
          }
        }
        final words = name.trim().split(' ');
        if (const {'fc', 'afc', 'sc'}.contains(words.first)) words.removeAt(0);
        if (words.isNotEmpty &&
            const {'fc', 'afc', 'sc'}.contains(words.last)) {
          words.removeLast();
        }
        // Retain a multiword club identity; never turn a full club name into
        // a city-only match. Guides commonly omit a trailing FC/SC.
        if (words.length >= 2 && words.join(' ').length >= 6) {
          out.add(' ${words.join(' ')} ');
        }
      }
    }
    if (!college) {
      final countryName = soccer
          ? t.name.toLowerCase().trim().replaceFirst(_countryYouthSuffix, '')
          : t.name.toLowerCase().trim();
      for (final alias
          in sportsCountryTeamAliases[countryName] ?? const <String>[]) {
        out.add(sportsNormalize(alias));
      }
    }
    if (college) {
      // Exact normalized identities only. Lookup cost stays proportional to
      // this team's phrases as the verified school vocabulary grows.
      for (final name in out.toList()) {
        final aliases = _schoolAliases[name];
        if (aliases != null) out.addAll(aliases);
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
    final nicknames = <String>{};
    if (!college) {
      if (soccer) {
        for (final name in out) {
          nicknames.addAll(sportsSoccerClubFeedAliases(name));
          // Preserve every identifying word. These abbreviations still need
          // competition + explicit opponents through the contextual path.
          final united = name.startsWith(' united ')
              ? name
              : name.replaceAll(' united ', ' utd ');
          final saint = name.replaceAll(' saint ', ' st ');
          if (united != name) nicknames.add(united);
          if (saint != name) nicknames.add(saint);
          if (united != name && saint != name) {
            nicknames.add(united.replaceAll(' saint ', ' st '));
          }
        }
      }
      // A three-letter word explicitly present in the full team identity is
      // useful (Sky, Sun, Goa, Pau), but only with competition + pair evidence.
      final short = sportsNormalize(t.shortName);
      if (_shortTeamWord.hasMatch(short) &&
          sportsNormalize(t.name).contains(short)) {
        nicknames.add(short);
      }
      // Expand verified identities only within this competition. Do not split
      // arbitrary full names into cities/mascots or infer a college by mascot.
      for (final name in out.toList()) {
        final club = sportsClubAliases(league.id, name);
        if (club == null) continue;
        for (final fullName in club.names) {
          // A longer spelling adds no evidence if an existing whole phrase
          // already finds it. Keep vocabulary and candidate sets compact.
          if (!out.any(fullName.contains)) out.add(fullName);
        }
        nicknames.addAll(club.nicknames);
        // Verified short feed spellings can also occur in the guide. They
        // receive the same contextual checks as nicknames, never global city
        // inference. Exclude a spelling shared by clubs in this directory.
        for (final shortName in club.feedNames) {
          if (identical(sportsClubAliases(league.id, shortName), club)) {
            nicknames.add(shortName);
          }
        }
      }
      // These professional competitions use distinct team mascots. Elsewhere
      // feed nicknames such as "Reds" or "Bulldogs" can identify several clubs;
      // use the reviewed league dictionary instead of trusting that field.
      if (const {
        'nba',
        'wnba',
        'nfl',
        'nhl',
        'mlb',
        'australian-football.afl',
      }.contains(league.id)) {
        final location = sportsNormalize(t.location ?? '');
        for (final name in t.matchingNames.take(4)) {
          if (name.length > 120) continue;
          final n = sportsClubIdentity(sportsNormalize(name));
          if (n.trim().length >= 4 &&
              n != location &&
              !const {
                ' united ',
                ' city ',
                ' football club ',
                ' sporting ',
                ' athletic ',
                ' club ',
                ' team '
              }.contains(n)) {
            nicknames.add(n);
          }
        }
      }
    }
    nicknames.removeAll(out);
    return (
      primary: out,
      all: nicknames.isEmpty ? out : {...out, ...nicknames}
    );
  }

  /// The name groups a channel name or guide title must all contain (one
  /// phrase from each). Team sports: the two teams. Fights: the two
  /// fighters (tennis: players), by full or last name — event channels say
  /// "Allen vs Duncan".
  /// Golf/racing: the event alone ("singapore grand prix").
  static final _expandedNames = Expando<List<List<String>>>();
  static final _primaryNames = Expando<List<List<String>>>();
  static List<List<String>> _nameGroups(SportsGame g) =>
      _expandedNames[g] ??= _buildNameGroups(g);

  static List<List<String>> _buildNameGroups(SportsGame g) {
    switch (g.league.kind) {
      case SportsKind.team:
        final first = _teamPhrases(g.home, league: g.league);
        final second = _teamPhrases(g.away, league: g.league);
        final shared = first.all.intersection(second.all);
        final all = [
          first.all.where((p) => !shared.contains(p)).toList(),
          second.all.where((p) => !shared.contains(p)).toList(),
        ];
        _primaryNames[g] = identical(first.primary, first.all) &&
                identical(second.primary, second.all)
            ? all
            : [
                first.primary.where((p) => !shared.contains(p)).toList(),
                second.primary.where((p) => !shared.contains(p)).toList(),
              ];
        return all;
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
            _scheduledRaceNames(g),
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

  static List<String> _scheduledRaceNames(SportsGame g) {
    final names = (g.event?.matchingNames ?? const <String>[])
        .map(sportsNormalize)
        .where((n) => n.trim().length >= 5)
        .toList();
    // Motorcycle guides abbreviate the Qatar Grand Prix to Qatar/Lusail.
    // Require an explicit calendar identity first; the second name group
    // still requires the series, with timing/session/replay guards unchanged.
    if (const {'racing.motogp', 'racing.moto2', 'racing.moto3'}
            .contains(g.league.id) &&
        names.any(const {
          ' qatar grand prix ',
          ' lusail international circuit ',
          ' losail international circuit ',
        }.contains)) {
      for (final alias in const [' qatar ', ' lusail ', ' losail ']) {
        if (!names.contains(alias)) names.add(alias);
      }
    }
    return names;
  }

  static const _nameSuffixes = {'jr', 'sr', 'ii', 'iii', 'iv'};

  static List<String> _fighterPhrases(SportsTeam t) {
    final full = _playerText(t.name);
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
      if (_playerText(t.shortName).trim().length >= 4) _playerText(t.shortName),
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

  static final _dateMatcher = SportsDateMatcher();
  static bool _dateFits(SportsListingDate date, DateTime reference) =>
      _dateMatcher.matches(date, reference);

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
        // The guide-only worker needs hints only for channels with exact
        // programme bindings, not a fuzzy text index for its whole catalogue.
        final name =
            _names[i].isEmpty ? (_names[i] = _fixtureText(c.name)) : _names[i];
        final date = _dateInName(name);
        final persistent = date == null &&
            !_fixtureSeparator.hasMatch(name) &&
            !_placeholder.hasMatch(name) &&
            !_idleWords.hasMatch(name) &&
            !RegExp(r' (?:ppv|day|court|round|next|end|live) ')
                .hasMatch(name) &&
            name.trim().split(' ').length <= 9;
        return _ChannelHints(
            _groupNames.putIfAbsent(c.group, () => _fixtureText(c.group)),
            date,
            _regionBias(i),
            persistent,
            _networkKey(c.name));
      });

  int _nameFlags(int i) {
    final cached = _channelNameFlags[i];
    if (cached != 0) return cached;
    final name = _names[i];
    return _channelNameFlags[i] = _nameChecked |
        (_idleWords.hasMatch(name) ? _nameIdle : 0) |
        (_replayWords.hasMatch(name) || name.startsWith(' end ')
            ? _nameReplay
            : 0);
  }

  bool _eligible(int i, SportsGame game) {
    if (_excluded.contains(i)) return false;
    final flags = _nameFlags(i);
    if ((flags & _nameIdle) != 0) return false;
    if (game.state != GameState.post && (flags & _nameReplay) != 0) {
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
          !_nonLiveCoverage(p, golfEvent: _golfReplayIdentity(game)) &&
          (listedDate == null || _dateFitsEvent(listedDate, game));
    }
    if (game.league.kind != SportsKind.tennis ||
        (_nameFlags(i) & (_nameIdle | _nameReplay)) != 0) {
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
        : '$title${_fixtureText(_guideDescription(p))}';
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
    final groups = _nameGroups(game);
    var pairs = _tennisPair.allMatches(text).toList();
    // A dash after "A vs B" usually introduces the tournament/date. Only
    // interpret dashes as pair separators when no explicit relation exists.
    if (pairs.isEmpty) {
      pairs = _tennisDashPair.allMatches(text).where((m) {
        final before = '${text.substring(0, m.start)} ';
        final after = ' ${text.substring(m.end)}';
        return (groups[0].any(before.contains) &&
                groups[1].any(after.contains)) ||
            (groups[1].any(before.contains) && groups[0].any(after.contains));
      }).toList();
    }
    if (pairs.length != 1 || _multiTennis.hasMatch(text)) return false;
    final separator = pairs.single;
    final before = '${text.substring(0, separator.start)} ';
    final after = ' ${text.substring(separator.end)}';
    // A different explicit initial must not fall back to the shared surname.
    for (final player in [game.home, game.away]) {
      final words = _playerText(player.name).trim().split(' ');
      if (words.length < 2) continue;
      final initials = RegExp(' ([a-z]) ${RegExp.escape(words.last)} ')
          .allMatches(text)
          .map((m) => m[1]);
      if (initials.isNotEmpty &&
          !initials.contains(words.first[0]) &&
          !text.contains(_playerText(player.name))) {
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
  final Map<String, _GuideQuery> _guideCache = {};
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
    final generation = (_epg.lastUpdated, _guideQueryRevision);
    final key =
        '${_epg.lastUpdated?.millisecondsSinceEpoch}|$_guideQueryRevision|'
        '${from.millisecondsSinceEpoch}|${to.millisecondsSinceEpoch}|'
        '${(terms.toList()..sort()).join('\u0001')}';
    final now = _clock();
    _guideCache.removeWhere((_, v) =>
        v.generation != generation ||
        now.isBefore(v.fetchedAt) ||
        now.difference(v.fetchedAt) > const Duration(minutes: 15));
    final hit = _guideCache[key];
    if (hit != null) return hit.result;
    _GuideQuery? reusable;
    var missing = terms;
    for (final entry in _guideCache.values) {
      if (entry.from.isAfter(from) || entry.to.isBefore(to)) continue;
      // The title query is a substring search. A previous shorter term covers
      // the longer one too, but never the reverse.
      final uncovered =
          terms.where((term) => !entry.terms.any(term.contains)).toSet();
      if (uncovered.isEmpty) return entry.result;
      if (uncovered.length < missing.length) {
        reusable = entry;
        missing = uncovered;
      }
    }
    final previous = reusable;
    late final Future<List<EpgProgram>> future;
    final fresh = _epg.findProgrammesByTitle(from, to, missing.toList());
    future = (previous == null
            ? fresh
            : Future.wait([
                previous.result,
                fresh,
              ]).then((parts) => <String, EpgProgram>{
                  for (final rows in parts)
                    for (final p in rows)
                      '${p.channelId}|${p.start.millisecondsSinceEpoch}': p,
                }.values.toList()))
        .catchError((Object error, StackTrace stack) {
      if (identical(_guideCache[key]?.result, future)) _guideCache.remove(key);
      Error.throwWithStackTrace(error, stack);
    });
    _guideCache[key] = _GuideQuery(generation, from, to,
        {...?previous?.terms, ...terms}, future, previous?.fetchedAt ?? now);
    while (_guideCache.length > 8) {
      _guideCache.remove(_guideCache.keys.first);
    }
    return future;
  }

  /// Suggestions for every game in [games], keyed by
  /// [SportsChannelPicks.eventKey], best first, at most [limit] each.
  // Retain bounded scoreboard identities across progressive/rematch batches.
  final _knownTennisTerms = <String, DateTime>{};

  /// Seed tournament context from the complete schedule before matching smaller
  /// batches. Context is vocabulary only; it never confirms a channel.
  Future<bool> rememberMatchContext(List<SportsGame> games) async {
    final now = _clock();
    var changed = false;
    for (final game in games) {
      if (game.league.kind != SportsKind.tennis) continue;
      for (final term in _MatchTerms._eventTerms(game)) {
        if (!_knownTennisTerms.containsKey(term)) changed = true;
        _knownTennisTerms[term] = now;
      }
    }
    return changed;
  }

  /// Inputs that affect channel evidence. Score/clock updates deliberately do
  /// not invalidate matching; fixture, broadcast and manual-pick changes do.
  static String matchingIdentity(SportsGame g, SportsMatchPicks picks,
          {bool includeBroadcasts = true, bool includePick = true}) =>
      jsonEncode([
        g.league.id,
        g.league.allowSportOnlySuggestions,
        g.id,
        g.start.millisecondsSinceEpoch,
        g.end?.millisecondsSinceEpoch,
        g.home.name,
        g.home.shortName,
        g.home.location,
        g.home.abbreviation,
        g.home.matchingNames,
        g.away.name,
        g.away.shortName,
        g.away.location,
        g.away.abbreviation,
        g.away.matchingNames,
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
          [
            for (final listing in [
              ...g.scoreboardBroadcasts,
              ...g.onlineBroadcasts
            ])
              listing.evidenceKey
          ],
        if (includePick) picks.channelIdFor(g),
        if (includePick && picks is SportsMatchRejections)
          (picks as SportsMatchRejections).rejectedKeysFor(g).toList()..sort(),
      ]);

  /// Finish the watchable window before querying the rest of the day. All
  /// live fixtures stay together so shared-feed confidence is resolved before
  /// publication. The final result still includes every requested fixture.
  Future<Map<String, List<ChannelMatch>>> matchDay(
      List<SportsGame> games, SportsMatchPicks picks,
      {int limit = 8,
      bool includeGuide = true,
      bool includePossible = false,
      void Function(Map<String, List<ChannelMatch>> matches)? onProgress,
      void Function(SportsWorkProgress)? onStatus,
      void Function(List<SportsGame>)? onGuideEvents,
      void Function(SportsGuideDiscovery)? onGuideProgress}) async {
    if (!includeGuide || (onGuideEvents == null && onGuideProgress == null)) {
      return _matchDayProgressive(games, picks,
          limit: limit,
          includeGuide: includeGuide,
          includePossible: includePossible,
          onProgress: onProgress,
          onStatus: onStatus);
    }
    Future<void>? discovery;
    final previewReady = Completer<void>();
    void finishPreview() {
      if (!previewReady.isCompleted) previewReady.complete();
    }

    void startDiscovery() {
      // Offer early guide coverage in a bounded slice, then resume discovery
      // after the first fixture preview. Both keep the same worker snapshot;
      // a later request cannot replace it while either operation still reads it.
      discovery ??= _discoverGuideEvents(this,
              picks: picks,
              onProgress: onGuideProgress,
              resumeAfterPreview: previewReady.future)
          .then<void>((games) => onGuideEvents?.call(games),
              onError: (Object error, StackTrace stack) {
        // The ordinary discovery path remains retryable. Its optional overlap
        // must not discard successful fixture matches if discovery fails.
        debugPrint('Sports discovery: ${error.runtimeType}');
      });
    }

    try {
      await _prepareQueue;
      startDiscovery();
      final result = await _matchDayProgressive(games, picks,
          limit: limit,
          includeGuide: includeGuide,
          includePossible: includePossible,
          onStatus: onStatus,
          onProgress: onProgress,
          onGuideWait: finishPreview);
      onProgress?.call(result);
      return result;
    } finally {
      finishPreview();
      await discovery;
    }
  }

  Future<Map<String, List<ChannelMatch>>> _matchDayProgressive(
      List<SportsGame> games, SportsMatchPicks picks,
      {int limit = 8,
      bool includeGuide = true,
      bool includePossible = false,
      void Function(Map<String, List<ChannelMatch>> matches)? onProgress,
      void Function(SportsWorkProgress)? onStatus,
      void Function()? onGuideWait}) async {
    final now = _clock();
    final hot = games.where((g) => isReadyToWatch(g, now)).toList();
    if (!includeGuide ||
        onProgress == null ||
        hot.isEmpty ||
        hot.length == games.length) {
      return _matchDay(games, picks,
          limit: limit,
          includeGuide: includeGuide,
          includePossible: includePossible,
          onProgress: onProgress,
          onStatus: onStatus,
          onGuideWait: onGuideWait);
    }
    // Learn tournament context from the complete day, not just the first batch.
    for (final g in games.where((g) => g.league.kind == SportsKind.tennis)) {
      for (final term in _MatchTerms._eventTerms(g)) {
        _knownTennisTerms[term] = now;
      }
    }
    void stage(SportsWorkProgress update, int completed) {
      if (onStatus == null) return;
      onStatus(update.stage == SportsWorkStage.matching
          ? SportsWorkProgress(update.stage,
              completed: completed + update.completed,
              total: games.length,
              detail: update.detail,
              failed: update.failed)
          : update);
    }

    final early = await _matchDay(hot, picks,
        limit: limit,
        includePossible: includePossible,
        onProgress: onProgress,
        onStatus: (update) => stage(update, 0),
        onGuideWait: onGuideWait);
    onProgress(early);
    if (const bool.fromEnvironment('IPTV_PROFILE_SPORTS')) {
      debugPrint(
          'IPTV_SPORTS hot_complete events=${hot.length} score_events=${hot.where((g) => !g.isGuideEvent).length} matched=${early.values.where((m) => m.isNotEmpty).length}');
    }
    final hotKeys = hot.map(SportsChannelPicks.eventKey).toSet();
    final remaining = games
        .where((g) => !hotKeys.contains(SportsChannelPicks.eventKey(g)))
        .toList();
    final later = await _matchDay(remaining, picks,
        limit: limit,
        includePossible: includePossible,
        onProgress: (partial) => onProgress({...early, ...partial}),
        onStatus: (update) => stage(update, hot.length),
        onGuideWait: onGuideWait);
    return _resolveFeedConflicts({...early, ...later}, games);
  }

  static bool isReadyToWatch(SportsGame g, DateTime now) =>
      g.state == GameState.live ||
      isF1BuildUp(g, now) ||
      (g.state == GameState.pre &&
          g.start.difference(now) >= const Duration(minutes: -15) &&
          g.start.difference(now) <= const Duration(minutes: 45));

  Future<Map<String, List<ChannelMatch>>> _matchDay(
      List<SportsGame> games, SportsMatchPicks picks,
      {int limit = 8,
      bool includeGuide = true,
      bool includePossible = false,
      bool currentOnly = false,
      void Function(Map<String, List<ChannelMatch>> matches)? onProgress,
      void Function(SportsWorkProgress)? onStatus,
      void Function()? onGuideWait}) async {
    final progress = SportsProgressReporter(onStatus);
    progress.report(
        includeGuide ? SportsWorkStage.guide : SportsWorkStage.matching);
    await _prepareQueue;
    final now = _clock();
    var expired = false;
    _eventMatchAge.removeWhere((key, at) {
      if (!now.isBefore(at) &&
          now.difference(at) < const Duration(minutes: 5) &&
          _eventMatchUntil[key]?.isAfter(now) == true) {
        return false;
      }
      _eventMatchCache.remove(key);
      _eventMatchUntil.remove(key);
      _eventGuideEvidence.remove(key);
      expired = true;
      return true;
    });
    if (expired) _matchCache.clear();
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
      _preparedFor,
      _epg.lastUpdated?.millisecondsSinceEpoch,
      _epg is _WorkerGuide && !currentOnly
          ? _epg.queryRevision
          : _epg.changeRevision,
      limit,
      includePossible,
      if (currentOnly) 'current-guide-preview',
    ]);
    final eventKeys = {
      for (final g in games)
        SportsChannelPicks.eventKey(g):
            '$generation:${g.league.kind == SportsKind.tennis ? tennisIdentity : ''}:${matchingIdentity(g, picks)}',
    };
    DateTime batchExpiry() {
      var until = now.add(const Duration(minutes: 5));
      for (final g in allGames) {
        final key = eventKeys[SportsChannelPicks.eventKey(g)];
        for (final date in [
          _gameBoundary(g, now),
          _eventMatchUntil['full:$key'],
          if (!includeGuide) _eventMatchUntil['quick:$key']
        ]) {
          if (date != null && date.isBefore(until)) until = date;
        }
      }
      return until;
    }

    final cacheKey = eventKeys.values.join('\u0001');
    final fullHit = _matchCache['full:$cacheKey'];
    final hit =
        fullHit ?? (includeGuide ? null : _matchCache['quick:$cacheKey']);
    if (hit != null &&
        !now.isBefore(hit.$2) &&
        now.difference(hit.$2) < const Duration(minutes: 5) &&
        now.isBefore(hit.$3)) {
      return hit.$1;
    }
    final indexVersion = _preparedFor;
    final out = <String, List<ChannelMatch>>{};
    if (games.isEmpty) return out;
    final missing = <SportsGame>[];
    final disk = !currentOnly &&
            includeGuide &&
            _epg is _WorkerGuide &&
            (_epg).diskCacheAllowed
        ? _diskCache
        : null;
    if (disk != null) await disk.load(now);
    String diskKey(SportsGame game) => sha256
        .convert(utf8.encode(jsonEncode([
          21, // Matching semantics version; do not restore older decisions.
          _catalogueFingerprint,
          (_epg as _WorkerGuide).fingerprint,
          limit,
          includePossible,
          if (game.league.kind == SportsKind.tennis) tennisIdentity,
          matchingIdentity(game, picks)
        ])))
        .toString();
    for (final game in games) {
      final id = SportsChannelPicks.eventKey(game);
      final key = eventKeys[id]!;
      if (game.isGuideEvent) {
        out[id] = _guideMatches(game, picks).take(math.max(0, limit)).toList();
        continue;
      }
      var cached = _eventMatchCache['full:$key'] ??
          (includeGuide ? null : _eventMatchCache['quick:$key']);
      if (cached == null && disk != null) {
        final stored = disk.read(diskKey(game), now);
        if (stored != null) {
          cached = _decodeStoredMatches(stored.rows);
          if (cached != null) {
            _eventMatchCache['full:$key'] = cached;
            _eventMatchAge['full:$key'] = stored.savedAt;
            _eventMatchUntil['full:$key'] = stored.expiresAt;
          }
        }
      }
      if (cached != null) {
        out[id] = cached;
      } else {
        missing.add(game);
      }
    }
    if (missing.isEmpty) {
      final resolved = _resolveFeedConflicts(out, allGames);
      _matchCache['${includeGuide ? 'full' : 'quick'}:$cacheKey'] =
          (resolved, now, batchExpiry());
      while (_matchCache.length > 8) {
        _matchCache.remove(_matchCache.keys.first);
      }
      return resolved;
    }
    // Make completed events browsable while their peers are still checking.
    // Until shared-feed owners are known, keep confidence provisional.
    final tennisKeys = allGames
        .where((g) => g.league.kind == SportsKind.tennis)
        .map(SportsChannelPicks.eventKey)
        .toSet();
    final liveSingleKeys = allGames
        .where((g) => g.state == GameState.live && !g.league.isField)
        .map(SportsChannelPicks.eventKey)
        .toSet();
    final progressClock = Stopwatch()..start();
    var publishedFirstMatch = false;
    Map<String, int>? pendingExactFeeds;
    final exactFeedsByEvent = <String, Set<String>>{};
    String feed(Channel channel) =>
        channel.epgId.isEmpty ? channel.id : normalizeEpgId(channel.epgId);
    bool exactReady(ChannelMatch match) =>
        (match.reason == MatchReason.guide ||
            match.reason == MatchReason.name) &&
        pendingExactFeeds != null &&
        !pendingExactFeeds.containsKey(feed(match.channel));
    void publishProgress() {
      if (onProgress == null) return;
      final checked = _resolveFeedConflicts(out, allGames);
      final incomplete = liveSingleKeys.any((key) => !out.containsKey(key));
      List<ChannelMatch> progressMatches(
          String key, List<ChannelMatch> matches) {
        bool pending(ChannelMatch m) =>
            m.isConfident && m.reason != MatchReason.pick && !exactReady(m);
        if (!incomplete ||
            !liveSingleKeys.contains(key) ||
            !matches.any(pending)) {
          return matches;
        }
        return [
          for (final match in matches)
            if (pending(match))
              ChannelMatch(
                  match.channel,
                  tennisKeys.contains(key)
                      ? MatchReason.tournament
                      : MatchReason.league,
                  math.min(match.score, 300),
                  detail: 'Checking other live fixtures',
                  programme: match.programme,
                  supportingBroadcasts: match.supportingBroadcasts)
            else
              match
        ];
      }

      onProgress({
        for (final entry in checked.entries)
          entry.key: progressMatches(entry.key, entry.value)
      });
      if (out.values.any((matches) => matches.isNotEmpty)) {
        publishedFirstMatch = true;
      }
      progressClock.reset();
    }

    if (out.isNotEmpty) publishProgress();
    // Work on watchable fixtures before completed/far-future ones. This only
    // changes processing order, not event ordering or the evidence considered.
    int readiness(SportsGame game) => game.isLive
        ? 0
        : game.state == GameState.pre &&
                game.start.isBefore(now.add(const Duration(hours: 2)))
            ? 1
            : game.state == GameState.post
                ? 3
                : 2;
    final orderedMissing = missing.indexed.toList()
      ..sort((a, b) {
        final priority = readiness(a.$2).compareTo(readiness(b.$2));
        return priority != 0 ? priority : a.$1.compareTo(b.$1);
      });
    games = orderedMissing.map((entry) => entry.$2).toList();

    final contexts = {for (final g in games) g: _MatchTerms(g, tennisTerms)};
    // Query the local guide once, with deduplicated discriminating words.
    // Unlike whole SQL phrases, these also find punctuation/reversed names.
    final raw = <String>{};
    for (final g in games) {
      final context = contexts[g]!;
      for (final phrase in [
        ...context.nameGroups.expand((group) => group),
        ...context.all,
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
    // Both exact and coverage scoring require stop > the game's reference.
    // Query by overlap from that boundary: a programme that started hours ago
    // is still included if it runs across the reference. Keep the full upper
    // window for delayed tennis, fight cards and all-day events.
    var earliest = _guideReference(games.first, now);
    var latest = _guideWindow(games.first).$2;
    for (final g in games) {
      final from = _guideReference(g, now);
      final to = _guideWindow(g).$2;
      if (from.isBefore(earliest)) earliest = from;
      if (to.isAfter(latest)) latest = to;
    }
    progress.report(SportsWorkStage.guide);
    Future<List<EpgProgram>> currentRows(Iterable<String> ids,
        {SportsTitleMatcher? titles}) async {
      final result = <EpgProgram>[];
      final slice = Stopwatch()..start();
      for (final id in ids) {
        for (final p in [_epg.getCurrentProgram(id), _epg.getNextProgram(id)]) {
          if (p != null &&
              p.stop.isAfter(earliest) &&
              p.start.isBefore(latest) &&
              (titles?.matches(p.title) ?? true)) {
            result.add(p);
          }
        }
        if (slice.elapsedMilliseconds >= _workSliceMs) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      return result;
    }

    Future<List<EpgProgram>> tennisGuide() async {
      var tennisProgrammes = const <EpgProgram>[];
      if (includeGuide &&
          _tennisGuideIds.isNotEmpty &&
          games.any((g) => g.league.kind == SportsKind.tennis)) {
        final key = '$_preparedFor|$_guideQueryRevision|${_epg.lastUpdated}|'
            '${earliest.millisecondsSinceEpoch ~/ 3600000}|'
            '${latest.millisecondsSinceEpoch ~/ 3600000}|'
            '${now.millisecondsSinceEpoch ~/ 600000}';
        try {
          tennisProgrammes = currentOnly
              ? await currentRows(_tennisGuideIds)
              : await (_tennisGuideCache[key] ??=
                  _epg.findSportsProgrammesForChannels(
                      _tennisGuideIds,
                      DateTime.fromMillisecondsSinceEpoch(
                          earliest.millisecondsSinceEpoch ~/ 3600000 * 3600000),
                      DateTime.fromMillisecondsSinceEpoch(
                          (latest.millisecondsSinceEpoch ~/ 3600000 + 1) *
                              3600000)));
        } catch (_) {
          _tennisGuideCache.remove(key);
          rethrow;
        }
        while (_tennisGuideCache.length > 4) {
          _tennisGuideCache.remove(_tennisGuideCache.keys.first);
        }
      }
      return tennisProgrammes;
    }

    // Start the local reads before optional current-guide suggestions. The
    // database can run while the worker scores its snapshot. Capture failures
    // immediately, even if the preview is still running when a read fails.
    var guideReady = false;
    final guideRead = Future.wait<List<EpgProgram>>([
      !includeGuide || _byEpgId.isEmpty
          ? Future.value(const <EpgProgram>[])
          : currentOnly
              ? currentRows(_byEpgId.keys, titles: SportsTitleMatcher(terms))
              : _guideHits(earliest, latest, terms),
      tennisGuide(),
    ]).then<Object>((rows) {
      guideReady = true;
      return rows;
    }, onError: (Object error, StackTrace stack) {
      guideReady = true;
      return AsyncError(error, stack);
    });
    if (!currentOnly && includeGuide && _epg is _WorkerGuide) {
      await Future<void>.delayed(Duration.zero);
    }
    // The worker already owns current/next guide metadata. Use it to make
    // live/soon events selectable before the full-day SQL search completes.
    // These are provisional results with a separate cache namespace; they
    // cannot satisfy, replace or pollute the authoritative full-schedule pass.
    if (!guideReady &&
        !currentOnly &&
        includeGuide &&
        onProgress != null &&
        _epg is _WorkerGuide &&
        (_epg).current.isNotEmpty) {
      final ready = missing
          .where((g) =>
              g.isLive ||
              isF1BuildUp(g, now) ||
              (g.state == GameState.pre &&
                  g.start.difference(now) >= const Duration(minutes: -15) &&
                  g.start.difference(now) <= const Duration(minutes: 45)))
          .toList();
      if (ready.isNotEmpty) {
        final audit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
            ? (Stopwatch()..start())
            : null;
        void publishCurrentPreview(Map<String, List<ChannelMatch>> early) {
          // Cached peers also await this cohort's conflict check. Overlaying
          // raw `out` after conversion would restore their old confidence.
          final provisional = <String, List<ChannelMatch>>{
            for (final entry in {...early, ...out}.entries)
              if (entry.value.isNotEmpty)
                entry.key: [
                  for (final match in entry.value)
                    if (!match.isConfident || match.reason == MatchReason.pick)
                      match
                    else
                      ChannelMatch(match.channel, MatchReason.league,
                          math.min(match.score, 300),
                          detail: 'Current guide · checking full schedule',
                          programme: match.programme,
                          supportingBroadcasts: match.supportingBroadcasts)
                ],
          };
          if (provisional.isNotEmpty) onProgress(provisional);
        }

        final early = await _matchDay(ready, picks,
            limit: limit,
            includePossible: includePossible,
            currentOnly: true,
            onProgress: publishCurrentPreview);
        publishCurrentPreview(early);
        if (audit != null) {
          debugPrint(
              'IPTV_SPORTS current_preview events=${ready.length} matched=${early.values.where((rows) => rows.isNotEmpty).length} ms=${audit.elapsedMilliseconds}');
        }
      }
    }
    // The first current-guide preview has had its turn, including an empty
    // preview. Discovery may now use this worker while the SQL result is pending.
    onGuideWait?.call();
    final readResult = await guideRead;
    if (readResult is AsyncError) {
      Error.throwWithStackTrace(readResult.error, readResult.stackTrace);
    }
    final guideResults = readResult as List<List<EpgProgram>>;
    final titleProgrammes = guideResults[0];
    final tennisProgrammes = guideResults[1];
    // Recursive preview scoring has its own coverage. Publish full coverage
    // only after it returns, so a fast SQL reply cannot be overwritten by it.
    if (includeGuide &&
        _tennisGuideIds.isNotEmpty &&
        games.any((g) => g.league.kind == SportsKind.tennis)) {
      _tennisGuideCoverage.clear();
      for (final p in tennisProgrammes) {
        (_tennisGuideCoverage[p.channelId] ??= []).add(p);
      }
    }
    // Now/next metadata is already in memory. Reuse the bounded synopsis
    // candidates across progressive batches, expiring at real slot turnover.
    final synopsisProgrammes = includeGuide &&
            games.any((g) => g.league.kind == SportsKind.team)
        ? (await _synopsisProgrammes(now))
            .where((p) => p.stop.isAfter(earliest) && p.start.isBefore(latest))
        : const <EpgProgram>[];
    // Cached title reads may cover a much wider day than this batch. Retain
    // every scoring reference and the existing cache-boundary margin, without
    // rebuilding postings for unrelated hours from a reusable broad result.
    var indexFrom = earliest, indexTo = latest;
    for (final game in games) {
      final reference = _guideReference(game, now);
      if (reference.isBefore(indexFrom)) indexFrom = reference;
      final boundary = reference.add(const Duration(minutes: 35));
      if (boundary.isAfter(indexTo)) indexTo = boundary;
    }
    indexFrom = DateTime.fromMillisecondsSinceEpoch(
        indexFrom.millisecondsSinceEpoch ~/ 3600000 * 3600000,
        isUtc: true);
    indexTo = DateTime.fromMillisecondsSinceEpoch(
        (indexTo.millisecondsSinceEpoch ~/ 3600000 + 1) * 3600000,
        isUtc: true);
    final programmes = <String, EpgProgram>{
      for (final rows in [
        titleProgrammes,
        tennisProgrammes,
        synopsisProgrammes
      ])
        for (final p in rows)
          if (p.stop.isAfter(indexFrom) &&
              p.start.isBefore(indexTo) &&
              _byEpgId.containsKey(normalizeEpgId(p.channelId)))
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
    final preparation = _prepareQueue;
    final prepared = await _prepareProgrammes(programmes, indexVersion,
        progress: progress, reuseText: !currentOnly && includeGuide);
    // A replacement may still be building and not have published its version.
    // Retry through matchDay's preparation gate before using either catalogue.
    if (prepared == null ||
        indexVersion != _preparedFor ||
        !identical(preparation, _prepareQueue)) {
      return matchDay(allGames, picks,
          limit: limit,
          includeGuide: includeGuide,
          includePossible: includePossible,
          onProgress: onProgress,
          onStatus: onStatus);
    }
    final titles = prepared.titles;
    final guideIdentities = prepared.identities;
    final programmesByChannel = prepared.byChannel;
    final titleIndex = prepared.words;
    final courtIndex = prepared.courts;
    final coverageKinds = <(EpgProgram, String?), bool>{};
    bool recorded(EpgProgram p, SportsGame game) {
      final identity = _golfReplayIdentity(game);
      if (identity != null &&
          _golfRecordedYear
              .allMatches(_fixtureText(p.title))
              .any((m) => int.parse(m[0]!.trim()) < game.start.year)) {
        return true;
      }
      return coverageKinds.putIfAbsent(
          (p, identity), () => _nonLiveCoverage(p, golfEvent: identity));
    }

    final slice = Stopwatch()..start();
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

    Set<int> eventProgrammeCandidates(SportsGame game, _MatchTerms context) => {
          ...candidates(
              context.nameGroups.isEmpty ? [] : context.nameGroups.first,
              guide: true),
          if (context.fightCard != null)
            ...candidates(context.event, guide: true),
          if (game.league.kind == SportsKind.tennis)
            ...courtIndex[_MatchTerms._court(
                    sportsNormalize(game.event?.court ?? ''))] ??
                const <int>[],
        };

    // Only exact name/guide assignments can displace another exact owner.
    // Build a conservative upper bound from the scorer's own postings, never
    // a second fuzzy matcher. Unrelated live fixtures then need not delay a
    // verified channel. Broadcaster/listing suggestions still await the cohort.
    if (onProgress != null &&
        includeGuide &&
        !currentOnly &&
        liveSingleKeys.length > 1) {
      final pending = <String, int>{};
      var memberships = 0, bounded = true;
      for (final game in games) {
        final key = SportsChannelPicks.eventKey(game);
        if (!liveSingleKeys.contains(key)) continue;
        final context = contexts[game]!;
        final feeds = <String>{};
        // Name scoring intersects all opponent groups. Its first group is a
        // safe superset, including aliases and duplicate-quality channels.
        for (final i in candidates(
            context.nameGroups.isEmpty ? [] : context.nameGroups.first)) {
          feeds.add(feed(_channels[i]));
        }
        for (final i in eventProgrammeCandidates(game, context)) {
          for (final channel
              in _byEpgId[normalizeEpgId(programmes[i].channelId)] ??
                  const <int>[]) {
            feeds.add(feed(_channels[channel]));
          }
        }
        for (final programme in game.guideProgrammes) {
          for (final i in _byEpgId[normalizeEpgId(programme.channelId)] ??
              const <int>[]) {
            feeds.add(feed(_channels[i]));
          }
        }
        memberships += feeds.length;
        if (memberships > 65536) {
          bounded = false;
          break;
        }
        exactFeedsByEvent[key] = feeds;
        for (final id in feeds) {
          pending[id] = (pending[id] ?? 0) + 1;
        }
        if (slice.elapsedMilliseconds >= _workSliceMs) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      if (bounded) {
        pendingExactFeeds = pending;
      } else {
        // A very broad alias cannot grow an unbounded dependency graph.
        exactFeedsByEvent.clear();
      }
    }

    final timedCoverage = <(String, int), Set<int>>{};
    Set<int> coverageCandidates(List<String> phrases, DateTime reference) {
      final hour = reference.millisecondsSinceEpoch ~/ 3600000;
      final key = (phrases.join('\u0001'), hour);
      return timedCoverage.putIfAbsent(key, () {
        return candidates(phrases, guide: true)
            .where((i) => prepared.times.containsHour(i, hour))
            .toSet();
      });
    }

    final sharedCoverage = <String,
        ({List<ChannelMatch> matches, Set<int> blocked, DateTime until})>{};
    final validUntil = <String, DateTime>{};
    progress.report(SportsWorkStage.matching,
        completed: out.length, total: allGames.length);
    // Shared coverage can read evidence for several fixtures together. Track
    // the complete scoring batch so those dependencies cannot be lost when a
    // later fixture reuses an earlier fixture's coverage calculation.
    final reads = includeGuide && !currentOnly && _epg is _WorkerGuide
        ? _epg.reads
        : null;
    reads?.begin();
    for (final g in games) {
      if (slice.elapsedMilliseconds >= _workSliceMs) {
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
      var until = _gameBoundary(g, now);
      void evidence(EpgProgram? p) {
        if (p == null) return;
        for (final date in [
          p.start.subtract(const Duration(minutes: 30)),
          p.start,
          p.stop
        ]) {
          if (date.isAfter(now) && date.isBefore(until)) until = date;
        }
      }

      void channelEvidence(int index) {
        final id = _channels[index].epgId;
        evidence(_epg.getCurrentProgram(id));
        evidence(_epg.getNextProgram(id));
      }

      final found = <String, ChannelMatch>{};
      void add(int index, MatchReason reason, int score,
          [String? detail, EpgProgram? programme]) {
        if (_excluded.contains(index)) return;
        channelEvidence(index);
        final c = _channels[index];
        final existing = found[c.id];
        if (existing == null || existing.score < score) {
          found[c.id] = ChannelMatch(c, reason, score,
              detail: detail, programme: programme);
        }
      }

      final rejectedKeys = picks is SportsMatchRejections
          ? (picks as SportsMatchRejections).rejectedKeysFor(g)
          : <String>{};
      final picked = picks.channelIdFor(g);
      if (picked != null) {
        final i = _byId[picked];
        if (i != null) add(i, MatchReason.pick, 1000);
      }
      final context = contexts[g]!;
      final groups = context.nameGroups;
      Set<int>? named;
      for (final group in groups) {
        final hits = candidates(group);
        named = named == null ? hits : named.intersection(hits);
        if (named.isEmpty) break;
      }
      final exact = <int>{};
      for (final i in named ?? const <int>{}) {
        channelEvidence(i);
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
        g.league.allowSportOnlySuggestions,
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
          channelEvidence(i);
          if (slice.elapsedMilliseconds >= _workSliceMs) {
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
        for (final pIndex in coverageCandidates(context.all, reference)) {
          if (slice.elapsedMilliseconds >= _workSliceMs) {
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
          evidence(p);
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
          if ((g.state != GameState.post && recorded(p, g)) ||
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
          blocked: blocked,
          until: until,
        );
        sharedCoverage[sharedKey] = shared;
      }
      if (shared.until.isBefore(until)) until = shared.until;
      for (final match in shared.matches) {
        add(_byId[match.channel.id]!, match.reason, match.score, match.detail,
            match.programme);
      }
      // Only opponent/event-specific postings need examining per individual
      // match. General tournament and sport coverage was scored once above.
      final eventProgrammes = eventProgrammeCandidates(g, context);
      for (final pIndex in eventProgrammes) {
        if (slice.elapsedMilliseconds >= _workSliceMs) {
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
        evidence(p);
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
                    : groups.isEmpty ||
                        !_opponentsFit(g, groups, identity,
                            allowMeeting: identity != title))) ||
            context.conflicts(g, identity) ||
            (g.state != GameState.post && recorded(p, g))) {
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
      final scoreboard = g.scoreboardBroadcasts.isNotEmpty
          ? g.scoreboardBroadcasts
          : [
              for (final name in g.broadcasts)
                SportsBroadcast(name, source: 'ESPN')
            ];
      for (final listing in scoreboard) {
        final network = listing.name;
        if (listing.isStreaming ||
            _streamingOnly.contains(network.toUpperCase())) {
          continue;
        }
        for (final i in _listedNetworkChannels(network)) {
          if (!_eligible(i, g) ||
              !_listingCountryFits(
                  listing.country, _names[i], _channelHints(i).group)) {
            continue;
          }
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
        if (listing.isStreaming ||
            _streamingOnly.contains(listing.name.toUpperCase())) {
          continue;
        }
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
        for (final i in _listedNetworkChannels(name)) {
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
                  : listing.requiresGuide
                      ? MatchReason.league
                      : listing.tournamentOnly
                          ? MatchReason.tournament
                          : MatchReason.listing,
              stronger
                  ? old.score + 25
                  : (listing.requiresGuide
                          ? 180
                          : listing.tournamentOnly
                              ? 330
                              : 360) +
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
            if (recorded(p, g) ||
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
          final originalTitle = _fixtureText(p.title);
          final title = (g.league.kind == SportsKind.team ||
                  g.league.kind == SportsKind.tennis ||
                  g.league.kind == SportsKind.racing)
              ? _guideIdentity(p, originalTitle)
              : originalTitle;
          return context.conflicts(g, title) ||
              f1ProgrammeConflicts(g, title) ||
              (g.state != GameState.post && recorded(p, g)) ||
              (_otherFixture(title) &&
                  !_opponentsFit(g, groups, title,
                      allowMeeting: title != originalTitle &&
                          title.contains(' meet at ') &&
                          context.synopsisNamesFixture(_guideDescription(p))));
        }

        final programme = _epg.getCurrentProgram(match.channel.epgId);
        evidence(programme);
        final next = _epg.getNextProgram(match.channel.epgId);
        evidence(next);
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
      out[SportsChannelPicks.eventKey(g)] = _rankMatches(found.values.where(
              (m) => !sportsChannelRejected(rejectedKeys, m.channel.id,
                  m.programme ?? _epg.getCurrentProgram(m.channel.epgId))))
          .take(math.max(0, limit))
          .toList();
      final eventKey = SportsChannelPicks.eventKey(g);
      for (final id in exactFeedsByEvent.remove(eventKey) ?? const <String>{}) {
        final count = pendingExactFeeds![id]!;
        if (count == 1) {
          pendingExactFeeds.remove(id);
        } else {
          pendingExactFeeds[id] = count - 1;
        }
      }
      validUntil[SportsChannelPicks.eventKey(g)] = until;
      progress.report(SportsWorkStage.matching,
          completed: out.length, total: allGames.length);
      // Publish the first usable result immediately, then coalesce nearby
      // completions so visible cards do not rebuild for every scored event.
      if ((!publishedFirstMatch && found.isNotEmpty) ||
          progressClock.elapsedMilliseconds >= 150) {
        publishProgress();
      }
    }
    if (indexVersion != _preparedFor) {
      return matchDay(allGames, picks,
          limit: limit,
          includeGuide: includeGuide,
          includePossible: includePossible,
          onProgress: onProgress,
          onStatus: onStatus);
    }
    publishProgress();
    final evidence = reads?.finish(
        usesSynopsis: games.any((g) => g.league.kind == SportsKind.team));
    for (final game in games) {
      final id = SportsChannelPicks.eventKey(game);
      final entryKey = '${includeGuide ? 'full' : 'quick'}:${eventKeys[id]}';
      _eventMatchCache[entryKey] = out[id]!;
      _eventMatchAge[entryKey] = now;
      final until = validUntil[id] ?? _gameBoundary(game, now);
      _eventMatchUntil[entryKey] = until;
      if (evidence != null) {
        _eventGuideEvidence[entryKey] = evidence;
      } else {
        _eventGuideEvidence.remove(entryKey);
      }
      if (disk != null) {
        disk.put(diskKey(game), _encodeStoredMatches(out[id]!), now, until);
      }
    }
    while (_eventMatchCache.length > 2048) {
      final oldest = _eventMatchCache.keys.first;
      _eventMatchCache.remove(oldest);
      _eventMatchAge.remove(oldest);
      _eventMatchUntil.remove(oldest);
      _eventGuideEvidence.remove(oldest);
    }
    if (disk != null) unawaited(disk.flush());
    progress.report(SportsWorkStage.verifying,
        completed: out.length, total: allGames.length);
    final resolved = _resolveFeedConflicts(out, allGames);
    _matchCache['${includeGuide ? 'full' : 'quick'}:$cacheKey'] =
        (resolved, now, batchExpiry());
    while (_matchCache.length > 8) {
      _matchCache.remove(_matchCache.keys.first);
    }
    // Reuse postings, not decisions. Exact row/tennis-context comparisons above
    // invalidate edits, including new synopsis evidence on another channel.
    if (!currentOnly && includeGuide && prepared.rows.length <= 160000) {
      _programmeIndexes.retain(prepared);
    }
    return resolved;
  }

  List<Map<String, dynamic>> _encodeStoredMatches(List<ChannelMatch> rows) => [
        for (final m in rows)
          {
            'id': m.channel.id,
            'reason': m.reason.name,
            'score': m.score,
            'detail': m.detail,
            'support': m.supportingBroadcasts,
            if (m.programme case final p?)
              'programme': {
                'id': p.channelId,
                'title': p.title,
                'description': p.description,
                'start': p.start.millisecondsSinceEpoch,
                'stop': p.stop.millisecondsSinceEpoch,
                'live': p.isLive,
              },
          }
      ];

  List<ChannelMatch>? _decodeStoredMatches(List<dynamic> rows) {
    try {
      final result = <ChannelMatch>[];
      for (final row in rows) {
        final channel = channelById(row['id'] as String);
        if (channel == null) return null;
        final p = row['programme'] as Map?;
        result.add(ChannelMatch(
            channel,
            MatchReason.values.byName(row['reason'] as String),
            row['score'] as int,
            detail: row['detail'] as String?,
            supportingBroadcasts: (row['support'] as List).cast<String>(),
            programme: p == null
                ? null
                : EpgProgram(
                    channelId: p['id'] as String,
                    title: p['title'] as String,
                    description: p['description'] as String?,
                    isLive: p['live'] == true,
                    start:
                        DateTime.fromMillisecondsSinceEpoch(p['start'] as int),
                    stop: DateTime.fromMillisecondsSinceEpoch(
                        p['stop'] as int))));
      }
      return result;
    } catch (_) {
      return null;
    }
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
            : '${_fixtureText(current.title)}${_fixtureText(_guideDescription(current))}',
        next: next,
        nextText: next == null
            ? ''
            : '${_fixtureText(next.title)}${_fixtureText(_guideDescription(next))}'
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
        if (i % 64 == 0 && slice.elapsedMilliseconds >= _workSliceMs) {
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
            groups.putIfAbsent(c.group, () => related(_fixtureText(c.group))) ||
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
      if (slice.elapsedMilliseconds >= _workSliceMs) {
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
    final normalized = _fixtureText(query).trim();
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
      if (i % 32 == 0 && slice.elapsedMilliseconds >= _workSliceMs) {
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
    final key = '${_fixtureText(query)}|$limit';
    final cached = _searchCache[key];
    if (cached != null) return cached;
    final words = _fixtureText(query)
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

// Exact linear-service synonyms, never parent networks, streaming products,
// regional affiliates or alternate feeds. A group is indexed in both directions
// once, preserving every original key and avoiding per-fixture normalisation.
final _listedNetworkKeys = _buildListedNetworkKeys();
Map<String, List<String>> _buildListedNetworkKeys() {
  final result = <String, List<String>>{};
  for (final names in const [
    ['ACCN', 'ACC Network'],
    ['SECN', 'SEC Network'],
    ['CBSSN', 'CBS Sports Network'],
    ['BTN', 'Big Ten Network'],
    ['FS1', 'Fox Sports 1'],
    ['FS2', 'Fox Sports 2'],
    ['ESPNU', 'ESPN U'],
    ['Golf Chnl', 'Golf Channel'],
    ['USA Net', 'USA Network'],
    ['NBA TV', 'NBATV'],
  ]) {
    final keys = names.map(canonicalChannelKey).toSet().toList();
    for (final key in keys) {
      result[key] = keys;
    }
  }
  return result;
}

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
final _tennisDashPair = RegExp(r' ~ ');
final _fixtureStructure = RegExp(r' [|~] ');
final _multiTennis = RegExp(
    r' (?:followed by|also featuring|also in action|matches include|line up|lineup|plus|later today|later on|and then) ');
final _tennisCourtBrand = RegExp(r'^ (?:centre|center) court ');
final _coverageOpponent = RegExp(
    r' (?:vs|v|versus) (?:day|early round|round|coverage|semifinals?|finals?|court|session|qualifying) ');
final _replayWords = RegExp(
    r' (?:replays?|repeat|re air(?:s)?|reairs?|rebroadcast|highlights?|hlts|hls|h l|condensed|recap|roundup|round up|classic|interviews?|news|movie|film|documentary|magazine|best of|top (?!14 )\d+|top 14 (?:tries|goals|moments|plays|hits|tackles)|shots of) ');
// Guide titles can name the exact opponents while the synopsis reveals
// highlights or a repeat. Only introductory coverage copy is evidence;
// mentioning a previous meeting later in a live description is not.
final _nonLiveIntro = RegExp(
    r'^(?:(?:watch|a|the|full|extended|match|game|race|event) )*(?:highlights?|replay|repeat|rebroadcast|re air|condensed|documentary|movie|film|news|interview)\b|^(?:another chance to (?:watch|see)|relive)\b');
final _recordedRaceSession = RegExp(
    r'^[^.]{0,100}\b(?:race|practice|qualifying|shootout)\s+(?:\d+\s+)?(?:replay|repeat|highlights)\b',
    caseSensitive: false);
// A feed's full tournament identity can contain "Classic". Only exempt that
// exact name, leaving other replay words and separate "classic" labels intact.
final _golfRecordedYear = RegExp(r' (?:19|20)\d{2}(?= )');
final _golfReplayNames = Expando<String>();
String? _golfReplayIdentity(SportsGame game) {
  if (game.league.kind != SportsKind.golf) return null;
  final identity =
      _golfReplayNames[game] ??= _fixtureText(game.event?.title ?? '');
  return identity.contains(' classic ') && identity.trim() != 'classic'
      ? identity
      : null;
}

final _nonLiveCoverageCache =
    _SportsTextCache<(String, String, String?), bool>();
bool _nonLiveCoverage(EpgProgram programme, {String? golfEvent}) {
  final description = _guideDescription(programme);
  final key = (programme.title, description, golfEvent);
  final cached = _nonLiveCoverageCache[key];
  if (cached != null) return cached;
  final title = _fixtureText(programme.title);
  final replayTitle = golfEvent == null
      ? title
      : title.replaceAll(golfEvent, golfEvent.replaceAll(' classic ', ' '));
  final result = _unavailableGuide.hasMatch(title) ||
      _nonEventGuide.hasMatch(title) ||
      _replayWords.hasMatch(replayTitle) ||
      _nonLiveIntro.hasMatch(_fixtureText(description).trim()) ||
      _recordedRaceSession.hasMatch(description);
  if (programme.title.length <= 1024) {
    _nonLiveCoverageCache.put(
        key, result, programme.title.length + description.length);
  }
  return result;
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
const _schoolAliasGroups = [
  [
    'northwestern state',
    'northwestern st',
    'n western state',
    'n western st',
    'nwestern state',
    'nwestern st'
  ],
  ['app state', 'appalachian state'],
  ['southern miss', 'southern mississippi'],
  ['uconn', 'connecticut'],
  ['ole miss', 'mississippi'],
  ['umass', 'massachusetts'],
  ['fau', 'florida atlantic'],
  ['usf', 'south florida'],
  ['ucf', 'central florida'],
  ['lsu', 'louisiana state'],
  ['boston university', 'boston u'],
  ['unc greensboro', 'uncg'],
  ['unc wilmington', 'uncw'],
  ['uab', 'alabama birmingham', 'alabama at birmingham'],
  ['umbc', 'maryland baltimore county'],
  ['uic', 'illinois chicago'],
  ['uc davis', 'california davis'],
  ['uc irvine', 'california irvine'],
  ['uc riverside', 'california riverside'],
  ['uc san diego', 'california san diego'],
  ['uc santa barbara', 'california santa barbara'],
  ['ucla', 'uc los angeles', 'california los angeles'],
];
final _schoolAliases = <String, List<String>>{
  for (final group in _schoolAliasGroups)
    for (final name in group)
      ' $name ': [for (final alias in group) ' $alias '],
};
final _shortTeamWord = RegExp(r'^ [a-z]{3} $');
final _schoolPrefix = RegExp(
    r'(?: north| south| east| west| northern| southern| eastern| western| central| mount| saint| st| uc| cal) $');
final _schoolSuffix = RegExp(
    r'^ (?:state|st|tech|a m|oh|fl|ny|pa|united|city|greensboro|wilmington|(?:at )?birmingham|baltimore county|chicago|southern|northern|eastern|western|central|valley|gulf coast|peay|wesleyan|dominican|kingsville|lynchburg|eau claire|newark|pomona|fort wayne|illinois|oklahoma|kearney|platteville|miss|corpus christi|commonwealth|river falls|davis|irvine|riverside|san diego|santa barbara|los angeles) ');

// Longer, distinct clubs found in the competition directories. A short feed
// identity must not consume the beginning of one of these other club names.
// Full identities still match independently; no new aliases are introduced.
const _soccerNameExtensions = <String, List<String>>{
  ' tokyo ': ['verdy '],
  ' independiente ': ['rivadavia '],
  ' nacional ': ['potosi ', 'asuncion '],
  ' ceuta ': ['6 de junio '],
  ' colorado ': ['springs '],
  ' stirling ': ['university '],
  ' cerro ': ['largo '],
  ' ado ': ['den haag '],
  ' afc ': ['34 '],
};

// The feed may shorten "Argentina U17" to "Argentina". Age evidence must
// survive those aliases; otherwise different squads become the same fixture.
final _koreanNationalTeam = RegExp(
    r'^ (north korea|korea dpr|dpr korea|south korea|korea republic|republic of korea)( u ?\d{2})? $');
final _countryYouthSuffix = RegExp(r' (?:u ?|under ?)(?:1[0-9]|2[0-3])$');
final _teamAge =
    RegExp(r' (?:u ?|under ?|sub ?|moins de |unter |до )(1[0-9]|2[0-3]) ');
final _teamAges = Expando<int>();
const _regionalBaseballLeagues = {'baseball.npb', 'baseball.kbo'};
final _regionalBaseballReserve =
    RegExp(r' (?:farm|reserves?|futures|minor league) |ファーム|二軍|2軍|2군|퓨처스');
int _teamAgeGroup(SportsGame game) => _teamAges[
    game] ??= int.tryParse(_teamAge.firstMatch(sportsNormalize(
            '${game.league.name} ${game.home.name} ${game.away.name}'))?[1] ??
        '') ??
    0;

bool _opponentsFit(SportsGame game, List<List<String>> groups, String text,
    {bool allowMeeting = false}) {
  if (groups.isEmpty || !groups.every((g) => g.any(text.contains))) {
    return false;
  }
  if (game.league.kind != SportsKind.team) return true;
  // Youth and reserve teams can share the senior clubs' complete identities.
  final regionalBaseball = _regionalBaseballLeagues.contains(game.league.id);
  if (regionalBaseball && _regionalBaseballReserve.hasMatch(text)) return false;
  if (game.league.soccer ||
      game.league.id == 'basketball.bleague' ||
      regionalBaseball) {
    final ownAge = _teamAgeGroup(game);
    final listedAge = int.tryParse(_teamAge.firstMatch(text)?[1] ?? '') ?? 0;
    if (ownAge != listedAge) return false;
    if (ownAge == 0 && text.contains(' youth ')) return false;
  }
  final college = _isCollege(game.league);
  if (!college) {
    final primary = SportsChannelMatcher._primaryNames[game];
    if (primary != null && !identical(primary, groups)) {
      if (primary.every((g) => g.any(text.contains))) {
        groups = primary;
      } else if (!(_teamAliasEvidence[game] ??=
              _TeamAliasEvidence(game, groups))
          .allows(text)) {
        return false;
      }
    }
    // Short codes are useful only with an explicit matchup and competition.
    // A prose mention of BOS/TOR must not confirm a professional fixture.
    bool codeOnly(SportsTeam team, List<String> phrases) {
      final code = sportsNormalize(team.abbreviation);
      return code.trim().isNotEmpty &&
          text.contains(code) &&
          !phrases.any((p) => p != code && text.contains(p));
    }

    if (codeOnly(game.home, groups[0]) || codeOnly(game.away, groups[1])) {
      // Cache the complete vocabulary even when this candidate used primary
      // names. A later short-name candidate must see the same pair evidence.
      final evidence = _teamAliasEvidence[game] ??=
          _TeamAliasEvidence(game, SportsChannelMatcher._nameGroups(game));
      if (!evidence.competition.any(text.contains) ||
          !(evidence.pair?.hasMatch(text) ?? false)) {
        return false;
      }
    }
  }
  List<(int, int)> spans(List<String> phrases) {
    final result = <(int, int)>[];
    for (final phrase in phrases) {
      var from = 0;
      while (from < text.length) {
        final start = text.indexOf(phrase, from);
        if (start < 0) break;
        final end = start + phrase.length;
        from = start + 1;
        // A different explicitly named club must not satisfy a short identity.
        if (game.league.soccer &&
            (_soccerNameExtensions[phrase]
                    ?.any((suffix) => text.startsWith(suffix, end)) ??
                false)) {
          continue;
        }
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
  final explicitPair = _teamSynopsisConnector.hasMatch(text);
  // "Michigan State" cannot count as both Michigan and Michigan State.
  // A country/network label before a delimiter cannot supply the other side
  // of an explicit fixture in the following segment.
  return first.any((a) => second.any((b) {
        if (a.$2 > b.$1 && b.$2 > a.$1) return false;
        final between = a.$2 <= b.$1
            ? text.substring(a.$2, b.$1)
            : text.substring(b.$2, a.$1);
        return !between.contains('|') &&
            (!explicitPair ||
                _teamSynopsisConnector.hasMatch(between) ||
                (allowMeeting &&
                    (between == ' and ' || between == ' and the ') &&
                    _meetingFixtureTail
                        .hasMatch(text.substring(math.max(a.$2, b.$2)))));
      }));
}

final _teamAliasEvidence = Expando<_TeamAliasEvidence>();

/// Extra nicknames never establish a fixture by incidental prose alone. The
/// expensive expression is lazy and only evaluated when original identities
/// cannot already prove both opponents. No work scales with the team catalogue.
class _TeamAliasEvidence {
  _TeamAliasEvidence(this.game, this.groups);
  final SportsGame game;
  final List<List<String>> groups;
  late final pair = _buildPair();
  RegExp? _buildPair() {
    final expanded = <Set<String>>[];
    for (final group in groups) {
      final names = group.toSet();
      for (final phrase in group) {
        final club = sportsClubAliases(game.league.id, phrase);
        if (club != null) names.addAll(club.names);
      }
      expanded.add(names);
    }
    if (expanded.length != 2) return null;
    final shared = expanded[0].intersection(expanded[1]);
    // Retrieval can omit longer names containing an existing short phrase.
    // Pair validation must consume the full verified spelling, longest first,
    // so its remainder check cannot mistake the rest of that name for prose.
    return _opponentPair([
      for (final names in expanded)
        names.where((name) => !shared.contains(name)).toList()
          ..sort((a, b) => b.length.compareTo(a.length)),
    ], allowDash: true);
  }

  late final competition = <String>{
    for (final label in [
      game.league.name,
      game.league.shortName,
      ...game.league.seriesPhrases,
    ]) ...[
      sportsNormalize(label),
      // Guide text already canonicalises labels such as Femenil to Women.
      sportsNormalize(sportsLanguageText(label)),
    ],
  }.where((p) => p.trim().length >= 3).toList(growable: false);
  bool allows(String text) {
    if (!competition.any(text.contains)) return false;
    final match = pair?.firstMatch(text);
    if (match == null) return false;
    // Do not read "Roar vs Phoenix Rising" as "Roar vs Phoenix" (or a
    // prefixed different club as the first side). Nickname-only evidence is
    // deliberately limited to simple labelled fixtures, not free-form prose.
    var surrounding = '${text.substring(0, match.start + 1)} '
        '${text.substring(match.end - 1)}';
    for (final label in competition) {
      surrounding = surrounding.replaceAll(label, ' ');
    }
    return surrounding.split(_aliasContextSeparator).every((word) =>
        word.isEmpty ||
        _aliasDecorations.contains(word) ||
        int.tryParse(word) != null);
  }
}

final _aliasContextSeparator = RegExp(r'[\s|~]+');
const _aliasDecorations = {
  'live',
  'soccer',
  'football',
  'basketball',
  'baseball',
  'hockey',
  'australian',
  'rules',
  'men',
  'mens',
  'women',
  'womens',
  'round',
  'week',
  'matchday',
  'game',
  'match',
  'day',
  'hd',
  'fhd',
  'uhd',
  'sd',
  '4k',
  '50fps',
  '60fps',
  'au',
  'aus',
  'nz',
  'uk',
  'us',
  'ca',
  'jp',
  'kr',
};

// A coordinated subject is not a fixture on its own. Require the complete
// present-tense venue/game sentence, using both verified participant names.
const _meetingFixtureTailPattern =
    r' meet at [a-z0-9 ]{1,80} for (?:a |an |the )?(?:regular season |preseason |postseason )?(?:(?:ncaa|nba|wnba|nhl|nfl|mlb) )?(?:game|match|contest) ';
final _meetingFixtureTail = RegExp('^$_meetingFixtureTailPattern');

RegExp? _opponentPair(List<List<String>> groups,
    {bool allowDash = false, bool meeting = false}) {
  if (groups.length != 2 || groups.any((g) => g.isEmpty)) return null;
  String side(List<String> group) =>
      '(?:${group.map((p) => RegExp.escape(p.trim())).join('|')})';
  // Only the structured title normalizer creates '~' from a spaced dash.
  // Label boundaries ('|') and hyphens inside a club name cannot join teams.
  final connector = meeting
      ? ' and (?:the )?'
      : allowDash
          ? '(?:$_fixtureConnectorPattern| ~ )'
          : _fixtureConnectorPattern;
  final tail = meeting ? _meetingFixtureTailPattern : ' ';
  return RegExp(' (?:${side(groups[0])}$connector${side(groups[1])}|'
      '${side(groups[1])}$connector${side(groups[0])})$tail');
}

final _explicitSports = RegExp(sportsExplicitSportPattern);
final _slotSportLabel =
    RegExp(r' (?:soccer|football|tennis|volleyball) ppv \d+ ');
String _guideDescription(EpgProgram programme) {
  final description = programme.description?.trim() ?? '';
  return description.substring(0, math.min(description.length, 640));
}

final _synopsisOtherTime = RegExp(
    r' (?:tomorrow|yesterday|last (?:week|month|season|year)|next (?:week|month|season|year)|previous meeting|highlights|replay) ');
const _fixtureConnectorPattern = sportsFixtureConnectorPattern;
final _teamSynopsisConnector = RegExp(_fixtureConnectorPattern);
final _guideSportContext = RegExp(
    r' (?:volleyball|basketball|nba|wnba|baseball|mlb|npb|kbo|softball|soccer|football|hockey|nhl|rugby|golf|nfl|ncaaf|premier league|laliga|la liga|uefa|ncaa|sportscene|scottish championship) ');

final _guideIdentityCache = _SportsTextCache<(String, String), String>();
String _guideIdentity(EpgProgram programme, String title) {
  if (_otherFixture(title)) return title;
  final description = _guideDescription(programme);
  final key = (title, description);
  final cached = _guideIdentityCache[key];
  if (cached != null) return cached;
  final result = _guideIdentityText(title, description);
  if (title.length <= 1024) {
    _guideIdentityCache.put(
        key, result, title.length + description.length + result.length);
  }
  return result;
}

final _synopsisCoverageTitle = RegExp(
    r' (?:tennis|atp|wta|supercars|supercar|motogp|moto gp|moto2|moto3|formula 1|formula one|formula e|nascar|indycar|wec|imsa|world superbike|worldsbk|motorsport|motor racing) ');
String _guideIdentityText(String title, String synopsis) {
  // Generic "College Soccer" titles often put the actual opponents in the
  // synopsis. Inspect only the already-retrieved, bounded text. An explicit
  // different fixture in the title always wins over incidental synopsis text.
  final coverageTitle = _synopsisCoverageTitle.hasMatch(title);
  if (!coverageTitle && !sportsSynopsisMayNameFixture(synopsis)) return title;
  final titleHasSport = coverageTitle || _guideSportContext.hasMatch(title);
  if (!titleHasSport && !sportsSynopsisMayNameSport(synopsis)) return title;
  final description = _fixtureText(synopsis.replaceAll('@', ' at '));
  // Bounded synopsis indexing happens once, not per match or database row.
  if (coverageTitle) {
    return '$title$description';
  }
  if (!titleHasSport && !_explicitSports.hasMatch(description)) {
    return title;
  }
  if (!_teamSynopsisConnector.hasMatch(description)) return title;
  return '$title$description';
}

final _women = RegExp(
    r' (?:women|womens|female|ladies|femenil|femenina|femenino)(?: s)? | (?:soccer|volleyball|basketball|tennis) w | w (?:soccer|volleyball|basketball|tennis) ');
final _men = RegExp(
    r' (?:men|mens|male)(?: s)? | (?:soccer|volleyball|basketball|tennis) m | m (?:soccer|volleyball|basketball|tennis) ');
final _hockeyGender = (
  men: RegExp(r' hockey m | m (?:ice |field )?hockey '),
  women: RegExp(r' hockey w | w (?:ice |field )?hockey '),
);
final _rugbyGender = (
  men: RegExp(r' rugby m | m rugby '),
  women: RegExp(r' rugby w | w rugby '),
);

// Event-independent text facts can be shared across fixtures. Keep decisions
// in _MatchTerms: the same title can fit one sport/gender and contradict another.
class _ConflictEvidence {
  _ConflictEvidence(String text)
      : eventText = text.replaceAll(_slotSportLabel, ' ');
  final String eventText;
  late final sports = _explicitSports
      .allMatches(eventText)
      .map((m) => switch (m[1]!) {
            'american football' ||
            'college football' ||
            'nfl' ||
            'ncaaf' =>
              'football',
            'nba' || 'wnba' => 'basketball',
            'mlb' || 'npb' || 'kbo' => 'baseball',
            'nhl' || 'ice hockey' => 'hockey',
            'field hockey' => 'field-hockey',
            'table tennis' => 'table-tennis',
            'atp' || 'wta' => 'tennis',
            final name => name,
          })
      .toSet();
  late final men = _men.hasMatch(eventText);
  late final women = _women.hasMatch(eventText);
}

final _conflictEvidenceCache = _SportsTextCache<String, _ConflictEvidence>();
_ConflictEvidence _conflictEvidence(String text) {
  final cached = _conflictEvidenceCache[text];
  if (cached != null) return cached;
  final result = _ConflictEvidence(text);
  if (text.length <= 2048) {
    // The sport names come from a fixed vocabulary. Allow for that set as well
    // as both strings; no guide, fixture or channel objects are retained here.
    _conflictEvidenceCache.put(
        text, result, text.length + result.eventText.length + 256);
  }
  return result;
}

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
  // One context belongs to one immutable fixture. Retrieval, title checks and
  // synopsis validation must share exactly the same opponent vocabulary.
  late final nameGroups = SportsChannelMatcher._nameGroups(_game);
  late final String? fightCard = _game.league.espnPath.startsWith('mma/')
      ? _numberedFightCard(sportsNormalize(_game.event?.title ?? ''))
      : null;
  late final RegExp? _synopsisPair = _opponentPair(nameGroups);
  late final RegExp? _synopsisMeetingPair =
      _opponentPair(nameGroups, meeting: true);

  bool synopsisNamesFixture(String description) {
    final text = _fixtureText(description.replaceAll('@', ' at '));
    final pair = _synopsisPair?.firstMatch(text) ??
        (text.contains(' meet at ')
            ? _synopsisMeetingPair?.firstMatch(text)
            : null);
    if (pair == null ||
        _multiTennis.hasMatch(text) ||
        !_opponentsFit(_game, nameGroups, text, allowMeeting: true)) {
      return false;
    }
    // A schedule preview or recap can mention today's opponents together.
    // Inspect nearby qualifiers, not unrelated history later in a synopsis.
    final local = text.substring(
        math.max(0, pair.start - 32), math.min(text.length, pair.end + 48));
    return !_synopsisOtherTime.hasMatch(local);
  }

  static String _leagueSport(SportsLeague league) =>
      league.espnPath == 'baseball/college-softball'
          ? 'softball'
          : league.espnPath.split('/').first;
  late final _sportKey = _leagueSport(_game.league);
  late final _sportNamedClubs = _game.league.kind == SportsKind.team
      ? [_game.home.name, _game.away.name]
          .map(_playerText)
          .where((name) =>
              name.trim().contains(' ') && _explicitSports.hasMatch(name))
          .toList(growable: false)
      : const <String>[];
  // Do not widen the hot gender expressions for every sport. These compact
  // labels need an extra check only in hockey and rugby fixture contexts.
  late final _compactGender = switch (_sportKey) {
    'hockey' || 'field-hockey' => _hockeyGender,
    'rugby' => _rugbyGender,
    _ => null,
  };
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
      switch (_leagueSport(league)) {
        'tennis' => ['tennis'],
        'soccer' => ['soccer', 'football'],
        'football' => ['american football'],
        'basketball' => ['basketball'],
        'hockey' => ['hockey', 'ice hockey'],
        'field-hockey' => ['field hockey'],
        'baseball' => ['baseball'],
        'softball' => ['softball'],
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
    final title = _fixtureText(game.event?.title ?? '')
        .replaceFirst(RegExp(r' (?:presented by|powered by) .*'), ' ');
    if (title.trim().length < 6) return [];
    final out = <String>{
      title,
      if (game.league.espnPath.startsWith('mma/'))
        if (_numberedFightCard(title) case final card?) card,
      for (final name in game.event?.matchingNames ?? const <String>[])
        if (_fixtureText(name).trim().length >= 4 &&
            !_generic.contains(_fixtureText(name).trim()))
          _fixtureText(name),
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
    final venue = _fixtureText(game.event?.venue ?? '');
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
  static final _golfRoundLabel = RegExp(
      r' (?:round ([1-4])|day ([1-4])|(first|second|third|fourth|1st|2nd|3rd|4th) round) ');
  static const _golfOrdinals = {
    'first': '1',
    '1st': '1',
    'second': '2',
    '2nd': '2',
    'third': '3',
    '3rd': '3',
    'fourth': '4',
    '4th': '4',
  };
  static String? _golfRound(String text) {
    final round = _golfRoundLabel.firstMatch(text);
    return round == null
        ? null
        : round[1] ?? round[2] ?? _golfOrdinals[round[3]];
  }

  // Quality/regional copies repeat the same evidence. Conflict checks depend
  // only on this immutable event context and the text, not the channel/clock.
  // Keep a small per-event memo rather than re-running every sport expression.
  final _conflictCache = <String, bool>{};
  bool conflicts(SportsGame game, String text) {
    if (!identical(game, _game)) return _conflicts(game, text);
    final cached = _conflictCache[text];
    if (cached != null) return cached;
    final result = _conflicts(game, text);
    if (text.length <= 2048) {
      if (_conflictCache.length >= 256) {
        for (final key
            in _conflictCache.keys.take(64).toList(growable: false)) {
          _conflictCache.remove(key);
        }
      }
      _conflictCache[text] = result;
    }
    return result;
  }

  bool _conflicts(SportsGame game, String text) {
    if (fightCard != null) {
      final other = _numberedFightCard(text);
      if (other != null && other != fightCard) return true;
    }
    final sport = _sportKey;
    // Some providers append "US: SOCCER PPV 4" to every kind of event.
    // Treat the event's sport as evidence, not that routing-slot label.
    final evidence = _conflictEvidence(text);
    final eventText = evidence.eventText;
    final namedSports = evidence.sports;
    if (namedSports.isNotEmpty && !namedSports.contains(sport)) {
      // "Rugby Borough" is a soccer club, not a rugby broadcast. Only remove
      // an exact full club identity, and only on this rare conflicting path.
      var context = eventText;
      for (final name in _sportNamedClubs) {
        context = context.replaceAll(name, ' ');
      }
      final remaining = identical(context, eventText)
          ? namedSports
          : _conflictEvidence(context).sports;
      if (remaining.isNotEmpty && !remaining.contains(sport)) return true;
    }
    if (sport == 'golf' &&
        game.league.id != 'golf.champions-tour' &&
        (eventText.contains(' pga tour champions ') ||
            eventText.contains(' champions tour '))) {
      return true;
    }
    if (game.league.kind == SportsKind.racing) {
      // Distinguish Le Mans cars/bikes/supports and other endurance series
      // before a shared venue can contribute matching evidence.
      final otherEndurance = enduranceSeriesPatterns.containsKey(game.league.id)
          ? enduranceLeagueId(eventText.replaceAll(_fixtureStructure, ' '), '')
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
    // Australian guides use ALW/ALM instead of spelling out the competition.
    // The same club names occur in both competitions.
    if (sport == 'soccer' &&
        ((female && eventText.contains(' alm ')) ||
            (male && eventText.contains(' alw ')))) {
      return true;
    }
    if ((female && evidence.men && !evidence.women) ||
        (male && evidence.women && !evidence.men)) {
      return true;
    }
    final compactGender = _compactGender;
    if (compactGender != null &&
        ((female &&
                compactGender.men.hasMatch(eventText) &&
                !compactGender.women.hasMatch(eventText) &&
                !evidence.women) ||
            (male &&
                compactGender.women.hasMatch(eventText) &&
                !compactGender.men.hasMatch(eventText) &&
                !evidence.men))) {
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
      'basketball': [
        'nba',
        'wnba',
        'nbl',
        'college basketball',
        'ncaa basketball'
      ],
      'hockey': ['nhl', 'college hockey'],
      'football': ['nfl', 'college football', 'ncaaf'],
      'baseball': ['mlb', 'college baseball'],
      'golf': ['pga', 'lpga', 'liv golf', 'dp world tour'],
    };
    final siblings = families[sport];
    if (siblings != null) {
      final own = _familyIdentity;
      final named = siblings.where((s) => text.contains(' $s ')).toList();
      if (named.isNotEmpty &&
          !named.any((s) =>
              own.contains(' $s ') ||
              (_isCollege(game.league) &&
                  (s == 'college basketball' || s == 'ncaa basketball')))) {
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
      if (bySport && game.league.allowSportOnlySuggestions) {
        return (score: guide ? 120 : 80, reason: MatchReason.sport);
      }
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
    'japan': ['jp', 'jpn', 'japan', 'japanese'],
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
