import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
import '../utils/tv_theme.dart';
import '../widgets/mode_button.dart';
import '../l10n/l10n.dart';

/// Asks before the automatic full catalog sync runs — this fires from
/// main.dart's bootstrap (a persisted "last synced" timestamp going stale),
/// not from a direct user action, so it needs its own explicit confirm
/// rather than just barging into a multi-minute blocking sync. Declining
/// leaves the last-synced timestamp untouched, so this asks again next
/// launch rather than silently postponing forever.
class CatalogSyncPromptScreen extends StatelessWidget {
  const CatalogSyncPromptScreen(
      {super.key, required this.lastSyncedAt, required this.onRespond});

  final DateTime? lastSyncedAt;
  final void Function(bool confirmed) onRespond;

  String get _subtitle {
    final last = lastSyncedAt;
    if (last == null) return tr('Your catalog has never been fully synced.');
    final days = DateTime.now().difference(last).inDays;
    if (days <= 0) {
      return tr('Your catalog was last fully synced earlier today.');
    }
    return tr('Your catalog was last fully synced {days} day{s} ago.',
        {'days': days, 's': days == 1 ? '' : 's'});
  }

  @override
  Widget build(BuildContext context) {
    // Bootstrap renders before the main MaterialApp exists. Apply the saved palette to this
    // local MaterialApp so its controls use the same theme.
    final palette = context.watch<AppPreferences>().palette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(palette),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_sync_outlined,
                      color: Colors.white70, size: 48),
                  const SizedBox(height: 24),
                  Text(
                    tr('Update content now?'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _subtitle,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('This can take a few minutes on a large catalog. Skipping opens the app with what\'s already cached.'),
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  // Use ModeButton so only the focused action receives the solid focus fill.
                  SizedBox(
                    width: 320,
                    child: Row(
                      children: [
                        Expanded(
                          child: ModeButton(
                            label: tr('Skip for now'),
                            selected: false,
                            onTap: () => onRespond(false),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ModeButton(
                            label: tr('Update'),
                            selected: false,
                            onTap: () => onRespond(true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
