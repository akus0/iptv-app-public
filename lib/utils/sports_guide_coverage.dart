import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/sports.dart';
import 'combat_sports.dart';
import 'extended_sports.dart' show namedTestCricketFixture;
import 'motorsport_coverage.dart';
import 'sports_coverage_models.dart';
import 'sports_guide_title.dart';

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
final _oneFridayBrand = RegExp(r'\bone championship (?:one )?friday fights\b');
final _oneFridaySeason =
    RegExp(r'\bone friday fights (20\d{2}) off (\d{1,3})\b');
final _oneFightNightBrand =
    RegExp(r'\bone championship (?:one )?fight night\b');
final _oneFightNightSeason =
    RegExp(r'\bone fight night (20\d{2}) ofn (\d{1,3})\b');
final _oneCard = RegExp(r'\bone (?:friday fights|fight night) \d{1,3}\b');
final _repeatedTitleSeparator = RegExp(r'\s[-|–—]\s|:\s');
final _onePromotionPrefix =
    RegExp(r'^one championship (?=one (?:fight night|friday fights)\b)');
final _numberedCombatSeries = RegExp(
    r'^(one fight night|one friday fights|pfl|bellator|cage warriors|lfa|bkfc) (\d{1,3})\b');
final _wholeCombatSeries = RegExp(
    r'^(one fight night|one friday fights|pfl|bellator|cage warriors|lfa|bkfc)(?: (\d{1,3}))?$');
final _oneSportPrefix =
    RegExp(r'^mma (?=one (?:championship|fight night|friday fights)\b)');
final _isoDate = RegExp(r'\b\d{4}-\d{2}-\d{2}\b');
final _golfOrdinalRound =
    RegExp(r'\b(first|second|third|fourth|1st|2nd|3rd|4th) round\b');
const _ordinals = {
  'first': '1',
  '1st': '1',
  'second': '2',
  '2nd': '2',
  'third': '3',
  '3rd': '3',
  'fourth': '4',
  '4th': '4',
  'fifth': '5',
  '5th': '5',
};
final _golfRound = RegExp(r'\bround [1-4]\b');
final _golfEvent = RegExp(
    r'\b(?:championship|open|masters|invitational|classic|cup|trophy)\b');
final _golfTourNoise = RegExp(
    r'\b(?:dp world tour|pga tour champions|pga tour|lpga tour|asian tour|golf)\b');
final _subtitleSentence = RegExp(r'[.!?]');
final _testNumber =
    RegExp(r'\b(1st|2nd|3rd|4th|5th|first|second|third|fourth|fifth) test\b');
final _testDay = RegExp(r'\bday ([1-5])\b');
final _testPhase = RegExp(r'\b(?:innings?|session|lunch|tea|stumps|break)\b');
final _golfPartialFeed =
    RegExp(r'\b(?:featured|groups?|holes?|morning|afternoon)\b');

String? _cricketCoverageTitle(SportsGame game, String full) {
  final pair = namedTestCricketFixture(
      game.title, game.guideProgrammes.first.description ?? '');
  if (pair == null || _testPhase.hasMatch(full)) return null;
  final tests =
      _testNumber.allMatches(full).map((m) => _ordinals[m[1]]!).toSet();
  final days = _testDay.allMatches(full).map((m) => m[1]).toSet();
  if (tests.length != 1 || days.length != 1) return null;
  final opponents = [pair.home, pair.away]..sort();
  return 'test cricket ${opponents.join(' vs ')} test ${tests.single} day ${days.single}';
}

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
  if (sport == 'golf') {
    s = s.replaceAllMapped(
        _golfOrdinalRound, (m) => 'round ${_ordinals[m[1]]}');
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
  const _CoverageIdentity(this.key, this.skew,
      {this.detailsInDescription = false,
      this.combatSlot,
      this.numberedCard = false,
      this.combatTarget = false});
  final String key;
  final Duration skew;
  final bool detailsInDescription;
  final String? combatSlot;
  final bool numberedCard, combatTarget;
}

final _episodeOnlyPrefix =
    RegExp(r'^E(\d{1,4})\s*(?:[—–:-]\s*)?', caseSensitive: false);
const _localDateGuideLeagues = {
  'guide.high-school-football',
  'guide.horse-racing',
  'guide.rodeo',
};

final _identities = Expando<_CoverageIdentity>();

_CoverageIdentity _identity(SportsGame game) => _identities[game] ??= () {
      final sport = game.league.espnPath.split('/').first;
      var title = _text(sportsGuideBroadcastTitle(game.title), sport);
      if (_repeatedTitleSeparator.hasMatch(game.title)) {
        final words = title.split(' ');
        final half = words.length ~/ 2;
        if (half >= 3 &&
            words.length == half * 2 &&
            words.take(half).join(' ') == words.skip(half).join(' ')) {
          title = words.take(half).join(' ');
        }
      }
      var synopsis = sportsGuideCoverageSynopsis(
          game.guideProgrammes.first.description ?? '', game.start,
          allowLiveLocalDate: game.statusText == 'Live · guide' &&
              _localDateGuideLeagues.contains(game.league.id));
      // Australian Championship guides put an episode prefix before either the
      // fixture heading or the prose. Preserve its number as a qualifier,
      // while allowing that identical heading to occupy the title in another feed.
      if (game.league.id == 'guide.australian-championship') {
        final episode = _episodeOnlyPrefix.firstMatch(synopsis);
        if (episode != null) {
          synopsis =
              '${synopsis.substring(episode.end)} (episode ${int.parse(episode[1]!)})';
        }
      }
      var detailsInDescription = false;
      final newline = synopsis.indexOf('\n');
      if (newline > 0 &&
          newline <= 160 &&
          newline < synopsis.trimRight().length - 1) {
        final subtitle = synopsis.substring(0, newline).trim();
        final heading = _text(subtitle, sport);
        // XMLTV feeds can put a short event heading in the first synopsis line.
        // Move that exact heading, preserving every word and the remaining prose.
        // Sentences and headings without an explicit stage/number stay untouched.
        if (!_subtitleSentence.hasMatch(subtitle) &&
            (_numbered.hasMatch(heading) || _stages.hasMatch(heading)) &&
            !title.endsWith(heading)) {
          title = '$title $heading';
          synopsis = synopsis.substring(newline + 1);
          detailsInDescription = true;
        }
      }
      if (sport == 'mma') {
        title = title
            .replaceFirst(_oneSportPrefix, '')
            .replaceFirst(_onePromotionPrefix, '')
            .replaceAll(_oneFridayBrand, 'one friday fights')
            .replaceAll(_oneFightNightBrand, 'one fight night');
        title = title.replaceAllMapped(
            _oneFightNightSeason,
            (m) => int.parse(m[1]!) == game.start.toUtc().year
                ? 'one fight night ${m[2]}'
                : m[0]!);
        title = title.replaceAllMapped(
            _oneFridaySeason,
            (m) => int.parse(m[1]!) == game.start.toUtc().year
                ? 'one friday fights ${m[2]}'
                : m[0]!);
        if (_oneCard.hasMatch(title)) {
          // Some XMLTV feeds append the airing date to every synopsis. Only
          // remove this exact slot's date, never another year/date or a bout.
          final date = game.start.toUtc().toIso8601String().substring(0, 10);
          synopsis = synopsis.replaceAllMapped(
              _isoDate, (m) => m[0] == date ? '' : m[0]!);
        }
      }
      final description = _text(synopsis, sport);
      final full = '$title $description';
      final cricketTitle =
          sport == 'cricket' ? _cricketCoverageTitle(game, full) : null;
      if (cricketTitle != null) {
        detailsInDescription = !_hasPair(title);
        title = cricketTitle;
      }
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
        } else if (sport == 'cricket') {
          strong = cricketTitle != null || _hasPair(title);
        } else if (sport == 'golf') {
          final named = title
              .replaceAll(_golfTourNoise, '')
              .replaceAll(_generic, '')
              .replaceAll(_space, ' ')
              .trim();
          strong = _hasPair(title) ||
              (_golfEvent.hasMatch(title) &&
                  !_golfPartialFeed.hasMatch(description) &&
                  _golfRound
                          .allMatches(title)
                          .map((m) => m[0])
                          .toSet()
                          .length ==
                      1 &&
                  named.length >= 6);
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
      final synopsisPair =
          cricketTitle == null && _hasPair(description) ? description : '';
      final key = jsonEncode([
        game.league.id,
        game.state.name,
        game.statusText,
        title,
        guards,
        strong ? synopsisPair : description
      ]);
      // A generic full-card listing may join one explicit card only when its
      // series and entire airing interval agree. Short bouts, named opponents,
      // phases and conflicting numbered cards never supply this fallback.
      final wholeCard = (sport == 'mma' || sport == 'boxing')
          ? _wholeCombatSeries.firstMatch(title)
          : null;
      final numbered = (sport == 'mma' || sport == 'boxing')
          ? _numberedCombatSeries.firstMatch(title)
          : null;
      final numberedCard = numbered != null;
      final wholeEligible = wholeCard != null &&
          !_studio.hasMatch(full) &&
          !_pairs.hasMatch(description) &&
          _phase(full).isEmpty &&
          !_numbered.hasMatch(description) &&
          (numberedCard || _qualifiers(full).isEmpty);
      final combatSlot = (numberedCard || wholeEligible) &&
              game.end != null &&
              game.end!.difference(game.start) >= const Duration(hours: 3) &&
              (game.statusText == 'Live · guide' ||
                  game.statusText == 'Starting soon · guide')
          ? jsonEncode([
              game.league.id,
              numbered?[1] ?? wholeCard![1],
              game.state.name,
              game.statusText,
              game.start.millisecondsSinceEpoch,
              game.end!.millisecondsSinceEpoch
            ])
          : null;
      return _CoverageIdentity(
          key,
          Duration(
              minutes: strong
                  ? 30
                  : description.isNotEmpty
                      ? 15
                      : 0),
          detailsInDescription: detailsInDescription,
          combatSlot: combatSlot,
          numberedCard: numberedCard,
          combatTarget: numberedCard && wholeEligible);
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
  final numbered = <String, Set<String>>{};
  final targets = <String>{};
  for (final game in ordered) {
    if (!game.isGuideEvent ||
        game.guideProgrammes.isEmpty ||
        !(game.league.espnPath.startsWith('mma/') ||
            game.league.espnPath.startsWith('boxing/'))) {
      continue;
    }
    final identity = _identity(game);
    if (identity.numberedCard && identity.combatSlot != null) {
      (numbered[identity.combatSlot!] ??= {}).add(identity.key);
      if (identity.combatTarget) targets.add(identity.key);
    }
  }
  for (final game in ordered) {
    if (!game.isGuideEvent ||
        game.guideProgrammes.isEmpty ||
        game.league.espnPath.startsWith('racing/')) {
      result.add(game);
      continue;
    }
    final identity = _identity(game);
    final candidates =
        identity.numberedCard ? null : numbered[identity.combatSlot];
    final key = candidates?.length == 1 && targets.contains(candidates!.single)
        ? candidates.single
        : identity.key;
    final groups = buckets.putIfAbsent(key, () => []);
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
        if (_identity(a).numberedCard != _identity(b).numberedCard) {
          return _identity(a).numberedCard ? -1 : 1;
        }
        final aSubtitle = _identity(a).detailsInDescription;
        final bSubtitle = _identity(b).detailsInDescription;
        if (aSubtitle != bSubtitle) return aSubtitle ? 1 : -1;
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
  final fieldHockey = [
    for (var i = 0; i < result.length; i++)
      if (result[i].league.id == 'field-hockey.womens-college-field-hockey' &&
          result[i].state != GameState.post)
        i,
  ];
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
    if (sport == 'field-hockey' && fieldHockey.isNotEmpty) {
      final title = ' ${_text(game.title, sport)} ';
      final candidates = fieldHockey.where((i) {
        final target = result[i];
        return game.end != null &&
            !target.start.isBefore(game.start) &&
            target.start.isBefore(game.end!) &&
            target.start.difference(game.start) <=
                const Duration(minutes: 90) &&
            _fieldFixture.hasMatch(title) &&
            !_studio.hasMatch(title) &&
            !title.contains(' studio ') &&
            !_mensFieldHockey.hasMatch(title) &&
            _fieldTeamNames(target).every(
                (names) => names.isNotEmpty && names.any(title.contains));
      }).toList();
      if (candidates.length == 1) {
        final index = candidates.single;
        result[index] = attachGuideCoverage(result[index], game);
        continue;
      }
    }
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

// Only explicit opponent pairs attach to the new score feed. Generic coverage,
// studio programmes and ambiguous fixtures retain their separate guide cards.
final _fieldFixture = RegExp(r'\b(?:vs|at)\b');
final _mensFieldHockey = RegExp(r'\b(?:men|mens|boys)\b');
final _fieldNames = Expando<List<List<String>>>();
List<List<String>> _fieldTeamNames(SportsGame game) => _fieldNames[game] ??= [
      for (final team in [game.home, game.away])
        [
          for (final name in {team.name, team.shortName})
            if (name.trim().length >= 4 &&
                !_unknownOpponent.hasMatch(name.toLowerCase()))
              ' ${_text(name, 'field-hockey')} ',
        ],
    ];

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
