import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/l10n.dart';
import '../services/app_update_service.dart';
import '../utils/constants.dart';
import 'mode_button.dart';

enum UpdatePromptChoice { update, later, skip }

/// The launch-time "new version" popup (TvHomeScreen checks once per
/// launch): version, a few highlights from the release notes, and
/// Update / Later / Skip this version. Update leads to Settings > Check
/// for Updates' own download + install flow.
class UpdatePromptDialog extends StatefulWidget {
  const UpdatePromptDialog({super.key, required this.update});

  final UpdateInfo update;

  static Future<UpdatePromptChoice?> show(
          BuildContext context, UpdateInfo update) =>
      showDialog<UpdatePromptChoice>(
        context: context,
        builder: (_) => UpdatePromptDialog(update: update),
      );

  /// Select up to max summary lines from release notes, preferring bold headings when
  /// available and otherwise using plain bullets.
  static List<String> highlights(String notes, {int max = 5}) {
    String clean(String s) => s
        .replaceAll('**', '')
        .replaceAll(RegExp(r'^[-*]\s+'), '')
        .replaceAll(RegExp(r'^#+\s*'), '')
        .trim();
    final lines = notes.split(RegExp(r'\r?\n')).map((l) => l.trim());
    final headings = [
      for (final l in lines)
        if (RegExp(r'^\*\*[^*]+\*\*:?$').hasMatch(l)) clean(l)
    ];
    final bullets = [
      for (final l in lines)
        if (RegExp(r'^[-*]\s+').hasMatch(l)) clean(l)
    ];
    final picked = headings.length >= 2 ? headings : bullets;
    return [
      for (final l in picked)
        if (l.isNotEmpty && !l.toLowerCase().startsWith('downloader code')) l
    ].take(max).toList();
  }

  @override
  State<UpdatePromptDialog> createState() => _UpdatePromptDialogState();
}

class _UpdatePromptDialogState extends State<UpdatePromptDialog> {
  final FocusNode _updateFocus = FocusNode(debugLabel: 'update-prompt');
  String _currentVersion = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _currentVersion = info.version);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _updateFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = UpdatePromptDialog.highlights(widget.update.releaseNotes);
    void close(UpdatePromptChoice c) => Navigator.of(context).pop(c);
    return AlertDialog(
      title: Text(tr('{appName} {version} is available', {
        'appName': AppConstants.appName,
        'version': widget.update.version,
      })),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Same string as Settings > Check for Updates.
            Text(
              _currentVersion.isEmpty
                  ? tr('Current version: —')
                  : tr('Current version: {currentVersion}',
                      {'currentVersion': _currentVersion}),
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            if (lines.isNotEmpty) ...[
              Text(tr("What's new:"),
                  style: TextStyle(
                      color: scheme.primary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('•  $l',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
            ] else
              Text(tr('A new version is ready to install.')),
          ],
        ),
      ),
      // ModeButton, not TextButton: its focus look is clear on a TV.
      actions: [
        ModeButton(
          label: tr('Skip this version'),
          selected: false,
          onTap: () => close(UpdatePromptChoice.skip),
        ),
        ModeButton(
          label: tr('Later'),
          selected: false,
          onTap: () => close(UpdatePromptChoice.later),
        ),
        ModeButton(
          icon: Icons.system_update,
          label: tr('Update'),
          selected: false,
          focusNode: _updateFocus,
          onTap: () => close(UpdatePromptChoice.update),
        ),
      ],
    );
  }
}
