import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/archive_models.dart';
import '../../services/archive_api_service.dart';
import '../../services/app_preferences.dart';
import '../../services/archive_service.dart';
import '../../services/phone_pairing_service.dart';
import '../../widgets/hold_to_activate.dart';
import '../../widgets/phone_pair_panel.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_switch_list_tile.dart';
import '../../widgets/tv_text_field_gate.dart';
import 'media_server_screen.dart';
import 'trackers_screen.dart';

/// Settings > Archive sources: the servers the Archive tab browses. Any
/// source following the catalog/stream add-on schema works (see
/// [ArchiveApiService]); adding one checks its manifest first. Hold OK on
/// a source to remove it. Same layout as Settings > Add-ons.
class ArchiveSourcesScreen extends StatefulWidget {
  const ArchiveSourcesScreen({super.key});

  @override
  State<ArchiveSourcesScreen> createState() => _ArchiveSourcesScreenState();
}

class _ArchiveSourcesScreenState extends State<ArchiveSourcesScreen> {
  final _link = TextEditingController();
  final _linkFocus = FocusNode();
  final _addFocus = FocusNode();
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_escapeLinkField);
    // TV: start on the link field (keyboard only on OK, see
    // TvTextFieldGate) instead of nothing focused.
    if (context.read<AppPreferences>().isTelevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _linkFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_escapeLinkField);
    _link.dispose();
    _linkFocus.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  /// Up/Down out of the link field (EditableText keeps the arrow keys —
  /// same fix as AddonsScreen._escapeLinkField).
  bool _escapeLinkField(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (!_linkFocus.hasFocus) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _addFocus.requestFocus();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _linkFocus.previousFocus();
      return true;
    }
    return false;
  }

  Future<void> _remove(ArchiveSource source) async {
    final service = context.read<ArchiveService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SwallowHeldActivate(
          child: AlertDialog(
        title: Text(tr('Remove {name}?', {'name': source.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Remove')),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Cancel')),
          ),
        ],
      )),
    );
    if (ok == true) await service.removeSource(source);
  }

  Future<void> _add() async {
    final url = _link.text.trim();
    if (url.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final service = context.read<ArchiveService>();
    setState(() => _adding = true);
    String? error;
    ArchiveSource? added;
    try {
      added = await service.addSource(url);
    } on StateError {
      error = tr('That source is already in the list.');
    } on ArchiveApiException {
      error = tr(
          'That link isn\'t a Media Hub source (it needs movie or series streams).');
    } catch (_) {
      error = tr("Couldn't reach that link.");
    }
    if (!mounted) return;
    setState(() => _adding = false);
    if (error != null) {
      messenger.showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red.shade900));
      return;
    }
    _link.clear();
    messenger.showSnackBar(
        SnackBar(content: Text(tr('{name} added.', {'name': added!.name}))));
  }

  Future<void> _clearAll() async {
    final service = context.read<ArchiveService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SwallowHeldActivate(
          child: AlertDialog(
        title: Text(tr('Clear Media Hub?')),
        content: Text(tr(
            'Removes every Media Hub source and its saved catalog from this device.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Clear')),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Cancel')),
          ),
        ],
      )),
    );
    if (ok != true) return;
    await service.clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Media Hub cleared.'))));
  }

  /// "From my phone": the Add Playlist QR flow, link kind — the phone
  /// pastes the long manifest URL, it lands in the field here to check.
  Future<void> _fromPhone() async {
    final link = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _PhoneLinkScreen()));
    if (link == null || !mounted) return;
    _link.text = link;
    _addFocus.requestFocus();
  }

  String _summary(ArchiveSource s) {
    final movies = s.catalogs.where((c) => c.type == ArchiveType.movie).length;
    final shows = s.catalogs.where((c) => c.type == ArchiveType.series).length;
    final parts = [
      if (movies > 0) tr('{n} movie catalogs', {'n': movies}),
      if (shows > 0) tr('{n} TV show catalogs', {'n': shows}),
    ];
    return '${parts.join(' · ')}  ·  ${tr('Hold OK to remove')}';
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ArchiveService>();
    final sources = service.sources;
    return SettingsScaffold(
      title: tr('Media Hub sources'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(
              'The Media Hub tab shows films and series from sources you add here. Any source that follows the catalog/stream add-on format works; a source that only offers streams by IMDb id gets its posters and episodes from Cinemeta. Only direct video links are played; torrent links are ignored.')),
          const SizedBox(height: 16),
          SectionLabel(tr('Your sources')),
          const SizedBox(height: 4),
          if (sources.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(tr('No sources yet.'),
                  style: const TextStyle(color: Colors.white60)),
            ),
          for (final s in sources)
            HoldToActivate(
              onTap: () => service.setEnabled(s, !s.enabled),
              onHold: () => _remove(s),
              child: TvSwitchListTile(
                title: Text(s.name),
                subtitle: Text(_summary(s),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                value: s.enabled,
                onChanged: (v) => service.setEnabled(s, v),
              ),
            ),
          const Divider(height: 32),
          SectionLabel(tr('Add a source')),
          const SizedBox(height: 8),
          TvTextFieldGate(
            focusNode: _linkFocus,
            builder: (context, readOnly) => TextField(
              controller: _link,
              focusNode: _linkFocus,
              readOnly: readOnly,
              textInputAction: TextInputAction.done,
              // The keyboard's Done lands on Add (Fire OS also sends it
              // for Back): the remote is never left with nothing focused.
              onSubmitted: (_) {
                _addFocus.requestFocus();
                _add();
              },
              decoration: InputDecoration(
                labelText: tr('Source link (ends with manifest.json)'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, children: [
            OutlinedButton(
              focusNode: _addFocus,
              onPressed: _adding ? null : _add,
              child: _adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('Add')),
            ),
            OutlinedButton.icon(
              onPressed: _fromPhone,
              icon: const Icon(Icons.qr_code_2),
              label: Text(tr('From phone')),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MediaServerScreen())),
              icon: const Icon(Icons.dns_outlined),
              label: Text(tr('Connect Jellyfin / Emby')),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TrackersScreen())),
              icon: const Icon(Icons.playlist_add_check),
              label: Text(tr('Trakt & Simkl')),
            ),
          ]),
          if (sources.isNotEmpty) ...[
            const Divider(height: 32),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _clearAll,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(tr('Clear Media Hub')),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            tr('iptv-app ships no sources. The titles you open are requested from the source you added; nothing else is shared.'),
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ),
    );
  }
}

/// The QR page behind "From my phone"; pops with the link the phone sent.
class _PhoneLinkScreen extends StatefulWidget {
  const _PhoneLinkScreen();

  @override
  State<_PhoneLinkScreen> createState() => _PhoneLinkScreenState();
}

class _PhoneLinkScreenState extends State<_PhoneLinkScreen> {
  final _toggleFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Focus the panel's only control so the remote has an initial target.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _toggleFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _toggleFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: tr('Media Hub sources'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PhonePairPanel(
          kind: PairingKind.link,
          toggleFocusNode: _toggleFocus,
          onResult: (r) {
            if (mounted) Navigator.of(context).pop(r.link);
          },
        ),
      ),
    );
  }
}
