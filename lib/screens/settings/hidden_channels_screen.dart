import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/channel.dart';
import '../../services/playlist_manager.dart';
import '../../widgets/settings_scaffold.dart';
import '../../l10n/l10n.dart';

/// Individually hidden live channels for one playlist; restoring a channel
/// does not change its category's visibility.
class HiddenChannelsScreen extends StatelessWidget {
  const HiddenChannelsScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final channels = playlist.hiddenChannelsFor(playlistId);

    return withSettingsTheme(
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
    return ListTile(
      leading: SizedBox(
        width: 28,
        height: 28,
        child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: channel.logoUrl!,
                fit: BoxFit.contain,
                memCacheWidth: 84,
                memCacheHeight: 84,
                errorWidget: (_, __, ___) => const Icon(Icons.tv))
            : const Icon(Icons.tv),
      ),
      title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle:
          Text(channel.group, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: OutlinedButton(
        onPressed: onUnhide,
        child: Text(tr('Unhide')),
      ),
    );
  }
}
