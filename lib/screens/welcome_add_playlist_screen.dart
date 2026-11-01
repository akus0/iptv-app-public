import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_preferences.dart';
import '../utils/tv_theme.dart';
import '../widgets/mode_button.dart';
import '../l10n/l10n.dart';

/// Shown once, from main.dart's bootstrap gate, the very first time the app
/// launches with zero playlists configured — a brand-new install has no
/// other hint that content lives behind Settings > Playlist Manager rather
/// than just showing up. Modeled directly on [CatalogSyncPromptScreen]: same
/// "runs before the real MaterialApp/theme tree exists, so it carries its
/// own" situation, same reason it reads [AppPreferences.palette] itself
/// instead of inheriting a theme.
class WelcomeAddPlaylistScreen extends StatelessWidget {
  const WelcomeAddPlaylistScreen({super.key, required this.onRespond});

  /// `true` to open [AddPlaylistScreen] right after bootstrap finishes,
  /// `false` to land on the normal (empty) main app — see main.dart's
  /// `_pendingAutoOpenAddPlaylist` for why this can't just push the screen
  /// directly from here (no Navigator exists yet at this point).
  final void Function(bool wantsToAddPlaylist) onRespond;

  @override
  Widget build(BuildContext context) {
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
                  Icon(Icons.live_tv_outlined,
                      size: 64, color: palette.primary),
                  const SizedBox(height: 20),
                  Text(
                    tr('Welcome to iptv-app'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    tr('Add your first playlist?'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr('Add a playlist to kick things off, or skip for now if you just want to browse and discover the app without content.'),
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  // ModeButton over plain Outlined/FilledButton for the same
                  // reason as CatalogSyncPromptScreen — a solid fill *only*
                  // on real D-pad focus, not permanently on one button.
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
                            label: tr('Add Playlist'),
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
