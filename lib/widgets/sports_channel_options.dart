import '../utils/guarded_dialog.dart';
import 'sports_header_controls.dart';
import 'package:flutter/material.dart';
import '../models/sports_channel_filters.dart';
import '../utils/sports_channel_browser.dart';
import 'sports_filter_picker.dart';

class SportsChannelOptionsDialog extends StatefulWidget {
  const SportsChannelOptionsDialog(
      {super.key,
      required this.initial,
      required this.choices,
      required this.playlistNames});
  final SportsChannelFilters initial;
  final Future<({List<String> regions, List<String> playlists})> choices;
  final Map<String, String> playlistNames;
  @override
  State<SportsChannelOptionsDialog> createState() =>
      _SportsChannelOptionsDialogState();
}

class _SportsChannelOptionsDialogState
    extends State<SportsChannelOptionsDialog> {
  final _scroll = ScrollController();
  late var _draft = widget.initial;
  List<String> _regions = const [], _playlists = const [];
  bool _pending = true, _choosing = false;
  String _playlistLabel(String id) =>
      widget.playlistNames[id] ??
      (_playlists.contains(id)
          ? 'Playlist ${_playlists.indexOf(id) + 1}'
          : 'Unavailable playlist');
  @override
  void initState() {
    super.initState();
    widget.choices.then((value) {
      if (mounted) {
        setState(() {
          _regions = value.regions;
          _playlists = value.playlists;
          _pending = false;
        });
      }
    });
  }

  Future<void> _choose({required bool country}) async {
    if (_choosing || _pending) return;
    _choosing = true;
    try {
      final values = country ? _regions : _playlists;
      final value = await showSportsFilterPicker(context,
          title: country ? 'Country / region' : 'Choose playlist',
          showSortingControls: false,
          selected: (country ? _draft.region : _draft.playlist) ?? '',
          options: [
            SportsFilterOption(
                '',
                country ? 'All countries / regions' : 'All playlists',
                Icons.all_inclusive),
            for (final id in values)
              SportsFilterOption(
                  id,
                  country
                      ? SportsChannelBrowser.regionLabel(id)
                      : _playlistLabel(id),
                  country ? Icons.public : Icons.playlist_play),
          ]);
      if (mounted && value != null) {
        setState(() {
          _draft = country
              ? _draft.copyWith(region: value, clearRegion: value.isEmpty)
              : _draft.copyWith(playlist: value, clearPlaylist: value.isEmpty);
        });
      }
    } finally {
      _choosing = false;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariant)));
    final height = sportsOptionHeight(context);
    return SportsCompactDialog(
        title: 'Sort & filter channels',
        closeTooltip: 'Cancel filters',
        scrollController: _scroll,
        actions: [
          Expanded(
              child: TextButton(
                  style: sportsPopupButtonStyle(context),
                  onPressed: () =>
                      popRouteIfCurrent(context, const SportsChannelFilters()),
                  child: const Text('Reset all', textAlign: TextAlign.center))),
          const SizedBox(width: 8),
          Expanded(
              child: FilledButton(
                  key: const ValueKey('channel-filters-done'),
                  style: sportsPopupButtonStyle(context),
                  onPressed: () => popRouteIfCurrent(context, _draft),
                  child: const Text('Show channels',
                      textAlign: TextAlign.center))),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          label('Order'),
          Wrap(spacing: 5, runSpacing: 5, children: [
            for (final sort in SportsChannelSort.values)
              SportsOptionButton(
                  key: ValueKey('channel-sort-${sort.name}'),
                  autofocus: widget.initial.sort == sort,
                  label: channelSortLabel(sort),
                  selected: _draft.sort == sort,
                  onPressed: () =>
                      setState(() => _draft = _draft.copyWith(sort: sort))),
          ]),
          const SizedBox(height: 12),
          label('Match evidence'),
          Wrap(spacing: 5, runSpacing: 5, children: [
            for (final evidence in SportsChannelEvidence.values)
              SportsOptionButton(
                  key: ValueKey('channel-evidence-${evidence.name}'),
                  label: channelEvidenceLabel(evidence),
                  selected: _draft.evidence == evidence,
                  onPressed: () => setState(
                      () => _draft = _draft.copyWith(evidence: evidence))),
          ]),
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                  switch (_draft.evidence) {
                    SportsChannelEvidence.all =>
                      'Related channels may be showing other events.',
                    SportsChannelEvidence.specific =>
                      'The guide or channel name identifies this event.',
                    SportsChannelEvidence.likely =>
                      'Includes listed broadcasters. Check the programme before watching.',
                  },
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.3,
                      color: colors.onSurfaceVariant))),
          SportsFilterButton(
              key: const ValueKey('channel-country-filter'),
              minimumHeight: height,
              caption: 'Country / region',
              value: _pending
                  ? 'Loading…'
                  : _draft.region == null
                      ? 'All countries / regions'
                      : SportsChannelBrowser.regionLabel(_draft.region!),
              selected: _draft.region != null,
              onTap: () => _choose(country: true)),
          if (_pending) const LinearProgressIndicator(minHeight: 2),
          if (_pending || _playlists.length > 1 || _draft.playlist != null) ...[
            const SizedBox(height: 6),
            SportsFilterButton(
                key: const ValueKey('channel-playlist-filter'),
                minimumHeight: height,
                caption: 'Playlist',
                value: _pending
                    ? 'Loading…'
                    : _draft.playlist == null
                        ? 'All playlists'
                        : _playlistLabel(_draft.playlist!),
                selected: _draft.playlist != null,
                onTap: () => _choose(country: false)),
          ],
          const SizedBox(height: 10),
          SportsOptionButton(
              key: const ValueKey('channel-untried-filter'),
              label: "Hide channels I've tried",
              tooltip: 'For this event',
              icon: _draft.untriedOnly
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              selected: _draft.untriedOnly,
              onPressed: () => setState(() =>
                  _draft = _draft.copyWith(untriedOnly: !_draft.untriedOnly))),
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'Regions follow playlist labels. Unlabelled or conflicting entries stay unspecified.',
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.3,
                      color: colors.onSurfaceVariant))),
        ]));
  }
}
