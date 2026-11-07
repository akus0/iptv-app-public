import 'package:flutter/material.dart';
import '../models/custom_guide_source.dart';
import 'tv_text_field_gate.dart';

class CustomGuideEditor extends StatefulWidget {
  const CustomGuideEditor(
      {super.key,
      this.source,
      required this.existing,
      required this.onSave,
      required this.onRemove});
  final CustomGuideSource? source;
  final List<CustomGuideSource> existing;
  final Future<void> Function(CustomGuideSource) onSave;
  final Future<void> Function() onRemove;
  @override
  State<CustomGuideEditor> createState() => _CustomGuideEditorState();
}

class _CustomGuideEditorState extends State<CustomGuideEditor> {
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  late final _url = TextEditingController(text: widget.source?.url ?? '');
  final _nameFocus = FocusNode(), _urlFocus = FocusNode();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _nameFocus.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  Future<void> _save({bool remove = false}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (remove) {
        await widget.onRemove();
      } else {
        final url = CustomGuideSource.validateUrl(_url.text);
        if (widget.existing
            .any((s) => s.id != widget.source?.id && s.url == url)) {
          throw const FormatException('This guide URL has already been added.');
        }
        await widget.onSave(CustomGuideSource(
            id: widget.source?.id ??
                DateTime.now().microsecondsSinceEpoch.toString(),
            name: _name.text.trim().isEmpty
                ? Uri.parse(url).host
                : _name.text.trim(),
            url: url,
            enabled: widget.source?.enabled ?? true));
      }
      if (mounted) Navigator.of(context).pop();
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
      _urlFocus.requestFocus();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save this guide. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(
            widget.source == null ? 'Add XMLTV guide' : 'Edit XMLTV guide'),
        titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        scrollable: true,
        content: SizedBox(
            width: 400,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TvTextFieldGate(
                      focusNode: _nameFocus,
                      builder: (_, readOnly) => TextField(
                          key: const ValueKey('custom-guide-name'),
                          controller: _name,
                          focusNode: _nameFocus,
                          readOnly: readOnly,
                          enabled: !_saving,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                              isDense: true, labelText: 'Name (optional)'),
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => _urlFocus.requestFocus())),
                  const SizedBox(height: 12),
                  TvTextFieldGate(
                      focusNode: _urlFocus,
                      builder: (_, readOnly) => TextField(
                          key: const ValueKey('custom-guide-url'),
                          controller: _url,
                          focusNode: _urlFocus,
                          readOnly: readOnly,
                          enabled: !_saving,
                          style: const TextStyle(fontSize: 13),
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'XMLTV URL',
                              hintText: 'https://…/guide.xml.gz'),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _save())),
                  const SizedBox(height: 12),
                  const Text(
                      'XML or XML.gz. Matching IDs or unique full channel names fill gaps. Other channels can be linked in the guide picker. Saving does not start a download.',
                      style: TextStyle(fontSize: 12, height: 1.4)),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.error))),
                ])),
        actions: [
          if (widget.source != null)
            TextButton(
                key: const ValueKey('custom-guide-remove'),
                onPressed: _saving ? null : () => _save(remove: true),
                child: const Text('Remove')),
          TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('custom-guide-save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save')),
        ],
      ));
}
