import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/sports.dart';
import 'sports_channel_matcher.dart';
import 'sports_match_inputs.dart';

/// Presentation state for one day/catalogue. Only completed, current-input
/// results replace a completed check. A progressive batch can populate a new
/// event, but cannot erase an existing guide match while rechecking it.
class SportsMatchSession {
  SportsMatchSession({this.maxRetainedEvents = 2000})
      : assert(maxRetainedEvents >= 0);
  final int maxRetainedEvents;
  final _retained = <String, _RetainedMatch>{};
  final _evidenceVersions = <String, Object?>{};
  Object? _evidenceVersion;
  @visibleForTesting
  int get retainedEventCount => _retained.length;
  void discardHiddenResults() => _retained.clear();
  Map<String, String> identities = const {};
  Map<String, String> _fixtures = const {};
  Map<String, SportsGame> _games = const {};
  Map<String, String?> _pickIds = const {};
  Map<String, List<ChannelMatch>> matches = const {};
  Set<String> checked = const {};
  final _completed = <String, String>{};
  final _checkedAt = <String, DateTime>{};
  final _recheckUntil = <String, DateTime>{};
  int? _catalogue;
  SportsMatchPicks? _decisionSource;
  int? _decisionRevision;

  /// Copy bookkeeping without sharing mutable maps between concurrent routes.
  /// Evidence lists/models are immutable; their original check times survive.
  SportsMatchSession copy() =>
      SportsMatchSession(maxRetainedEvents: maxRetainedEvents)
        ..identities = identities
        .._fixtures = _fixtures
        .._games = _games
        .._pickIds = _pickIds
        ..matches = matches
        ..checked = checked
        .._completed.addAll(_completed)
        .._checkedAt.addAll(_checkedAt)
        .._recheckUntil.addAll(_recheckUntil)
        .._retained.addAll(_retained)
        .._evidenceVersions.addAll(_evidenceVersions)
        .._evidenceVersion = _evidenceVersion
        .._catalogue = _catalogue
        .._decisionSource = _decisionSource
        .._decisionRevision = _decisionRevision;

  /// Expire only fixtures whose known coverage boundary passed while away.
  void expireEvents(Set<String> keys) {
    if (keys.isEmpty) return;
    _completed.removeWhere((key, _) => keys.contains(key));
    _checkedAt.removeWhere((key, _) => keys.contains(key));
    _recheckUntil.removeWhere((key, _) => keys.contains(key));
    _retained.removeWhere((key, _) => keys.contains(key));
    _evidenceVersions.removeWhere((key, _) => keys.contains(key));
    _publish({
      for (final e in matches.entries)
        if (!keys.contains(e.key)) e.key: e.value
    });
  }

  int get recheckingCount => _recheckUntil.length;

  void updateInputs(List<SportsGame> games, SportsMatchPicks picks,
      int catalogue, DateTime now,
      {Object? evidenceVersion}) {
    final decisionRevision = picks is SportsMatchRejections
        ? (picks as SportsMatchRejections).decisionsRevision
        : 0;
    final sameDecisions = identical(picks, _decisionSource) &&
        decisionRevision == _decisionRevision;
    final current = {for (final g in games) SportsChannelPicks.eventKey(g): g};
    // Hiding an event is not an evidence change. Keep a bounded working set
    // outside the displayed maps, and validate it again before publication.
    if (_catalogue != catalogue) _retained.clear();
    _retained.removeWhere((_, entry) =>
        entry.evidenceVersion != evidenceVersion || !entry.isFresh(now));
    if (_catalogue == catalogue) {
      for (final entry in matches.entries) {
        if (current.containsKey(entry.key) ||
            _evidenceVersions[entry.key] != evidenceVersion) {
          continue;
        }
        final at = _checkedAt[entry.key];
        if (at == null) continue;
        var until = at.add(const Duration(minutes: 5));
        final boundary = sportsMatchBoundary(_games[entry.key]!, at);
        if (boundary != null && boundary.isBefore(until)) until = boundary;
        final retained = _RetainedMatch(
            fixture: _fixtures[entry.key]!,
            pickId: _pickIds[entry.key],
            matches: entry.value,
            completed: _completed[entry.key],
            checkedAt: at,
            expiresAt: until,
            evidenceVersion: evidenceVersion);
        if (retained.isFresh(now)) {
          _retained.remove(entry.key);
          _retained[entry.key] = retained;
        }
      }
    }
    final restored = <String, _RetainedMatch>{};
    for (final key in current.keys) {
      final entry = _retained.remove(key);
      if (entry == null) continue;
      restored[key] = entry;
      _checkedAt[key] = entry.checkedAt;
      _evidenceVersions[key] = entry.evidenceVersion;
      if (entry.completed case final completed?) _completed[key] = completed;
    }
    final retainedLimit =
        (maxRetainedEvents - current.length).clamp(0, maxRetainedEvents);
    while (_retained.length > retainedLimit) {
      _retained.remove(_retained.keys.first);
    }
    final previousMatches = restored.isEmpty
        ? matches
        : {
            ...matches,
            for (final entry in restored.entries)
              entry.key: entry.value.matches,
          };
    final ids = <String, String>{}, fixtures = <String, String>{};
    final pickIds = <String, String?>{};
    for (final e in current.entries) {
      final pick = pickIds[e.key] = picks.channelIdFor(e.value);
      // Models are replaced on score/fixture/enrichment updates. Reuse their
      // encoded inputs across repeated queue checks, but always read mutable
      // manual picks and always run the time-based evidence expiry below.
      if (sameDecisions &&
          !restored.containsKey(e.key) &&
          identical(_games[e.key], e.value) &&
          _pickIds[e.key] == pick) {
        ids[e.key] = identities[e.key]!;
        fixtures[e.key] = _fixtures[e.key]!;
      } else {
        ids[e.key] = SportsChannelMatcher.matchingIdentity(e.value, picks);
        fixtures[e.key] = SportsChannelMatcher.matchingIdentity(e.value, picks,
            includeBroadcasts: false, includePick: false);
      }
    }
    final kept = <String, List<ChannelMatch>>{};
    for (final e in previousMatches.entries) {
      if (_catalogue != catalogue ||
          fixtures[e.key] != (restored[e.key]?.fixture ?? _fixtures[e.key])) {
        continue;
      }
      final at = _checkedAt[e.key];
      final expired =
          at == null || now.difference(at) >= const Duration(minutes: 5);
      // After time away (for example PiP), age requests a fresh check instead
      // of blanking the last good results first. This grace is never renewed
      // by polls/partial replies and never extends a known programme end.
      if (expired &&
          _completed.containsKey(e.key) &&
          e.value.any((m) => m.reason != MatchReason.pick)) {
        _recheckUntil.putIfAbsent(
            e.key, () => now.add(const Duration(minutes: 1)));
      }
      bool isFresh(ChannelMatch m) {
        if (picks is SportsMatchRejections &&
            sportsChannelRejected(
                (picks as SportsMatchRejections)
                    .rejectedKeysFor(current[e.key]!),
                m.channel.id,
                m.programme)) {
          return false;
        }
        if (m.reason == MatchReason.pick) {
          return m.channel.id == pickIds[e.key];
        }
        final until = _recheckUntil[e.key];
        if (expired && (until == null || !now.isBefore(until))) return false;
        return _programmeIsFresh(m, current[e.key]!, now);
      }

      if (e.value.every(isFresh)) {
        kept[e.key] = e.value;
      } else {
        kept[e.key] = e.value.where(isFresh).toList();
        if (e.value.any((m) => m.reason != MatchReason.pick && !isFresh(m))) {
          _completed.remove(e.key);
        }
      }
      // Trying a different feed changes the preference, not the fixture or
      // its guide evidence. Keep alternatives usable while the check runs.
      // An old saved pick must not remain falsely confirmed after switching.
      final pick = pickIds[e.key];
      final previousPick = restored.containsKey(e.key)
          ? restored[e.key]!.pickId
          : _pickIds[e.key];
      if (pick != previousPick && pick != null) {
        final candidate =
            kept[e.key]!.where((m) => m.channel.id == pick).firstOrNull;
        if (candidate != null) {
          kept[e.key] = [
            ChannelMatch(candidate.channel, MatchReason.pick, 1000,
                programme: candidate.programme),
            for (final m in kept[e.key]!)
              if (m.channel.id != pick) m,
          ];
        }
      }
    }
    _completed.removeWhere((key, _) => !kept.containsKey(key));
    _checkedAt.removeWhere((key, _) => !kept.containsKey(key));
    _evidenceVersions.removeWhere((key, _) => !kept.containsKey(key));
    _recheckUntil.removeWhere(
        (key, _) => !kept.containsKey(key) || !_completed.containsKey(key));
    if (!mapEquals(identities, ids)) identities = ids;
    if (!mapEquals(_fixtures, fixtures)) _fixtures = fixtures;
    _games = current;
    _pickIds = pickIds;
    _catalogue = catalogue;
    _evidenceVersion = evidenceVersion;
    _decisionSource = picks;
    _decisionRevision = decisionRevision;
    _publish(kept);
  }

  /// A batch is compared with the inputs captured when its job started, not
  /// with a newer scoreboard's request token. Score-only polls remain valid.
  bool apply(Map<String, List<ChannelMatch>> batch,
      Map<String, String> expected, int catalogue, DateTime now,
      {required bool complete}) {
    if (_catalogue != catalogue) return false;
    Map<String, List<ChannelMatch>>? next;
    var accepted = false;
    for (final e in batch.entries) {
      if (expected[e.key] != identities[e.key] || !_games.containsKey(e.key)) {
        continue;
      }
      if (!complete && _completed.containsKey(e.key)) continue;
      accepted = true;
      // A reply may contain a historical slot or arrive after that slot ends.
      // Apply the same programme-expiry rule used by updateInputs before
      // publishing it. Otherwise every cached reply restores expired evidence
      // and the next batch immediately invalidates this completed check again.
      final game = _games[e.key]!;
      final incoming = e.value.every((m) => _programmeIsFresh(m, game, now))
          ? e.value
          : e.value.where((m) => _programmeIsFresh(m, game, now)).toList();
      final old = matches[e.key];
      if (old == null || !_sameMatches(old, incoming)) {
        (next ??= Map<String, List<ChannelMatch>>.of(matches))[e.key] =
            incoming;
      }
      _checkedAt[e.key] = now;
      _evidenceVersions[e.key] = _evidenceVersion;
      if (complete) {
        _completed[e.key] = expected[e.key]!;
        _recheckUntil.remove(e.key);
      }
    }
    return accepted && _publish(next ?? matches);
  }

  static bool _programmeIsFresh(
      ChannelMatch match, SportsGame game, DateTime now) {
    final programme = match.programme;
    return match.reason == MatchReason.pick ||
        programme == null ||
        programme.stop.isAfter(now) ||
        game.state == GameState.post;
  }

  bool _publish(Map<String, List<ChannelMatch>> next) {
    final done = {
      for (final id in identities.keys)
        if (_completed[id] == identities[id] && !_recheckUntil.containsKey(id))
          id
    };
    final changed = !identical(matches, next) &&
        (matches.length != next.length ||
            next.entries.any((e) => !identical(matches[e.key], e.value)));
    final checksChanged =
        checked.length != done.length || !checked.containsAll(done);
    if (changed) matches = next;
    if (checksChanged) checked = done;
    return changed || checksChanged;
  }

  static bool _sameMatches(List<ChannelMatch> a, List<ChannelMatch> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i], p = x.programme, q = y.programme;
      if (x.channel.id != y.channel.id ||
          x.reason != y.reason ||
          x.score != y.score ||
          x.detail != y.detail ||
          p?.title != q?.title ||
          p?.description != q?.description ||
          p?.start != q?.start ||
          p?.stop != q?.stop ||
          p?.isLive != q?.isLive ||
          !listEquals(x.supportingBroadcasts, y.supportingBroadcasts)) {
        return false;
      }
    }
    return true;
  }
}

class _RetainedMatch {
  const _RetainedMatch(
      {required this.fixture,
      required this.pickId,
      required this.matches,
      required this.completed,
      required this.checkedAt,
      required this.expiresAt,
      required this.evidenceVersion});
  final String fixture;
  final String? pickId, completed;
  final List<ChannelMatch> matches;
  final DateTime checkedAt, expiresAt;
  final Object? evidenceVersion;
  bool isFresh(DateTime now) =>
      !now.isBefore(checkedAt) && now.isBefore(expiresAt);
}

/// At most one running job plus one replaceable follow-up. Bursts of score,
/// guide and listing updates never build an unbounded chain of obsolete jobs.
class SportsMatchWork {
  Future<void> Function()? _latest;
  Completer<void>? _idle;
  Future<void> request(Future<void> Function() job) {
    _latest = job;
    if (_idle != null) return _idle!.future;
    final idle = _idle = Completer<void>();
    scheduleMicrotask(() async {
      Object? failure;
      StackTrace? trace;
      while (_latest != null) {
        final next = _latest!;
        _latest = null;
        try {
          await next();
        } catch (error, stack) {
          failure = error;
          trace = stack;
        }
      }
      _idle = null;
      if (failure == null) {
        idle.complete();
      } else {
        idle.completeError(failure, trace);
      }
    });
    return idle.future;
  }
}
