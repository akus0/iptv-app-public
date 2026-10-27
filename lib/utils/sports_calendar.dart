/// Local calendar arithmetic: a day can be 23 or 25 hours around a clock change.
/// Inputs represent calendar dates; convert event timestamps to local time first.
DateTime sportsCalendarDay(DateTime date, [int offset = 0]) =>
    DateTime(date.year, date.month, date.day + offset);

int sportsCalendarDayOffset(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays;
