import '../utils/guarded_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../utils/playback_error_message.dart';
import '../services/playlist_manager.dart';
import '../services/addon_service.dart';
import '../services/storage_service.dart';
import '../services/subtitle_tracks.dart';
import 'player_dialog.dart';
import 'player_stream_info.dart';
import 'player_connection_status.dart';
import 'epg_guide.dart';
import 'player_chrome.dart';
import 'cached_channel_logo.dart';
import '../utils/time_format.dart';
import 'tv_menu_tile.dart';
import '../l10n/l10n.dart';

/// Renders whatever [PlaybackService] is currently playing.
///
/// Purely presentational — it doesn't own a controller or start playback
/// itself; call `context.read<PlaybackService>().play(channel)` to start
/// something, and every mounted [VideoPlayerPane] (inline pane, fullscreen
/// screen, mini-player) reflects the same live video.
class VideoPlayerPane extends StatelessWidget {
  const VideoPlayerPane(
      {super.key,
      this.showEpgBar = true,
      this.showControls = true,
      this.fillScreen = false,
      this.fullscreen = false,
      this.switchButtonFocusNode});

  /// Zoom the picture to cover the whole pane (edges cropped, no black
  /// bars) — an explicit Picture size choice in playback settings. Not clipped here: the pane
  /// is the whole screen there, the display edge does the cropping (a clip
  /// on a platform view costs weak boxes a lot).
  final bool fillScreen;

  /// Only one native view may present the shared controller during handoff.
  final bool fullscreen;

  final bool showEpgBar;

  /// [PlayerScreen] renders its own auto-hiding controls overlay (so the
  /// seek bar can't permanently steal D-pad focus) and just wants the bare
  /// video here — pass false there.
  final bool showControls;

  /// Expose the linked-channel button's focus node so the fullscreen player can navigate
  /// between explicit control zones. Inline previews can omit it.
  final FocusNode? switchButtonFocusNode;

  /// Sizes the video to fit the pane (black bars) or, with [fillScreen], to
  /// cover it. The same widgets either way, so toggling never recreates the
  /// platform view.
  Widget _fit(double ratio, Widget child) => LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final h = c.maxHeight;
          if (!w.isFinite || !h.isFinite || h == 0) return child;
          final paneWider = w / h > ratio;
          final size =
              paneWider != fillScreen ? Size(h * ratio, h) : Size(w, w / ratio);
          return OverflowBox(
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: SizedBox.fromSize(size: size, child: child),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackService>();
    // Unmount the covered preview surface before fullscreen presents this
    // controller. Recreate it at its actual preview bounds on return, avoiding
    // stale native fullscreen geometry and competing visibility callbacks.
    if (!fullscreen && playback.isFullscreenActive) {
      return const SizedBox.expand();
    }
    final channel = playback.currentChannel;
    final controller = playback.controller;

    if (channel == null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  playback.error == null
                      ? tr('Select a channel to start watching')
                      : playbackErrorMessage(playback.error!),
                  textAlign: TextAlign.center)));
    }
    final channelLink = context.read<PlaylistManager>().channelLinkFor(channel);
    final linkedChannel = channelLink == null
        ? null
        : context.read<PlaylistManager>().resolveChannelLink(channelLink);
    final status = PlayerConnectionStatus(
        switchFocusNode: switchButtonFocusNode,
        onSwitch:
            linkedChannel == null ? null : () => playback.play(linkedChannel));
    if (controller == null || playback.error != null) return status;

    return FutureBuilder<void>(
      future: playback.initFuture,
      builder: (context, snapshot) {
        if (!controller.value.isInitialized) {
          return status;
        }

        return Column(
          children: [
            // Use the guide ID, including any saved manual assignment.
            if (showEpgBar) EpgGuide(channelId: channel.epgId),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Keep the stream's aspect ratio inside the selected fit mode.
                  _fit(
                    controller.value.aspectRatio == 0
                        ? 16 / 9
                        : controller.value.aspectRatio,
                    AspectRatio(
                      aspectRatio: controller.value.aspectRatio == 0
                          ? 16 / 9
                          : controller.value.aspectRatio,
                      // Key the video surface to its controller instance so switching
                      // controllers cannot retain the previous platform view's frame.
                      child: VideoPlayerHdr(controller,
                          key: ObjectKey(controller)),
                    ),
                  ),
                  Positioned.fill(child: status),
                  if (showControls)
                    Positioned(
                        top: 0,
                        right: 4,
                        child: Builder(
                            builder: (context) => PlayerControls(
                                    controller: controller,
                                    title: channel.name,
                                    channelId: channel.epgId,
                                    channel: channel,
                                    isLive: Channel.isLiveId(channel.rawId))
                                .utilityActions(context))),
                  if (showControls)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: PlayerControls(
                        controller: controller,
                        title: channel.name,
                        // rawId, not the composite `id` — see
                        // PlaylistManager.knownChannelIdsFor's doc comment;
                        // Channel.isLiveId also documents that it expects
                        // rawId, not id.
                        channelId: channel.epgId,
                        isLive: Channel.isLiveId(channel.rawId),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Bottom-anchored playback controls: play/pause, seek bar, elapsed/total
/// duration. Rebuilds on every controller tick via [ValueListenableBuilder]
/// rather than manual `setState` calls. Fullscreen/immersive mode is a
/// screen-level concern (see [PlayerScreen]), not a control-bar one.
class PlayerControls extends StatelessWidget {
  const PlayerControls({
    super.key,
    required this.controller,
    required this.title,
    required this.channelId,
    required this.isLive,
    this.isFavorite,
    this.onToggleFavorite,
    this.onPrevious,
    this.onNext,
    this.onActivity,
    this.linkedChannel,
    this.channel,
    this.onOpenMultiview,
    this.playFocusNode,
    this.active = true,
    this.onOpenChannels,
    this.onExitFullscreen,
    this.onEnterPip,
    this.onRotate,
    this.onTogglePictureFit,
    this.pictureFill = false,
  });

  final VideoPlayerHdrController controller;
  final bool active;
  final VoidCallback? onOpenChannels;
  final VoidCallback? onExitFullscreen,
      onEnterPip,
      onRotate,
      onTogglePictureFit;
  final bool pictureFill;
  final String title;

  /// Which EPG programme to check remaining time against — only read
  /// when [isLive] is true.
  final String channelId;

  /// Live channels use a confirmed native seekable window for DVR; their
  /// reported duration alone must never enable seeking. VOD uses its duration.
  final bool isLive;

  /// Null hides the favorite button entirely (the shared inline preview
  /// panes don't pass these) — [PlayerScreen] is the one caller that does,
  /// so pressing Down to reveal these controls also surfaces "add to
  /// favorites" for whatever's playing.
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;

  /// Null hides the button entirely — a movie or live channel has no
  /// previous/next *episode* concept (see PlaybackService.previousUpChannel/
  /// nextUpChannel, both null in that case), and only [PlayerScreen] passes
  /// these at all, same as [onToggleFavorite] above.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// Notify on each seek tick so the parent can reset auto-hide during both taps and held
  /// seeking.
  final VoidCallback? onActivity;

  /// Optional manually linked channel for a deliberate failover action. Hide the button when
  /// no link exists; buffering alone does not trigger automatic switching.
  final Channel? linkedChannel;

  /// The live channel actually playing — only used to exclude it from its
  /// own Recall history below. Null hides that button entirely, same
  /// convention as [onToggleFavorite]/[linkedChannel] — the shared inline
  /// preview panes don't pass it.
  final Channel? channel;

  /// Opens Multiview with whatever's currently playing already loaded as
  /// the first cell — lives in the secondary row, gated on [isLive]
  /// (Multiview is live-TV only) at the call site, same as Recall/Reload.
  /// Null hides the button entirely, same convention as every other
  /// optional action here; kept as a callback rather than this widget
  /// importing `MultiviewScreen` itself and navigating directly, so this
  /// file stays navigation-agnostic — [PlayerScreen] owns the actual
  /// `Navigator.push`.
  final VoidCallback? onOpenMultiview;

  /// Play/Pause's node, so the caller can land the remote's focus on it
  /// when the bar opens (PlayerScreen._focusBottomBar).
  final FocusNode? playFocusNode;

  Widget utilityActions(BuildContext context, {FocusNode? infoFocusNode}) {
    void settings() {
      onActivity?.call();
      showPlayerSettings(context,
          controller: controller,
          channel: channel,
          linkedChannel: linkedChannel,
          onOpenMultiview: onOpenMultiview,
          onRotate: onRotate,
          pictureFill: pictureFill,
          onTogglePictureFit: onTogglePictureFit,
          isFavorite: isFavorite,
          onToggleFavorite: onToggleFavorite);
    }

    return PlayerUtilityActions(
      onMultiview: onOpenMultiview,
      infoFocusNode: infoFocusNode,
      compact: MediaQuery.sizeOf(context).width < 600,
      onRotate: onRotate,
      onSettings: settings,
      onInfo: () {
        onActivity?.call();
        showPlayerStreamInfo(context);
      },
      onReconnect: isLive
          ? () {
              onActivity?.call();
              context.read<PlaybackService>().reloadCurrentChannel();
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final programme = isLive
        ? context.watch<EpgService>().getCurrentProgram(channelId)
        : null;
    final next =
        isLive ? context.watch<EpgService>().getNextProgram(channelId) : null;

    return Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
              Color(0x00000000),
              Color(0x85000000),
              Color(0xB3000000)
            ],
                stops: [
              0,
              .28,
              1
            ])),
        padding: EdgeInsets.fromLTRB(narrow ? 10 : 20, 14, narrow ? 10 : 20, 2),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                if (channel?.logoUrl != null) ...[
                  SizedBox(
                      width: 26,
                      height: 26,
                      child: CachedChannelLogo(url: channel!.logoUrl)),
                  const SizedBox(width: 10),
                ],
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(children: [
                        if (isLive) ...[
                          const Icon(Icons.circle,
                              size: 6, color: Color(0xFFE68B8B)),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                            child: Text(title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: programme == null ? 14 : 10,
                                    color: programme == null
                                        ? Colors.white
                                        : playerMuted,
                                    fontWeight: FontWeight.w500))),
                      ]),
                      if (programme != null) ...[
                        const SizedBox(height: 3),
                        Text(programme.title,
                            maxLines: narrow ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: narrow ? 14 : 16,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                        const SizedBox(height: 4),
                        Text(
                            '${TimeFormat.hm.format(programme.start)}–${TimeFormat.hm.format(programme.stop)}'
                            '${next == null ? '' : '   ·   ${tr('Next')} ${next.title}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 10, color: playerMuted)),
                      ],
                    ])),
              ]),
              const SizedBox(height: 4),
              PlayerToolbar(
                controller: controller,
                isLive: isLive,
                active: active,
                compact: narrow,
                fullscreen: true,
                onFullscreen: onExitFullscreen,
                playFocusNode: playFocusNode,
                onActivity: onActivity,
                onPrevious: onPrevious,
                onNext: onNext,
                onOpenChannels: onOpenChannels,
                onEnterPip: onEnterPip,
              ),
            ]));
  }
}

/// Audio-track selector using the player's track metadata. Hide it when fewer than two tracks
/// are available.
class _AudioTrackButton extends StatefulWidget {
  const _AudioTrackButton({super.key, required this.controller});

  final VideoPlayerHdrController controller;

  @override
  State<_AudioTrackButton> createState() => _AudioTrackButtonState();
}

class _AudioTrackButtonState extends State<_AudioTrackButton> {
  List<VideoAudioTrack>? _tracks;
  Timer? _retry;
  int _tries = 0;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _loadTracks() async {
    if (!widget.controller.isAudioTrackSupportAvailable()) return;
    try {
      final tracks = await widget.controller.getAudioTracks();
      if (mounted) setState(() => _tracks = tracks);
      if (tracks.length >= 2) return;
    } catch (_) {
      // Not every stream/platform combination actually has track info
      // available even when the capability check passes — leave the
      // button hidden (_tracks stays null) rather than show a picker
      // that can't do anything.
    }
    // Retry track discovery while stream headers load; the first controls frame can arrive
    // before track metadata.
    if (!mounted || ++_tries > 5) return;
    _retry = Timer(const Duration(seconds: 3), _loadTracks);
  }

  String _trackLabel(VideoAudioTrack track) {
    final label = track.label;
    if (label != null && label.isNotEmpty) return label;
    final language = track.language;
    if (language != null && language.isNotEmpty && language != 'und') {
      return language.toUpperCase();
    }
    return tr('Track {id}', {'id': track.id});
  }

  Future<void> _openPicker() async {
    // Re-fetch right before showing rather than trusting the initState
    // snapshot — reflects the actual current selection (isSelected) even
    // if something else changed it since this button first loaded.
    List<VideoAudioTrack> tracks;
    try {
      tracks = await widget.controller.getAudioTracks();
    } catch (_) {
      return;
    }
    if (!mounted || tracks.length < 2) return;
    setState(() => _tracks = tracks);

    final chosen = await showPlayerChoices<VideoAudioTrack>(
        context,
        tr('Audio track'),
        (sheet) => [
              for (final track in tracks)
                PlayerSettingRow(
                    autofocus: track.isSelected,
                    selected: track.isSelected,
                    icon: Icons.multitrack_audio,
                    title: _trackLabel(track),
                    detail: [
                      if (track.language != null && track.language != 'und')
                        languageName(track.language),
                      if (track.channelCount != null)
                        '${track.channelCount} ${tr('channels')}'
                    ].join(' · '),
                    onTap: () => Navigator.pop(sheet, track)),
            ]);
    if (chosen != null && mounted) {
      try {
        await widget.controller.selectAudioTrack(chosen.id);
        if (mounted) await _loadTracks();
      } catch (_) {/* Player changed while choosing. */}
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _tracks;
    if (tracks == null || tracks.length < 2) return const SizedBox.shrink();
    final selected = tracks.where((t) => t.isSelected).firstOrNull;
    return PlayerSettingRow(
        icon: Icons.multitrack_audio,
        title: 'Audio track',
        detail: selected == null
            ? tr('Choose a language or commentary')
            : _trackLabel(selected),
        onTap: _openPicker);
  }
}

/// Embedded subtitle selector, hidden when no text tracks are available. PlayerScreen draws
/// selected cues through SubtitleTracks.
class _SubtitleButton extends StatefulWidget {
  const _SubtitleButton({super.key, required this.controller});

  final VideoPlayerHdrController controller;

  @override
  State<_SubtitleButton> createState() => _SubtitleButtonState();
}

class _SubtitleButtonState extends State<_SubtitleButton> {
  List<SubtitleTrack> _tracks = const [];
  Timer? _retry;
  int _tries = 0;

  int get _playerId => SubtitleTracks.playerIdOf(widget.controller);

  Channel? get _channel => context.read<PlaybackService>().currentChannel;

  AddonService get _addons => AddonService(context.read<StorageService>());

  /// Movies/episodes can get subtitles from an add-on (Settings > Add-ons).
  bool get _canSearchOnline {
    final c = _channel;
    return c != null && AddonService.supports(c) && _addons.anyEnabled;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  // The track list only exists once the file's header is read, which can
  // be after this button is built — retry a few times.
  Future<void> _load() async {
    try {
      final tracks = await SubtitleTracks.list(_playerId);
      if (!mounted) return;
      setState(() => _tracks = tracks);
      if (tracks.isNotEmpty) return;
    } catch (_) {
      // No player yet: stay hidden.
    }
    if (!mounted || ++_tries > 5) return;
    _retry = Timer(const Duration(seconds: 3), _load);
  }

  /// The file's own track name when it has one ("French (France) Full"),
  /// else the language; "Forced" added unless the name already says it
  /// (it read "Français · French (France) Forced · Forced").
  String _trackLabel(SubtitleTrack t) {
    if (t.closedCaptions) {
      return tr('Closed captions (CC) — if the channel broadcasts them');
    }
    final label = t.label?.trim() ?? '';
    final name = languageName(t.language);
    final base = label.isNotEmpty
        ? label
        : name.isNotEmpty
            ? name
            : tr('Track {id}', {'id': t.track + 1});
    return t.forced && !base.toLowerCase().contains('forced')
        ? '$base · ${tr('Forced')}'
        : base;
  }

  Widget _option(BuildContext sheetContext,
      {required bool selected,
      required String title,
      String? subtitle,
      IconData? icon,
      required Object result}) {
    return PlayerSettingRow(
        autofocus: selected,
        selected: selected,
        icon: icon ?? Icons.subtitles_outlined,
        title: title,
        detail: subtitle,
        onTap: () => Navigator.of(sheetContext).pop(result));
  }

  Future<T?> _sheet<T>(
          String title, List<Widget> Function(BuildContext) items) =>
      showPlayerChoices<T>(context, title, items);

  Future<void> _openPicker() async {
    final id = _playerId;
    var tracks = const <SubtitleTrack>[];
    try {
      tracks = await SubtitleTracks.list(id);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _tracks = tracks);
    final online = _canSearchOnline;
    if (tracks.isEmpty && !online) return;
    final external = SubtitleTracks.externalFor.value == id
        ? SubtitleTracks.externalLabel[id]
        : null;
    final anySelected = external != null || tracks.any((t) => t.selected);
    final remembered = online
        ? context.read<StorageService>().getOnlineSubtitleLangs()
        : const <String>[];
    // 'off', 'online', or a SubtitleTrack.
    final chosen = await _sheet<Object>(
      tr('Subtitles'),
      (sheet) => [
        _option(sheet, selected: !anySelected, title: tr('Off'), result: 'off'),
        if (external != null)
          _option(sheet,
              selected: true,
              title: external,
              subtitle: tr('Online'),
              result: 'keep'),
        for (final t in tracks)
          _option(sheet,
              selected: external == null && t.selected,
              title: _trackLabel(t),
              result: t),
        // Previously picked languages: the first match for this title.
        if (online)
          for (final lang in remembered)
            if (external != _langLabel(lang))
              _option(sheet,
                  selected: false,
                  icon: Icons.cloud_outlined,
                  title: _langLabel(lang),
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
    final track = chosen is SubtitleTrack ? chosen : null;
    // An episode: the choice carries on to the rest of the series; Off
    // forgets it (SubtitleTracks.rememberForSeries).
    unawaited(SubtitleTracks.rememberForSeries(
        context.read<StorageService>(), _channel,
        kind: track == null ? null : 'embedded',
        lang: track?.language,
        label: track?.label));
    try {
      await SubtitleTracks.clearExternal(widget.controller);
      await SubtitleTracks.select(id, track);
      if (mounted) await _load();
    } catch (_) {
      // The stream changed underneath: nothing to select any more.
    }
  }

  Future<void> _searchOnline() async {
    final channel = _channel;
    if (channel == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final results = _addons.search(channel);
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
                    title: languageName(list[i].lang).isEmpty
                        ? list[i].lang
                        : languageName(list[i].lang),
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

  static String _langLabel(String lang) =>
      languageName(lang).isEmpty ? lang : languageName(lang);

  Future<void> _applyOnline(
      OnlineSubtitle chosen, ScaffoldMessengerState messenger) async {
    final storage = context.read<StorageService>();
    try {
      final text = await AddonService.download(chosen);
      await SubtitleTracks.useExternal(widget.controller, text);
      SubtitleTracks.externalLabel[_playerId] = _langLabel(chosen.lang);
      await storage.addOnlineSubtitleLang(chosen.lang);
      await SubtitleTracks.rememberForSeries(storage, _channel,
          kind: 'online', lang: chosen.lang);
      if (mounted) setState(() {}); // Refresh the selected-language row.
    } catch (_) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Couldn\'t download that subtitle. Try another.'))));
    }
  }

  /// A remembered language: the first match for this title, else the full
  /// online list to pick from.
  Future<void> _applyOnlineLang(String lang) async {
    final channel = _channel;
    if (channel == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(tr('Looking for {language} subtitles…',
            {'language': _langLabel(lang)}))));
    final results = await _addons.search(channel);
    if (!mounted) return;
    final match = results.where((s) => s.lang == lang).firstOrNull;
    if (match == null) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('No {language} subtitles online for this title.',
              {'language': _langLabel(lang)}))));
      return _searchOnline();
    }
    await _applyOnline(match, messenger);
  }

  @override
  Widget build(BuildContext context) {
    if (_tracks.isEmpty && !_canSearchOnline) return const SizedBox.shrink();
    final selected = _tracks.where((t) => t.selected).firstOrNull;
    return PlayerSettingRow(
        icon: Icons.subtitles_outlined,
        title: 'Subtitles',
        detail: SubtitleTracks.externalFor.value == _playerId
            ? SubtitleTracks.externalLabel[_playerId]
            : selected == null
                ? tr('Off')
                : _trackLabel(selected),
        onTap: _openPicker);
  }
}

/// Manual one-press failover to a linked channel on another playlist —
/// see [PlayerControls.linkedChannel]'s doc comment. Always shown (not
/// conditional on anything actually being wrong right now), same
/// "there whether you need it or not" shape as the skip/next-episode
/// buttons either side of it. The bare swap icon means nothing on its
/// own — there's no established icon convention for "cross-playlist
/// failover" the way there is for play/pause or skip — so this was the
/// first button to get [_LabeledIconButton]'s on-focus label treatment;
/// every other situational button in the secondary row has it now too.
class _LinkedChannelButton extends StatelessWidget {
  const _LinkedChannelButton({required this.linkedChannel});

  final Channel linkedChannel;

  @override
  Widget build(BuildContext context) {
    final playlistName = context
        .watch<PlaylistManager>()
        .playlistNameFor(linkedChannel.playlistId);
    return PlayerSettingRow(
      icon: Icons.swap_horiz,
      title: tr('Switch to {playlistName}: {name}',
          {'playlistName': playlistName, 'name': linkedChannel.name}),
      onTap: () {
        final playback = context.read<PlaybackService>();
        Navigator.of(context).pop();
        unawaited(playback.play(linkedChannel));
      },
    );
  }
}

Future<void> showPlayerSettings(
  BuildContext context, {
  required VideoPlayerHdrController controller,
  Channel? channel,
  Channel? linkedChannel,
  VoidCallback? onOpenMultiview,
  VoidCallback? onRotate,
  VoidCallback? onTogglePictureFit,
  bool pictureFill = false,
  bool? isFavorite,
  VoidCallback? onToggleFavorite,
}) {
  var fill = pictureFill;
  var favourite = isFavorite == true;
  return showGuardedDialog<void>(
      context: context,
      barrierColor: const Color(0x40000000),
      builder: (dialog) => StatefulBuilder(
          builder: (context, update) => PlayerDialog(
              title: 'Playback settings',
              subtitle: channel?.name,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const PlayerSection('Sound'),
                    Container(
                        decoration: BoxDecoration(
                            color: const Color(0x801E2935),
                            borderRadius: BorderRadius.circular(4)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: PlayerVolume(
                            controller: controller, compact: true)),
                    const SizedBox(height: 6),
                    _AudioTrackButton(
                        key: ValueKey(('audio', controller)),
                        controller: controller),
                    _SubtitleButton(
                        key: ValueKey(('subtitles', controller)),
                        controller: controller),
                    if (onTogglePictureFit != null || onRotate != null)
                      const PlayerSection('Picture'),
                    if (onTogglePictureFit != null)
                      PlayerSettingRow(
                          key: const ValueKey('player-picture-size'),
                          icon: Icons.aspect_ratio_rounded,
                          title: 'Picture size',
                          detail: tr(fill
                              ? 'Zoom to fill · edges cropped'
                              : 'Fit · entire picture'),
                          onTap: () async {
                            final choice = await showPlayerChoices<bool>(
                                dialog,
                                tr('Picture size'),
                                (sheet) => [
                                      for (final zoom in [false, true])
                                        PlayerSettingRow(
                                            icon: zoom
                                                ? Icons.crop_rounded
                                                : Icons.fit_screen_rounded,
                                            selected: fill == zoom,
                                            autofocus: fill == zoom,
                                            title: zoom
                                                ? 'Zoom to fill'
                                                : 'Fit to screen',
                                            detail: tr(zoom
                                                ? 'Crops the edges to fill the screen'
                                                : 'Shows the entire picture without cropping'),
                                            onTap: () =>
                                                Navigator.pop(sheet, zoom)),
                                    ]);
                            if (!context.mounted ||
                                choice == null ||
                                choice == fill) {
                              return;
                            }
                            onTogglePictureFit();
                            update(() => fill = choice);
                          }),
                    if (onRotate != null)
                      PlayerSettingRow(
                          icon: Icons.screen_rotation_outlined,
                          title: 'Rotate',
                          detail: tr('Switch between portrait and landscape'),
                          onTap: () {
                            Navigator.pop(dialog);
                            onRotate();
                          }),
                    if (onToggleFavorite != null ||
                        linkedChannel != null ||
                        onOpenMultiview != null)
                      const PlayerSection('Watching'),
                    if (onToggleFavorite != null)
                      PlayerSettingRow(
                          icon: favourite
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          title: favourite
                              ? 'Remove from favourites'
                              : 'Add to favourites',
                          selected: favourite,
                          onTap: () {
                            onToggleFavorite();
                            update(() => favourite = !favourite);
                          }),
                    if (linkedChannel != null)
                      _LinkedChannelButton(linkedChannel: linkedChannel),
                    if (onOpenMultiview != null)
                      PlayerSettingRow(
                          icon: Icons.grid_view_outlined,
                          title: 'Multiview',
                          detail: tr('Watch multiple channels together'),
                          onTap: () {
                            Navigator.pop(dialog);
                            onOpenMultiview();
                          }),
                    const PlayerSection('Connection'),
                    PlayerSettingRow(
                        icon: Icons.info_outline_rounded,
                        title: 'Stream info',
                        detail:
                            tr('Connection, buffer, video and audio details'),
                        onTap: () => showPlayerStreamInfo(dialog)),
                    if (channel != null && Channel.isLiveId(channel.rawId))
                      PlayerSettingRow(
                          icon: Icons.refresh_rounded,
                          title: 'Reconnect',
                          detail: tr('Retry the current channel'),
                          onTap: () {
                            final playback = context.read<PlaybackService>();
                            Navigator.pop(dialog);
                            unawaited(playback.reloadCurrentChannel());
                          }),
                  ]))));
}

Future<T?> showPlayerChoices<T>(BuildContext context, String title,
        List<Widget> Function(BuildContext) items) =>
    showGuardedDialog<T>(
        context: context,
        barrierColor: const Color(0x40000000),
        builder: (dialog) => PlayerDialog(
            title: title,
            child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                    mainAxisSize: MainAxisSize.min, children: items(dialog)))));
