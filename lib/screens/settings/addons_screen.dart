import '../../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/addon_service.dart';
import '../../services/storage_service.dart';
import '../../widgets/hold_to_activate.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_switch_list_tile.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../l10n/l10n.dart';

/// Settings > Add-ons: Stremio-protocol add-ons, used for subtitles only
/// (see [AddonService]). The official OpenSubtitles add-on is listed, off,
/// so turning it on is one press; any other subtitle
/// add-on can be added by its link. Hold OK on an added one to remove it.
class AddonsScreen extends StatefulWidget {
  const AddonsScreen({super.key});

  @override
  State<AddonsScreen> createState() => _AddonsScreenState();
}

class _AddonsScreenState extends State<AddonsScreen> {
  late final AddonService _service;
  late List<Addon> _addons;
  final _link = TextEditingController();
  final _linkFocus = FocusNode();
  final _addFocus = FocusNode();
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _service = AddonService(context.read<StorageService>());
    _addons = _service.addons;
    HardwareKeyboard.instance.addHandler(_escapeLinkField);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_escapeLinkField);
    _link.dispose();
    _linkFocus.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  /// Up/Down out of the link field: EditableText keeps the arrow keys, so
  /// without this the remote was stuck in it (see
  /// TmdbSettingsScreen._handleApiKeyFieldEscapeKey).
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

  Future<void> _update(List<Addon> list) async {
    setState(() => _addons = list);
    await _service.save(list);
  }

  // A copy: the first time, [_addons] is AddonService's const default list,
  // and writing into it threw — the switch never turned on.
  Future<void> _toggle(int i, bool on) =>
      _update([..._addons]..[i] = _addons[i].copyWith(enabled: on));

  Future<void> _remove(int i) async {
    final addon = _addons[i];
    if (addon.manifestUrl == AddonService.openSubtitlesManifest) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SwallowHeldActivate(
          child: AlertDialog(
        title: Text(tr('Remove {name}?', {'name': addon.name})),
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
    if (ok != true || !mounted) return;
    await _update([..._addons]..removeAt(i));
  }

  Future<void> _add() async {
    final url = _link.text.trim();
    if (url.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding = true);
    Addon? addon;
    try {
      addon = await AddonService.fetchManifest(url);
    } catch (_) {
      addon = null;
    }
    if (!mounted) return;
    setState(() => _adding = false);
    if (addon == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(tr(
            'That link isn\'t a subtitle add-on (only subtitle add-ons are supported).')),
        backgroundColor: Colors.red.shade900,
      ));
      return;
    }
    final found = addon;
    if (_addons.any((a) => a.manifestUrl == found.manifestUrl)) {
      messenger.showSnackBar(
          SnackBar(content: Text(tr('That add-on is already in the list.'))));
      return;
    }
    _link.clear();
    await _update([..._addons, found]);
    messenger.showSnackBar(
        SnackBar(content: Text(tr('{name} added.', {'name': found.name}))));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: tr('Add-ons'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(
              'Add-ons find subtitles online for movies and episodes, in many languages. They are free community services, separate from your provider — iptv-app only uses them for subtitles. Turn one on, then pick "Search online subtitles" in the player\'s Subtitles button.')),
          const SizedBox(height: 16),
          SectionLabel(tr('Subtitle add-ons')),
          const SizedBox(height: 4),
          for (var i = 0; i < _addons.length; i++)
            HoldToActivate(
              onTap: () => _toggle(i, !_addons[i].enabled),
              onHold:
                  _addons[i].manifestUrl == AddonService.openSubtitlesManifest
                      ? null
                      : () => _remove(i),
              child: TvSwitchListTile(
                title: Text(_addons[i].name),
                subtitle: Text(
                  _addons[i].manifestUrl == AddonService.openSubtitlesManifest
                      ? tr('Subtitles in 60+ languages from OpenSubtitles.org')
                      : '${_addons[i].description.isEmpty ? _addons[i].baseUrl : _addons[i].description}  ·  ${tr('Hold OK to remove')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                value: _addons[i].enabled,
                onChanged: (v) => _toggle(i, v),
              ),
            ),
          const Divider(height: 32),
          SectionLabel(tr('Add an add-on')),
          const SizedBox(height: 8),
          TvTextFieldGate(
            focusNode: _linkFocus,
            builder: (context, readOnly) => TextField(
              controller: _link,
              focusNode: _linkFocus,
              readOnly: readOnly,
              textInputAction: TextInputAction.done,
              // Lands on Add, never on nothing (see ArchiveSourcesScreen).
              onSubmitted: (_) {
                _addFocus.requestFocus();
                _add();
              },
              decoration: InputDecoration(
                labelText: tr('Add-on link (ends with manifest.json)'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              focusNode: _addFocus,
              onPressed: _adding ? null : _add,
              child: _adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('Add')),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr('Only subtitle add-ons work here. When one is on, the title and episode you are watching are sent to it to find subtitles; nothing else is shared.'),
            style: TextStyle(
                fontSize: 12, color: interfaceColor(context, Colors.white60)),
          ),
        ],
      ),
    );
  }
}
