import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../utils/time_format.dart';
import '../services/epg_service.dart';
import '../l10n/l10n.dart';

/// Shows the current and next program for a channel.
///
/// Renders as a compact single-line subtitle inside channel list rows when
/// [compact] is true, or as a fuller bar above the video player otherwise.
class EpgGuide extends StatelessWidget {
  const EpgGuide({super.key, required this.channelId, this.compact = false});

  final String channelId;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final current = epg.getCurrentProgram(channelId);
    final next = epg.getNextProgram(channelId);
    final timeFormat = TimeFormat.hm;

    if (current == null && next == null) {
      return compact
          ? Text(tr('No program data'), style: const TextStyle(fontSize: 12))
          : const SizedBox.shrink();
    }

    if (compact) {
      final text = current != null
          ? '${timeFormat.format(current.start)} ${current.title}'
          : tr('Next: {p}', {'p': next!.title});
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          if (current != null)
            Expanded(
              child: Text(
                tr('NOW: {title} ({p}-{p2})', {
                  'title': current.title,
                  'p': timeFormat.format(current.start),
                  'p2': timeFormat.format(current.stop)
                }),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (next != null)
            Expanded(
              child: Text(
                tr('NEXT: {title} ({p})',
                    {'title': next.title, 'p': timeFormat.format(next.start)}),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }
}
