import 'catalog_database.dart';
import 'playlist_manager.dart';

/// Fill only missing categories for an explicit library search. Existing title
/// rows remain on disk; ordinary browsing never starts this work.
class LibrarySearchLoader {
  LibrarySearchLoader(this.database, this.playlists);
  final CatalogDatabase database;
  final PlaylistManager playlists;
  final _checked = <(bool, String, String)>{};

  Future<void> load({
    required bool series,
    required Iterable<({String playlistId, String title})> groups,
    required bool Function() isCurrent,
    required void Function(int done, int total, bool changed, bool failed)
        onProgress,
  }) async {
    final stored = await database.storedLibraryGroups(series: series);
    if (!isCurrent()) return;
    _checked.addAll(stored.map((g) => (series, g.playlistId, g.title)));
    final missing = groups
        .toSet()
        .where((g) => !_checked.contains((series, g.playlistId, g.title)))
        .toList();
    onProgress(0, missing.length, false, false);
    for (var i = 0; i < missing.length; i++) {
      if (!isCurrent()) return;
      final group = missing[i];
      var failed = false;
      try {
        await playlists.loadLibraryCategory(
            group.playlistId, group.title, series ? 'series' : 'vod');
        // Successful empty categories count as checked too. A new keystroke
        // must not repeatedly ask the provider for the same empty response.
        _checked.add((series, group.playlistId, group.title));
      } catch (_) {
        failed = true;
      }
      if (!isCurrent()) return;
      onProgress(i + 1, missing.length, !failed, failed);
    }
  }
}
