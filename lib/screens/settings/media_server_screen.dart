import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/app_preferences.dart';
import '../../services/archive_service.dart';
import '../../services/media_server_api.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_text_field_gate.dart';

/// Media Hub > Connect Jellyfin / Emby: server address, user name and
/// password. The server kind (and Emby's `/emby` path) is detected, so
/// there is nothing to pick. On success the server's movie and TV
/// libraries become Media Hub rows (see `MediaServerApi`); the server is
/// then listed with the other sources (hold OK there to remove it).
class MediaServerScreen extends StatefulWidget {
  const MediaServerScreen({super.key});

  @override
  State<MediaServerScreen> createState() => _MediaServerScreenState();
}

class _MediaServerScreenState extends State<MediaServerScreen> {
  final _address = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _addressFocus = FocusNode();
  final _userFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _connectFocus = FocusNode();
  bool _connecting = false;

  /// Up/Down order of the form (fields keep the arrow keys, so they're
  /// moved by hand — same fix as ArchiveSourcesScreen._escapeLinkField).
  late final _order = [
    _addressFocus,
    _userFocus,
    _passwordFocus,
    _connectFocus
  ];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_escapeField);
    // TV: start on the first field (keyboard only on OK, TvTextFieldGate).
    if (context.read<AppPreferences>().isTelevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _addressFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_escapeField);
    for (final c in [_address, _user, _password]) {
      c.dispose();
    }
    for (final f in _order) {
      f.dispose();
    }
    super.dispose();
  }

  bool _escapeField(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final i = _order.indexWhere((f) => f.hasFocus);
    if (i < 0 || i == _order.length - 1) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _order[i + 1].requestFocus();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && i > 0) {
      _order[i - 1].requestFocus();
      return true;
    }
    return false;
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final address = _address.text.trim();
    final user = _user.text.trim();
    if (address.isEmpty || user.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Enter the server address and your user name.'))));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final service = context.read<ArchiveService>();
    setState(() => _connecting = true);
    String? error;
    String? name;
    try {
      name = (await service.addMediaServer(address, user, _password.text)).name;
    } on MediaServerLoginException {
      error = tr('Wrong user name or password.');
    } on MediaServerNoLibraryException {
      error = tr('This account has no movie or TV library.');
    } catch (_) {
      error = tr("Couldn't find a Jellyfin or Emby server at that address.");
    }
    if (!mounted) return;
    setState(() => _connecting = false);
    if (error != null) {
      messenger.showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red.shade900));
      return;
    }
    messenger.showSnackBar(
        SnackBar(content: Text(tr('{name} added.', {'name': name}))));
    navigator.pop();
  }

  Widget _field({
    required TextEditingController controller,
    required FocusNode focus,
    required FocusNode next,
    required String label,
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
    VoidCallback? onDone,
  }) =>
      TvTextFieldGate(
        focusNode: focus,
        builder: (context, readOnly) => TextField(
          controller: controller,
          focusNode: focus,
          readOnly: readOnly,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: keyboard,
          textInputAction:
              onDone == null ? TextInputAction.next : TextInputAction.done,
          // IME Next/Done moves focus; open the next keyboard only on OK because some
          // systems also emit the submission event when Back closes input.
          onSubmitted: (_) {
            next.requestFocus();
            onDone?.call();
          },
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: tr('Connect Jellyfin / Emby'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(
              'Sign in to your own Jellyfin or Emby server: its movie and TV libraries show up in the Media Hub. Files play as they are stored on the server (no transcoding).')),
          const SizedBox(height: 16),
          _field(
            controller: _address,
            focus: _addressFocus,
            next: _userFocus,
            label: tr('Server address'),
            hint: 'http://192.0.2.10:8096',
            keyboard: TextInputType.url,
          ),
          const SizedBox(height: 12),
          _field(
            controller: _user,
            focus: _userFocus,
            next: _passwordFocus,
            label: tr('User name'),
          ),
          const SizedBox(height: 12),
          _field(
            controller: _password,
            focus: _passwordFocus,
            next: _connectFocus,
            label: tr('Password'),
            obscure: true,
            onDone: _connect,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              focusNode: _connectFocus,
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.dns_outlined),
              label: Text(tr('Connect')),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr('Your password is only sent to your server. iptv-app keeps the sign-in token the server gives back, not the password.'),
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ),
    );
  }
}
