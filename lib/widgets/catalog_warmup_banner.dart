import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/playlist_manager.dart';
import '../l10n/l10n.dart';

/// Prominent, persistent banner showing background catalog warm-up
/// progress — shown above the content on every tab (not just tucked away
/// in search) so it's obvious the app is still populating Movies/TV Shows
/// rather than looking broken or "asleep".
class CatalogWarmupBanner extends StatelessWidget {
  const CatalogWarmupBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    if (!playlist.isWarmingCatalog) return const SizedBox.shrink();

    final overallDone = playlist.warmCatalogDone;
    final overallTotal = playlist.warmCatalogTotal;
    final progress = overallTotal == 0 ? null : overallDone / overallTotal;

    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr('Loading full catalog in the background — {p}', {
                      'p':
                          progress == null ? '' : '${(progress * 100).round()}%'
                    }),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _TypeProgress(
                    label: tr('Live TV'),
                    done: 1,
                    total: 1,
                    doneOverride: tr('Ready'),
                  ),
                ),
                Expanded(
                  child: _TypeProgress(
                    label: tr('Movies'),
                    done: playlist.vodCatalogDone,
                    total: playlist.vodCatalogTotal,
                  ),
                ),
                Expanded(
                  child: _TypeProgress(
                    label: tr('TV Shows'),
                    done: playlist.seriesCatalogDone,
                    total: playlist.seriesCatalogTotal,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TypeProgress extends StatelessWidget {
  const _TypeProgress({
    required this.label,
    required this.done,
    required this.total,
    this.doneOverride,
  });

  final String label;
  final int done;
  final int total;
  final String? doneOverride;

  @override
  Widget build(BuildContext context) {
    final text = doneOverride ??
        (total == 0
            ? '$done'
            : tr('{done}/{total} categories', {'done': done, 'total': total}));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
