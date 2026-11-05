/// Local browsing preferences; these never change matching scores or saved picks.
enum SportsChannelSort { suggested, name, region, playlist }

enum SportsChannelEvidence { all, specific, likely }

class SportsChannelFilters {
  const SportsChannelFilters({
    this.sort = SportsChannelSort.suggested,
    this.evidence = SportsChannelEvidence.all,
    this.region,
    this.playlist,
    this.untriedOnly = false,
  });
  final SportsChannelSort sort;
  final SportsChannelEvidence evidence;
  final String? region, playlist;
  final bool untriedOnly;
  bool get isDefault => sort == SportsChannelSort.suggested && !hasFilters;
  bool get hasFilters =>
      evidence != SportsChannelEvidence.all ||
      region != null ||
      playlist != null ||
      untriedOnly;
  int get activeCount =>
      (sort != SportsChannelSort.suggested ? 1 : 0) +
      (evidence != SportsChannelEvidence.all ? 1 : 0) +
      (region != null ? 1 : 0) +
      (playlist != null ? 1 : 0) +
      (untriedOnly ? 1 : 0);
  SportsChannelFilters copyWith(
          {SportsChannelSort? sort,
          SportsChannelEvidence? evidence,
          String? region,
          String? playlist,
          bool? untriedOnly,
          bool clearRegion = false,
          bool clearPlaylist = false}) =>
      SportsChannelFilters(
        sort: sort ?? this.sort,
        evidence: evidence ?? this.evidence,
        region: clearRegion ? null : region ?? this.region,
        playlist: clearPlaylist ? null : playlist ?? this.playlist,
        untriedOnly: untriedOnly ?? this.untriedOnly,
      );
}

/// Kept by the Sports screen, not on disk. A different event starts unfiltered.
class SportsChannelBrowseSession {
  final _filters = <Object, SportsChannelFilters>{};
  SportsChannelFilters read(Object key) =>
      _filters[key] ?? const SportsChannelFilters();
  void write(Object key, SportsChannelFilters value) {
    _filters.remove(key);
    if (!value.isDefault) _filters[key] = value;
    while (_filters.length > 24) {
      _filters.remove(_filters.keys.first);
    }
  }
}
