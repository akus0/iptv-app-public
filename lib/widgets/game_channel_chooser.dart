import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../services/multiview_sports.dart';
import '../services/sports_channel_matcher.dart';
import '../services/storage_service.dart';
import 'tv_menu_tile.dart';

/// The channel for a live game in the Multiview picker: the only match at
/// once, else a list of every channel found (with why it matched) to pick
/// from — the first suggestion isn't always the right feed. The choice is
/// remembered as the game's pick ([MultiviewSports.rememberPick]). Null =
/// cancelled.
Future<Channel?> chooseGameChannel(
    BuildContext context, LiveGameChannel live) async {
  final storage = context.read<StorageService>();
  Channel? picked;
  if (live.matches.length == 1) {
    picked = live.channel;
  } else {
    picked = await showDialog<Channel>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: interfaceColor(context, const Color(0xFF1A1A1A)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Text(live.game.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: interfaceColor(context, Colors.white),
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(tr('Pick a channel'),
                    style: TextStyle(color: interfaceColor(context, Colors.white54))),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: live.matches.length,
                  itemBuilder: (_, i) {
                    final m = live.matches[i];
                    return TvMenuTile(
                      autofocus: i == 0,
                      icon: m.reason == MatchReason.pick
                          ? Icons.star
                          : Icons.live_tv,
                      title: m.channel.name,
                      subtitle: m.detail == null
                          ? m.reason.label
                          : '${m.reason.label} · ${m.detail}',
                      trailing: const SizedBox.shrink(),
                      onTap: () => Navigator.of(ctx).pop(m.channel),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  if (picked != null) {
    await MultiviewSports.rememberPick(storage, live.game, picked);
  }
  return picked;
}
