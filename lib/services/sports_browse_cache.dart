import 'package:flutter/widgets.dart';
import '../models/sports.dart';
import '../utils/formula_one.dart';
import 'sports_match_session.dart';

/// Small, in-memory presentation cache shared by the hub and multiview picker.
/// Scores still come from their normal feed caches and refresh on every visit.
/// No widgets, focus nodes, players or full channel indexes are retained here.
class SportsBrowseCache with WidgetsBindingObserver {
  SportsBrowseCache();
  static final shared = SportsBrowseCache().._observe();
  void _observe() => WidgetsBinding.instance.addObserver(this);

  final _entries = <Object, SportsBrowseSnapshot>{};
  SportsBrowseSnapshot? read(Object key, DateTime now) {
    _entries.removeWhere((_, value) =>
        now.isBefore(value.savedAt) || !now.isBefore(value.expiresAt));
    return _entries[key];
  }

  void save(Object key, SportsMatchSession session, List<SportsGame> guideGames,
      Object signature, DateTime now,
      {required Iterable<SportsGame> games}) {
    // Bound memory independently of the number of enabled leagues/days.
    if (session.identities.length > 2000) return;
    var until = now.add(const Duration(minutes: 5));
    void expireAt(DateTime? boundary) {
      if (boundary != null &&
          boundary.isAfter(now) &&
          boundary.isBefore(until)) {
        until = boundary;
      }
    }

    for (final game in games) {
      expireAt(game.start);
      expireAt(game.end);
      if (isFormulaOne(game)) {
        expireAt(game.start.subtract(f1BuildUpLead(game)));
      }
      for (final listing in game.onlineBroadcasts) {
        for (final boundary in [
          listing.expiresAt,
          listing.programme?.start,
          listing.programme?.stop
        ]) {
          expireAt(boundary);
        }
      }
    }
    _entries.remove(key);
    _entries[key] = SportsBrowseSnapshot(
        session.copy(), List.unmodifiable(guideGames), signature, now, until);
    while (_entries.length > 2) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  void didHaveMemoryPressure() => _entries.clear();
}

class SportsBrowseSnapshot {
  SportsBrowseSnapshot(this._session, this.guideGames, this.signature,
      this.savedAt, this.expiresAt);
  final SportsMatchSession _session;
  final List<SportsGame> guideGames;
  final Object signature;
  final DateTime savedAt, expiresAt;

  /// Every route owns its mutable state. Restoring never extends evidence age.
  SportsMatchSession restoreSession() => _session.copy();
}
