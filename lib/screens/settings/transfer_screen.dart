import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/catalog_database.dart';
import '../../services/cloud_transfer.dart';
import '../../services/device_transfer.dart';
import '../../services/epg_service.dart';
import '../../services/storage_service.dart';
import '../../utils/time_format.dart';
import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../l10n/l10n.dart';

/// Settings > Transfer to another device — see `device_transfer.dart`.
/// "Include Archive tab data" (on by default) decides whether Send takes
/// the Archive sources and their watch progress along
/// (`StorageService.exportForTransfer`).
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  bool _includeArchive = true;

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: tr('Transfer to another device'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Text(
                tr('Copies your playlists, favorites, hidden groups, profiles, watch progress and settings to another device. On the same Wi-Fi it goes straight across; anywhere else it goes through an encrypted upload only the code can open. Channels, movies and the guide download again on the new device.'),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            TvMenuTile(
              autofocus: true,
              icon: Icons.upload,
              title: tr('Send from this device'),
              subtitle: tr('Shows a code to enter on the other device'),
              // Internet transfer is the main path; the same-Wi-Fi one is a
              // link on that screen (works without our relay).
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      _CloudSendScreen(includeArchive: _includeArchive))),
            ),
            TvMenuTile(
              icon: _includeArchive
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              title: tr('Include Media Hub tab data'),
              subtitle: _includeArchive
                  ? tr(
                      'Media Hub sources and their watch progress are sent too')
                  : tr('The other device keeps its own Media Hub sources'),
              trailing: const SizedBox.shrink(),
              onTap: () => setState(() => _includeArchive = !_includeArchive),
            ),
            TvMenuTile(
              icon: Icons.download,
              title: tr('Receive on this device'),
              subtitle:
                  tr('Replaces this device\'s setup with the other one\'s'),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _ReceiveScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- send

class _SendScreen extends StatefulWidget {
  const _SendScreen({required this.includeArchive});

  final bool includeArchive;

  @override
  State<_SendScreen> createState() => _SendScreenState();
}

enum _SendState { starting, waiting, sent, closed, noNetwork }

class _SendScreenState extends State<_SendScreen> {
  TransferSendSession? _session;
  _SendState _state = _SendState.starting;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final session = TransferSendSession(context
        .read<StorageService>()
        .exportForTransfer(includeArchive: widget.includeArchive));
    _session = session;
    try {
      await session.start();
    } on TransferException {
      if (mounted) setState(() => _state = _SendState.noNetwork);
      return;
    }
    if (!mounted) return;
    setState(() => _state = _SendState.waiting);
    try {
      await session.sent;
      if (mounted) setState(() => _state = _SendState.sent);
    } on TransferException {
      if (mounted) setState(() => _state = _SendState.closed);
    }
  }

  @override
  void dispose() {
    unawaited(_session?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = _session?.code;
    final Widget body = switch (_state) {
      _SendState.starting => const CircularProgressIndicator(),
      _SendState.noNetwork => _message(Icons.wifi_off,
          tr('This device isn\'t on a Wi-Fi or wired home network.')),
      _SendState.sent => _message(
          Icons.check_circle, tr('Sent! Finish on the other device.'),
          color: scheme.primary),
      _SendState.closed => _message(Icons.timer_off,
          tr('This code has expired. Go back and start again.')),
      _SendState.waiting => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                tr('On the other device, open Settings > Transfer to another device > Receive, and enter:'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 20),
            Text(
              code == null
                  ? ''
                  : '${code.substring(0, 3)} ${code.substring(3, 6)} ${code.substring(6)}',
              style: TextStyle(
                  color: scheme.primary,
                  fontSize: 56,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4),
            ),
            const SizedBox(height: 12),
            Text(
                tr('This device: {address} · the code works once, for 10 minutes',
                    {'address': _session?.address ?? ''}),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 24),
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
    };
    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: tr('Send from this device'),
        body: Center(
          child: Padding(padding: const EdgeInsets.all(24), child: body),
        ),
      ),
    );
  }
}

Widget _message(IconData icon, String text, {Color? color}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 56, color: color ?? Colors.white54),
        const SizedBox(height: 14),
        Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 18)),
      ],
    );

// ------------------------------------------------------ send (internet)

class _CloudSendScreen extends StatefulWidget {
  const _CloudSendScreen({required this.includeArchive});

  final bool includeArchive;

  @override
  State<_CloudSendScreen> createState() => _CloudSendScreenState();
}

class _CloudSendScreenState extends State<_CloudSendScreen> {
  late final StorageService _storage = context.read<StorageService>();

  /// The live upload, or null = pick a duration.
  CloudTransfer? _upload;
  bool _busy = false;
  String? _error;
  final FocusNode _doneNode = FocusNode();
  final FocusNode _againNode = FocusNode();
  final FocusNode _deleteNode = FocusNode();
  final FocusNode _firstLifetimeNode = FocusNode();

  @override
  void initState() {
    super.initState();
    final saved = CloudTransfer.fromJson(_storage.getCloudTransfer());
    if (saved != null && saved.isActive) {
      _upload = saved;
    } else if (saved != null) {
      unawaited(_storage.setCloudTransfer(null));
    }
  }

  @override
  void dispose() {
    _doneNode.dispose();
    _againNode.dispose();
    _deleteNode.dispose();
    _firstLifetimeNode.dispose();
    super.dispose();
  }

  String _errorText(TransferError kind) => switch (kind) {
        TransferError.tooBig => tr(
            'This setup is too big to upload. Use the same-Wi-Fi transfer instead.'),
        _ => tr(
            'Couldn\'t reach the iptv-app transfer server. Check this device\'s internet connection and try again.'),
      };

  Future<void> _send(Duration lifetime) async {
    if (_busy) return;
    final previous =
        _upload ?? CloudTransfer.fromJson(_storage.getCloudTransfer());
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final upload = await uploadCloudTransfer(
          _storage.exportForTransfer(includeArchive: widget.includeArchive),
          lifetime);
      await _storage.setCloudTransfer(upload.toJson());
      // The old upload would otherwise stay readable until it expires.
      if (previous != null && previous.isActive) {
        unawaited(deleteCloudTransfer(previous.code).catchError((_) {}));
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _upload = upload;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _doneNode.requestFocus();
      });
    } on TransferException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errorText(e.kind);
      });
    }
  }

  Future<void> _delete() async {
    final upload = _upload;
    if (upload == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await deleteCloudTransfer(upload.code);
      await _storage.setCloudTransfer(null);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _upload = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _firstLifetimeNode.requestFocus();
      });
    } on TransferException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errorText(e.kind);
      });
    }
  }

  void _uploadAgain() {
    setState(() {
      _upload = null;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstLifetimeNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: tr('Send from this device'),
        body: _upload == null ? _chooser(context) : _active(context),
      ),
    );
  }

  Widget _chooser(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String label(Duration d) => d.inDays >= 1
        ? trPlural(d.inDays, '{n} day', '{n} days')
        : trPlural(d.inHours, '{n} hour', '{n} hours');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Text(
            tr('Your setup is encrypted on this device and uploaded. Any device that enters the code can copy it until it expires — even with this device turned off. How long should it stay available?'),
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        for (final (i, lifetime) in kCloudTransferLifetimes.indexed)
          TvMenuTile(
            focusNode: i == 0 ? _firstLifetimeNode : null,
            autofocus: i == 0,
            icon: Icons.timer_outlined,
            title: label(lifetime),
            onTap: () => _send(lifetime),
          ),
        SizedBox(
          height: 56,
          child: Center(
            child: _busy
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text(tr('Encrypting and uploading…'),
                        style: const TextStyle(color: Colors.white70)),
                  ])
                : _error == null
                    ? null
                    : Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error, fontSize: 14)),
          ),
        ),
        TvMenuTile(
          icon: Icons.wifi,
          title: tr('Both devices on the same Wi-Fi?'),
          subtitle: tr('Send directly, without uploading'),
          onTap: () {
            if (_busy) return;
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    _SendScreen(includeArchive: widget.includeArchive)));
          },
        ),
      ],
    );
  }

  Widget _active(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final upload = _upload!;
    final until = TimeFormat.dayTime(upload.expires);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                tr('On the other device, open Settings > Transfer to another device > Receive, and enter:'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 20),
            Text(
              formatCloudCode(upload.code),
              style: TextStyle(
                  color: scheme.primary,
                  fontSize: 44,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3),
            ),
            const SizedBox(height: 12),
            Text(tr('Works on any network until {time}', {'time': until}),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 6),
            Text(
                tr('Anyone with this code can copy your setup, playlist logins included. Changes made after this upload aren\'t in it — upload again to update it.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
            SizedBox(
              height: 40,
              child: Center(
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _error == null
                        ? null
                        : Text(_error!,
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: scheme.error, fontSize: 14)),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ChoiceButton(
                  focusNode: _doneNode,
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr('Done')),
                ),
                const SizedBox(width: 16),
                _ChoiceButton(
                  focusNode: _againNode,
                  onPressed: _busy ? null : _uploadAgain,
                  child: Text(tr('Upload again')),
                ),
                const SizedBox(width: 16),
                _ChoiceButton(
                  focusNode: _deleteNode,
                  onPressed: _busy ? null : _delete,
                  child: Text(tr('Delete now')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- receive

class _ReceiveScreen extends StatefulWidget {
  const _ReceiveScreen();

  @override
  State<_ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<_ReceiveScreen> {
  /// 9 digits = same Wi-Fi (`device_transfer.dart`), 16 = internet
  /// (`cloud_transfer.dart`).
  static const _codeLength = 9;
  static const _codeKeys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['back', '0', 'ok'],
  ];

  /// Address mode adds a dot key.
  static const _addressKeys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['.', '0', 'back', 'ok'],
  ];

  String _code = '';

  /// Non-null = the user is typing the sender's address (a home with two
  /// routers, where the code's short address can't work — see
  /// `receiveTransfer`'s `host`).
  String? _address;
  bool _busy = false;
  String? _error;
  bool _offerAddress = false;
  Map<String, Object?>? _received;
  late final List<List<FocusNode>> _nodes = [
    for (final row in _addressKeys) [for (final _ in row) FocusNode()],
  ];
  late final FocusNode _replaceNode = FocusNode();
  late final FocusNode _cancelNode = FocusNode();
  late final FocusNode _addressOptionNode = FocusNode();

  List<List<String>> get _keys => _address == null ? _codeKeys : _addressKeys;

  bool get _isCloudCode => _code.length > _codeLength;

  bool get _canSubmit => _address == null
      ? _code.length == _codeLength || _code.length == kCloudCodeLength
      : RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(_address!);

  @override
  void dispose() {
    for (final row in _nodes) {
      for (final n in row) {
        n.dispose();
      }
    }
    _replaceNode.dispose();
    _cancelNode.dispose();
    _addressOptionNode.dispose();
    super.dispose();
  }

  void _type(String key) {
    if (_busy || _received != null) return;
    setState(() {
      _error = null;
      final address = _address;
      if (key == 'ok') {
        unawaited(_fetch());
      } else if (address != null) {
        if (key == 'back') {
          if (address.isNotEmpty) {
            _address = address.substring(0, address.length - 1);
          }
        } else if (address.length < 15) {
          _address = address + key;
        }
      } else if (key == 'back') {
        if (_code.isNotEmpty) _code = _code.substring(0, _code.length - 1);
      } else if (key != '.' && _code.length < kCloudCodeLength) {
        _code += key;
      }
    });
  }

  void _startAddressEntry() {
    setState(() {
      _address = '';
      _error = null;
      _offerAddress = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes[0][0].requestFocus();
    });
  }

  Future<void> _fetch() async {
    final cloud = _code.length == kCloudCodeLength;
    if (!_canSubmit || (_code.length != _codeLength && !cloud) || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _offerAddress = false;
    });
    try {
      final values = cloud
          ? await downloadCloudTransfer(_code)
          : await receiveTransfer(_code, host: _address);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _received = values;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _cancelNode.requestFocus();
      });
    } on TransferException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _offerAddress =
            e.kind == TransferError.unreachable && _address == null && !cloud;
        _error = switch (e.kind) {
          TransferError.noNetwork =>
            tr('This device isn\'t on a Wi-Fi or wired home network.'),
          TransferError.unreachable when cloud => tr(
              'Couldn\'t reach the iptv-app transfer server. Check this device\'s internet connection and try again.'),
          TransferError.notFound || TransferError.tooBig => tr(
              'Nothing was found for that code. Check it — the upload may also have expired or been deleted.'),
          TransferError.unreachable => tr(
              'Couldn\'t find the other device. Check the code, and that both devices are on the same Wi-Fi with the code still showing.'),
          TransferError.wrongCode =>
            tr('That code isn\'t right. Check it on the other device.'),
          TransferError.closed => tr(
              'That code has expired or was already used. Start again on the other device.'),
          TransferError.invalid =>
            tr('The transfer didn\'t go through. Try again.'),
        };
      });
    }
  }

  Future<void> _apply() async {
    final values = _received;
    if (values == null) return;
    setState(() => _busy = true);
    final storage = context.read<StorageService>();
    final catalogDb = context.read<CatalogDatabase>();
    final epg = context.read<EpgService>();
    // Old caches first (clearCache also drops watch positions, which the
    // import then brings back from the other device).
    await storage.clearCache();
    await epg.clearAll();
    await catalogDb.clearAll();
    await storage.importForTransfer(values);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(tr('Transfer complete')),
        content: Text(tr(
            'iptv-app will close now. Open it again to load your playlists.')),
        actions: [
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('OK')),
          ),
        ],
      ),
    );
    // Every service still holds the old setup in memory; a fresh start is
    // the only clean way to load the new one.
    exit(0);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final digit = _digitOf(key);
    if (digit != null) {
      _type(digit);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _type('back');
      return KeyEventResult.handled;
    }
    if (_address != null &&
        (key == LogicalKeyboardKey.period ||
            key == LogicalKeyboardKey.numpadDecimal)) {
      _type('.');
      return KeyEventResult.handled;
    }
    if (_received != null) {
      // The summary's two buttons, explicitly: focus could be left on
      // nothing once the keypad was swapped out, and default traversal
      // then had nowhere to start (stuck on
      // "Ready to copy").
      if (key == LogicalKeyboardKey.arrowLeft) {
        _cancelNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _replaceNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        if (!_cancelNode.hasFocus && !_replaceNode.hasFocus) {
          _cancelNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_addressOptionNode.hasFocus) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _nodes[_keys.length - 1][0].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // Move explicitly between grid positions rather than relying on geometric focus
    // traversal.
    final dir = switch (key) {
      LogicalKeyboardKey.arrowUp => (-1, 0),
      LogicalKeyboardKey.arrowDown => (1, 0),
      LogicalKeyboardKey.arrowLeft => (0, -1),
      LogicalKeyboardKey.arrowRight => (0, 1),
      _ => null,
    };
    if (dir == null) return KeyEventResult.ignored;
    final keys = _keys;
    for (var r = 0; r < keys.length; r++) {
      for (var c = 0; c < keys[r].length; c++) {
        if (_nodes[r][c].hasFocus) {
          if (r == keys.length - 1 && dir.$1 == 1 && _offerAddress) {
            _addressOptionNode.requestFocus();
            return KeyEventResult.handled;
          }
          final nr = (r + dir.$1).clamp(0, keys.length - 1);
          final nc = (c + dir.$2).clamp(0, keys[nr].length - 1);
          _nodes[nr][nc].requestFocus();
          return KeyEventResult.handled;
        }
      }
    }
    _nodes[0][0].requestFocus();
    return KeyEventResult.handled;
  }

  static String? _digitOf(LogicalKeyboardKey key) {
    const digits = [
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    const numpad = [
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
      LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ];
    var i = digits.indexOf(key);
    if (i < 0) i = numpad.indexOf(key);
    return i < 0 ? null : '$i';
  }

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: tr('Receive on this device'),
        body: Focus(
          // Only listens to keys bubbling up from the keys/buttons; never
          // takes focus itself (it could swallow it when the keypad goes).
          canRequestFocus: false,
          onKeyEvent: _onKey,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: _received != null ? _summary(context) : _entry(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 16 slots (4-4-4-4) — the internet code is the main one; a 9-digit
    // Wi-Fi code just fills part of it. Address entry (Wi-Fi only) shows the
    // code 3-3-3 like that sender does.
    final String codeText;
    if (_address == null || _isCloudCode) {
      codeText = formatCloudCode(_code.padRight(kCloudCodeLength, '·'));
    } else {
      final shown = _code.padRight(_codeLength, '·');
      codeText =
          '${shown.substring(0, 3)} ${shown.substring(3, 6)} ${shown.substring(6)}';
    }
    final address = _address;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
            address == null
                ? tr('Enter the code shown on the other device')
                : tr(
                    'Enter the address shown under the code on the other device (This device: …)'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 16)),
        if (address == null)
          Text(tr('9 digits on the same Wi-Fi, 16 digits over the internet'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
        const SizedBox(height: 16),
        Text(
          address == null ? codeText : (address.isEmpty ? '_' : address),
          style: TextStyle(
              color: scheme.primary,
              fontSize: address == null ? 36 : 44,
              fontWeight: FontWeight.w800,
              letterSpacing: 4),
        ),
        if (address != null)
          Text(tr('Code: {code}', {'code': codeText}),
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: _busy
              ? const Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : _error == null
                  ? null
                  : Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, fontSize: 14)),
        ),
        const SizedBox(height: 8),
        for (final (r, row) in _keys.indexed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (c, key) in row.indexed)
                Padding(
                  padding: const EdgeInsets.all(5),
                  child: _KeyButton(
                    focusNode: _nodes[r][c],
                    autofocus: r == 0 && c == 0,
                    label: key,
                    enabled: !_busy && (key != 'ok' || _canSubmit),
                    onPressed: () => _type(key),
                  ),
                ),
            ],
          ),
        if (_offerAddress) ...[
          const SizedBox(height: 12),
          TextButton.icon(
            focusNode: _addressOptionNode,
            icon: const Icon(Icons.lan_outlined),
            label: Text(tr('Type the address instead')),
            onPressed: _startAddressEntry,
          ),
        ],
      ],
    );
  }

  Widget _summary(BuildContext context) {
    final values = _received!;
    int jsonListLength(String key) {
      final tagged = values[key];
      if (tagged is! Map) return 0;
      try {
        final v = jsonDecode(tagged['v'] as String);
        return v is List ? v.length : 0;
      } catch (_) {
        return 0;
      }
    }

    var favorites = 0;
    for (final e in values.entries) {
      final isFav = e.key.startsWith(AppConstants.keyFavorites) ||
          e.key.startsWith(AppConstants.keyFavoriteSeries);
      final tagged = e.value;
      if (isFav && tagged is Map && tagged['v'] is List) {
        favorites += (tagged['v'] as List).length;
      }
    }
    final playlists = jsonListLength(AppConstants.keyPlaylists);
    final profiles = jsonListLength(AppConstants.keyViewerProfiles);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.devices,
            size: 52, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(tr('Ready to copy'),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          [
            trPlural(playlists, '{n} playlist', '{n} playlists'),
            trPlural(
                profiles < 1 ? 1 : profiles, '{n} profile', '{n} profiles'),
            trPlural(favorites, '{n} favorite', '{n} favorites'),
          ].join(' · '),
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
        const SizedBox(height: 16),
        Text(
          tr('This replaces the playlists, favorites and settings on this device.'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Same look for both — only the focused one fills (a
            // filled Replace read as "selected" while Cancel had focus).
            _ChoiceButton(
              focusNode: _cancelNode,
              autofocus: true,
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: Text(tr('Cancel')),
            ),
            const SizedBox(width: 16),
            _ChoiceButton(
              focusNode: _replaceNode,
              onPressed: _busy ? null : _apply,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('Replace my data')),
            ),
          ],
        ),
      ],
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.focusNode,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.autofocus = false,
  });

  final FocusNode focusNode;
  final String label;
  final bool enabled;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final child = switch (label) {
      'back' => const Icon(Icons.backspace_outlined),
      'ok' => const Icon(Icons.check),
      _ => Text(label,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
    };
    return SizedBox(
      width: 76,
      height: 58,
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, _) => OutlinedButton(
          focusNode: focusNode,
          autofocus: autofocus,
          onPressed: enabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: focusNode.hasFocus
                ? scheme.primary.withValues(alpha: 0.3)
                : null,
            side: BorderSide(
                color: focusNode.hasFocus ? scheme.primary : Colors.white24,
                width: focusNode.hasFocus ? 2.5 : 1),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Outlined until focused, then `ModeButton`'s focus look (dark diagonal
/// sheen, accent border/text, soft glow) — a solid accent fill read as
/// pastel on a real TV.
class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.focusNode,
    required this.onPressed,
    required this.child,
    this.autofocus = false,
  });

  final FocusNode focusNode;
  final VoidCallback? onPressed;
  final Widget child;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, _) {
        final focused = focusNode.hasFocus;
        // The Container is always there (only its decoration changes) so
        // the button's FocusNode never changes ancestors between builds.
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: focused
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.black,
                      Color.lerp(Colors.black, scheme.primaryContainer, 0.4)!,
                      Colors.black,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  )
                : null,
            boxShadow: focused
                ? [
                    BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.45),
                        blurRadius: 14)
                  ]
                : const [],
          ),
          child: OutlinedButton(
            focusNode: focusNode,
            autofocus: autofocus,
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: focused ? scheme.primary : Colors.white,
              backgroundColor: Colors.transparent,
              overlayColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              side: BorderSide(
                  color: focused ? scheme.primary : Colors.white38,
                  width: focused ? 2 : 1),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            ),
            child: child,
          ),
        );
      },
    );
  }
}
