import '../../utils/guide_enrichment.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/epg_service.dart';
import '../../models/epg_source_status.dart';
import '../../utils/thai_epg.dart';
import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../models/custom_guide_source.dart';
import '../../widgets/custom_guide_editor.dart';
import '../../utils/time_format.dart';
import '../../utils/constants.dart';
import '../../widgets/tv_menu_tile.dart';
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

  Future<void> _editCustom([CustomGuideSource? source]) =>
      showSettingsDialog<void>(
          context: context,
          useRootNavigator: false,
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
            content:
                Text('Could not save guide selection. Please try again.')));
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
    final clear = await showSettingsDialog<bool>(
        context: context,
        useRootNavigator: false,
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

  String _statusLabel(EpgSourceStatus? status) {
    if (status == null) return tr('Not checked this session');
    final time = TimeFormat.dateTime(status.at);
    return switch (status.state) {
      EpgSourceState.updating => tr('Updating…'),
      EpgSourceState.updated => tr('{n} listings imported · {p}', {
          'n': MaterialLocalizations.of(context)
              .formatDecimal(status.programmes ?? 0),
          'p': time
        }),
      EpgSourceState.cached =>
        tr('Using cached listings · checked {p}', {'p': time}),
      EpgSourceState.empty => tr('No listings returned · {p}', {'p': time}),
      EpgSourceState.failed => status.httpStatus == null
          ? tr('Update failed · {p}', {'p': time})
          : tr('Update failed (HTTP {n}) · {p}',
              {'n': status.httpStatus!, 'p': time}),
    };
  }

  Widget _sourceTile(String id, String name, String source, bool busy) =>
      Semantics(
          checked: _selected.contains(id),
          child: TvMenuTile(
            icon: Icons.public,
            title: name,
            subtitle: _selected.contains(id) ? source : null,
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
    return ListenableBuilder(
      listenable: epg.sourceStatusRevision,
      builder: (context, _) => _buildSettings(context, epg),
    );
  }

  Widget _buildSettings(BuildContext context, EpgService epg) {
    final busy = epg.isLoading || _savingSources;
    // Read profile metadata only; epgSources() would scan the catalogue in build.
    final profiles = context.read<PlaylistManager>().profiles.where((p) =>
        p.enabled &&
        p.includeLive &&
        ((p.epgUrl?.isNotEmpty ?? false) || p.isStalker));
    final sourceStatuses =
        SettingsSection(title: tr('Playlist guides'), children: [
      for (final profile in profiles)
        Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
                _statusLabel(epg.sourceStatus(
                    (profile.epgUrl?.isNotEmpty ?? false)
                        ? profile.epgUrl!
                        : 'stalker:${profile.id}')),
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
    ]);

    final interval = DropdownButtonFormField<int>(
      initialValue: _refreshInterval,
      isExpanded: true,
      decoration: InputDecoration(labelText: tr('Refresh automatically')),
      items: AppConstants.refreshIntervalOptions
          .map((m) => DropdownMenuItem(
              value: m, child: Text(tr('Every {p} hours', {'p': m ~/ 60}))))
          .toList(),
      onChanged: busy
          ? null
          : (value) {
              if (value != null) _applyInterval(value);
            },
    );
    final refresh = OutlinedButton.icon(
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(tr('Refresh guide')),
        onPressed: busy ? null : _updateNow);
    final updates = SettingsSection(title: tr('Guide updates'), children: [
      Padding(
          padding: const EdgeInsets.all(10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LayoutBuilder(
                builder: (context, constraints) =>
                    constraints.maxWidth >= 390 &&
                            MediaQuery.textScalerOf(context).scale(13) <= 16
                        ? Row(children: [
                            Expanded(child: interval),
                            const SizedBox(width: 10),
                            refresh
                          ])
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                interval,
                                const SizedBox(height: 6),
                                refresh
                              ])),
            const SizedBox(height: 6),
            Text(
                epg.isLoading
                    ? (epg.refreshStatus ?? tr('Refreshing listings…'))
                    : epg.lastUpdated == null
                        ? tr('No listings downloaded yet')
                        : tr('Updated {p}',
                            {'p': TimeFormat.dateTime(epg.lastUpdated!)}),
                style: Theme.of(context).textTheme.bodySmall),
          ])),
    ]);
    final gaps = SettingsSection(title: tr('Fill missing listings'), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Text(
            tr('Extra guides fill gaps after playlist updates. Existing listings and manual links stay unchanged.'),
            style: Theme.of(context).textTheme.bodySmall),
      ),
      for (final source in guideEnrichmentSources)
        _sourceTile(
            source.country,
            source.label,
            _selected.contains(source.country)
                ? _statusLabel(epg.sourceStatus(source.url))
                : 'iptv-epg.org',
            busy),
      _sourceTile(
          'th',
          'Thailand',
          _selected.contains('th')
              ? _statusLabel(epg.sourceStatus(thaiEpgSourceUrl))
              : 'Public XMLTV guide',
          busy),
    ]);
    final customGuides =
        SettingsSection(title: tr('Your XMLTV guides'), children: [
      for (final source in _custom)
        Semantics(
            checked: source.enabled,
            child: TvMenuTile(
                key: ValueKey('custom-guide-${source.id}'),
                icon: Icons.description_outlined,
                title: source.name,
                subtitle: source.enabled
                    ? _statusLabel(epg.sourceStatus(source.sourceUrl))
                    : tr('Updates disabled'),
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
          child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                  key: const ValueKey('add-custom-guide'),
                  onPressed: busy ? null : _editCustom,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add XMLTV guide')))),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Text(
            tr('Updates run in the background. Turning a guide off keeps its listings until they expire.'),
            style: Theme.of(context).textTheme.bodySmall),
      ),
    ]);
    final maintenance = SettingsSection(title: tr('Storage'), children: [
      TvMenuTile(
          icon: Icons.cleaning_services_outlined,
          title: tr('Clear guide listings'),
          subtitle: tr(
              'Remove downloaded listings. Playlists and saved links stay saved.'),
          enabled: !busy,
          onTap: _clearGuide),
    ]);
    final errors = [
      if (epg.error != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
                tr('Some listings could not be updated. Existing guide data has been kept.'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)))
    ];
    return withSettingsTheme(
        context,
        (context) => SettingsScaffold(
              title: tr('TV guide'),
              body: LayoutBuilder(
                  builder: (context, constraints) => ListView(
                        padding: const EdgeInsets.all(12),
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
                                            if (profiles.isNotEmpty)
                                              sourceStatuses,
                                            ...errors,
                                            maintenance
                                          ])),
                                      const SizedBox(width: 16),
                                      Expanded(
                                          child: Column(
                                              children: [gaps, customGuides])),
                                    ])
                              ]
                            : [
                                updates,
                                if (profiles.isNotEmpty) sourceStatuses,
                                gaps,
                                customGuides,
                                ...errors,
                                maintenance
                              ],
                      )),
            ));
  }
}
