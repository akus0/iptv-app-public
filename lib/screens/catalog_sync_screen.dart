import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
import '../services/playlist_manager.dart';
import '../utils/tv_theme.dart';
import '../utils/guarded_dialog.dart';
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
    BuildContext context, PlaylistManager playlist,
    {String? playlistId, VoidCallback? onStarted}) async {
  final television = context.read<AppPreferences?>()?.isTelevision == true;
  final selected = playlist.profiles
      .where((p) => p.enabled && (playlistId == null || p.id == playlistId))
      .toList(growable: false);
  final scope = playlistId == null
      ? selected.length == 1
          ? tr('1 enabled playlist')
          : tr('{count} enabled playlists', {'count': selected.length})
      : selected.firstOrNull?.name;
  final confirmed = await showGuardedDialog<bool>(
    context: context,
    animationStyle: television ? AnimationStyle.noAnimation : null,
    builder: (context) => AlertDialog(
      scrollable: true,
      constraints: const BoxConstraints(maxWidth: 480),
      titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface),
      contentTextStyle: TextStyle(
          fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
      title: Text(tr('Update content now?')),
      content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (scope != null) ...[
              Text(scope,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 6),
            ],
            Text(playlistId == null
                ? tr(
                    'Re-checks every visible category for new content. This can take a few minutes on a large catalog.')
                : tr(
                    'Re-checks visible categories in this playlist for new content.')),
          ]),
      actions: [
        TextButton(
            autofocus: true,
            style: TextButton.styleFrom(
                minimumSize: Size(0, television ? 36 : 48),
                textStyle: const TextStyle(fontSize: 12)),
            onPressed: () => popRouteIfCurrent(context, false),
            child: Text(tr('Cancel'))),
        TextButton(
            style: TextButton.styleFrom(
                minimumSize: Size(0, television ? 36 : 48),
                textStyle: const TextStyle(fontSize: 12)),
            onPressed: () => popRouteIfCurrent(context, true),
            child: Text(tr('Update'))),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  onStarted?.call();

  final navigator = Navigator.of(context);
  Widget progress(BuildContext context) => PopScope(
      canPop: false,
      child: Scaffold(body: CatalogSyncBody(playlist: playlist)));
  final route = television
      ? PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              progress(context))
      : MaterialPageRoute<void>(builder: progress);
  unawaited(navigator.push(route));
  try {
    await playlist.runFullCatalogSync(playlistId: playlistId);
  } finally {
    // Remove only our progress route, even if another route was opened above it.
    if (route.isActive) {
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    }
  }
  return true;
}
