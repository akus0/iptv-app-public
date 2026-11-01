import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
import '../services/playlist_manager.dart';
import '../utils/tv_theme.dart';
import '../widgets/mode_button.dart';
import '../l10n/l10n.dart';

/// The actual progress UI for a full catalog sync — phase text + a
/// progress bar off [PlaylistManager]'s existing warm-up counters.
/// Extracted from [CatalogSyncScreen] so the exact same content can be
/// shown two ways: as the app's root during main.dart's bootstrap gate
/// (no Navigator/MaterialApp exists yet there), or pushed as a normal
/// full-screen route when the user manually triggers "Update Content"
/// from within the already-running app.
class CatalogSyncBody extends StatelessWidget {
  const CatalogSyncBody({super.key, required this.playlist, this.footer});

  final PlaylistManager playlist;

  /// Shown at the bottom in a dimmer style — the automatic (launch-time)
  /// and manual ("Update Content") triggers word this differently, since
  /// only the automatic one is about *not* having to see this again soon.
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ListenableBuilder(
            listenable: playlist,
            builder: (context, _) {
              final total = playlist.warmCatalogTotal;
              final done = playlist.warmCatalogDone;
              final hasProgress = total > 0;
              final fraction =
                  hasProgress ? (done / total).clamp(0.0, 1.0) : null;
              final phase = playlist.loadingPhase ??
                  (hasProgress
                      ? tr('Loading movies & TV shows...')
                      : tr('Connecting to server...'));
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_sync_outlined,
                      color: Colors.white70, size: 48),
                  const SizedBox(height: 24),
                  Text(
                    tr('Updating Content'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    phase,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: 260,
                    child: LinearProgressIndicator(value: fraction),
                  ),
                  if (hasProgress) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr('{done} / {total} categories',
                          {'done': done, 'total': total}),
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                  if (footer != null) ...[
                    const SizedBox(height: 32),
                    Text(
                      footer!,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Blocking "Updating..." screen shown while the *automatic* full catalog
/// sync runs at launch — see [PlaylistManager.runFullCatalogSync] and
/// [CatalogSyncBody] for the shared progress UI. This variant wraps its
/// own MaterialApp/Scaffold because it renders from main.dart's bootstrap
/// gate, before the app's real MaterialApp tree exists yet.
class CatalogSyncScreen extends StatelessWidget {
  const CatalogSyncScreen({super.key, required this.playlist});

  final PlaylistManager playlist;

  @override
  Widget build(BuildContext context) {
    // Same fix, same reason, as CatalogSyncPromptScreen's own doc comment
    // — this also renders from main.dart's bootstrap gate with its own
    // MaterialApp, which previously meant CatalogSyncBody's progress
    // indicator fell back to Flutter's stock default ColorScheme instead
    // of the user's palette.
    final palette = context.watch<AppPreferences>().palette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(palette),
      home: Scaffold(
        body: CatalogSyncBody(
          playlist: playlist,
          footer: tr(
              'This happens every few days to keep your catalog current — everyday launches open straight in.'),
        ),
      ),
    );
  }
}

/// Confirms and runs [PlaylistManager.runFullCatalogSync] behind a blocking progress screen.
/// Returns true if the sync ran, or false if cancelled.
Future<bool> confirmAndRunFullCatalogSync(
    BuildContext context, PlaylistManager playlist) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Update content now?')),
      content: Text(
        tr('Re-checks every visible category for new content. This can take a few minutes on a large catalog.'),
      ),
      // Use ModeButton to distinguish actual D-pad focus from the default appearance of a
      // filled action.
      actions: [
        ModeButton(
            label: tr('Cancel'),
            selected: false,
            onTap: () => Navigator.of(context).pop(false)),
        ModeButton(
            label: tr('Update'),
            selected: false,
            onTap: () => Navigator.of(context).pop(true)),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final syncFuture = playlist.runFullCatalogSync();
  if (!context.mounted) return false;
  final navigator = Navigator.of(context);
  unawaited(navigator.push(MaterialPageRoute(
    builder: (_) => Scaffold(
        body: CatalogSyncBody(playlist: playlist)),
  )));
  await syncFuture;
  if (context.mounted) navigator.pop();
  return true;
}
