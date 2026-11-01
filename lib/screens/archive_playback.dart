import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/archive_models.dart';
import '../models/channel.dart';
import '../models/series_details.dart';
import '../models/xtream_series.dart';
import '../services/archive_service.dart';
import '../services/desktop_mini_player.dart';
import '../services/playback_service.dart';
import '../services/tracker_api.dart';
import '../services/watch_tracker.dart';
import '../widgets/tv_menu_tile.dart';
import 'desktop_player_screen.dart';
import 'player_screen.dart';
import 'series_detail_screen.dart';

/// Starting playback of Archive titles, shared by the movie page
/// (`ArchiveDetailScreen`) and Archive shows, which open the regular
/// [SeriesDetailScreen] through [openArchiveSeries].
///
/// Play asks the source(s) for every direct stream: one plays at once,
/// several open [pickArchiveStream]. An episode's queue (Next, auto-
/// advance) holds placeholder channels without a URL; the resolver handed
/// to the player looks the next one's streams up when it's due and keeps
/// to the pick made here — same source, same stream name (quality) when
/// it has one — via [preferredArchiveStream].

/// The stream list for a title with several: each row shows the stream's
/// `name` (source, quality) over its `title` (file, size, language). Null
/// when dismissed with Back.
Future<ArchiveStreamOption?> pickArchiveStream(
    BuildContext context, List<ArchiveStreamOption> options) {
  final manySources =
      options.map((o) => o.source.manifestUrl).toSet().length > 1;
  return showModalBottomSheet<ArchiveStreamOption>(
    context: context,
    backgroundColor: const Color(0xFF1A1A1A),
    isScrollControlled: true,
    constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8, maxWidth: 760),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(tr('Choose a stream'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              itemCount: options.length,
              itemBuilder: (_, i) {
                final o = options[i];
                final name = o.stream.name ??
                    o.stream.title?.split('\n').first ??
                    tr('Stream {n}', {'n': i + 1});
                final details = [
                  if (o.stream.name != null && o.stream.title != null)
                    o.stream.title!,
                  if (manySources) o.source.name,
                ].join('\n');
                return TvMenuTile(
                  autofocus: i == 0,
                  icon: Icons.play_circle_outline,
                  title: name,
                  titleMaxLines: 2,
                  subtitle: details.isEmpty ? null : details,
                  onTap: () => Navigator.of(sheetContext).pop(o),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// The option of [options] closest to [previous]: same source and same
/// stream name, else the same source's first, else the first of all.
ArchiveStreamOption preferredArchiveStream(
    List<ArchiveStreamOption> options, ArchiveStreamOption? previous) {
  if (previous == null) return options.first;
  final sameSource = options
      .where((o) => o.source.manifestUrl == previous.source.manifestUrl)
      .toList();
  final name = previous.stream.name;
  if (name != null) {
    for (final o in sameSource) {
      if (o.stream.name == name) return o;
    }
  }
  return sameSource.firstOrNull ?? options.first;
}

/// Lets the players report this title to Trakt/Simkl (by IMDb id; titles
/// without one aren't reported). See `WatchTracker`.
void _track(Channel channel, ArchiveMeta meta, ArchiveVideo? episode) {
  final imdb = meta.imdb;
  if (imdb == null) return;
  WatchTracker.instance.register(
      channel.id,
      episode == null
          ? TrackedItem.movie(imdb)
          : TrackedItem.episode(imdb,
              season: episode.season, episode: episode.episode));
}

void _noStream(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(tr('No playable stream for this title.')),
    backgroundColor: Colors.red.shade900,
  ));
}

/// Looks up [meta]'s (or its [episode]'s) streams, lets the user pick when
/// there are several, and plays it. With [queue] (every episode, in order,
/// as placeholders) and [videosById] (their [ArchiveVideo]s by channel id)
/// the player's Next / auto-advance continue with the same source.
Future<void> playArchiveTitle(
  BuildContext context, {
  required ArchiveSource source,
  required ArchiveMeta meta,
  ArchiveVideo? episode,
  List<Channel>? queue,
  Map<String, ArchiveVideo> videosById = const {},
}) async {
  final service = context.read<ArchiveService>();
  final playback = context.read<PlaybackService>();
  List<ArchiveStreamOption> options;
  try {
    options = await service.streams(source, meta, episode: episode);
  } catch (_) {
    options = const [];
  }
  if (!context.mounted) return;
  if (options.isEmpty) return _noStream(context);
  // One stream plays at once; several (qualities, languages…) = pick.
  var picked = options.length == 1
      ? options.single
      : await pickArchiveStream(context, options);
  if (picked == null || !context.mounted) return;
  final channel =
      service.channelFor(source, meta, picked.stream, episode: episode);
  _track(channel, meta, episode);
  // Extras' "Recently watched" row (the show, for an episode).
  unawaited(service.recordWatched(source, meta));

  Future<Channel?> resolve(Channel placeholder) async {
    final video = videosById[placeholder.id];
    if (video == null) return null;
    final next = await service.streams(source, meta, episode: video);
    if (next.isEmpty) return null;
    final o = preferredArchiveStream(next, picked);
    picked = o; // the episode after follows this one
    final ch = service.channelFor(source, meta, o.stream, episode: video);
    _track(ch, meta, video);
    return ch;
  }

  final hasQueue = queue != null && queue.isNotEmpty;
  // Same split as MovieDetailScreen._play: Windows has its own player.
  if (Platform.isWindows) {
    DesktopMiniPlayer.instance.clear();
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DesktopPlayerScreen(
              channel: channel,
              queue: hasQueue ? queue : null,
              resolveQueued: hasQueue ? resolve : null,
            )));
  } else {
    playback.setUpNextQueue(hasQueue ? queue : null,
        resolve: hasQueue ? resolve : null);
    // Awaited so PlayerScreen's own play() doesn't race this one (see
    // TvHomeScreen._selectChannel).
    await playback.play(channel);
    if (!context.mounted) return;
    await PlayerScreen.open(Navigator.of(context), channel);
  }
}

/// Opens an Archive show on the regular [SeriesDetailScreen]: the meta
/// (provider's or the source's own) becomes its episodes and details, and
/// Play goes through [playArchiveTitle] with the whole show as the queue.
Future<void> openArchiveSeries(
    BuildContext context, ArchiveSource source, ArchiveMeta preview) {
  final service = context.read<ArchiveService>();
  var meta = preview;
  final videosById = <String, ArchiveVideo>{};

  Future<SeriesEpisodesResult> load() async {
    meta = await service.meta(source, preview) ?? preview;
    final episodes = <int, List<Channel>>{};
    final details = <String, EpisodeDetails>{};
    videosById.clear();
    for (final v in meta.videos) {
      final placeholder = service
          .channelFor(source, meta, const ArchiveStream(url: ''), episode: v);
      videosById[placeholder.id] = v;
      episodes.putIfAbsent(v.season, () => []).add(placeholder);
      details[placeholder.id] = EpisodeDetails(
        season: v.season,
        episodeNumber: v.episode,
        title: v.title.isEmpty ? null : v.title,
        plot: v.overview,
        airDate: v.released,
      );
    }
    final runtime =
        int.tryParse(RegExp(r'\d+').firstMatch(meta.runtime ?? '')?[0] ?? '');
    return (
      episodes: episodes,
      plot: meta.description,
      details: SeriesDetails(
        backdropUrls: [if (meta.backgroundUrl != null) meta.backgroundUrl!],
        coverUrl: meta.posterUrl,
        genre: meta.genres.isEmpty ? null : meta.genres.join(', '),
        cast: meta.cast.isEmpty ? null : meta.cast.join(', '),
        director: meta.director.isEmpty ? null : meta.director.join(', '),
        releaseDate: meta.year,
        rating: meta.rating,
        episodeRunTimeMinutes: runtime,
        episodes: details,
      ),
    );
  }

  Future<void> play(Channel episode, List<Channel> all) async {
    final video = videosById[episode.id];
    if (video == null) return;
    await playArchiveTitle(context,
        source: source,
        meta: meta,
        episode: video,
        queue: all,
        videosById: videosById);
  }

  return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SeriesDetailScreen(
            series: XtreamSeries(
              seriesId: 0,
              playlistId: ArchiveService.playlistId,
              name: preview.name,
              categoryId: ArchiveService.playlistId,
              coverUrl: preview.posterUrl,
              posterUrl: preview.posterUrl,
              backdropUrl: preview.backgroundUrl,
            ),
            loadEpisodes: load,
            playEpisode: play,
            showFavorite: false,
            imdbId: preview.imdb,
          )));
}
