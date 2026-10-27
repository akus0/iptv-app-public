import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../screens/multiview_screen.dart';
import '../services/app_preferences.dart';
import '../services/playback_service.dart';

bool canOpenMultiview(BuildContext context) =>
    defaultTargetPlatform == TargetPlatform.android &&
    !context.read<AppPreferences>().hideMultiview;

/// The route owns release of the normal preview before opening grid players.
Future<void> openChannelInMultiview(
    BuildContext context, Channel channel) async {
  final playback = context.read<PlaybackService>();
  final current = playback.currentChannel;
  final keepCurrent = current != null &&
      current.id != channel.id &&
      Channel.isLiveId(current.rawId);
  final route = MaterialPageRoute<void>(
      builder: (_) => MultiviewScreen(
          initialChannel: keepCurrent ? current : channel,
          additionalChannel: keepCurrent ? channel : null));
  await Navigator.of(context).push(route);
  await route.completed;
  // Multiview has released every decoder/connection before this route returns.
  if (context.mounted && playback.currentChannel == null) {
    await playback.play(current ?? channel);
  }
}
