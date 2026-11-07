final _slotPrefix = RegExp(
    r'^\s*live\s+event\s+\d{1,3}\s*[-:|–—]\s*(?:(?:0?[1-9]|1[0-2]):[0-5]\d\s*[ap]m\s+)?',
    caseSensitive: false);

/// Provider slot labels are not event numbers. Retain the original EPG title
/// on the programme so channel selection and playback evidence stay exact.
String sportsGuideBroadcastTitle(String title) {
  final clean = title.replaceFirst(_slotPrefix, '').trim();
  return clean.isEmpty ? title : clean;
}

final _genreFooter = RegExp(
    r'^\(([^()]{1,160})\)(?:\s*-\s*(\d{4}(?:-\d{2}-\d{2}|\d{4})?))?\s*$');
const _guideGenres = {
  'sports',
  'sport',
  'sports event',
  'football',
  'playoff sports',
  'horse racing',
  'rodeo',
  'golf',
  'tennis',
  'poker',
  'card games',
  'snooker',
  'pool',
  'cricket',
  'martial arts',
  'mixed martial arts',
  'boxing',
  'auto racing',
  'motor sport',
  'motorsport',
  'racquet',
  'episode',
  'series',
};

/// Only XMLTV category footers are redundant. Keep recorded dates, numbered
/// episodes, courts, divisions and any unrecognised parenthesised information.
/// This is grouping evidence only; the stored programme is never rewritten.
String sportsGuideCoverageSynopsis(String text, DateTime start,
    {bool allowLiveLocalDate = false}) {
  final opening = text.lastIndexOf('(');
  if (opening < 0 || text.length - opening > 200) return text;
  final footer = _genreFooter.firstMatch(text.substring(opening));
  if (footer == null ||
      !footer[1]!.split(',').every(
          (genre) => _guideGenres.contains(genre.trim().toLowerCase()))) {
    return text;
  }
  final date = footer[2];
  final airing = start.toUtc().toIso8601String().substring(0, 10);
  bool sameDate(DateTime instant) {
    final day = instant.toUtc().toIso8601String().substring(0, 10);
    return date == day || date == day.replaceAll('-', '');
  }

  // Coalescing only: explicit live copies may label the same UTC airing with
  // a local calendar date. Never discard a date in the title/body or alter
  // programme eligibility, timestamps, replay checks or channel bindings.
  final localDate = allowLiveLocalDate &&
      date != null &&
      (sameDate(start.subtract(const Duration(hours: 12))) ||
          sameDate(start.add(const Duration(hours: 14))));
  final keepDate = date != null &&
      date != airing &&
      date != airing.replaceAll('-', '') &&
      !localDate;
  return '${text.substring(0, opening).trimRight()}${keepDate ? ' - $date' : ''}';
}
