import 'settings_theme.dart';
import 'package:flutter/material.dart';
import '../utils/playlist_user_agent.dart';
import 'compact_choice_list.dart';
import 'tv_text_field_gate.dart';

Future<String?> choosePlaylistUserAgent(BuildContext context, String current) =>
    showSettingsDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (_) => _UserAgentDialog(current: current));

class _UserAgentDialog extends StatefulWidget {
  const _UserAgentDialog({required this.current});
  final String current;
  @override
  State<_UserAgentDialog> createState() => _UserAgentDialogState();
}

class _UserAgentDialogState extends State<_UserAgentDialog> {
  late final _text = TextEditingController(text: widget.current);
  final _focus = FocusNode(debugLabel: 'playlist-user-agent-input');
  bool _custom = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final error = playlistUserAgentError(_text.text);
    if (error != null) {
      setState(() => _error = error);
      _focus.requestFocus();
      return;
    }
    Navigator.pop(context, normalizePlaylistUserAgent(_text.text));
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.current.isEmpty
        ? 'default'
        : playlistUserAgentPresets.containsValue(widget.current)
            ? widget.current
            : 'custom';
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_custom ? 'Custom user agent' : 'User agent',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                if (!_custom || MediaQuery.viewInsetsOf(context).bottom == 0)
                  Text(
                      _custom
                          ? 'Enter the exact value your provider requires. Leave blank to use the default.'
                          : 'Optional. Identifies this playlist’s requests to its provider. Use Default unless your provider requires another value.',
                      style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Flexible(
                    child: _custom
                        ? SingleChildScrollView(
                            child: TvTextFieldGate(
                                focusNode: _focus,
                                builder: (context, readOnly) => TextField(
                                      key: const ValueKey(
                                          'playlist-user-agent-input'),
                                      controller: _text,
                                      focusNode: _focus,
                                      readOnly: readOnly,
                                      autofocus: true,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      textInputAction: TextInputAction.done,
                                      decoration: InputDecoration(
                                          labelText: 'User-agent value',
                                          hintText: 'For example: VLC/3.0.20',
                                          errorText: _error,
                                          errorMaxLines: 2),
                                      onSubmitted: (_) => _save(),
                                      onChanged: (_) {
                                        if (_error != null) {
                                          setState(() => _error = null);
                                        }
                                      },
                                    )))
                        : SizedBox(
                            height:
                                SettingsTheme.isTelevision(context) ? 240 : 288,
                            child: CompactChoiceList(
                                rowHeight: SettingsTheme.isTelevision(context)
                                    ? 40
                                    : 48,
                                selected: selected,
                                polished: true,
                                choices: [
                                  CompactChoice(
                                      id: 'default',
                                      title: 'Default (recommended)',
                                      onTap: () => Navigator.pop(context, '')),
                                  for (final entry
                                      in playlistUserAgentPresets.entries)
                                    CompactChoice(
                                        id: entry.value,
                                        title: entry.key,
                                        subtitle: entry.key == entry.value
                                            ? null
                                            : entry.value,
                                        onTap: () => Navigator.pop(
                                            context, entry.value)),
                                  CompactChoice(
                                      id: 'custom',
                                      title: 'Custom…',
                                      onTap: () =>
                                          setState(() => _custom = true)),
                                ]))),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  if (_custom) ...[
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _save, child: const Text('Save')),
                  ],
                ]),
              ]),
        ),
      ),
    );
  }
}
