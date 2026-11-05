import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/channel.dart';
import '../../services/playlist_manager.dart';
import '../../widgets/auto_pair_flow.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../l10n/l10n.dart';

/// Manual one-to-one channel links across playlists for playback failover. Embedded in EPG
/// settings; choosing a target opens a separate picker.
class ChannelLinkingScreen extends StatefulWidget {
  const ChannelLinkingScreen({super.key});

  @override
  State<ChannelLinkingScreen> createState() => _ChannelLinkingScreenState();
}

class _ChannelLinkingScreenState extends State<ChannelLinkingScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'channel-pairing-search');
  final _autoPairFocus = FocusNode(debugLabel: 'channel-pairing-auto-pair');

  /// See `EpgChannelMatchingScreen._firstResultFocus`'s doc comment.
  final _firstResultFocus =
      FocusNode(debugLabel: 'channel-pairing-first-result');

  /// Non-null right after "Auto-Pair Channels" and choosing Review —
  /// narrows the list to just the composite `Channel.id`s that pass
  /// paired, instead of every channel. Cleared by editing the search
  /// field (typing a fresh query is a clearer "I'm done reviewing, I want
  /// to look for something else" signal than a separate button) or by
  /// running Auto-Pair/Unpair again.
  Set<String>? _reviewFilter;

  /// Escape the search field in both directions, matching EpgChannelMatchingScreen.
  bool _handleSearchEscape(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowUp &&
        event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return false;
    }
    if (FocusManager.instance.primaryFocus != _searchFocus) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _autoPairFocus.requestFocus();
    } else {
      _firstResultFocus.requestFocus();
    }
    return true;
  }

  Future<void> _autoPair(PlaylistManager playlist) async {
    final result =
        await runAutoPairFlow(context, autoPair: playlist.autoPairChannelLinks);
    if (!mounted) return;
    setState(() => _reviewFilter = result.review ? result.paired : null);
  }

  Future<void> _unpair(PlaylistManager playlist) async {
    final didUnpair = await confirmAndUnpair(context,
        autoPairedCount: playlist.autoPairedChannelLinkCount,
        unpair: playlist.unpairAutoChannelLinks);
    if (!mounted || !didUnpair) return;
    setState(() => _reviewFilter = null);
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleSearchEscape);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleSearchEscape);
    _searchController.dispose();
    _searchFocus.dispose();
    _autoPairFocus.dispose();
    _firstResultFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    // Every enabled playlist's live channels together, not scoped to one —
    // linking is inherently a relationship *between* playlists, so this
    // list needs to show all of them side by side (with which playlist
    // each row belongs to) rather than picking one as "the" source.
    final channels = playlist.visibleChannels(category: 'tv');
    final query = _searchController.text.trim().toLowerCase();
    final reviewFilter = _reviewFilter;
    final filtered = (query.isEmpty
            ? channels
            : channels.where((c) => c.name.toLowerCase().contains(query)))
        .where((c) => reviewFilter == null || reviewFilter.contains(c.id))
        .toList();
    final enabledCount = playlist.profiles.where((p) => p.enabled).length;
    final canLink = enabledCount >= 2;

    return Column(
      children: [
        if (!canLink)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              tr('Add and enable a second playlist first — a link connects a channel on one playlist to its equivalent on another.'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (canLink)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    focusNode: _autoPairFocus,
                    icon: const Icon(Icons.auto_fix_high),
                    label: Text(tr('Auto-Pair Channels')),
                    onPressed: () => _autoPair(playlist),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.undo),
                    label: Text(tr('Unpair Channels')),
                    onPressed: () => _unpair(playlist),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          // Open the keyboard only on OK so D-pad navigation can pass through the field.
          child: TvTextFieldGate(
            focusNode: _searchFocus,
            builder: (context, readOnly) => TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              readOnly: readOnly,
              decoration: InputDecoration(
                labelText: reviewFilter != null
                    ? tr(
                        'Reviewing {reviewFilter} auto-paired channel{s} — type to search all instead',
                        {
                            'reviewFilter': reviewFilter.length,
                            's': reviewFilter.length == 1 ? '' : 's'
                          })
                    : tr('Search your channels'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() {
                if (value.isNotEmpty) _reviewFilter = null;
              }),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(tr('No channels found.')))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final channel = filtered[i];
                    final link = playlist.channelLinkFor(channel);
                    final linkedChannel =
                        link == null ? null : playlist.resolveChannelLink(link);
                    final ownPlaylistName =
                        playlist.playlistNameFor(channel.playlistId);
                    final String status;
                    final bool isError;
                    if (link == null) {
                      status = tr('Not linked');
                      isError = false;
                    } else if (linkedChannel == null) {
                      // The linked playlist was removed/disabled, or that
                      // channel disappeared from a refreshed catalog —
                      // surfaced rather than silently resolving to
                      // nothing the next time playback actually needs it.
                      status = tr('Linked channel no longer available');
                      isError = true;
                    } else {
                      status = tr('Linked to {p}: {name}', {
                        'p': playlist.playlistNameFor(link.playlistId),
                        'name': linkedChannel.name
                      });
                      isError = false;
                    }
                    return ListTile(
                      focusNode: i == 0 ? _firstResultFocus : null,
                      title: Text(channel.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('$ownPlaylistName — $status',
                          style: TextStyle(
                              color: isError
                                  ? Theme.of(context).colorScheme.error
                                  : null)),
                      trailing: link != null
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              tooltip: tr('Clear link'),
                              onPressed: () =>
                                  playlist.setChannelLink(channel, null),
                            )
                          : Icon(Icons.chevron_right,
                              color: canLink ? null : Colors.white24),
                      onTap: !canLink
                          ? null
                          : () async {
                              final picked = await Navigator.of(context)
                                  .push<Channel>(MaterialPageRoute(
                                      builder: (_) => _PickLinkedChannelScreen(
                                          source: channel)));
                              if (picked != null) {
                                await playlist.setChannelLink(channel, (
                                  playlistId: picked.playlistId,
                                  rawId: picked.rawId
                                ));
                              }
                            },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Searches every *other* enabled playlist's live channels (never the
/// source channel's own playlist — same-playlist failover is already the
/// backup-servers mechanism, a link to another channel on the same
/// playlist wouldn't mean anything) and pops the picked [Channel] back to
/// [ChannelLinkingScreen].
class _PickLinkedChannelScreen extends StatefulWidget {
  const _PickLinkedChannelScreen({required this.source});

  final Channel source;

  @override
  State<_PickLinkedChannelScreen> createState() =>
      _PickLinkedChannelScreenState();
}

class _PickLinkedChannelScreenState extends State<_PickLinkedChannelScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final candidates = playlist
        .visibleChannels(category: 'tv')
        .where((c) => c.playlistId != widget.source.playlistId)
        .toList();
    final query = _searchController.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? candidates
        : candidates
            .where((c) => c.name.toLowerCase().contains(query))
            .toList();

    return SettingsScaffold(
      title: tr('Link "{name}"', {'name': widget.source.name}),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FocusNodeOwner(
              builder: (context, node) => TvTextFieldGate(
                focusNode: node,
                builder: (context, readOnly) => TextField(
                  controller: _searchController,
                  focusNode: node,
                  readOnly: readOnly,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: tr('Search other playlists\' channels'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text(tr('No matches.')))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final channel = filtered[i];
                      return ListTile(
                        title: Text(channel.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle:
                            Text(playlist.playlistNameFor(channel.playlistId)),
                        onTap: () => Navigator.of(context).pop(channel),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
