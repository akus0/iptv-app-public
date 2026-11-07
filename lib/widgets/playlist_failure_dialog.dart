import 'settings_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/playlist_failure.dart';

enum PlaylistFailureAction { edit, retry }

Future<PlaylistFailureAction?> showPlaylistFailureDialog(BuildContext context,
        {required PlaylistFailure failure, required String source}) =>
    showSettingsDialog<PlaylistFailureAction>(
        context: context,
        useRootNavigator: false,
        barrierDismissible: false,
        animationStyle: AnimationStyle.noAnimation,
        builder: (_) => _FailureDialog(failure: failure, source: source));

class _FailureDialog extends StatefulWidget {
  const _FailureDialog({required this.failure, required this.source});
  final PlaylistFailure failure;
  final String source;
  @override
  State<_FailureDialog> createState() => _FailureDialogState();
}

class _FailureDialogState extends State<_FailureDialog> {
  late final Future<PackageInfo?> _version = _readVersion();
  bool _copying = false;
  bool _closing = false;
  String _copyLabel = 'Copy error details';

  static Future<PackageInfo?> _readVersion() async {
    try {
      return await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  Future<void> _copy() async {
    if (_copying || _closing) return;
    setState(() => _copying = true);
    try {
      final info = await _version;
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(
          text: widget.failure.report(
              source: widget.source,
              version: info?.version,
              build: info?.buildNumber)));
      if (mounted) setState(() => _copyLabel = 'Copied');
    } catch (_) {
      if (mounted) setState(() => _copyLabel = 'Copy failed · try again');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  void _finish(PlaylistFailureAction action) {
    if (_closing) return;
    _closing = true;
    Navigator.pop(context, action);
  }

  @override
  Widget build(BuildContext context) {
    final failure = widget.failure;
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('playlist-failure-dialog'),
      constraints: const BoxConstraints(maxWidth: 460),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      scrollable: true,
      title: Text('Couldn’t save playlist', style: theme.textTheme.titleMedium),
      content: SizedBox(
          width: 400,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(failure.stageLabel, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Text(failure.message, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                Text(
                    'Reference: ${failure.code}${failure.safeHttpStatus == null ? '' : '\nHTTP ${failure.safeHttpStatus}'}',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Text(
                    'Copied details include the app version and error reference, without playlist addresses or account details.',
                    style: theme.textTheme.bodySmall),
              ])),
      actions: [
        TextButton(
            key: const ValueKey('playlist-error-copy'),
            // Keep remote focus while the guarded clipboard operation runs.
            onPressed: _copy,
            child: Text(_copying ? 'Copying…' : _copyLabel)),
        TextButton(
            key: const ValueKey('playlist-error-edit'),
            autofocus: true,
            onPressed: () => _finish(PlaylistFailureAction.edit),
            child: const Text('Edit details')),
        FilledButton(
            key: const ValueKey('playlist-error-retry'),
            onPressed: () => _finish(PlaylistFailureAction.retry),
            child: const Text('Retry')),
      ],
    );
  }
}
