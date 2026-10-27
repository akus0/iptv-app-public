import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/sports.dart';
import 'combat_sports.dart';
import 'motorsport_coverage.dart';
import 'sports_coverage_models.dart';

final _punctuation = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _space = RegExp(r'\s+');
final _cosmetic = RegExp(r'\b(?:live|hd|uhd|fhd|sd|hdr|4k)\b');
final _episode = RegExp(r'\bs\s*0*(\d+)\s*e\s*0*(\d+)\b');
final _numbered = RegExp(
    r'\b(season|episode|table|day|part|round|stage|game|match|session|heat|board|court|flight|event)\s+(\d+[a-z]?|one|two|three|four|five|six|seven|eight|nine|ten|[a-z])\b');
const _numbers = {
  'one': '1',
  'two': '2',
  'three': '3',
  'four': '4',
  'five': '5',
  'six': '6',
  'seven': '7',
  'eight': '8',
  'nine': '9',
  'ten': '10'
};
final _stages = RegExp(
    r'\b(?:early prelims|prelims|main card|quarterfinals?|semifinals?|finals?|qualifying|final table|cash game|main event|feature table|side event|singles|doubles|mixed|women|men|ladies|girls|boys|youth|juniors?|seniors?|veterans|u ?\d{2}|under \d{2}|\d{4})\b');
final _studio = RegExp(
    r'\b(?:weigh in|press conference|preview|review|countdown|highlights|replay|repeat|interview|pre show|post show)\b');
final _pairs = RegExp(r'\bvs\b');
final _unknownOpponent =
    RegExp(r'\b(?:tbd|tba|unknown|winner|loser|team \d+|player \d+)\b');
final _unresolvedDetail = RegExp(r'\b(?:table|court|board|flight|session)\b');
final _ordinaryTable = RegExp(r'\b(?:final table|feature table)\b');
final _episodeFields = RegExp(r'\b(?:season|episode) \d+\b');
final _money = RegExp(r'[$€£]\s*[\d,.]+(?:\s*[kKmM]\b)?');
final _dates = RegExp(
    r'\b(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \d{1,2}(?: \d{4})?|\d{4} \d{1,2} \d{1,2}|best of \d+)\b');
final _generic = RegExp(
    r'\b(?:world|tour|championship|championships|coverage|sports|sport|darts|snooker|billiards|bowling|poker|tennis|table|badminton|open|quarterfinals?|semifinals?|finals?|qualifying|round|session|day|the|of|and|\d+)\b');

String _text(String value, String sport) {
  var s = value
      .toLowerCase()
      .replaceAll(RegExp('ᴸᶦᵛᵉ|ᶫᶦᵛᵉ', caseSensitive: false), ' ');
  s = s.replaceAll(_punctuation, ' ').replaceAll(_space, ' ').trim();
  s = s.replaceAllMapped(_episode,
      (m) => 'season ${int.parse(m[1]!)} episode ${int.parse(m[2]!)}');
  s = s
      .replaceAll(RegExp(r'\b(?:versus|vs|v)\b'), 'vs')
      .replaceAll(RegExp(r'\bquarter finals?\b'), 'quarterfinal')
      .replaceAll(RegExp(r'\bsemi finals?\b'), 'semifinal')
      .replaceAll(RegExp(r'\bquarterfinals\b'), 'quarterfinal')
      .replaceAll(RegExp(r'\bsemifinals\b'), 'semifinal')
      .replaceAll(
          RegExp(r'\bpreliminary (?:card|fights|bouts)|preliminaries\b'),
          'prelims');
  if (sport == 'poker') {
    s = s
        .replaceAll(RegExp(r'\bwpt\b'), 'world poker tour')
        .replaceAll(RegExp(r'\bwsop\b'), 'world series of poker');
  }
  if (sport == 'billiards') {
    s = s.replaceAll(RegExp(r'\bworld snooker tour\b'), 'snooker');
  }
  s = s.replaceAllMapped(_numbered, (m) {
    final n = _numbers[m[2]!] ?? int.tryParse(m[2]!)?.toString() ?? m[2]!;
    return '${m[1]} $n';
  });
  return s.replaceAll(_cosmetic, ' ').replaceAll(_space, ' ').trim();
}

String _qualifiers(String text) {
  final values = {
    for (final m in _numbered.allMatches(text)) m[0]!,
    for (final m in _stages.allMatches(text)) m[0]!,
    for (final m in _dates.allMatches(text)) m[0]!,
  }.toList()
    ..sort();
  return values.join('|');
}

String _phase(String text) {
  if (text.contains('early prelims')) return 'early prelims';
  if (text.contains('prelims')) return 'prelims';
  if (text.contains('main card')) return 'main card';
  return '';
}

bool _hasPair(String title) {
  if (_unknownOpponent.hasMatch(title)) return false;
  final sides = title.split(_pairs);
  return sides.length == 2 && sides.every((s) => s.trim().length >= 2);
}

class _CoverageIdentity {
  const _CoverageIdentity(this.key, this.skew);
  final String key;
  final Duration skew;
}

final _identities = Expando<_CoverageIdentity>();

_CoverageIdentity _identity(SportsGame game) => _identities[game] ??= () {
      final sport = game.league.espnPath.split('/').first;
      var title = _text(game.title, sport);
      final description =
          _text(game.guideProgrammes.first.description ?? '', sport);
      final full = '$title $description';
      final stakes = _money
          .allMatches(
              '${game.title} ${game.guideProgrammes.first.description ?? ''}')
          .map((m) => m[0]!.toLowerCase().replaceAll(_space, ''))
          .toSet()
          .toList()
        ..sort();
      final guards = '${_qualifiers(full)}|${stakes.join('|')}';
      var strong = false;
      if (!_studio.hasMatch(full) && description.length <= 2048) {
        final card = combatCardIdentity(title);
        if (sport == 'mma' || sport == 'boxing') {
          // A card number is an identity; "UFC live" is not. Named individual
          // bouts remain distinct because the complete title is part of the key.
          strong = card != null || _hasPair(title);
        } else if (sport == 'poker') {
          final hasEpisode = RegExp(r'\bseason \d+\b').hasMatch(full) &&
              RegExp(r'\bepisode \d+\b').hasMatch(full);
          final eventTitle = title
              .replaceAll(
                  RegExp(
                      r'\b(?:world poker tour|world series of poker|final table|main event|day \d+[ab]?|table \d+|\d{4})\b'),
                  '')
              .trim();
          // Generic shows are repeated all day. Different synopses can be ignored
          // only for a complete episode ID, or a specifically named LIVE table.
          strong = hasEpisode ||
              (game.statusText == 'Live · guide' &&
                  eventTitle.length >= 6 &&
                  (title.contains('final table') ||
                      (title.contains('day ') && title.contains('table '))));
          if (hasEpisode) {
            title = title
                .replaceAll(_episodeFields, '')
                .replaceAll(_space, ' ')
                .trim();
          }
        } else {
          final named =
              title.replaceAll(_generic, '').replaceAll(_space, ' ').trim();
          final explicitStage =
              RegExp(r'\b(?:quarterfinal|semifinal|final|qualifying)\b')
                  .hasMatch(title);
          strong = _hasPair(title) || (explicitStage && named.length >= 6);
        }
      }
      // Named tables and sessions ("Table Alpha", "afternoon session")
      // lack a normalised identifier. Keep the synopsis as evidence rather
      // than treating those words as interchangeable broadcaster prose.
      if (strong &&
          _unresolvedDetail.hasMatch(description
              .replaceAll(_numbered, '')
              .replaceAll(_ordinaryTable, ''))) {
        strong = false;
      }
      // A synopsis may distinguish opponents/tables even under a specific title.
      // Do not discard such information, or guess that an absent qualifier agrees.
      final synopsisPair = _hasPair(description) ? description : '';
      final key = jsonEncode([
        game.league.id,
        game.state.name,
        game.statusText,
        title,
        guards,
        strong ? synopsisPair : description
      ]);
      return _CoverageIdentity(
          key,
          Duration(
              minutes: strong
                  ? 30
                  : description.isNotEmpty
                      ? 15
                      : 0));
    }();

bool _overlap(SportsGame a, SportsGame b, Duration skew) {
  if (a.end == null ||
      b.end == null ||
      a.start.difference(b.start).abs() > skew) {
    return false;
  }
  // +1/time-shift services and successive episodes should remain separate.
  if (a.end!.difference(b.end!).abs() > const Duration(minutes: 30)) {
    return false;
  }
  final begin = a.start.isAfter(b.start) ? a.start : b.start;
  final end = a.end!.isBefore(b.end!) ? a.end! : b.end!;
  final shorter = a.end!.difference(a.start) < b.end!.difference(b.start)
      ? a.end!.difference(a.start)
      : b.end!.difference(b.start);
  return shorter.inSeconds > 0 &&
      end.difference(begin).inSeconds * 5 >= shorter.inSeconds * 4;
}

/// Existing worker only: exact/cosmetic copies plus narrowly identified bouts,
/// episodes and tournament stages. No fuzzy similarity, network or guide reads.
List<SportsGame> coalesceOtherGuideCoverage(List<SportsGame> games) {
  final buckets = <String, List<List<SportsGame>>>{};
  final result = <SportsGame>[];
  final ordered = [...games]..sort((a, b) {
      final order = a.start.compareTo(b.start);
      return order != 0 ? order : a.id.compareTo(b.id);
    });
  for (final game in ordered) {
    if (!game.isGuideEvent ||
        game.guideProgrammes.isEmpty ||
        game.league.espnPath.startsWith('racing/')) {
      result.add(game);
      continue;
    }
    final identity = _identity(game);
    final groups = buckets.putIfAbsent(identity.key, () => []);
    final group =
        groups.where((g) => _overlap(g.first, game, identity.skew)).firstOrNull;
    if (group == null) {
      groups.add([game]);
    } else {
      group.add(game);
    }
  }
  for (final entry in buckets.entries) {
    for (final (index, group) in entry.value.indexed) {
      final start = group.first.start;
      final end =
          group.map((g) => g.end!).reduce((a, b) => a.isAfter(b) ? a : b);
      group.sort((a, b) {
        final length = a.title.length.compareTo(b.title.length);
        return length != 0 ? length : a.id.compareTo(b.id);
      });
      final programmes = [for (final g in group) ...g.guideProgrammes]
        ..sort((a, b) => a.channelId.compareTo(b.channelId));
      final key =
          '${entry.key}|${start.toUtc().toIso8601String().substring(0, 10)}|$index';
      result.add(copyGuideCoverage(group.first, programmes,
          id: 'guide:coverage:${sha256.convert(utf8.encode(key)).toString().substring(0, 24)}',
          start: start,
          end: end));
    }
  }
  return result;
}

/// Replaces the old blanket suppression of numbered combat guide cards.
/// A whole scored card can own its prelim/main coverage, but two explicit
/// phases or different individual bouts never stand in for each other.
List<SportsGame> mergeSportsGuideCoverage(
    List<SportsGame> scheduled, List<SportsGame> guide) {
  final motor = mergeMotorsportCoverage(scheduled, guide);
  final result = motor.where((g) => !g.isGuideEvent).toList();
  final cards = <String, List<int>>{};
  for (var i = 0; i < result.length; i++) {
    final game = result[i];
    if (game.league.kind != SportsKind.fight || game.state == GameState.post) {
      continue;
    }
    final id = _combat(game).card;
    if (id != null) {
      (cards['${game.league.espnPath.split('/').first}|$id'] ??= []).add(i);
    }
  }
  for (final game in motor.where((g) => g.isGuideEvent)) {
    final sport = game.league.espnPath.split('/').first;
    if (sport != 'mma' && sport != 'boxing') {
      result.add(game);
      continue;
    }
    final info = _combat(game);
    final id = info.card;
    final candidates = id == null || info.studio
        ? const <int>[]
        : (cards['$sport|$id'] ?? const <int>[]).where((i) {
            final target = result[i];
            final other = _combat(target);
            if (other.phase.isNotEmpty && other.phase != info.phase) {
              return false;
            }
            // The score feed represents the headline/card; a different named
            // undercard bout is still an independently browsable event.
            if (info.pair && (!other.pair || info.title != other.title)) {
              return false;
            }
            final stop =
                target.end ?? target.start.add(const Duration(hours: 6));
            return game.end != null &&
                game.end!.isAfter(target.start) &&
                game.start.isBefore(stop) &&
                game.start.difference(target.start).abs() <=
                    const Duration(hours: 2);
          }).toList();
    if (candidates.length != 1) {
      result.add(game);
      continue;
    }
    final index = candidates.single;
    result[index] = attachGuideCoverage(result[index], game);
  }
  return result;
}

typedef _Combat = ({
  String title,
  String? card,
  String phase,
  bool studio,
  bool pair
});
final _combatCache = Expando<_Combat>();
_Combat _combat(SportsGame game) => _combatCache[game] ??= () {
      final sport = game.league.espnPath.split('/').first;
      final title = _text(game.event?.title ?? game.title, sport);
      return (
        title: title,
        card: combatCardIdentity(title),
        phase: _phase('$title ${_text(game.event?.session ?? '', sport)}'),
        studio: _studio.hasMatch(title),
        pair: _hasPair(title)
      );
    }();
