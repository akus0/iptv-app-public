import '../models/epg_program.dart';

enum ReplayDatePrecision { day, year, season, monthDay }

enum ReplayDateRange { all, recent, older, unknown }

const replayRecentDays = 28;

/// Possible/API dates and yearless dates never masquerade as precisely dated
/// events. Coarse years/seasons qualify as older only when wholly in the past.
bool replayDateInRange(
    ReplayEventDate? date, ReplayDateRange range, DateTime now) {
  if (range == ReplayDateRange.all) return true;
  final age = date?.isPossible == true ? null : date?.ageInDays(now);
  final olderYear = date != null &&
      !date.isPossible &&
      date.day == null &&
      date.year != null &&
      (date.seasonEnd ?? date.year!) < now.year;
  return switch (range) {
    ReplayDateRange.all => true,
    ReplayDateRange.recent => age != null && age >= 0 && age < replayRecentDays,
    ReplayDateRange.older =>
      (age != null && age >= replayRecentDays) || olderYear,
    ReplayDateRange.unknown =>
      (age == null && !olderYear) || (age != null && age < 0),
  };
}

/// Original-event information from the guide, never the current airing time.
/// Partial dates stay partial; a missing year is not silently filled in.
class ReplayEventDate {
  const ReplayEventDate(this.precision, this.label, this.source,
      {this.day,
      this.year,
      this.seasonEnd,
      this.isGuideDate = false,
      this.isPossible = false});
  final ReplayDatePrecision precision;
  final String label, source;
  final DateTime? day;
  final int? year, seasonEnd;
  final bool isGuideDate;
  final bool isPossible;

  int? ageInDays(DateTime now) => day == null
      ? null
      : DateTime.utc(now.year, now.month, now.day).difference(day!).inDays;

  String? ageLabel(DateTime now) {
    final age = ageInDays(now);
    if (age == null || age < 0) return null;
    if (age == 0) return 'Today';
    if (age == 1) return 'Yesterday';
    if (age < 7) return '$age days ago';
    if (age < 60) return '${age ~/ 7} weeks ago';
    final months = (now.year - day!.year) * 12 +
        now.month -
        day!.month -
        (now.day < day!.day ? 1 : 0);
    if (months < 12) return '$months months ago';
    final years = months ~/ 12;
    return '$years ${years == 1 ? 'year' : 'years'} ago';
  }

  /// Coarse years/seasons follow exact dates within their starting year. A
  /// 2026/27 season must not appear newer than a dated October 2026 event just
  /// because it ends in the future. Unknown years have no chronological rank.
  int? get sortKey => isPossible
      ? null
      : day != null
          ? day!.year * 10000 + day!.month * 100 + day!.day
          : year == null
              ? null
              : year! * 10000;
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec'
];
final _monthNames = RegExp(
    r'^(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec)$',
    caseSensitive: false);
const _translatedMonths = {
  'janvier': 'January',
  'février': 'February',
  'fevrier': 'February',
  'mars': 'March',
  'avril': 'April',
  'mai': 'May',
  'juin': 'June',
  'juillet': 'July',
  'août': 'August',
  'aout': 'August',
  'septembre': 'September',
  'octobre': 'October',
  'novembre': 'November',
  'décembre': 'December',
  'decembre': 'December',
};
String _dateLanguage(String value) => value.replaceAllMapped(
    RegExp(
        r'\b(?:janvier|février|fevrier|mars|avril|mai|juin|juillet|août|aout|septembre|octobre|novembre|décembre|decembre)\b',
        caseSensitive: false),
    (m) => _translatedMonths[m[0]!.toLowerCase()]!);
final _contextDate = RegExp(
    r'\b(?:from|played(?:\s+on)?|held(?:\s+on)?|recorded(?:\s+on)?|event date[: ]*)\s+((?:19|20)\d{2}-\d{1,2}-\d{1,2}|\d{1,2}[/.\-]\d{1,2}[/.\-](?:19|20)\d{2}|[a-z]+\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+(?:19|20)\d{2})?|\d{1,2}(?:st|nd|rd|th)?\s+[a-z]+\.?(?:,?\s+(?:19|20)\d{2})?)\b',
    caseSensitive: false);
final _iso = RegExp(r'^((?:19|20)\d{2})-(\d{1,2})-(\d{1,2})$');
final _numeric = RegExp(r'^(\d{1,2})[/.\-](\d{1,2})[/.\-]((?:19|20)\d{2})$');
final _season = RegExp(
    r'\b(\d{4}|\d{2})/(\d{4}|\d{2})\b|\b((?:19|20)\d{2})-(\d{2}|(?:19|20)\d{2})\b(?!-\d)');
// Poker stakes and buy-ins are amounts, not historical event years.
final _year = RegExp(r'(?<![\d$€£])\b((?:19|20)\d{2})\b');
final _fixture = RegExp(
    r'\b(?:vs?\.?|versus|at|faces?|hosts?|meets?|final|grand prix|test|round|game|gala|fight night)\b|\s@\s',
    caseSensitive: false);

ReplayEventDate? replayEventDate(EpgProgram programme) {
  final title = _dateLanguage(programme.title);
  final description = _dateLanguage(programme.description ?? '');
  final airing = programme.start.toUtc();
  final today = DateTime.utc(airing.year, airing.month, airing.day);
  final titleSeason = _season.firstMatch(title);
  final titleYear = _year.firstMatch(title);
  bool agreesWithTitle(int year) {
    if (titleSeason != null) {
      var start = int.parse(titleSeason[1] ?? titleSeason[3]!);
      var end = int.parse(titleSeason[2] ?? titleSeason[4]!);
      if (start < 100) start += start > 70 ? 1900 : 2000;
      if (end < 100) end += (start ~/ 100) * 100;
      if (end < start) end += 100;
      if (end < start || end > start + 1) return false;
      return year >= start && year <= end;
    }
    return titleYear == null || int.parse(titleYear[1]!) == year;
  }

  ReplayEventDate? date(int year, int month, int day, String source,
      {bool guide = false}) {
    final value = DateTime.utc(year, month, day);
    if (year < 1900 ||
        value.year != year ||
        value.month != month ||
        value.day != day ||
        value.isAfter(today)) {
      return null;
    }
    return ReplayEventDate(
        ReplayDatePrecision.day, '$day ${_months[month - 1]} $year', source,
        day: value, year: year, isGuideDate: guide);
  }

  ReplayEventDate? partial(int month, int day, String source) {
    final value =
        DateTime.utc(2000, month, day); // Allows an unknown leap year.
    if (value.month != month || value.day != day) return null;
    if (titleYear != null && titleSeason == null) {
      return date(int.parse(titleYear[1]!), month, day,
          '$source; event year explicitly supplied in the guide title');
    }
    return ReplayEventDate(ReplayDatePrecision.monthDay,
        '$day ${_months[month - 1]} · year not listed', source);
  }

  ReplayEventDate? parse(String value, String source, {bool guide = false}) {
    final iso = _iso.firstMatch(value);
    if (iso != null) {
      return date(
          int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!), source,
          guide: guide);
    }
    final numeric = _numeric.firstMatch(value);
    if (numeric != null) {
      final a = int.parse(numeric[1]!), b = int.parse(numeric[2]!);
      // Only disambiguate when one part cannot be a month.
      if (a <= 12 && b <= 12 && a != b) return null;
      return date(
          int.parse(numeric[3]!), a > 12 ? b : a, a > 12 ? a : b, source,
          guide: guide);
    }
    final words = value.replaceAll(RegExp(r'[.,]'), '').split(RegExp(r'\s+'));
    if (words.length < 2) return null;
    final monthFirst = _monthNames.hasMatch(words[0]);
    final monthWord = monthFirst ? words[0] : words[1];
    if (!_monthNames.hasMatch(monthWord)) return null;
    final month = _months.indexWhere(
            (m) => m.toLowerCase() == monthWord.toLowerCase().substring(0, 3)) +
        1;
    final day = int.tryParse((monthFirst ? words[1] : words[0])
        .replaceAll(RegExp(r'(st|nd|rd|th)$', caseSensitive: false), ''));
    if (day == null) return null;
    final year = words.length == 3 ? int.tryParse(words[2]) : null;
    return year == null
        ? partial(month, day, source)
        : date(year, month, day, source);
  }

  // An explicit event context wins over a provider's trailing programme date.
  // Ignore dates buried in a historical aside about a previous meeting.
  final contexts = _contextDate.allMatches(description).where((m) =>
      m.start == 0 ||
      RegExp(r'(?:^|[.!?]\s+)(?:full (?:game|match|race) replay |replay |coverage )?$',
              caseSensitive: false)
          .hasMatch(description.substring(0, m.start)) ||
      RegExp(r'\b(?:final|match|game|race|event)\s+$', caseSensitive: false)
          .hasMatch(description.substring(0, m.start)) ||
      (m.start < 250 &&
          _fixture.hasMatch(description.substring(0, m.start)) &&
          !RegExp(r'\b(?:previous|earlier|last meeting|last met|history|founded|since|back in)\b',
                  caseSensitive: false)
              .hasMatch(description.substring(0, m.start))));
  for (final match in contexts) {
    final parsed = parse(match[1]!, 'Event date in the guide synopsis');
    if (parsed != null &&
        (parsed.year == null || agreesWithTitle(parsed.year!))) {
      return parsed;
    }
  }
  // Event dates in titles often lack a "from" prefix. Restrict this to an
  // actual named calendar date, not free-floating years in synopsis prose.
  final namedTitle = RegExp(
          r'\b(?:\d{1,2}(?:st|nd|rd|th)?\s+[a-z]+|[a-z]+\.?\s+\d{1,2}(?:st|nd|rd|th)?),?\s+(?:19|20)\d{2}\b',
          caseSensitive: false)
      .allMatches(title);
  for (final match in namedTitle) {
    final parsed = parse(match[0]!, 'Event date in the guide title');
    if (parsed != null) return parsed;
  }
  final titleIso = RegExp(r'\b(?:19|20)\d{2}-\d{2}-\d{2}\b').firstMatch(title);
  if (titleIso != null) {
    final parsed = parse(titleIso[0]!, 'Event date in the guide title');
    if (parsed != null) return parsed;
  }
  // Full numeric dates in event titles are useful only when their day/month
  // order is unambiguous. A broadcast timestamp is never used as the year.
  for (final match in RegExp(r'\b\d{1,2}[/.\-]\d{1,2}[/.\-](?:19|20)\d{2}\b')
      .allMatches(title)) {
    final parsed = parse(match[0]!, 'Event date in the guide title');
    if (parsed != null) return parsed;
  }
  if (RegExp(
          r'^(?:another chance to (?:watch|see)|replay|full (?:race|match|game) replay|a look back)\b[^.!?]{0,140}\b(?:yesterday[’\x27]s?|previous night|last night)\b',
          caseSensitive: false)
      .hasMatch(description)) {
    final yesterday = today.subtract(const Duration(days: 1));
    return ReplayEventDate(
        ReplayDatePrecision.day,
        '${yesterday.day} ${_months[yesterday.month - 1]} ${yesterday.year}',
        'Guide describes the previous day, relative to this airing; the synopsis may be reused.',
        day: yesterday,
        year: yesterday.year,
        isGuideDate: true,
        isPossible: true);
  }
  // Provider programme dates can be series-premiere dates. Use them only
  // when the title/synopsis describes an actual fixture, and label the source.
  final footer = RegExp(r'\s[-–]\s((?:19|20)\d{2}-\d{2}-\d{2})\s*$')
      .firstMatch(description);
  if (footer != null && _fixture.hasMatch('$title $description')) {
    final parsed =
        parse(footer[1]!, 'Programme date supplied by the guide', guide: true);
    if (parsed != null && agreesWithTitle(parsed.year!)) return parsed;
  }
  final compact = RegExp(r'\s[-–]\s((?:19|20)\d{2})(\d{2})(\d{2})\s*$')
      .firstMatch(description);
  if (compact != null && _fixture.hasMatch('$title $description')) {
    final parsed = date(int.parse(compact[1]!), int.parse(compact[2]!),
        int.parse(compact[3]!), 'Programme date supplied by the guide',
        guide: true);
    if (parsed != null && agreesWithTitle(parsed.year!)) return parsed;
  }
  final short = RegExp(r'\((\d{2})\.(\d{2})\)\s*$').firstMatch(description);
  if (short != null && int.parse(short[1]!) > 12) {
    final parsed = partial(int.parse(short[2]!), int.parse(short[1]!),
        'Day and month in the guide; year not supplied');
    if (parsed != null) return parsed;
  }
  final season = _season.firstMatch(title) ??
      RegExp(r'\b(?:from|of|in) the (\d{4}|\d{2})[/-](\d{4}|\d{2}) season\b',
              caseSensitive: false)
          .firstMatch(description);
  if (season != null) {
    var start = int.parse(season[1] ?? season[3]!);
    var end = int.parse(season[2] ?? season[4]!);
    if (start < 100) start += start > 70 ? 1900 : 2000;
    if (end < 100) end += (start ~/ 100) * 100;
    if (end < start) end += 100;
    if (end >= start && end <= start + 1 && start <= airing.year) {
      return ReplayEventDate(
          ReplayDatePrecision.season,
          '$start/${(end % 100).toString().padLeft(2, '0')} season',
          'Season in the guide; exact event date not supplied',
          year: start,
          seasonEnd: end);
    }
  }
  final shortYear = RegExp(r"[’'](\d{2})\s*$").firstMatch(title);
  if (shortYear != null &&
      RegExp(r'\b(classic|greatest|replay)\b', caseSensitive: false)
          .hasMatch(title)) {
    final n = int.parse(shortYear[1]!);
    final year = n > 70 ? 1900 + n : 2000 + n;
    if (year <= airing.year) {
      return ReplayEventDate(ReplayDatePrecision.year, '$year',
          'Shortened event year in the guide title',
          year: year);
    }
  }
  // Never treat a bare synopsis year as an event year (often a series date).
  final year = _year
      .allMatches(title)
      .where((m) =>
          (season == null || !title.contains(season[0]!)) &&
          (titleIso == null ||
              m.start < titleIso.start ||
              m.start >= titleIso.end))
      .firstOrNull;
  if (year != null && int.parse(year[1]!) <= airing.year) {
    return ReplayEventDate(ReplayDatePrecision.year, year[1]!,
        'Year in the guide title; exact event date not supplied',
        year: int.parse(year[1]!));
  }
  // Structured episode subtitles are event metadata, unlike years mentioned
  // later in a narrative (previous winners, team history, series premieres).
  final subtitleYear = RegExp(
          r'^(?:(19\d{2}|20\d{2}):\s*\S|S(19\d{2}|20\d{2})\s+E\d+\b)',
          caseSensitive: false)
      .firstMatch((programme.description ?? '').trim());
  if (subtitleYear != null) {
    final value = int.parse(subtitleYear[1] ?? subtitleYear[2]!);
    if (value <= airing.year && agreesWithTitle(value)) {
      return ReplayEventDate(ReplayDatePrecision.year, '$value',
          'Year in the guide event subtitle; exact event date not supplied',
          year: value);
    }
  }
  return null;
}
