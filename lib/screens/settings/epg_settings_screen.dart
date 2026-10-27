import '../../utils/guide_enrichment.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../utils/time_format.dart';
import '../../utils/constants.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/settings_section.dart';
import '../../l10n/l10n.dart';

class EpgSettingsScreen extends StatefulWidget {
  const EpgSettingsScreen({super.key});

  @override
  State<EpgSettingsScreen> createState() => _EpgSettingsScreenState();
}

class _EpgSettingsScreenState extends State<EpgSettingsScreen> {
  late int _refreshInterval =
      context.read<StorageService>().getRefreshInterval();

  List<EpgSource> _sources() => context.read<PlaylistManager>().epgSources();

  late final Set<String> _selected =
      context.read<PlaylistManager>().supplementaryGuideSelection();

  Future<void> _selectSource(String id, bool enabled) async {
    setState(() => enabled ? _selected.add(id) : _selected.remove(id));
    await context
        .read<StorageService>()
        .setSupplementaryGuideSelection(_selected);
  }

  Future<void> _applyInterval(int minutes) async {
    setState(() => _refreshInterval = minutes);
    final storage = context.read<StorageService>();
    await storage.setRefreshInterval(minutes);
    if (mounted) {
      final playlist = context.read<PlaylistManager>();
      context.read<EpgService>().startAutoRefresh(minutes, playlist.epgSources);
    }
  }

  Future<void> _updateNow() async {
    final sources = _sources();
    if (sources.isEmpty && _selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                tr('Add a guide URL to your playlist to download listings.'))),
      );
      return;
    }
    await context.read<EpgService>().refreshAll();
  }

  Future<void> _clearGuide() async {
    final clear = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text(tr('Clear guide listings?')),
              content: Text(tr(
                  'Downloaded programme listings will be removed. Your playlists, favourites and saved guide assignments stay saved.')),
              actions: [
                TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: Text(tr('Cancel'))),
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: Text(tr('Clear listings'))),
              ],
            ));
    if (clear != true || !mounted) return;
    await context.read<EpgService>().clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
            'Guide listings cleared. Use Refresh guide to download them again.'))));
  }

  Widget _sourceTile(String id, String name, String source, bool busy) =>
      Semantics(
          checked: _selected.contains(id),
          child: TvMenuTile(
            icon: Icons.public,
            title: name,
            subtitle: source,
            enabled: !busy,
            trailing: ExcludeFocus(
                child: IgnorePointer(
                    child: Checkbox(
              value: _selected.contains(id),
              onChanged: busy ? null : (_) {},
            ))),
            onTap: () => _selectSource(id, !_selected.contains(id)),
          ));

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();

    final updates = SettingsSection(title: tr('Guide updates'), children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<int>(
              initialValue: _refreshInterval,
              decoration:
                  InputDecoration(labelText: tr('Refresh automatically')),
              items: AppConstants.refreshIntervalOptions
                  .map((m) => DropdownMenuItem(
                      value: m,
                      child: Text(tr('Every {p} hours', {'p': m ~/ 60}))))
                  .toList(),
              onChanged: epg.isLoading
                  ? null
                  : (value) {
                      if (value != null) {
                        _applyInterval(value);
                      }
                    },
            ),
            const SizedBox(height: 12),
            Text(
                epg.lastUpdated == null
                    ? tr('No listings downloaded yet')
                    : tr('Updated {p}',
                        {'p': TimeFormat.dateTime(epg.lastUpdated!)}),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(epg.isLoading
                    ? (epg.refreshStatus ?? tr('Refreshing listings…'))
                    : tr('Refresh guide')),
                onPressed: epg.isLoading ? null : _updateNow),
          ])),
    ]);
    final gaps = SettingsSection(title: tr('Fill missing listings'), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Text(
            tr('Selected public guides run after each playlist guide update. Only missing listings are filled; your working guides and manual links stay intact.'),
            style: Theme.of(context).textTheme.bodySmall),
      ),
      for (final source in guideEnrichmentSources)
        _sourceTile(
            source.country, source.label, 'iptv-epg.org', epg.isLoading),
      _sourceTile('th', 'Thailand', 'Public XMLTV guide', epg.isLoading),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Text(
            tr('Updates only request guides with matching channels. Turning a source off stops future updates and keeps downloaded listings until they expire.'),
            style: Theme.of(context).textTheme.bodySmall),
      ),
    ]);
    final maintenance = SettingsSection(title: tr('Storage'), children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            OutlinedButton.icon(
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                onPressed: epg.isLoading ? null : _clearGuide,
                label: Text(tr('Clear guide listings'))),
            const SizedBox(height: 8),
            Text(tr('Removes downloaded programme listings only. Refresh the guide to download them again.'),
                style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ])),
    ]);
    final errors = [
      if (epg.error != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
                tr('Some listings could not be updated. Existing guide data has been kept.'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)))
    ];
    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
              title: tr('TV guide'),
              body: LayoutBuilder(
                  builder: (context, constraints) => ListView(
                        padding: const EdgeInsets.all(16),
                        children: constraints.maxWidth >= 760
                            ? [
                                Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                            updates,
                                            ...errors,
                                            maintenance
                                          ])),
                                      const SizedBox(width: 16),
                                      Expanded(child: gaps),
                                    ])
                              ]
                            : [updates, gaps, ...errors, maintenance],
                      )),
            ));
  }
}
