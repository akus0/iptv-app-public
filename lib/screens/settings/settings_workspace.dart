import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/channel.dart';
import '../../services/playback_service.dart';
import '../../widgets/player_controls.dart';
import '../../widgets/preview_player_controls.dart';
import '../../widgets/settings_navigation.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/sports_hub_layout.dart';
import '../../widgets/sports_widgets.dart';
import '../player_screen.dart';
import 'settings_menu_screen.dart';

/// One player presentation for the whole settings stack. Page changes only
/// replace the right pane; they never create another playback controller.
class SettingsWorkspace extends StatefulWidget {
  const SettingsWorkspace({super.key});
  @override
  State<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends State<SettingsWorkspace> {
  final _navigator = GlobalKey<NavigatorState>();
  late final Widget _pages = NavigatorPopHandler<Object?>(
    onPopWithResult: (_) => _navigator.currentState?.maybePop(),
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (_) => SettingsRoute<void>(
          builder: (_) => const SettingsMenuScreen(includeTools: true)),
    ),
  );
  void _exit(SettingsAction? action) => Navigator.of(context).pop(action);

  @override
  Widget build(BuildContext context) => SettingsNavigation(
      onExit: _exit,
      child: SportsScreenFrame(
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(child: LayoutBuilder(builder: (context, box) {
            final beside = sportsLandscape(context) && box.maxWidth >= 700;
            final channel = context
                .select<PlaybackService, Channel?>((p) => p.currentChannel);
            final live = channel != null && Channel.isLiveId(channel.rawId);
            final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
            final previewWidth =
                beside ? sportsPreviewWidth(box.maxWidth - 40) : box.maxWidth;
            final previewHeight = beside
                ? box.maxHeight
                : live
                    ? (keyboard ? 64.0 : 126.0)
                    : 0.0;
            // A stable Flex keeps the nested Navigator and the player mounted
            // when a phone rotates or the keyboard changes the available area.
            return Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: beside ? 20 : 0, vertical: beside ? 6 : 0),
              child: Flex(
                direction: beside ? Axis.horizontal : Axis.vertical,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    key: const ValueKey('settings-preview-column'),
                    width: beside ? previewWidth : null,
                    height: beside ? null : previewHeight,
                    child: ClipRect(
                        child: RepaintBoundary(
                            child: _SettingsPreview(
                                channel: live ? channel : null,
                                beside: beside))),
                  ),
                  SizedBox(width: beside ? 12 : 0, height: 0),
                  Expanded(child:
                      ClipRect(child: LayoutBuilder(builder: (context, pane) {
                    final media = MediaQuery.of(context);
                    return MediaQuery(
                      data: media.copyWith(
                          size: Size(pane.maxWidth, pane.maxHeight),
                          padding: EdgeInsets.zero,
                          viewPadding: EdgeInsets.zero),
                      child: _pages,
                    );
                  }))),
                ],
              ),
            );
          })),
        ),
      ));
}

class _SettingsPreview extends StatelessWidget {
  const _SettingsPreview({required this.channel, required this.beside});
  final Channel? channel;
  final bool beside;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = channel;
    final video = RepaintBoundary(
        child: PreviewPlayerControls(
      active: current != null,
      onFullscreen: current == null
          ? null
          : () => PlayerScreen.open(Navigator.of(context), current),
      child: ColoredBox(
          color: Colors.black,
          child: current == null
              ? const Center(
                  child: Icon(Icons.live_tv_outlined,
                      size: 28, color: Colors.white38))
              : VideoPlayerPane(
                  key: ValueKey(current.id),
                  showEpgBar: false,
                  showControls: false)),
    ));
    return Padding(
      padding:
          beside ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: LayoutBuilder(
          builder: (context, box) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                      height: beside ? 38 : 0,
                      child: ClipRect(
                          child: Align(
                        alignment: Alignment.centerLeft,
                        child: current == null
                            ? Text('CHANNEL PREVIEW',
                                style: TextStyle(
                                    fontSize: 11,
                                    letterSpacing: .5,
                                    color: scheme.onSurfaceVariant))
                            : Row(children: [
                                Text('NOW PLAYING',
                                    style: TextStyle(
                                        fontSize: 9,
                                        letterSpacing: .5,
                                        color: scheme.onSurfaceVariant)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text(current.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: scheme.onSurface))),
                              ]),
                      ))),
                  SizedBox(
                      height: beside ? box.maxWidth * 9 / 16 : box.maxHeight,
                      child: video),
                  if (beside && current == null)
                    Expanded(
                        child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                          'Select a channel in Live TV or Sports to keep watching here.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: scheme.onSurfaceVariant)),
                    )),
                ],
              )),
    );
  }
}
