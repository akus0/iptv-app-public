import '../../utils/guide_enrichment.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../models/custom_guide_source.dart';
import '../../widgets/custom_guide_editor.dart';
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
  late List<CustomGuideSource> _custom =
      context.read<StorageService>().getCustomGuideSources();
  bool _savingSources = false;

  Future<void> _storeCustom(List<CustomGuideSource> sources) async {
    await context.read<StorageService>().setCustomGuideSources(sources);
    if (mounted) setState(() => _custom = sources);
  }

  Future<void> _editCustom([CustomGuideSource? source]) => showDialog<void>(
      context: context,
      builder: (_) => CustomGuideEditor(
          source: source,
          existing: _custom,
          onSave: (updated) => _storeCustom([
                for (final item in _custom)
                  item.id == source?.id ? updated : item,
                if (source == null) updated,
              ]),
          onRemove: () async {
            if (source != null) {
              await context
                  .read<PlaylistManager>()
                  .removeAutomaticGuideSource(source.prefix);
            }
            await _storeCustom(
                _custom.where((item) => item.id != source?.id).toList());
          }));

  Future<void> _toggleCustom(CustomGuideSource source) async {
    if (_savingSources) return;
    setState(() => _savingSources = true);
    try {
      await _storeCustom([
        for (final item in _custom)
          item.id == source.id ? item.withEnabled(!item.enabled) : item
      ]);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not save guide selection. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _savingSources = false);
    }
  }

  Future<void> _selectSource(String id, bool enabled) async {
    if (_savingSources) return;
    final next = Set<String>.of(_selected);
    enabled ? next.add(id) : next.remove(id);
    setState(() => _savingSources = true);
    try {
      await context.read<StorageService>().setSupplementaryGuideSelection(next);
      if (mounted) {
        setState(() {
          _selected.clear();
          _selected.addAll(next);
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save guide selection. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _savingSources = false);
    }
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
    if (sources.isEmpty &&
        _selected.isEmpty &&
        !_custom.any((s) => s.enabled) &&
        context.read<PlaylistManager>().portalGuideSources().isEmpty) {
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
    final busy = epg.isLoading || _savingSources;

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
              onChanged: busy
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
                onPressed: busy ? null : _updateNow),
          ])),
    ]);
    final gaps = SettingsSection(title: tr('Fill missing listings'), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Text(
            tr('Selected extra guides run after each playlist guide update. Only missing listings are filled; your working guides and manual links stay intact.'),
            style: Theme.of(context).textTheme.bodySmall),
      ),
      for (final source in guideEnrichmentSources)
        _sourceTile(source.country, source.label, 'iptv-epg.org', busy),
      _sourceTile('th', 'Thailand', 'Public XMLTV guide', busy),
      const Divider(height: 16),
      const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('Your XMLTV guides',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
      for (final source in _custom)
        Semantics(
            checked: source.enabled,
            child: TvMenuTile(
                key: ValueKey('custom-guide-${source.id}'),
                icon: Icons.description_outlined,
                title: source.name,
                subtitle: Uri.parse(source.url).host,
                enabled: !busy,
                onTap: () => _toggleCustom(source),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  ExcludeFocus(
                      child: IgnorePointer(
                          child: Checkbox(
                              value: source.enabled, onChanged: (_) {}))),
                  IconButton(
                      tooltip: 'Edit ${source.name}',
                      onPressed: busy ? null : () => _editCustom(source),
                      icon: const Icon(Icons.edit_outlined, size: 18)),
                ]))),
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: OutlinedButton.icon(
              key: const ValueKey('add-custom-guide'),
              onPressed: busy ? null : _editCustom,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add XMLTV guide'))),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Text(
            tr('Guide downloads run in the background and retain relevant listings only. Turning a source off stops future updates and keeps downloaded listings until they expire.'),
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
                onPressed: busy ? null : _clearGuide,
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
