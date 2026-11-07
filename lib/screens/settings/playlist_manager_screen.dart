import '../../widgets/playlist_content_picker.dart';
import '../../utils/interface_colors.dart';
import '../../widgets/playlist_organisation_picker.dart';
import '../../widgets/settings_section.dart';
import '../catalog_sync_screen.dart';
import 'epg_settings_screen.dart';
import 'package:flutter/material.dart';
import '../../widgets/playlist_user_agent_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/playlist_profile.dart';
import '../../services/playback_service.dart';
import '../../services/playlist_manager.dart';
import '../../utils/time_format.dart';
import '../../utils/constants.dart';
import '../../widgets/mode_button.dart';
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

    return withSettingsTheme(
        context,
        (context) => SettingsScaffold(
              title: tr('Playlists & guide'),
              body: ListView(
                padding: const EdgeInsets.all(12),
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
                        title: tr('Add playlist'),
                        onTap: () => Navigator.of(context).push(SettingsRoute(
                            builder: (_) => const AddPlaylistScreen())),
                      ),
                      if (profiles.where((p) => p.enabled).length >= 2) ...[
                        TvMenuTile(
                          icon: Icons.low_priority,
                          title: tr('Playlist order'),
                          subtitle: tr('Choose which playlist appears first'),
                          onTap: () => Navigator.of(context).push(SettingsRoute(
                              builder: (_) => const PlaylistPriorityScreen())),
                        ),
                      ],
                      for (var i = 0; i < profiles.length; i++) ...[
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
      icon: profile.hasCatalog ? Icons.dns : Icons.link,
      title: profile.name,
      subtitle: profile.isStalker
          ? 'Stalker / MAC'
          : profile.isXtream
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
        SettingsRoute(
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
    final confirmed = await showSettingsDialog<bool>(
      context: context,
      useRootNavigator: false,
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
    final entered = await showSettingsDialog<String>(
      context: context,
      useRootNavigator: false,
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

  Future<void> _showConnectionDetails(PlaylistProfile profile) =>
      showSettingsDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Connection details'),
                scrollable: true,
                titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                content: SizedBox(
                    width: 420,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (profile.isStalker) ...[
                            _DetailRow(
                                label: 'Portal',
                                value: profile.portalUrl ?? ''),
                            _DetailRow(
                                label: 'MAC', value: profile.portalMac ?? ''),
                          ] else if (profile.isXtream) ...[
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
                                value: profile.m3uUrl ?? ''),
                          _DetailRow(
                              label: tr('Added'),
                              value: TimeFormat.dateTime(profile.createdAt)),
                        ])),
                actions: [
                  TextButton(
                      autofocus: true,
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ],
              ));

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

    return withSettingsTheme(
        context,
        (context) => SettingsScaffold(
              title: profile.name,
              actions: [
                TvAppBarButton.icon(
                  icon: Icons.edit_outlined,
                  tooltip: tr('Edit login'),
                  onTap: () => Navigator.of(context).push(
                    SettingsRoute(
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
              body: ListView(padding: const EdgeInsets.all(12), children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                    child: Text(
                        [
                          profile.isStalker
                              ? 'Stalker / MAC'
                              : profile.isXtream
                                  ? 'Xtream Codes'
                                  : 'M3U',
                          if (summary != null)
                            tr('{p} live channels', {'p': summary['tv']}),
                          if (lastLoaded != null)
                            tr('Updated {p}',
                                {'p': TimeFormat.dateTime(lastLoaded)}),
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall)),
                SettingsSection(title: tr('Content'), children: [
                  TvSwitchListTile(
                      title: Text(tr('Playlist enabled')),
                      value: profile.enabled,
                      onChanged: (value) {
                        playlist.setPlaylistEnabled(profile.id, value);
                        if (!value) context.read<PlaybackService>().stop();
                      }),
                  if (profile.hasCatalog)
                    TvMenuTile(
                        icon: Icons.video_library_outlined,
                        title: 'Content from this playlist',
                        subtitle: [
                          if (profile.includeLive) 'Live TV',
                          if (profile.includeMovies) 'Movies',
                          if (profile.includeSeries) 'Series'
                        ].join(' · '),
                        onTap: () => choosePlaylistContent(context, profile)),
                  TvMenuTile(
                      icon: Icons.visibility_outlined,
                      title: tr('Manage categories'),
                      onTap: () => Navigator.of(context).push(SettingsRoute(
                          builder: (_) =>
                              GroupManagementScreen(playlistId: profile.id)))),
                  TvMenuTile(
                      icon: Icons.visibility_off_outlined,
                      title: tr('Hidden channels'),
                      onTap: () => Navigator.of(context).push(SettingsRoute(
                          builder: (_) =>
                              HiddenChannelsScreen(playlistId: profile.id)))),
                  Padding(
                      padding: const EdgeInsets.all(10),
                      child: PlaylistOrganisationPicker(
                          value: playlist.categoryLayoutFor(profile.id),
                          showDescription: false,
                          onChanged: playlist.isLoading
                              ? null
                              : (v) =>
                                  playlist.setCategoryLayout(profile.id, v))),
                ]),
                SettingsSection(title: tr('Updates'), children: [
                  _RefreshPlaylistsTile(playlistId: profile.id),
                  if (profile.hasCatalog)
                    Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              DropdownButtonFormField<int>(
                                  initialValue: profile.syncFrequencyDays,
                                  decoration: InputDecoration(
                                      labelText: tr('Update reminder'),
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
                              const SizedBox(height: 6),
                              Text(
                                  tr('Prompts at startup when an update is due.'),
                                  style: Theme.of(context).textTheme.bodySmall),
                            ])),
                ]),
                SettingsSection(title: tr('Connection'), children: [
                  TvMenuTile(
                    key: const ValueKey('playlist-user-agent'),
                    icon: Icons.tune,
                    title: 'User agent',
                    subtitle: profile.userAgent.isEmpty
                        ? 'Default · optional provider setting'
                        : profile.userAgent,
                    onTap: () async {
                      final value = await choosePlaylistUserAgent(
                          context, profile.userAgent);
                      if (!context.mounted ||
                          value == null ||
                          value == profile.userAgent) {
                        return;
                      }
                      try {
                        await playlist.setPlaylistUserAgent(profile.id, value);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                'User agent saved. Applies to new requests; reopen a playing channel to use it.')));
                      } catch (_) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                'Could not save the user agent. Please retry.')));
                      }
                    },
                  ),
                  TvMenuTile(
                      icon: Icons.info_outline,
                      title: 'Connection details',
                      subtitle: profile.expiresAt == null
                          ? null
                          : tr('Expires {p}', {
                              'p': DateFormat('yyyy-MM-dd')
                                  .format(profile.expiresAt!)
                            }),
                      onTap: () => _showConnectionDetails(profile)),
                  if (profile.isXtream) ...[
                    for (final backup in profile.backupServers)
                      Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: _BackupServerRow(
                              server: backup,
                              isLastWorking:
                                  profile.lastWorkingServer == backup,
                              onRemove: () async {
                                await playlist.removeBackupServer(
                                    profile.id, backup);
                                if (mounted) setState(() {});
                              })),
                    TvMenuTile(
                        icon: Icons.dns_outlined,
                        title: tr('Add backup server'),
                        subtitle:
                            tr('Alternative address for the same account'),
                        onTap: () => _promptForBackupServer(context, playlist)),
                  ],
                ]),
              ]),
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
  const _RefreshPlaylistsTile({this.playlistId});
  final String? playlistId;
  @override
  State<_RefreshPlaylistsTile> createState() => _RefreshPlaylistsTileState();
}

class _RefreshPlaylistsTileState extends State<_RefreshPlaylistsTile> {
  bool _busy = false, _opening = false;
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final playlist = context.read<PlaylistManager>();
    if (_opening || _busy || playlist.isLoading) return;
    final hadFocus = _focus.hasFocus;
    var blockingUpdate = false;
    _opening = true;
    final selected = playlist.profiles
        .where((p) =>
            p.enabled &&
            (widget.playlistId == null || p.id == widget.playlistId))
        .toList();
    try {
      if (selected.any((p) => p.hasCatalog)) {
        if (!await confirmAndRunFullCatalogSync(context, playlist,
            playlistId: widget.playlistId, onStarted: () {
          blockingUpdate = true;
          if (mounted) setState(() => _busy = true);
        })) {
          return;
        }
      }
      if (mounted) setState(() => _busy = true);
      for (final profile in selected.where((p) => !p.hasCatalog)) {
        await playlist.loadPlaylist(profile.id);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text((widget.playlistId == null
                        ? playlist.anyPlaylistError
                        : playlist.error) ==
                    null
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
      _opening = false;
      if (mounted) {
        setState(() => _busy = false);
        // The disabled action loses focus while the blocking progress route
        // is open. Restore it after it is enabled again, including failures.
        if (hadFocus && blockingUpdate) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                ModalRoute.of(context)?.isCurrent == true &&
                _focus.canRequestFocus) {
              _focus.requestFocus();
            }
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    return TvMenuTile(
        focusNode: _focus,
        icon: Icons.sync,
        title: tr(_busy
            ? 'Updating playlists…'
            : widget.playlistId == null
                ? 'Refresh playlists'
                : 'Refresh playlist'),
        subtitle: tr(widget.playlistId == null
            ? 'Check for new channels in your enabled playlists'
            : 'Check this playlist for new content'),
        enabled: !_busy &&
            !playlist.isLoading &&
            playlist.profiles.any((p) =>
                p.enabled &&
                (widget.playlistId == null || p.id == widget.playlistId)),
        onTap: _refresh);
  }
}
