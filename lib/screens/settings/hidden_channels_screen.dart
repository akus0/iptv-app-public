import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/channel.dart';
import '../../services/playlist_manager.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/settings_scaffold.dart';
import '../../l10n/l10n.dart';

/// Individually-hidden live channels for one playlist — the counterpart
/// to `GroupManagementScreen`'s whole-group hide/show, for a duplicate
/// feed within an otherwise-wanted group (e.g. the same channel offered
/// in both HD and HEVC) that hiding the whole group can't target. A
/// separate, self-contained screen rather than a new tab in
/// `GroupManagementScreen` — that screen's 4-tab D-pad navigation (Left/
/// Right tab switching, Up-arrow-to-Done fallback, leave-confirmation)
/// is already tightly tuned; a flat list with one action per row doesn't
/// need any of that.
class HiddenChannelsScreen extends StatelessWidget {
  const HiddenChannelsScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final channels = playlist.hiddenChannelsFor(playlistId);

    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: tr('Hidden channels'),
        body: channels.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    tr('No channels are individually hidden. Hide one from its row in the Live TV list.'),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: channels.length,
                itemBuilder: (context, i) {
                  final channel = channels[i];
                  return _HiddenChannelRow(
                    channel: channel,
                    onUnhide: () => playlist.toggleChannelHidden(channel),
                  );
                },
              ),
      ),
    );
  }
}

class _HiddenChannelRow extends StatelessWidget {
  const _HiddenChannelRow({required this.channel, required this.onUnhide});

  final Channel channel;
  final VoidCallback onUnhide;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: SizedBox(
          width: 40,
          height: 40,
          child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
              ? CachedNetworkImage(
                  imageUrl: channel.logoUrl!,
                  fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => const Icon(Icons.tv))
              : const Icon(Icons.tv),
        ),
        title: Text(channel.name),
        subtitle: Text(channel.group),
        trailing: OutlinedButton(
          onPressed: onUnhide,
          child: Text(tr('Unhide')),
        ),
      ),
    );
  }
}
