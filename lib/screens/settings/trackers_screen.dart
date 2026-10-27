import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import '../../models/archive_models.dart';
import '../../services/archive_service.dart';
import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../services/tracker_api.dart';
import '../../services/tracker_sync.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_menu_tile.dart';

/// Settings > Trakt & Simkl: connect a watch tracker. Signing in is a
/// code on the TV the viewer approves on their phone (nothing typed on the
/// remote). A connected account adds its lists to the Media Hub and gets
/// the Media Hub's plays reported (`WatchTracker`); disconnecting removes
/// both. Accounts are Media Hub sources, so they also travel with Transfer.
class TrackersScreen extends StatelessWidget {
  const TrackersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ArchiveService>();
    Widget tile(TrackerKind kind, String blurb, {bool autofocus = false}) {
      final account = service.trackerSource(kind);
      final configured = TrackerApi.isConfigured(kind);
      return TvMenuTile(
        autofocus: autofocus,
        icon: account != null ? Icons.check_circle : Icons.link,
        title: kind.label,
        subtitle: account != null
            ? tr('Connected as {name} — press OK to disconnect', {
                'name': account.tracker!.userName.isEmpty
                    ? kind.label
                    : account.tracker!.userName
              })
            : configured
                ? blurb
                : tr('Not available in this build yet'),
        trailing: const SizedBox.shrink(),
        enabled: account != null || configured,
        onTap: () => account != null
            ? _disconnect(context, account)
            : _connect(context, kind),
      );
    }

    return SettingsScaffold(
      title: tr('Trakt & Simkl'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(
              'Connect a watch tracker: what you watch in the Media Hub is marked as watched on your account, and your lists show up as Media Hub rows. Nothing is sent unless you connect an account.')),
          const SizedBox(height: 16),
          tile(TrackerKind.trakt, tr('Watchlist and trending rows, scrobbling'),
              autofocus: true),
          tile(TrackerKind.simkl,
              tr('Watching and plan-to-watch rows, scrobbling')),
          const SizedBox(height: 16),
          Text(
            tr('Titles from your lists play through your stream add-ons (Media Hub sources), by IMDb id. Only titles with an IMDb id are reported.'),
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 8),
          Text(
            '${tr('Powered by Trakt (trakt.tv) and Simkl (simkl.com).')} '
            '${tr('iptv-app is not affiliated with or endorsed by Trakt or Simkl.')}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Future<void> _connect(BuildContext context, TrackerKind kind) async {
    final service = context.read<ArchiveService>();
    final storage = context.read<StorageService>();
    final playlist = context.read<PlaylistManager>();
    final messenger = ScaffoldMessenger.of(context);
    final login = await showDialog<TrackerLogin>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SignInDialog(kind: kind),
    );
    if (login == null) return;
    await service.addTracker(login);
    // Bring this account's history in now, not at the next launch.
    TrackerSync.instance.invalidate();
    unawaited(TrackerSync.instance.syncCatalog(storage, playlist));
    messenger.showSnackBar(
        SnackBar(content: Text(tr('{name} connected.', {'name': kind.label}))));
  }

  Future<void> _disconnect(BuildContext context, ArchiveSource account) async {
    final service = context.read<ArchiveService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Disconnect {name}?', {'name': account.name})),
        content: Text(tr(
            'Its rows leave the Media Hub and plays are no longer reported. Your account itself is untouched.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('Disconnect')),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('Cancel')),
          ),
        ],
      ),
    );
    if (ok == true) await service.removeSource(account);
  }
}

/// "Go to … and enter CODE" with a QR code of the page, polling until the
/// viewer approves on their phone. Pops the login, or null (cancel/expired).
class _SignInDialog extends StatefulWidget {
  const _SignInDialog({required this.kind});
  final TrackerKind kind;

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  final _api = TrackerApi();
  TrackerDeviceCode? _code;
  String? _error;
  Timer? _timer;
  DateTime? _deadline;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api.close();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _code = null;
    });
    try {
      final code = await _api.startSignIn(widget.kind);
      if (!mounted) return;
      setState(() {
        _code = code;
        _deadline = DateTime.now().add(code.expiresIn);
      });
      _timer = Timer.periodic(code.interval, (_) => _poll());
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr(
            "Couldn't reach {name}. Check the connection.",
            {'name': widget.kind.label}));
      }
    }
  }

  Future<void> _poll() async {
    final code = _code;
    if (code == null || _polling) return;
    if (DateTime.now().isAfter(_deadline!)) {
      _timer?.cancel();
      setState(() => _error = tr('The code expired. Try again.'));
      return;
    }
    _polling = true;
    try {
      final login = await _api.pollSignIn(code);
      if (login != null && mounted) {
        _timer?.cancel();
        Navigator.of(context).pop(login);
      }
    } on TrackerAuthException {
      _timer?.cancel();
      if (mounted) {
        setState(() => _error = tr('Sign-in was not completed. Try again.'));
      }
    } catch (_) {
      // Network hiccup: the next tick tries again.
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('Connect {name}', {'name': widget.kind.label})),
      content: SizedBox(
        width: 520,
        child: _error != null
            ? Text(_error!)
            : code == null
                ? const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()))
                : Row(
                    children: [
                      Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(8),
                        child: QrImageView(
                            data: code.qrUrl ?? code.verificationUrl,
                            size: 150),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr('On your phone or computer, open')),
                            const SizedBox(height: 4),
                            Text(code.verificationUrl,
                                style: TextStyle(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 12),
                            Text(tr('and enter this code:')),
                            const SizedBox(height: 4),
                            SelectableText(code.userCode,
                                style: const TextStyle(
                                    fontSize: 34,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 4)),
                            const SizedBox(height: 12),
                            Text(tr('Waiting for you to approve…'),
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.white60)),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
      actions: [
        if (_error != null)
          TextButton(onPressed: _start, child: Text(tr('Try again'))),
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Cancel')),
        ),
      ],
    );
  }
}
