// Diagnostic entry point. Exports cached guide text, never stream URLs/accounts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:nox_iptv/main.dart' as app;
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.main();
  var attempts = 0;
  Timer.periodic(const Duration(seconds: 1), (timer) {
    if (++attempts > 90) timer.cancel();
    void visit(Element element) {
      if (element.widget is TvHomeScreen) {
        timer.cancel();
        unawaited(exportGuide(
            element.read<PlaylistManager>(), element.read<EpgService>()));
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  });
}

Future<void> exportGuide(PlaylistManager playlist, EpgService epg) async {
  await playlist.whenRestored;
  await epg.init();
  final now = DateTime.now();
  final channels = <String, List<Map<String, String>>>{};
  for (final c in playlist.visibleLiveChannels) {
    (channels[normalizeEpgId(c.epgId)] ??= [])
        .add({'name': c.name, 'group': c.group});
  }
  final rows = <Map<String, Object?>>[];
  for (final p in epg.cachedCurrentProgrammes(now)) {
    final mapped = channels[normalizeEpgId(p.channelId)];
    if (mapped == null) continue;
    rows.add({
      'channelId': p.channelId,
      'channels': mapped,
      'title': [
        {'text': p.title}
      ],
      'desc': [
        {'text': p.description ?? ''}
      ],
      'start': p.start.toIso8601String(),
      'stop': p.stop.toIso8601String(),
      if (p.isLive) 'live': true,
    });
  }
  final directory = (await getExternalStorageDirectory())!;
  await File('${directory.path}/replay-audit.json')
      .writeAsString(jsonEncode({'at': now.toIso8601String(), 'rows': rows}));
  // ignore: avoid_print
  print('IPTV_REPLAY_AUDIT exported ${rows.length} current guide slots');
  final watch = Stopwatch()..start();
  var lastPulse = 0, maxGap = 0;
  final pulse = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final at = watch.elapsedMicroseconds;
    final gap = at - lastPulse;
    if (gap > maxGap) maxGap = gap;
    lastPulse = at;
  });
  final service = SportsReplayService(epg);
  final snapshot = await service.load(playlist.visibleLiveChannels,
      revision: playlist.liveRevision, at: now);
  final cold = watch.elapsedMicroseconds;
  pulse.cancel();
  watch.reset();
  await service.load(playlist.visibleLiveChannels,
      revision: playlist.liveRevision, at: now, force: true);
  final warm = watch.elapsedMicroseconds;
  watch.reset();
  await service.load(playlist.visibleLiveChannels,
      revision: playlist.liveRevision, at: now);
  // ignore: avoid_print
  print('IPTV_REPLAY_PERF ${jsonEncode({
        'coldUs': cold,
        'warmUs': warm,
        'cachedUs': watch.elapsedMicroseconds,
        'maxHeartbeatGapUs': maxGap,
        'confirmed': snapshot.events
            .where((e) => e.evidence != ReplayEvidence.likely)
            .length,
        'possible': snapshot.events
            .where((e) => e.evidence == ReplayEvidence.likely)
            .length,
        'highlights': snapshot.highlights.length,
      })}');
}
