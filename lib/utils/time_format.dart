import 'package:intl/intl.dart';

/// Settings > General > "24-hour clock": every clock/programme/game time in
/// the app formats through [TimeFormat.hm]. Device-wide; set at startup by
/// `AppPreferences.init` and on change by `AppPreferences.setUse24h`
/// (screens rebuild from its notify, clocks on their next tick).
class TimeFormat {
  static bool use24h = true;

  /// "21:30" or "9:30 PM".
  static DateFormat get hm => DateFormat(use24h ? 'HH:mm' : 'h:mm a');

  /// "2026-10-16 21:30" / "2026-10-16 9:30 PM" (Settings "last updated").
  static String dateTime(DateTime t) =>
      '${DateFormat('yyyy-MM-dd').format(t)} ${hm.format(t)}';

  /// "Fri, Oct 16 21:30" — locale-aware day + [hm].
  static String dayTime(DateTime t) =>
      '${DateFormat.MMMEd().format(t)} ${hm.format(t)}';
}
