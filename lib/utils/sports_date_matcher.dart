typedef SportsListingDate = ({int? year, int month, int day, bool ambiguous});
typedef _CalendarDay = ({int year, int month, int day});

/// The provider date may be one day either side of the event's reference.
/// Retains only three calendar dates, never an eligibility decision or clock.
class SportsDateMatcher {
  var _from = 0, _until = 0;
  List<_CalendarDay> _days = const [];

  bool matches(SportsListingDate date, DateTime reference) {
    // Local +/-24-hour arithmetic can cross DST differently from UTC days.
    // Preserve the original calculation for local references and the extreme
    // DateTime range, where eagerly adding a day could change overflow timing.
    if (!reference.isUtc) return _uncached(date, reference);
    final stamp = reference.microsecondsSinceEpoch;
    const edge = 8640000000000000000 - Duration.microsecondsPerDay;
    if (stamp <= -edge || stamp >= edge) return _uncached(date, reference);

    if (stamp < _from || stamp >= _until) {
      _days = [
        for (final offset in const [-1, 0, 1])
          _calendarDay(reference.add(Duration(days: offset))),
      ];
      _from = DateTime.utc(reference.year, reference.month, reference.day)
          .microsecondsSinceEpoch;
      _until = _from + Duration.microsecondsPerDay;
    }
    for (final day in _days) {
      if (date.year != null && day.year != date.year) continue;
      if (day.month == date.month && day.day == date.day) return true;
      if (date.ambiguous && day.month == date.day && day.day == date.month) {
        return true;
      }
    }
    return false;
  }

  static _CalendarDay _calendarDay(DateTime date) =>
      (year: date.year, month: date.month, day: date.day);

  static bool _uncached(SportsListingDate date, DateTime reference) {
    for (final offset in const [-1, 0, 1]) {
      final day = reference.add(Duration(days: offset));
      if (date.year != null && day.year != date.year) continue;
      if (day.month == date.month && day.day == date.day) return true;
      if (date.ambiguous && day.month == date.day && day.day == date.month) {
        return true;
      }
    }
    return false;
  }
}
