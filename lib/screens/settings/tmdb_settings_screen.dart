import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../services/playlist_manager.dart';
import '../../services/storage_service.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../l10n/l10n.dart';

/// Where a user supplies their own free TMDB (The Movie Database) API
/// key — see `TmdbEnrichmentService`'s doc comment for why this can't
/// just be a key baked into the app itself. Off by default: nothing here
/// is required for the app to work, it only unlocks the "TMDB" sort
/// option on a group's "Expand catalog" screen, and sharpens "What's New"
/// (see `PlaylistManager.refreshWhatsNewTmdbIfDue`) once one's been set.
class TmdbSettingsScreen extends StatefulWidget {
  const TmdbSettingsScreen({super.key});

  @override
  State<TmdbSettingsScreen> createState() => _TmdbSettingsScreenState();
}

class _TmdbSettingsScreenState extends State<TmdbSettingsScreen> {
  late final TextEditingController _controller;
  bool _validating = false;
  bool _refreshing = false;

  final _apiKeyFocus = FocusNode();
  final _saveFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: context.read<StorageService>().getTmdbApiKey() ?? '');
    HardwareKeyboard.instance.addHandler(_handleApiKeyFieldEscapeKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleApiKeyFieldEscapeKey);
    _apiKeyFocus.dispose();
    _saveFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// EditableText consumes arrow keys. Use an explicit keyboard handler to leave the API-key
  /// field and reach the other controls.
  bool _handleApiKeyFieldEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) return false;
    if (FocusManager.instance.primaryFocus != _apiKeyFocus) return false;
    _saveFocus.requestFocus();
    return true;
  }

  /// Saves immediately (so a key is never lost just because the
  /// validation check below fails/times out), then separately checks it
  /// against TMDB's own `/authentication` endpoint — the one endpoint
  /// TMDB provides specifically to answer "is this key good", at zero
  /// cost toward anything else. "Saved" alone said nothing about whether
  /// the key actually works, which is the thing someone pasting in a long
  /// string actually wants to know.
  Future<void> _save() async {
    final key = _controller.text.trim();
    await context.read<StorageService>().setTmdbApiKey(key);
    if (!mounted) return;
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Cleared — TMDB sorting is now off'))));
      return;
    }
    setState(() => _validating = true);
    final valid = await _checkKey(key);
    if (!mounted) return;
    setState(() => _validating = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(valid
          ? tr('Saved — key verified with TMDB ✓')
          : tr(
              'Saved, but TMDB rejected this key — double-check it\'s correct')),
      backgroundColor: valid ? null : Colors.red.shade900,
    ));
  }

  /// Bypasses the normal once-a-week gate — see
  /// `PlaylistManager.refreshWhatsNewTmdbIfDue`'s own doc comment for why
  /// that gate exists and why a manual override is needed at all: its
  /// persisted "last run" timestamp survives an app *update*, not just a
  /// restart, so anyone whose weekly window already started under an
  /// older, narrower version of that lookup would otherwise see no
  /// change for up to another 7 days with nothing to explain why.
  Future<void> _refreshWhatsNew() async {
    setState(() => _refreshing = true);
    await context.read<PlaylistManager>().refreshWhatsNewTmdbIfDue(force: true);
    if (!mounted) return;
    setState(() => _refreshing = false);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('What\'s New refreshed from TMDB'))));
  }

  Future<bool> _checkKey(String key) async {
    try {
      final uri =
          Uri.parse('https://api.themoviedb.org/3/authentication?api_key=$key');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['success'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: tr('TMDB (Release Dates)'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            tr('TMDB (The Movie Database) is a free, independent movie and TV database — not your IPTV provider. Adding your own free TMDB key lets iptv-app look up a title\'s actual real-world release date, which powers two things: a "TMDB" sort option on any group\'s "Expand catalog" screen, and a more accurate "What\'s New" row (ordered by real release date instead of just when your provider added the title).'),
          ),
          const SizedBox(height: 12),
          Text(
            tr('This is completely optional and free — iptv-app works 100% without it. Without a key, sorting just falls back to whenever your provider added or updated each title, which is still available and works fine on its own.'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(
            tr('To get one: create a free account at themoviedb.org, then generate an API key under Settings > API (choose "Personal use" when asked) and paste it below. iptv-app never collects or shares it — it\'s stored only on this device.'),
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 20),
          // Open the keyboard only on OK so D-pad navigation can reach the controls below.
          TvTextFieldGate(
            focusNode: _apiKeyFocus,
            builder: (context, readOnly) => TextField(
              controller: _controller,
              focusNode: _apiKeyFocus,
              readOnly: readOnly,
              // Support submission from the IME Done/Enter action while the system keyboard
              // owns navigation.
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: tr('TMDB API Key'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // OutlinedButton has a transparent idle background, making the shared focused fill
          // visible.
          OutlinedButton(
            focusNode: _saveFocus,
            onPressed: _validating ? null : _save,
            child: _validating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(tr('Save')),
          ),
          if (context.watch<StorageService>().getTmdbApiKey()?.isNotEmpty ??
              false) ...[
            const SizedBox(height: 16),
            Text(
                tr('What\'s New only re-checks TMDB about once a week on its own. Use this to force it right now instead of waiting — useful right after saving a key for the first time.'),
                style: const TextStyle(fontSize: 12, color: Colors.white60)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _refreshing ? null : _refreshWhatsNew,
              icon: _refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              label: Text(tr('Refresh What\'s New Now')),
            ),
          ],
          const SizedBox(height: 24),
          // TMDB's own terms require this attribution wherever their API
          // is actually used — not optional/cosmetic.
          Text(
            tr('This product uses the TMDB API but is not endorsed or certified by TMDB.'),
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
