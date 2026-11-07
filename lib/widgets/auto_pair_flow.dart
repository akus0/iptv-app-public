import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

/// Shared auto-pair flow: show progress, then offer review or continue. Return the paired
/// count independently of whether review was chosen.
Future<({Set<String> paired, bool review})> runAutoPairFlow(
  BuildContext context, {
  required Future<Set<String>> Function() autoPair,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Flexible(child: Text(tr('Channels are pairing, please wait…'))),
          ],
        ),
      ),
    ),
  );

  final paired = await autoPair();

  if (!context.mounted) return (paired: paired, review: false);
  Navigator.of(context).pop(); // dismiss the wait dialog

  if (!context.mounted) return (paired: paired, review: false);
  final review = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(tr('Auto-Pair Channels')),
      content: Text(paired.isEmpty
          ? tr(
              'No new matches found — anything still unmatched needs a manual pick.')
          : tr('Paired {paired} channel{s} automatically.',
              {'paired': paired.length, 's': paired.length == 1 ? '' : 's'})),
      actions: [
        if (paired.isNotEmpty)
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('Review'))),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('Continue'))),
      ],
    ),
  );
  return (paired: paired, review: review ?? false);
}

/// Shared "Unpair Channels" confirmation — undoes only what auto-pairing
/// itself set (never a manual pick), see the caller's own
/// `unpairAuto*`/`autoPaired*Count` doc comments for the actual rule.
/// Returns true only if the person confirmed and [unpair] actually ran.
Future<bool> confirmAndUnpair(
  BuildContext context, {
  required int autoPairedCount,
  required Future<int> Function() unpair,
}) async {
  if (autoPairedCount == 0) {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('Unpair Channels')),
        content:
            Text(tr('Nothing was auto-paired — there\'s nothing to undo.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('OK'))),
        ],
      ),
    );
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(tr('Unpair Channels')),
      content: Text(tr(
          'Undo {autoPairedCount} automatic pairing{s}? Anything you\'ve set by hand is kept.',
          {
            'autoPairedCount': autoPairedCount,
            's': autoPairedCount == 1 ? '' : 's'
          })),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('Cancel'))),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('Unpair'))),
      ],
    ),
  );
  if (confirmed != true) return false;
  await unpair();
  return true;
}
