import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../widgets/auto_pair_flow.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../l10n/l10n.dart';

/// Assign guide entries to visible channels when automatic identifiers do not match. Embedded
/// in the EPG settings page; selecting a channel opens the guide directory, and clearing an
/// override restores automatic matching.
class EpgChannelMatchingScreen extends StatefulWidget {
  const EpgChannelMatchingScreen({super.key});

  @override
  State<EpgChannelMatchingScreen> createState() =>
      _EpgChannelMatchingScreenState();
}

class _EpgChannelMatchingScreenState extends State<EpgChannelMatchingScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'epg-matching-search');
  final _autoPairFocus = FocusNode(debugLabel: 'epg-matching-auto-pair');

  /// The currently-first row's own node — retargeted to whichever channel
  /// is actually first after every filter/search change (see [build]) so
  /// Down from the search field always has a real, live node to jump to.
  final _firstResultFocus = FocusNode(debugLabel: 'epg-matching-first-result');

  /// See `ChannelLinkingScreen._reviewFilter`'s doc comment — same idea,
  /// for this screen's own "Auto-Pair Channels".
  Set<String>? _reviewFilter;

  /// Handle both Up and Down explicitly to escape EditableText and reach the controls above
  /// or channel list below.
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

  Future<void> _autoPair(PlaylistManager playlist, EpgService epg) async {
    if (epg.channelCatalog.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(tr('Auto-Pair Channels')),
          content: Text(tr(
              'No EPG feed has been loaded yet this session — run "Update EPG Now" first so there\'s a channel directory to match against.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('OK'))),
          ],
        ),
      );
      return;
    }
    final result = await runAutoPairFlow(context,
        autoPair: () => playlist.autoPairEpgIds(epg));
    if (!mounted) return;
    setState(() => _reviewFilter = result.review ? result.paired : null);
  }

  Future<void> _unpair(PlaylistManager playlist) async {
    final didUnpair = await confirmAndUnpair(context,
        autoPairedCount: playlist.autoPairedEpgOverrideCount,
        unpair: playlist.unpairAutoEpgOverrides);
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
    final epg = context.watch<EpgService>();
    // Live TV only, and already excludes hidden channels — the same list
    // the sidebar itself shows, so nothing turns up here the user can't
    // otherwise see and wouldn't recognize.
    final channels = playlist.visibleChannels(category: 'tv');
    final query = _searchController.text.trim().toLowerCase();
    final reviewFilter = _reviewFilter;
    final filtered = (query.isEmpty
            ? channels
            : channels.where((c) => c.name.toLowerCase().contains(query)))
        .where((c) => reviewFilter == null || reviewFilter.contains(c.id))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  focusNode: _autoPairFocus,
                  icon: const Icon(Icons.auto_fix_high),
                  label: Text(tr('Auto-Pair Channels')),
                  onPressed: () => _autoPair(playlist, epg),
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
        if (epg.channelCatalog.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              tr('No EPG feed has been loaded yet this session — run "Update EPG Now" above first so there\'s a channel directory to search.'),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text(tr('No channels found.')))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final channel = filtered[i];
                    final overrideId = channel.epgIdOverride;
                    final hasPrograms = epg.hasPrograms(channel.epgId);
                    final String status;
                    final bool ok;
                    if (overrideId != null) {
                      status = tr('Assigned: {p}',
                          {'p': epg.channelCatalog[overrideId] ?? overrideId});
                      ok = true;
                    } else if (hasPrograms) {
                      status = tr('Matched automatically');
                      ok = true;
                    } else {
                      status = tr('No program data');
                      ok = false;
                    }
                    return ListTile(
                      focusNode: i == 0 ? _firstResultFocus : null,
                      title: Text(channel.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(status,
                          style: TextStyle(
                              color: ok
                                  ? null
                                  : Theme.of(context).colorScheme.error)),
                      trailing: overrideId != null
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              tooltip: tr('Clear assignment'),
                              onPressed: () =>
                                  playlist.setEpgIdOverride(channel, null),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: () async {
                        final picked = await Navigator.of(context).push<String>(
                            MaterialPageRoute(
                                builder: (_) => _AssignEpgScreen(
                                    channelName: channel.name)));
                        if (picked != null) {
                          await playlist.setEpgIdOverride(channel, picked);
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

/// Searches [EpgService.channelCatalog] — the loaded feed's own directory
/// of `<channel id>` -> display name — and pops the picked id back to
/// [EpgChannelMatchingScreen]. [channelName] is shown for context only
/// (the search starts empty rather than prefilled with it: this app's
/// own branded channel names, e.g. "4K| ESPN UHD", routinely share no
/// substring at all with a feed's plain "ESPN", so prefilling would often
/// show zero results by default instead of actually helping).
class _AssignEpgScreen extends StatefulWidget {
  const _AssignEpgScreen({required this.channelName});
  final String channelName;

  @override
  State<_AssignEpgScreen> createState() => _AssignEpgScreenState();
}

class _AssignEpgScreenState extends State<_AssignEpgScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final query = _searchController.text.trim().toLowerCase();
    final entries = epg.channelCatalog.entries
        .where((e) => query.isEmpty || e.value.toLowerCase().contains(query))
        .toList()
      // A candidate with something airing right now is far more likely
      // to be the actual right pick than one the feed has no current
      // data for at all — surfaced first, alphabetical within each group.
      ..sort((a, b) {
        final aHas = epg.currentProgramInCatalog(a.key) != null;
        final bHas = epg.currentProgramInCatalog(b.key) != null;
        if (aHas != bHas) return aHas ? -1 : 1;
        return a.value.compareTo(b.value);
      });

    return SettingsScaffold(
      title: tr('Assign "{channelName}"', {'channelName': widget.channelName}),
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
                    labelText: tr('Search the EPG feed\'s channels'),
                    hintText: widget.channelName,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
          ),
          Expanded(
            child: epg.channelCatalog.isEmpty
                // Distinguish an unloaded in-memory guide directory from a completed search
                // with no matches.
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      tr('No EPG feed has been loaded yet this app session — go back and run "Update EPG Now" first.'),
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  )
                : entries.isEmpty
                    ? Center(child: Text(tr('No matches.')))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final entry = entries[i];
                          final nowPlaying =
                              epg.currentProgramInCatalog(entry.key);
                          return ListTile(
                            title: Text(entry.value),
                            // Show the current programme to help distinguish guide entries
                            // with similar names.
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(entry.key,
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 11)),
                                Text(
                                  nowPlaying != null
                                      ? tr('Now: {title}',
                                          {'title': nowPlaying.title})
                                      : tr('No current program data'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontStyle: nowPlaying == null
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                      color: nowPlaying == null
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                          : null),
                                ),
                              ],
                            ),
                            isThreeLine: true,
                            onTap: () => Navigator.of(context).pop(entry.key),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
