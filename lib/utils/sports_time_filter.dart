import 'formula_one.dart';
import '../models/sports.dart';

/// Presentation only: never changes event state or channel confidence.
enum SportsTimeFilter {
  live,
  liveAndSoon,
  soon,
  all;

  String get label => switch (this) {
        live => 'Live',
        liveAndSoon => 'Live + soon',
        soon => 'Starting soon',
        all => 'All events',
      };
  String get description => switch (this) {
        live =>
          'Live events and on-air guide coverage, plus F1 build-up: 30 minutes before sessions and 90 before races.',
        liveAndSoon =>
          'Live events plus scheduled starts in the next 45 minutes.',
        soon =>
          'Scheduled starts in the next 45 minutes, including up to 15 minutes late.',
        all => 'Live, upcoming and finished events on the selected day.',
      };
  bool get includesSoon => this == soon || this == liveAndSoon;
  bool accepts(SportsGame game, DateTime now) {
    if (this == all) return true;
    if (isF1BuildUp(game, now)) return true;
    if (game.state == GameState.live) return this != soon;
    if (!includesSoon || game.state != GameState.pre) return false;
    final until = game.start.difference(now);
    return until >= const Duration(minutes: -15) &&
        until <= const Duration(minutes: 45);
  }
}
