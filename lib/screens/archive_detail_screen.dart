import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/archive_models.dart';
import '../services/archive_service.dart';
import '../services/storage_service.dart';
import '../services/tracker_sync.dart';
import '../widgets/detail_header.dart';
import 'archive_playback.dart';

/// An Archive movie's page: backdrop, poster, year/genres, description and
/// Play. Built from the same `detail_header.dart` pieces as
/// MovieDetailScreen. Play goes through [playArchiveTitle] (stream lookup,
/// picker when there are several, then the normal player), so resume
/// positions work like any VOD. Archive shows open the regular
/// SeriesDetailScreen instead — see [openArchiveSeries].
class ArchiveDetailScreen extends StatefulWidget {
  const ArchiveDetailScreen(
      {super.key, required this.source, required this.preview});

  final ArchiveSource source;
  final ArchiveMeta preview;

  @override
  State<ArchiveDetailScreen> createState() => _ArchiveDetailScreenState();
}

class _ArchiveDetailScreenState extends State<ArchiveDetailScreen> {
  final _playNode = FocusNode(debugLabel: 'archive-play');
  final _restartNode = FocusNode(debugLabel: 'archive-restart');

  ArchiveMeta? _full;
  bool _starting = false;

  ArchiveMeta get _meta => _full ?? widget.preview;

  @override
  void initState() {
    super.initState();
    _loadMeta();
    _syncTrackers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _playNode.context != null) _playNode.requestFocus();
    });
  }

  /// Trakt / Simkl: a watch or pause made elsewhere fills in this movie's
  /// mark / resume point (by IMDb id). Its play is registered when it
  /// starts (`playArchiveTitle`).
  Future<void> _syncTrackers() async {
    final imdb = widget.preview.imdb;
    if (imdb == null) return;
    final changed = await TrackerSync.instance.applyToMovie(
        context.read<StorageService>(),
        imdb: imdb,
        channelId: ArchiveService.channelId(widget.source, widget.preview.id,
            episode: false));
    if (changed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _playNode.dispose();
    _restartNode.dispose();
    super.dispose();
  }

  /// The full meta has a longer description than the catalog preview.
  Future<void> _loadMeta() async {
    ArchiveMeta? full;
    try {
      full = await context
          .read<ArchiveService>()
          .meta(widget.source, widget.preview);
    } catch (_) {
      full = null; // the preview is enough for a movie
    }
    if (mounted && full != null) setState(() => _full = full);
  }

  Future<void> _play({bool restart = false}) async {
    if (_starting) return;
    setState(() => _starting = true);
    if (restart) {
      await context.read<StorageService>().setLastPosition(
          ArchiveService.channelId(widget.source, _meta.id, episode: false), 0);
    }
    if (!mounted) return;
    try {
      await playArchiveTitle(context, source: widget.source, meta: _meta);
    } finally {
      if (mounted) setState(() => _starting = false); // + refresh progress
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 700;
    final meta = _meta;
    final backdrop = meta.backgroundUrl;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: DetailBackdrop(
                url: backdrop ?? meta.posterUrl, fadeLeft: !narrow),
          ),
          SafeArea(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  narrow ? 16 : 40, narrow ? 8 : 32, narrow ? 16 : 40, 32),
              children: [
                if (narrow)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (meta.posterUrl != null && !narrow) ...[
                      DetailPoster(url: meta.posterUrl!, width: 150),
                      const SizedBox(width: 24),
                    ],
                    Expanded(child: _buildInfo(meta)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfo(ArchiveMeta meta) {
    final storage = context.read<StorageService>();
    final scheme = Theme.of(context).colorScheme;
    final movieId =
        ArchiveService.channelId(widget.source, meta.id, episode: false);
    final positionMs = storage.getLastPosition(movieId);
    final watched = storage.isFullyWatched(movieId);
    final resume = positionMs > 0 && !watched;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(meta.name,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 4, children: [
          if (meta.rating != null)
            DetailMetaChip(
              scale: 1,
              leading:
                  Icon(Icons.star_rounded, size: 14, color: scheme.primary),
              label: meta.rating!,
              strong: true,
            ),
          if (meta.year != null)
            DetailMetaChip(scale: 1, label: meta.year!, strong: true),
          if (meta.runtime != null)
            DetailMetaChip(scale: 1, label: meta.runtime!),
          for (final g in meta.genres.take(4))
            DetailMetaChip(scale: 1, label: g),
          DetailMetaChip(scale: 1, label: widget.source.name),
        ]),
        const SizedBox(height: 12),
        if (meta.description != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(meta.description!,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: Colors.white70)),
          ),
        if (meta.cast.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(tr('Cast: {names}', {'names': meta.cast.take(4).join(', ')}),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: [
          DetailPillButton(
            focusNode: _playNode,
            icon: _starting ? Icons.hourglass_top : Icons.play_arrow_rounded,
            label: resume ? tr('Resume') : tr('Play'),
            emphasized: true,
            scale: 1,
            onPressed: () => _play(restart: watched),
          ),
          if (resume)
            DetailPillButton(
              focusNode: _restartNode,
              icon: Icons.replay_rounded,
              label: tr('Restart'),
              scale: 1,
              onPressed: () => _play(restart: true),
            ),
        ]),
      ],
    );
  }
}
