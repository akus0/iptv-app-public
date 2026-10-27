import 'channel.dart';

/// What `get_series_info` returns for one show: the playable episodes per
/// season, the series plot (kept as its own field — the browse hero and the
/// description cache only ever want that), and [details], the rest of the
/// metadata the series detail screen shows. In-memory only, never persisted.
typedef SeriesEpisodesResult = ({
  Map<int, List<Channel>> episodes,
  String? plot,
  SeriesDetails? details,
});

/// Display metadata from `get_series_info` beyond the episode list itself.
/// Every field is optional — panels vary wildly in what they fill in, and
/// the detail screen just leaves out whatever is missing.
class SeriesDetails {
  const SeriesDetails({
    this.backdropUrls = const [],
    this.coverUrl,
    this.genre,
    this.cast,
    this.director,
    this.releaseDate,
    this.rating,
    this.episodeRunTimeMinutes,
    this.seasonNames = const {},
    this.episodes = const {},
  });

  /// `info.backdrop_path` — landscape fanart, usually TMDB. Empty when the
  /// panel sends none.
  final List<String> backdropUrls;

  /// `info.cover` — the poster again, sometimes a bigger copy than the one
  /// the `get_series` list carried.
  final String? coverUrl;
  final String? genre;
  final String? cast;
  final String? director;

  /// `info.releaseDate` / `info.release_date`, raw (usually `YYYY-MM-DD`).
  final String? releaseDate;

  /// `info.rating`, already filtered of the "0"/empty placeholders.
  final String? rating;

  /// `info.episode_run_time`, minutes.
  final int? episodeRunTimeMinutes;

  /// Season number -> its own name from the `seasons` list (e.g.
  /// "Specials"), when the panel sends one.
  final Map<int, String> seasonNames;

  /// Per-episode extras, keyed by the episode's `Channel.id`.
  final Map<String, EpisodeDetails> episodes;

  String? get firstBackdrop => backdropUrls.isEmpty ? null : backdropUrls.first;

  /// Four-digit year out of [releaseDate], when it has one.
  int? get year {
    final raw = releaseDate;
    if (raw == null) return null;
    final match = RegExp(r'(19|20)\d{2}').firstMatch(raw);
    return match == null ? null : int.tryParse(match.group(0)!);
  }
}

/// One episode's own metadata from `get_series_info` (`title`,
/// `episode_num`, `info.plot`, `info.duration_secs`/`info.duration`, ...).
class EpisodeDetails {
  const EpisodeDetails({
    required this.season,
    this.episodeNumber,
    this.title,
    this.plot,
    this.durationSeconds,
    this.airDate,
    this.rating,
  });

  final int season;
  final int? episodeNumber;

  /// The provider's raw `title` — often still decorated with the series
  /// name and an `SxxEyy` tag; see `episodeDisplayTitle`.
  final String? title;
  final String? plot;
  final int? durationSeconds;
  final String? airDate;
  final String? rating;
}
