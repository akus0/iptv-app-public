import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../services/epg_service.dart';

/// Only cached now/next data, never a database query or playlist scan.
String channelNowText(EpgService epg, Channel channel) {
  final programme = epg.getCurrentProgram(channel.epgId);
  final now = DateTime.now();
  if (programme == null ||
      programme.start.isAfter(now) ||
      !programme.stop.isAfter(now)) {
    return 'No current programme data';
  }
  final time = DateFormat.Hm();
  return '${time.format(programme.start.toLocal())}–${time.format(programme.stop.toLocal())} · ${programme.title}';
}

class ChannelNowLabel extends StatelessWidget {
  const ChannelNowLabel(
      {super.key, required this.channel, this.fontSize = 10.5});
  final Channel channel;
  final double fontSize;
  @override
  Widget build(BuildContext context) => Selector<EpgService, String>(
        selector: (_, epg) => channelNowText(epg, channel),
        builder: (_, text, __) => Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: fontSize, height: 1.2, color: interfaceColor(context, Colors.white60))),
      );
}
