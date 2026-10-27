import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../services/addon_service.dart';
import '../services/storage_service.dart';
import '../services/subtitle_tracks.dart';
import 'tv_menu_tile.dart';

/// Subtitles on Windows (`DesktopPlayerScreen`'s media_kit `Player`) — the
/// same choices as the Android player's Subtitles button
/// (player_controls.dart `_SubtitleButton`): Off, the file's own text
/// tracks, languages picked online before, and "Search online subtitles"
/// from the user's add-ons (Settings > Add-ons). media_kit's `Video` draws
/// the text itself, so there is no overlay here; a downloaded file is
/// handed to mpv as data. The per-series memory is the Android one
/// ([SubtitleTracks.rememberForSeries]); [applyForSeries] reapplies it.
class DesktopSubtitles {
  /// Title given to a downloaded subtitle loaded as data, so its copy in
  /// mpv's track list can be told apart from the file's own tracks.
  static const _onlinePrefix = 'vesper-online:';

  /// Image subtitles (Blu-ray/DVD/DVB) — `Video`'s text view can't draw
  /// them, so they're left out like on Android.
  static const _imageCodecs = {
    'hdmv_pgs_subtitle',
    'pgssub',
    'dvd_subtitle',
    'dvdsub',
    'dvb_subtitle',
    'dvbsub',
  };

  static String langLabel(String lang) =>
      languageName(lang).isEmpty ? lang : languageName(lang);

  /// The file's own text tracks (no auto/off entries, no downloaded copy).
  static List<mk.SubtitleTrack> embedded(mk.Player player) => [
        for (final t in player.state.tracks.subtitle)
          if (t.id != 'auto' &&
              t.id != 'no' &&
              !t.data &&
              !t.uri &&
              !(t.title?.startsWith(_onlinePrefix) ?? false) &&
              !_imageCodecs.contains(t.codec?.toLowerCase()))
            t,
      ];

  /// The language of the downloaded subtitle showing now, or null.
  static String? onlineLang(mk.Player player) {
    final t = player.state.track.subtitle;
    final title = t.title ?? '';
    return (t.data || t.uri) && title.startsWith(_onlinePrefix)
        ? title.substring(_onlinePrefix.length)
        : null;
  }

  static Future<void> useOnline(mk.Player player, String text, String lang) =>
      player.setSubtitleTrack(mk.SubtitleTrack.data(text,
          title: '$_onlinePrefix$lang', language: lang));

  /// Same as `SubtitleTracks.applyForSeries`, for this player: a new
  /// episode gets the series' remembered subtitles (same language + label
  /// for a track of the file, first add-on match for online). Quiet when
  /// nothing matches.
  static Future<void> applyForSeries(
      StorageService storage, Channel channel, mk.Player player) async {
    final choice = SubtitleTracks.seriesChoiceFor(storage, channel);
    if (choice == null) return;
    final lang = choice['lang'] as String?;
    if (choice['kind'] == 'online') {
      final addons = AddonService(storage);
      if (lang == null || !addons.anyEnabled) return;
      final match = (await addons.search(channel))
          .where((s) => s.lang == lang)
          .firstOrNull;
      if (match == null) return;
      await useOnline(player, await AddonService.download(match), lang);
      return;
    }
    // A track of the file: the list exists once the file's header is read.
    for (var i = 0; i < 6; i++) {
      final tracks = embedded(player);
      if (tracks.isNotEmpty) {
        final label = choice['label'] as String?;
        final sameLang = tracks.where((t) => t.language == lang);
        final pick = sameLang.where((t) => t.title == label).firstOrNull ??
            sameLang.firstOrNull;
        if (pick != null) await player.setSubtitleTrack(pick);
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

/// The Windows player bar's Subtitles button. Hidden while the file has no
/// text track and no online search is possible (live channels, no add-on).
class DesktopSubtitleButton extends StatefulWidget {
  const DesktopSubtitleButton(
      {super.key, required this.player, required this.channel});

  final mk.Player player;
  final Channel channel;

  @override
  State<DesktopSubtitleButton> createState() => _DesktopSubtitleButtonState();
}

class _DesktopSubtitleButtonState extends State<DesktopSubtitleButton> {
  StreamSubscription<mk.Tracks>? _tracksSub;

  mk.Player get _player => widget.player;

  AddonService get _addons => AddonService(context.read<StorageService>());

  bool get _canSearchOnline =>
      AddonService.supports(widget.channel) && _addons.anyEnabled;

  @override
  void initState() {
    super.initState();
    // The track list fills once the file's header is read.
    _tracksSub = _player.stream.tracks.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tracksSub?.cancel();
    super.dispose();
  }

  String _trackLabel(mk.SubtitleTrack t, int i) {
    final label = t.title?.trim() ?? '';
    final name = languageName(t.language);
    return label.isNotEmpty
        ? label
        : name.isNotEmpty
            ? name
            : tr('Track {id}', {'id': i + 1});
  }

  Widget _option(BuildContext sheetContext,
      {required bool selected,
      required String title,
      String? subtitle,
      IconData? icon,
      required Object result}) {
    return TvMenuTile(
      autofocus: selected,
      leading: Icon(
        icon ?? (selected ? Icons.check_circle : Icons.circle_outlined),
        color: selected ? Colors.amber : Colors.white54,
      ),
      title: title,
      subtitle: subtitle,
      onTap: () => Navigator.of(sheetContext).pop(result),
    );
  }

  Future<T?> _sheet<T>(
      String title, List<Widget> Function(BuildContext) items) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.8),
          // Not a lazy ListView: autofocus on the selected language (often
          // far down a 30-track list) needs its tile built.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                ),
                ...items(sheetContext),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPicker() async {
    final tracks = DesktopSubtitles.embedded(_player);
    final online = _canSearchOnline;
    final current = _player.state.track.subtitle;
    final onlineLang = DesktopSubtitles.onlineLang(_player);
    final selectedTrack = onlineLang != null
        ? null
        : tracks.where((t) => t.id == current.id).firstOrNull;
    final anySelected = onlineLang != null || selectedTrack != null;
    final remembered = online
        ? context.read<StorageService>().getOnlineSubtitleLangs()
        : const <String>[];
    // 'off', 'keep', 'online', (lang:), or an mk.SubtitleTrack.
    final chosen = await _sheet<Object>(
      tr('Subtitles'),
      (sheet) => [
        _option(sheet, selected: !anySelected, title: tr('Off'), result: 'off'),
        if (onlineLang != null)
          _option(sheet,
              selected: true,
              title: DesktopSubtitles.langLabel(onlineLang),
              subtitle: tr('Online'),
              result: 'keep'),
        for (final (i, t) in tracks.indexed)
          _option(sheet,
              selected: t == selectedTrack,
              title: _trackLabel(t, i),
              result: t),
        if (online)
          for (final lang in remembered)
            if (lang != onlineLang)
              _option(sheet,
                  selected: false,
                  icon: Icons.cloud_outlined,
                  title: DesktopSubtitles.langLabel(lang),
                  subtitle: tr('Online'),
                  result: (lang: lang)),
        if (online)
          _option(sheet,
              selected: false,
              icon: Icons.cloud_download_outlined,
              title: tr('Search online subtitles'),
              subtitle: tr('From your add-ons (Settings > Add-ons)'),
              result: 'online'),
      ],
    );
    if (chosen == null || chosen == 'keep' || !mounted) return;
    if (chosen == 'online') return _searchOnline();
    if (chosen is ({String lang})) return _applyOnlineLang(chosen.lang);
    final track = chosen is mk.SubtitleTrack ? chosen : null;
    // An episode: the choice carries on to the rest of the series; Off
    // forgets it.
    unawaited(SubtitleTracks.rememberForSeries(
        context.read<StorageService>(), widget.channel,
        kind: track == null ? null : 'embedded',
        lang: track?.language,
        label: track?.title));
    await _player.setSubtitleTrack(track ?? mk.SubtitleTrack.no());
    if (mounted) setState(() {});
  }

  Future<void> _searchOnline() async {
    final messenger = ScaffoldMessenger.of(context);
    final results = _addons.search(widget.channel);
    final chosen = await _sheet<OnlineSubtitle>(
      tr('Online subtitles'),
      (sheet) => [
        FutureBuilder<List<OnlineSubtitle>>(
          future: results,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final list = snap.data ?? const <OnlineSubtitle>[];
            if (list.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(tr('No subtitles found for this title.'),
                    style: const TextStyle(color: Colors.white70)),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < list.length; i++)
                  TvMenuTile(
                    autofocus: i == 0,
                    icon: Icons.subtitles_outlined,
                    title: DesktopSubtitles.langLabel(list[i].lang),
                    subtitle: [list[i].addonName, list[i].fileName ?? '']
                        .where((x) => x.isNotEmpty)
                        .join(' · '),
                    onTap: () => Navigator.of(sheet).pop(list[i]),
                  ),
              ],
            );
          },
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    await _applyOnline(chosen, messenger);
  }

  Future<void> _applyOnline(
      OnlineSubtitle chosen, ScaffoldMessengerState messenger) async {
    final storage = context.read<StorageService>();
    try {
      final text = await AddonService.download(chosen);
      await DesktopSubtitles.useOnline(_player, text, chosen.lang);
      await storage.addOnlineSubtitleLang(chosen.lang);
      await SubtitleTracks.rememberForSeries(storage, widget.channel,
          kind: 'online', lang: chosen.lang);
    } catch (_) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Couldn\'t download that subtitle. Try another.'))));
    }
    if (mounted) setState(() {});
  }

  /// A remembered language: the first match for this title, else the full
  /// online list to pick from.
  Future<void> _applyOnlineLang(String lang) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(tr('Looking for {language} subtitles…',
            {'language': DesktopSubtitles.langLabel(lang)}))));
    final results = await _addons.search(widget.channel);
    if (!mounted) return;
    final match = results.where((s) => s.lang == lang).firstOrNull;
    if (match == null) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('No {language} subtitles online for this title.',
              {'language': DesktopSubtitles.langLabel(lang)}))));
      return _searchOnline();
    }
    await _applyOnline(match, messenger);
  }

  @override
  Widget build(BuildContext context) {
    if (DesktopSubtitles.embedded(_player).isEmpty && !_canSearchOnline) {
      return const SizedBox.shrink();
    }
    final on = _player.state.track.subtitle.id != 'no' &&
        _player.state.track.subtitle.id != 'auto';
    return IconButton(
      icon: Icon(on ? Icons.subtitles : Icons.subtitles_outlined,
          color: Colors.white),
      tooltip: tr('Subtitles'),
      onPressed: _openPicker,
    );
  }
}
