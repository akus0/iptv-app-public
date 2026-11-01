import '../../widgets/playlist_content_picker.dart';
import '../../utils/interface_colors.dart';
import '../../widgets/playlist_organisation_picker.dart';
import '../../widgets/settings_section.dart';
import '../catalog_sync_screen.dart';
import 'epg_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/playlist_profile.dart';
import '../../services/playback_service.dart';
import '../../services/playlist_manager.dart';
import '../../utils/time_format.dart';
import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_panel.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_app_bar_button.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../widgets/tv_switch_list_tile.dart';
import 'add_playlist_screen.dart';
import 'group_management_screen.dart';
import 'hidden_channels_screen.dart';
import 'playlist_priority_screen.dart';
import '../../l10n/l10n.dart';

/// Playlist list with enablement, content counts, login settings and sync cadence. Each
/// playlist opens a separate detail screen with a responsive settings layout.
class PlaylistManagerScreen extends StatelessWidget {
  const PlaylistManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final profiles = playlist.profiles;

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: tr('Playlists & guide'),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SettingsSection(title: tr('Programme listings'), children: [
                    TvMenuTile(
                        icon: Icons.calendar_month_outlined,
                        title: tr('TV guide'),
                        subtitle: tr(
                            'Update schedule and supplementary guide sources'),
                        onTap: () => Navigator.of(context).push(SettingsRoute(
                            builder: (_) => const EpgSettingsScreen()))),
                    const _RefreshPlaylistsTile(),
                  ]),
                  SettingsSection(
                    title: tr('Your playlists'),
                    children: [
                      TvMenuTile(
                        icon: Icons.add,
                        title: tr('Add Playlist'),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AddPlaylistScreen())),
                      ),
                      if (profiles.where((p) => p.enabled).length >= 2) ...[
                        const Divider(height: 1),
                        TvMenuTile(
                          icon: Icons.low_priority,
                          title: tr('Playlist order'),
                          subtitle: tr('Choose which playlist appears first'),
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const PlaylistPriorityScreen())),
                        ),
                      ],
                      if (profiles.isNotEmpty) const Divider(height: 1),
                      for (var i = 0; i < profiles.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _PlaylistRow(profile: profiles[i]),
                      ],
                    ],
                  ),
                  if (profiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        tr('No playlists yet — tap "Add Playlist" above to get started.'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ));
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.profile});

  final PlaylistProfile profile;

  @override
  Widget build(BuildContext context) {
    return TvMenuTile(
      icon: profile.isXtream ? Icons.dns : Icons.link,
      title: profile.name,
      subtitle: profile.isXtream
          ? [
              if (profile.includeLive) 'Live TV',
              if (profile.includeMovies) 'Movies',
              if (profile.includeSeries) 'Series'
            ].join(' · ')
          : 'M3U · Live TV',
      trailing: Icon(
        profile.enabled ? Icons.check_circle : Icons.pause_circle_outline,
        color: profile.enabled
            ? interfaceColor(context, Colors.greenAccent)
            : interfaceColor(context, Colors.white38),
        size: 20,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) => _PlaylistDetailScreen(playlistId: profile.id)),
      ),
    );
  }
}

class _PlaylistDetailScreen extends StatefulWidget {
  const _PlaylistDetailScreen({required this.playlistId});

  final String playlistId;

  @override
  State<_PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<_PlaylistDetailScreen> {
  Future<void> _confirmDelete(
      PlaylistManager playlist, PlaylistProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete playlist?')),
        content: Text(
          tr('This removes "{name}"\'s login and cached catalog from this device. Its favourite channels stay in your shared Favorites list, but will no longer play unless you add this playlist back.',
              {'name': profile.name}),
        ),
        // Plain TextButton/FilledButton left which one has D-pad focus
        // ambiguous — FilledButton's permanent solid fill looks the same
        // whether it's actually focused or not. ModeButton is this app's
        // established fix elsewhere for exactly this.
        actions: [
          ModeButton(
            label: tr('Cancel'),
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: tr('Delete'),
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await playlist.removePlaylist(profile.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _promptForBackupServer(
      BuildContext context, PlaylistManager playlist) async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Add backup server')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('The full address, exactly like the main one — for example http://backup.example.com:8080'),
            ),
            const SizedBox(height: 12),
            FocusNodeOwner(
              builder: (context, node) => TvTextFieldGate(
                focusNode: node,
                builder: (context, readOnly) => TextField(
                  controller: controller,
                  focusNode: node,
                  readOnly: readOnly,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: tr('Server address'),
                    hintText: 'http://',
                  ),
                  onSubmitted: (value) => Navigator.of(context).pop(value),
                ),
              ),
            ),
          ],
        ),
        // Same ModeButton reasoning as _confirmDelete above.
        actions: [
          ModeButton(
            label: tr('Cancel'),
            selected: false,
            onTap: () => Navigator.of(context).pop(),
          ),
          ModeButton(
            label: tr('Add'),
            selected: false,
            onTap: () => Navigator.of(context).pop(controller.text),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null || entered.trim().isEmpty) return;
    await playlist.addBackupServer(widget.playlistId, entered);
    // Refresh after the dialog closes; a manager notification during route teardown may not
    // repaint this screen.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    PlaylistProfile? found;
    for (final p in playlist.profiles) {
      if (p.id == widget.playlistId) {
        found = p;
        break;
      }
    }
    if (found == null) {
      // Deleted out from under this screen (e.g. via a race with another
      // route) — nothing left to show, pop back rather than crash on a
      // null profile.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }
    // A separate, genuinely final binding — `found` above is reassigned
    // inside the loop, so Dart won't promote its type across the
    // null-check for the rest of this method.
    final profile = found;

    final summary = playlist.summaryFor(profile.id);
    final lastLoaded = playlist.lastLoadedFor(profile.id);

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: profile.name,
              actions: [
                TvAppBarButton.icon(
                  icon: Icons.edit_outlined,
                  tooltip: tr('Edit login'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            AddPlaylistScreen(editPlaylistId: profile.id)),
                  ),
                ),
                TvAppBarButton.icon(
                  icon: Icons.delete_outline,
                  tooltip: tr('Delete playlist'),
                  onTap: () => _confirmDelete(playlist, profile),
                ),
              ],
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _SettingsColumns(children: [
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionLabel(tr('This Playlist')),
                        const SizedBox(height: 8),
                        SettingsPanel(padding: EdgeInsets.zero, children: [
                          TvSwitchListTile(
                              title: Text(tr('Playlist enabled')),
                              subtitle: Text(tr(
                                  'Turn off to stop using this playlist. Channels and settings stay saved.')),
                              value: profile.enabled,
                              onChanged: (value) {
                                playlist.setPlaylistEnabled(profile.id, value);
                                if (!value) {
                                  context.read<PlaybackService>().stop();
                                }
                              })
                        ]),
                        if (profile.isXtream) ...[
                          const SizedBox(height: 12),
                          TvMenuTile(
                              icon: Icons.video_library_outlined,
                              title: 'Content from this playlist',
                              subtitle:
                                  'Live TV: ${profile.includeLive ? "On" : "Off"} · Movies: ${profile.includeMovies ? "On" : "Off"} · Series: ${profile.includeSeries ? "On" : "Off"}',
                              onTap: () =>
                                  choosePlaylistContent(context, profile)),
                        ],
                        const SizedBox(height: 20),
                        SectionLabel(tr('Connection')),
                        const SizedBox(height: 8),
                        SettingsPanel(children: [
                          if (profile.isXtream) ...[
                            _DetailRow(
                                label: tr('Server'),
                                value: profile.xtreamServer ?? ''),
                            _DetailRow(
                                label: tr('Username'),
                                value: profile.xtreamUsername ?? ''),
                            _DetailRow(
                                label: tr('Password'),
                                value: '•' *
                                    (profile.xtreamPassword?.length ?? 0)),
                            if (profile.expiresAt != null)
                              _DetailRow(
                                  label: tr('Expires'),
                                  value: DateFormat('yyyy-MM-dd')
                                      .format(profile.expiresAt!),
                                  valueColor: profile.expiresAt!
                                          .isBefore(DateTime.now())
                                      ? interfaceColor(
                                          context, Colors.redAccent)
                                      : null),
                            if (profile.maxConnections != null)
                              _DetailRow(
                                  label: tr('Max connections'),
                                  value: '${profile.maxConnections}')
                          ] else
                            _DetailRow(
                                label: tr('M3U URL'),
                                value: profile.m3uUrl ?? '')
                        ]),
                        if (profile.isXtream) ...[
                          const SizedBox(height: 20),
                          SectionLabel(tr('Backup Servers')),
                          const SizedBox(height: 8),
                          SettingsPanel(children: [
                            if (profile.backupServers.isEmpty)
                              Text(
                                  tr('None yet. If your provider gave you more than one server address for this same account, add them here and this playlist will try them in order whenever the main one can\'t be reached.'),
                                  style: Theme.of(context).textTheme.bodySmall)
                            else
                              for (final backup in profile.backupServers)
                                _BackupServerRow(
                                    server: backup,
                                    isLastWorking:
                                        profile.lastWorkingServer == backup,
                                    onRemove: () async {
                                      await playlist.removeBackupServer(
                                          profile.id, backup);
                                      if (mounted) setState(() {});
                                    }),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                                icon: const Icon(Icons.dns_outlined),
                                label: Text(tr('Add backup server')),
                                onPressed: () =>
                                    _promptForBackupServer(context, playlist)),
                            Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                    tr(
                                        'Same username and password as above — only the address differs. Tried in order, a few seconds apart, and whichever answers is used first next time.'),
                                    style:
                                        Theme.of(context).textTheme.bodySmall))
                          ])
                        ]
                      ]),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionLabel(tr('Channels')),
                        const SizedBox(height: 8),
                        SettingsPanel(children: [
                          if (summary == null)
                            Text(tr('Not loaded yet.'))
                          else
                            Text(tr('{p} live channels', {'p': summary['tv']})),
                          if (lastLoaded != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                    tr('Last updated: {p}',
                                        {'p': TimeFormat.dateTime(lastLoaded)}),
                                    style:
                                        Theme.of(context).textTheme.bodySmall)),
                          Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                  tr('Added: {p}', {
                                    'p': TimeFormat.dateTime(profile.createdAt)
                                  }),
                                  style:
                                      Theme.of(context).textTheme.bodySmall)),
                          const SizedBox(height: 16),
                          PlaylistOrganisationPicker(
                              value: playlist.categoryLayoutFor(profile.id),
                              onChanged: playlist.isLoading
                                  ? null
                                  : (v) => playlist.updatePlaylist(
                                      profile.copyWith(categoryLayout: v))),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                              icon: const Icon(Icons.visibility_outlined),
                              label: Text(tr('Group Management')),
                              onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => GroupManagementScreen(
                                          playlistId: profile.id)))),
                          Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: OutlinedButton.icon(
                                  icon:
                                      const Icon(Icons.visibility_off_outlined),
                                  label: Text(tr('Hidden Channels')),
                                  onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) => HiddenChannelsScreen(
                                              playlistId: profile.id))))),
                          Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                  tr('Hide a group here and it\'s excluded from the background download too, not just the browse tabs.'),
                                  style: Theme.of(context).textTheme.bodySmall))
                        ]),
                        if (profile.isXtream) ...[
                          const SizedBox(height: 20),
                          SectionLabel(tr('Channel updates')),
                          const SizedBox(height: 8),
                          SettingsPanel(children: [
                            DropdownButtonFormField<int>(
                                initialValue: profile.syncFrequencyDays,
                                decoration: InputDecoration(
                                    labelText: tr('Update content every'),
                                    border: const OutlineInputBorder()),
                                items: AppConstants.syncFrequencyDaysOptions
                                    .map((d) => DropdownMenuItem(
                                        value: d,
                                        child: Text(d == 1
                                            ? tr('1 day')
                                            : tr('{d} days', {'d': d}))))
                                    .toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    playlist.updatePlaylist(profile.copyWith(
                                        syncFrequencyDays: value));
                                  }
                                }),
                            Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                    tr(
                                        'A stale sync prompts "Update content now?" on launch instead of running automatically.'),
                                    style:
                                        Theme.of(context).textTheme.bodySmall))
                          ])
                        ]
                      ])
                ]),
              ),
            ));
  }
}

/// One configured backup server, with its own remove action. Marks the
/// one this playlist actually connected through last, so a list of
/// near-identical hostnames still tells you which is currently carrying
/// the account.
class _BackupServerRow extends StatelessWidget {
  const _BackupServerRow({
    required this.server,
    required this.isLastWorking,
    required this.onRemove,
  });

  final String server;
  final bool isLastWorking;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(server,
                      style: const TextStyle(fontFamily: 'monospace')),
                ),
                if (isLastWorking) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check_circle,
                      size: 16, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(tr('in use'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary)),
                ],
              ],
            ),
          ),
          TvAppBarButton.icon(
            icon: Icons.close,
            tooltip: tr('Remove {server}', {'server': server}),
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
              child: Text(value,
                  style:
                      TextStyle(fontFamily: 'monospace', color: valueColor))),
        ],
      ),
    );
  }
}

class _RefreshPlaylistsTile extends StatefulWidget {
  const _RefreshPlaylistsTile();
  @override
  State<_RefreshPlaylistsTile> createState() => _RefreshPlaylistsTileState();
}

class _RefreshPlaylistsTileState extends State<_RefreshPlaylistsTile> {
  bool _busy = false;
  Future<void> _refresh() async {
    final playlist = context.read<PlaylistManager>();
    if (_busy || playlist.isLoading) return;
    setState(() => _busy = true);
    try {
      if (playlist.profiles.any((p) => p.enabled && p.isXtream)) {
        if (!await confirmAndRunFullCatalogSync(context, playlist)) return;
      }
      for (final profile in playlist.profiles
          .where((p) => p.enabled && !p.isXtream)
          .toList()) {
        await playlist.loadPlaylist(profile.id);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(playlist.anyPlaylistError == null
                ? tr('Playlists updated')
                : tr(
                    'Some playlists could not be updated. Please try again.'))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(tr('Could not update playlists. Please try again.'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    return TvMenuTile(
        icon: Icons.sync,
        title: tr(_busy ? 'Updating playlists…' : 'Refresh playlists'),
        subtitle: tr('Check for new channels in your enabled playlists'),
        enabled: !_busy &&
            !playlist.isLoading &&
            playlist.profiles.any((p) => p.enabled),
        onTap: _refresh);
  }
}

class _SettingsColumns extends StatelessWidget {
  const _SettingsColumns({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                children.last,
                const SizedBox(height: 20),
                children.first,
              ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: children.last),
          const SizedBox(width: 16),
          Expanded(child: children.first),
        ]);
      });
}
