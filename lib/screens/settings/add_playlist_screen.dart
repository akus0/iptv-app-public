import '../../widgets/settings_navigation.dart';
import '../../services/app_preferences.dart';
import '../../services/stalker_portal_service.dart';
import '../../models/playlist_failure.dart';
import '../../widgets/playlist_failure_dialog.dart';
import '../../utils/interface_colors.dart';
import '../../widgets/playlist_organisation_picker.dart';
import '../../widgets/playlist_user_agent_picker.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/playlist_profile.dart';
import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../utils/constants.dart';
import '../../utils/smart_add_parser.dart';
import '../../utils/xtream.dart';
import '../../services/phone_pairing_service.dart';
import '../../widgets/phone_pair_panel.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/playlist_content_picker.dart';
import '../../l10n/l10n.dart';

/// Scroll focused controls into view when the playlist form exceeds the viewport, including
/// buttons that do not scroll themselves.
void _ensureVisible(BuildContext context) {
  if (context.read<AppPreferences>().isTelevision) {
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    return;
  }
  Scrollable.ensureVisible(context,
      duration: const Duration(milliseconds: 150), alignment: 0.5);
}

/// Playlist source configuration — M3U URL or Xtream Codes login — plus the
/// independent Live TV, Movies and Series choices for Xtream accounts.
class AddPlaylistScreen extends StatefulWidget {
  const AddPlaylistScreen({super.key, this.editPlaylistId});

  /// Set when opened from `PlaylistManagerScreen`'s detail panel to edit
  /// an existing playlist's login details, instead of adding a new one —
  /// the whole reason this screen takes an *optional* id rather than being
  /// two separate screens: it's the exact same form either way, just
  /// prefilled from a `PlaylistProfile` instead of starting blank, and
  /// saving updates that profile in place instead of creating a new one.
  final String? editPlaylistId;

  @override
  State<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends State<AddPlaylistScreen> {
  late String
      _mode; // 'm3u', 'xtream', or 'smart'/'phone' (UI-only tabs — see _save)
  late TextEditingController _nameController;
  late TextEditingController _m3uController;
  late TextEditingController _epgController;
  late TextEditingController _xtreamServerController;
  late TextEditingController _xtreamUsernameController;
  late TextEditingController _xtreamPasswordController;

  /// Smart Add: paste-and-parse for the common case of copying a
  /// provider's whole welcome message off a phone and typing it in via
  /// the Fire Stick's QR-code-to-phone-keyboard relay — one paste instead
  /// of three separate fields to hunt values out of by hand. See
  /// [parseSmartAddText]'s doc comment for the parsing approach.
  final _smartPasteController = TextEditingController();

  /// Parsed server candidates ordered by confidence. Let the user choose when copied text
  /// produces multiple plausible URLs.
  List<String> _smartServerCandidates = [];
  String? _smartSelectedServer;

  /// Whether Smart Add has parsed its pasted text yet — before this, the
  /// tab shows just the paste box; after, it shows the candidate picker
  /// plus the same server/username/password fields the Xtream tab uses
  /// (reusing those controllers directly, so there's exactly one place
  /// that actually gets saved regardless of which tab filled it in).
  bool _smartParsed = false;

  /// The system keyboard may consume D-pad arrows. Use explicit focus nodes and the IME
  /// Next/Done actions to move between fields.
  final _nameFocus = FocusNode();
  final _m3uFocus = FocusNode();
  final _epgFocus = FocusNode();
  final _serverFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _portalAdvancedFocus = FocusNode();
  final _portalVisibilityFocus = FocusNode();
  final _contentFocus = FocusNode();
  final _userAgentFocus = FocusNode();
  final _organisationFocus = FocusNode();

  bool get _stacked {
    final size = MediaQuery.sizeOf(context);
    return size.width < 900 ||
        (!context.read<AppPreferences>().isTelevision && size.height < 600);
  }

  void _focusControl(FocusNode node, {bool up = false}) =>
      FocusTraversalPolicy.defaultTraversalRequestFocusCallback(node,
          alignmentPolicy: up
              ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : ScrollPositionAlignmentPolicy.keepVisibleAtEnd);

  List<FocusNode> get _options => [
        if (_mode == 'stalker' ||
            _mode == 'xtream' ||
            (_mode == 'smart' && _smartParsed)) ...[
          _contentFocus,
        ],
        _userAgentFocus,
        _organisationFocus,
      ];

  /// Focus nodes for the playlist-source modes, including the Left-arrow destination and
  /// initial active mode.
  final _modeM3uFocus = FocusNode();
  final _modeXtreamFocus = FocusNode();
  final _modePortalFocus = FocusNode();
  final _modeSmartFocus = FocusNode();
  final _modePhoneFocus = FocusNode();

  /// "From my phone"'s Wi-Fi/relay switch — the Right-arrow target into
  /// the middle pane in that mode, which has no Name field of its own (the
  /// phone form carries the name).
  final _phoneToggleFocus = FocusNode();

  FocusNode get _currentModeListFocus => switch (_mode) {
        'xtream' => _modeXtreamFocus,
        'stalker' => _modePortalFocus,
        'smart' => _modeSmartFocus,
        'phone' => _modePhoneFocus,
        _ => _modeM3uFocus,
      };

  /// Where Down/`onSubmitted` out of the Name field lands — the first
  /// field of whichever mode is currently selected. Smart Add has two
  /// different "firsts" depending on stage: the paste box before it's
  /// been parsed, the server field once it has (same fields the Xtream
  /// tab uses from then on).
  FocusNode get _firstModeFieldFocus => switch (_mode) {
        'm3u' => _m3uFocus,
        'stalker' => _portalNodes['portalUrl']!,
        'smart' => _smartParsed ? _serverFocus : _smartPasteFocus,
        'phone' => _phoneToggleFocus,
        _ => _serverFocus,
      };

  /// Separate focus scopes for the mode list, fields and status panel give Left/Right a
  /// predictable destination.
  final _modeScope = FocusScopeNode(
      debugLabel: 'add-playlist-modes',
      directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope);
  final _fieldsScope = FocusScopeNode(
      debugLabel: 'add-playlist-fields',
      directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope);
  final _statusScope = FocusScopeNode(
      debugLabel: 'add-playlist-status',
      directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope);

  /// The paste field submits to Parse through the keyboard action. It has no sibling text
  /// fields, so only a forward escape target is needed.
  final _smartPasteFocus = FocusNode();
  final _parseButtonFocus = FocusNode();

  /// Target for the last field's "Done" action in each mode — landing on
  /// `.unfocus()` moved focus to the ambient scope rather than anywhere
  /// specific, which then made the *next* Down press restart from the
  /// top of the screen instead of continuing to Add Playlist. Requesting
  /// this node directly instead gives an obvious, specific landing spot.
  final _addButtonFocus = FocusNode();

  /// Remember the last focused field: dismissing some system keyboards clears Flutter focus,
  /// but subsequent navigation still needs a valid escape origin.
  FocusNode? _lastFocusedTextField;

  void _trackTextFieldFocus() {
    for (final node in _allTrackedFields) {
      if (node.hasFocus) {
        _lastFocusedTextField = node;
        return;
      }
    }
  }

  /// Guards the *whole* add flow, not just the network fetch —
  /// `playlist.isLoading` goes back to false as soon as the fetch itself
  /// finishes, while the "download everything or choose groups" dialog is
  /// still open and the warm-up is only about to start. Tapping "Add
  /// Playlist" again in that window re-ran the whole thing a second time,
  /// which is how two overlapping warm-up passes happened.
  bool _saving = false;

  /// The profile being edited, or null when adding a brand-new playlist —
  /// resolved once in [initState] rather than re-looked-up on every
  /// build, since `_save` needs the *original* profile's `sortOrder`/
  /// `createdAt` even after the user's edits change every other field.
  PlaylistProfile? _editingProfile;
  String _categoryLayout = 'organised';
  String _userAgent = '';
  bool _includeLive = true, _includeMovies = true, _includeSeries = true;

  @override
  void initState() {
    super.initState();
    final editId = widget.editPlaylistId;
    PlaylistProfile? existing;
    if (editId != null) {
      for (final p in context.read<PlaylistManager>().profiles) {
        if (p.id == editId) {
          existing = p;
          break;
        }
      }
    }
    _editingProfile = existing;
    _userAgent = existing?.userAgent ?? '';
    _categoryLayout = existing?.categoryLayout ?? 'organised';
    _includeLive = existing?.includeLive ?? true;
    _includeMovies = existing?.includeMovies ?? true;
    _includeSeries = existing?.includeSeries ?? true;

    _mode = existing?.mode ?? 'm3u';
    for (final key in _portalLabels.keys) {
      _portalControllers[key]!.text = existing?.toJson()[key] as String? ?? '';
    }
    _portalAdvanced = _portalLabels.keys
        .skip(2)
        .any((k) => _portalControllers[k]!.text.isNotEmpty);
    _nameController = TextEditingController(text: existing?.name ?? '');
    _m3uController = TextEditingController(text: existing?.m3uUrl ?? '');
    // For an Xtream profile, epgUrl is usually just the auto-derived
    // xmltv.php link (see _save) rather than something the user actually
    // typed in — pre-filling this field with that would make a later
    // credential edit (server/username/password) silently keep the *old*
    // auto-derived URL instead of re-deriving it, since a non-empty field
    // here is taken as a deliberate override. Only genuinely-custom EPG
    // URLs (saved because they didn't match what today's credentials
    // would derive) get pre-filled.
    String? existingAutoEpg;
    if (existing != null && existing.mode == 'xtream') {
      try {
        existingAutoEpg = XtreamHelper.buildEpgUrl(
            server: existing.xtreamServer ?? '',
            username: existing.xtreamUsername ?? '',
            password: existing.xtreamPassword ?? '');
      } on FormatException {
        // Keep an incomplete saved profile editable so its address can be fixed.
      }
    }
    _epgController = TextEditingController(
        text: existing?.epgUrl == existingAutoEpg
            ? ''
            : (existing?.epgUrl ?? ''));
    _xtreamServerController =
        TextEditingController(text: existing?.xtreamServer ?? '');
    _xtreamUsernameController =
        TextEditingController(text: existing?.xtreamUsername ?? '');
    _xtreamPasswordController =
        TextEditingController(text: existing?.xtreamPassword ?? '');
    HardwareKeyboard.instance.addHandler(_handleFieldEscapeKey);
    for (final node in _allTrackedFields) {
      node.addListener(_trackTextFieldFocus);
    }
    // Start on the active mode instead of relying on traversal across separate focus scopes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.read<AppPreferences>().isTelevision) {
        _currentModeListFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleFieldEscapeKey);
    for (final node in _allTrackedFields) {
      node.removeListener(_trackTextFieldFocus);
    }
    _nameController.dispose();
    _m3uController.dispose();
    _epgController.dispose();
    _xtreamServerController.dispose();
    _xtreamUsernameController.dispose();
    _xtreamPasswordController.dispose();
    _smartPasteController.dispose();
    _nameFocus.dispose();
    _m3uFocus.dispose();
    _epgFocus.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _portalAdvancedFocus.dispose();
    _portalVisibilityFocus.dispose();
    _contentFocus.dispose();
    _userAgentFocus.dispose();
    _organisationFocus.dispose();
    _addButtonFocus.dispose();
    _smartPasteFocus.dispose();
    _parseButtonFocus.dispose();
    _modeM3uFocus.dispose();
    _modeXtreamFocus.dispose();
    _modePortalFocus.dispose();
    for (final c in _portalControllers.values) {
      c.dispose();
    }
    for (final n in _portalNodes.values) {
      n.dispose();
    }
    _modeSmartFocus.dispose();
    _modePhoneFocus.dispose();
    _phoneToggleFocus.dispose();
    _modeScope.dispose();
    _fieldsScope.dispose();
    _statusScope.dispose();
    super.dispose();
  }

  // Buttons use the Focus handler; editable fields also need the raw handler.
  // Deduplicate their shared event so a single press cannot advance twice.
  KeyEvent? _handledNavigationEvent;

  /// Follow the visible form while navigating; the keyboard owns editing arrows.
  bool _handleFieldEscapeKey(KeyEvent event) {
    if (identical(event, _handledNavigationEvent)) return true;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (TvTextFieldGate.isEditing(FocusManager.instance.primaryFocus)) {
      return false;
    }

    if (event.logicalKey != LogicalKeyboardKey.arrowDown &&
        event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return false;
    }

    if (!context.read<AppPreferences>().isTelevision) return false;
    final current = FocusManager.instance.primaryFocus;
    final controls = [..._allTrackedFields, ..._options, _addButtonFocus];
    if (current != null &&
        current is! FocusScopeNode &&
        !controls.contains(current)) {
      return false;
    }
    final effective =
        controls.contains(current) ? current : _lastFocusedTextField;

    final fields = switch (_mode) {
      'm3u' => [_nameFocus, _m3uFocus, _epgFocus],
      'stalker' => [
          _nameFocus,
          for (final key in _portalLabels.keys)
            if (_portalAdvanced ||
                key == 'portalUrl' ||
                key == 'portalMac') ...[
              _portalNodes[key]!,
              if (key == 'portalPassword') _portalVisibilityFocus,
            ],
          _portalAdvancedFocus,
          _epgFocus
        ],
      'smart' => _smartParsed
          ? [
              _nameFocus,
              _serverFocus,
              _usernameFocus,
              _passwordFocus,
              _epgFocus
            ]
          : [_nameFocus, _smartPasteFocus, _parseButtonFocus],
      'phone' => <FocusNode>[],
      _ => [
          _nameFocus,
          _serverFocus,
          _usernameFocus,
          _passwordFocus,
          _epgFocus
        ],
    };
    // In the stacked layout, follow the visible form all the way through
    // content options to Save. The wide form keeps its side-to-side shortcuts.
    final sequence = [
      ...fields,
      if (_stacked && _mode != 'phone') ..._options,
      if (_mode != 'phone') _addButtonFocus,
    ];
    final index = sequence.indexOf(effective ?? _nameFocus);
    if (index < 0) return false;
    _handledNavigationEvent = event;
    final next =
        index + (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1);
    if (next < 0) {
      if (_stacked) _focusControl(_currentModeListFocus, up: true);
    } else if (next < sequence.length) {
      final target = sequence[next];
      if (target.canRequestFocus) {
        _focusControl(target,
            up: event.logicalKey == LogicalKeyboardKey.arrowUp);
      }
    }
    return true;
  }

  /// Every text field this screen's escape mechanism tracks, across every
  /// mode — used by [_handleFieldEscapeKey] to tell "a tracked field lost
  /// bare focus but is still the logical last-known one" apart from "focus
  /// moved somewhere this handler has no opinion about".
  List<FocusNode> get _allTrackedFields => [
        ..._portalNodes.values,
        _portalAdvancedFocus,
        _portalVisibilityFocus,
        _nameFocus,
        _smartPasteFocus,
        _parseButtonFocus,
        _m3uFocus,
        _epgFocus,
        _serverFocus,
        _usernameFocus,
        _passwordFocus
      ];

  /// Smart Add has no save path of its own — parsing just fills the same
  /// controllers the Xtream tab reads from, so from here on it's really an
  /// Xtream login, and is persisted/loaded as one.
  String get _effectiveMode => _mode == 'smart' ? 'xtream' : _mode;

  void _handleSmartParse() {
    final raw = _smartPasteController.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Paste some text first.'))),
      );
      return;
    }
    final result = parseSmartAddText(raw);
    if (result.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(tr("Couldn't find anything usable in that text."))),
      );
      return;
    }
    setState(() {
      _smartServerCandidates = result.serverCandidates;
      _smartSelectedServer = result.serverCandidates.isNotEmpty
          ? result.serverCandidates.first
          : null;
      _xtreamServerController.text = _smartSelectedServer ?? '';
      _xtreamUsernameController.text = result.username;
      _xtreamPasswordController.text = result.password;
      _smartParsed = true;
    });
  }

  /// "From my phone" delivered: fill the real tab's fields and switch to it,
  /// so the user reviews exactly what will be saved (nothing is added until
  /// they press Add Playlist themselves).
  void _applyPhoneResult(PairingResult r) {
    if (!mounted) return;
    setState(() {
      if (r.name.isNotEmpty) _nameController.text = r.name;
      _epgController.text = r.epgUrl;
      if (r.mode == 'm3u') {
        _mode = 'm3u';
        _m3uController.text = r.m3uUrl;
      } else if (r.mode == 'stalker') {
        _mode = 'stalker';
        for (final entry in _portalControllers.entries) {
          entry.value.text = r.portalDetails[entry.key] ?? '';
        }
        _portalAdvanced = _portalLabels.keys
            .where((key) => key != 'portalUrl' && key != 'portalMac')
            .any((key) => _portalControllers[key]!.text.isNotEmpty);
      } else {
        _mode = 'xtream';
        _xtreamServerController.text = r.server;
        _xtreamUsernameController.text = r.username;
        _xtreamPasswordController.text = r.password;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
            'Received from your phone — check the details, then press Add Playlist.'))));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_nameController.text.trim().isEmpty ? _nameFocus : _addButtonFocus)
          .requestFocus();
    });
  }

  void _resetSmartAdd() {
    setState(() {
      _smartParsed = false;
      _smartServerCandidates = [];
      _smartSelectedServer = null;
    });
  }

  static const _portalLabels = {
    'portalUrl': 'Portal URL',
    'portalMac': 'Registered MAC address',
    'portalUsername': 'Portal username — optional',
    'portalPassword': 'Portal password — optional',
    'portalSerial': 'Serial number — optional',
    'portalDeviceId': 'Device ID — optional',
    'portalDeviceId2': 'Device ID 2 — optional',
    'portalSignature': 'Signature — optional',
  };
  final _portalControllers = {
    for (final key in _portalLabels.keys) key: TextEditingController()
  };
  final _portalNodes = {for (final key in _portalLabels.keys) key: FocusNode()};
  bool _portalAdvanced = false;
  bool _portalPasswordVisible = false;

  List<Widget> _portalFields() {
    final fields = _portalLabels.entries
        .where((e) =>
            _portalAdvanced || e.key == 'portalUrl' || e.key == 'portalMac')
        .toList();
    return [
      const Text('Use the portal URL and MAC registered with your provider.',
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 12),
      for (var i = 0; i < fields.length; i++) ...[
        TvTextFieldGate(
            focusNode: _portalNodes[fields[i].key]!,
            builder: (context, readOnly) => TextField(
                  key: ValueKey(fields[i].key),
                  controller: _portalControllers[fields[i].key],
                  focusNode: _portalNodes[fields[i].key],
                  readOnly: readOnly,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: fields[i].key == 'portalPassword' &&
                      !_portalPasswordVisible,
                  keyboardType: fields[i].key == 'portalUrl'
                      ? TextInputType.url
                      : TextInputType.text,
                  decoration: InputDecoration(
                      labelText: fields[i].value,
                      suffixIcon: fields[i].key == 'portalPassword'
                          ? IconButton(
                              focusNode: _portalVisibilityFocus,
                              tooltip: _portalPasswordVisible
                                  ? 'Hide password'
                                  : 'Show password',
                              onPressed: () => setState(() =>
                                  _portalPasswordVisible =
                                      !_portalPasswordVisible),
                              icon: Icon(_portalPasswordVisible
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined))
                          : null,
                      border: const OutlineInputBorder(),
                      isDense: true),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => (i + 1 < fields.length
                          ? _portalNodes[fields[i + 1].key]!
                          : _epgFocus)
                      .requestFocus(),
                )),
        const SizedBox(height: 12),
      ],
      TextButton.icon(
          key: const ValueKey('portal-advanced'),
          focusNode: _portalAdvancedFocus,
          icon: Icon(_portalAdvanced ? Icons.expand_less : Icons.expand_more),
          onPressed: () {
            setState(() => _portalAdvanced = !_portalAdvanced);
            if (_portalAdvanced &&
                context.read<AppPreferences>().isTelevision) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _portalAdvancedFocus.hasFocus) {
                  _focusControl(_portalNodes['portalUsername']!, up: true);
                }
              });
            }
          },
          label: const Text('Additional provider details')),
      TvTextFieldGate(
          focusNode: _epgFocus,
          builder: (context, readOnly) => TextField(
              controller: _epgController,
              focusNode: _epgFocus,
              readOnly: readOnly,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'Custom EPG (XMLTV) URL — optional',
                  helperText: 'Uses the portal guide when left blank.',
                  border: OutlineInputBorder(),
                  isDense: true),
              onSubmitted: (_) => _addButtonFocus.requestFocus())),
    ];
  }

  String? _saveError;
  bool _failureDialogOpen = false;
  String? _pendingNewPlaylistId;
  final _saveStatusKey = GlobalKey();

  Future<void> _presentSaveFailure(
      PlaylistFailure failure, String source) async {
    if (!mounted ||
        _failureDialogOpen ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _failureDialogOpen = true;
    FocusScope.of(context).unfocus();
    PlaylistFailureAction? action;
    try {
      action = await showPlaylistFailureDialog(context,
          failure: failure, source: source);
    } finally {
      _failureDialogOpen = false;
    }
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (action == PlaylistFailureAction.retry) {
      await _save();
    } else if (action == PlaylistFailureAction.edit) {
      final focus = switch (source) {
        'xtream' => failure.reason == PlaylistFailureReason.access
            ? _usernameFocus
            : _serverFocus,
        'stalker' => _portalNodes['portalUrl']!,
        _ => _m3uFocus,
      };
      focus.requestFocus();
      if (focus.context != null) _ensureVisible(focus.context!);
    } else {
      _addButtonFocus.requestFocus();
    }
  }

  void _showSaveFeedback(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 72),
          content: Text(message)));
  }

  Future<void> _save() async {
    if (_saving || _failureDialogOpen) return;
    if (_mode == 'phone') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              tr('Scan the code with your phone and send the form first.'))));
      return;
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Playlist name is required.'))),
      );
      return;
    }
    var restoreSaveFocus = _addButtonFocus.hasFocus;
    var submitted = false;
    PlaylistFailure? failure;
    final source = _effectiveMode;
    var stage = PlaylistFailureStage.save;
    VoidCallback? focusListener;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_saving || !restoreSaveFocus) return;
      // Disabling Save moves focus. Remember that automatic fallback, but
      // respect any subsequent navigation while the provider is responding.
      FocusManager.instance.applyFocusChangesIfNeeded();
      final fallback = FocusManager.instance.primaryFocus;
      focusListener = () {
        if (FocusManager.instance.primaryFocus != fallback) {
          restoreSaveFocus = false;
        }
      };
      FocusManager.instance.addListener(focusListener!);
    });
    setState(() {
      _saving = true;
      _saveError = null;
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    try {
      final mode = _effectiveMode;
      final isEditing = _editingProfile != null;
      // Fixed, identifiable, generated once and never reused for the
      // lifetime of this playlist — every per-playlist prefs key, cache
      // file, and catalog-database row this playlist owns is namespaced
      // by this same id (see Channel.playlistId's doc comment).
      final playlistId = _editingProfile?.id ??
          DateTime.now().microsecondsSinceEpoch.toString();

      if (!mounted) return;
      final playlist = context.read<PlaylistManager>();
      final epg = context.read<EpgService>();

      String epgUrl;
      PlaylistProfile profile;

      if (mode == 'stalker') {
        T validate<T>(String field, T Function(String) parse) {
          try {
            return parse(_portalControllers[field]!.text);
          } on PortalException {
            _portalNodes[field]!.requestFocus();
            rethrow;
          }
        }

        final portal = _portalControllers['portalUrl']!.text.trim();
        validate('portalUrl', portalEndpoints);
        final mac = validate('portalMac', normalizePortalMac);
        if (!_includeLive && !_includeMovies && !_includeSeries) {
          throw const PortalException('Select at least one content type.');
        }
        epgUrl = _includeLive ? _epgController.text.trim() : '';
        profile = PlaylistProfile(
            id: playlistId,
            name: name,
            mode: 'stalker',
            portalUrl: portal,
            portalMac: mac,
            portalUsername: _portalControllers['portalUsername']!.text.trim(),
            portalPassword: _portalControllers['portalPassword']!.text,
            portalSerial: _portalControllers['portalSerial']!.text.trim(),
            portalDeviceId: _portalControllers['portalDeviceId']!.text.trim(),
            portalDeviceId2: _portalControllers['portalDeviceId2']!.text.trim(),
            portalSignature: _portalControllers['portalSignature']!.text.trim(),
            epgUrl: epgUrl,
            categoryLayout: _categoryLayout,
            includeLive: _includeLive,
            includeMovies: _includeMovies,
            includeSeries: _includeSeries,
            enabled: _editingProfile?.enabled ?? true,
            sortOrder: _editingProfile?.sortOrder ?? playlist.profiles.length,
            syncFrequencyDays: _editingProfile?.syncFrequencyDays ??
                AppConstants.defaultSyncFrequencyDays,
            createdAt: _editingProfile?.createdAt ?? DateTime.now());
      } else if (mode == 'xtream') {
        final enteredServer = _xtreamServerController.text.trim();
        final username = _xtreamUsernameController.text.trim();
        final password = _xtreamPasswordController.text.trim();

        if (enteredServer.isEmpty || username.isEmpty || password.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    tr('Server, username, and password are all required.'))),
          );
          return;
        }

        final String server;
        try {
          server = XtreamHelper.normalizeServer(enteredServer);
        } on FormatException catch (e) {
          _saveError = e.message;
          _serverFocus.requestFocus();
          _showSaveFeedback(_saveError!);
          return;
        }

        // Use player_api.php for Xtream content; some servers disable get.php exports. An
        // optional XMLTV override replaces the derived guide URL, with entries matched by
        // epg_channel_id.
        final customEpgUrl = _epgController.text.trim();
        if (!_includeLive && !_includeMovies && !_includeSeries) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Select at least one content type.')));
          return;
        }
        epgUrl = !_includeLive
            ? ''
            : customEpgUrl.isNotEmpty
                ? customEpgUrl
                : XtreamHelper.buildEpgUrl(
                    server: server, username: username, password: password);
        profile = PlaylistProfile(
          id: playlistId,
          categoryLayout: _categoryLayout,
          name: name,
          mode: 'xtream',
          includeLive: _includeLive,
          includeMovies: _includeMovies,
          includeSeries: _includeSeries,
          xtreamServer: server,
          xtreamUsername: username,
          xtreamPassword: password,
          epgUrl: epgUrl,
          enabled: _editingProfile?.enabled ?? true,
          sortOrder: _editingProfile?.sortOrder ?? playlist.profiles.length,
          syncFrequencyDays: _editingProfile?.syncFrequencyDays ??
              AppConstants.defaultSyncFrequencyDays,
          createdAt: _editingProfile?.createdAt ?? DateTime.now(),
        );
      } else {
        final m3uUrl = _m3uController.text.trim();
        epgUrl = _epgController.text.trim();
        if (m3uUrl.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('M3U playlist URL is required.'))),
          );
          return;
        }
        profile = PlaylistProfile(
          id: playlistId,
          categoryLayout: _categoryLayout,
          name: name,
          mode: 'm3u',
          m3uUrl: m3uUrl,
          epgUrl: epgUrl,
          enabled: _editingProfile?.enabled ?? true,
          sortOrder: _editingProfile?.sortOrder ?? playlist.profiles.length,
          syncFrequencyDays: _editingProfile?.syncFrequencyDays ??
              AppConstants.defaultSyncFrequencyDays,
          createdAt: _editingProfile?.createdAt ?? DateTime.now(),
        );
      }

      profile = profile.copyWith(userAgent: _userAgent);
      submitted = true;
      if (isEditing) {
        final original = _editingProfile!;
        profile = profile.copyWith(
          liveSortOrder: original.liveSortOrder,
          vodSortOrder: original.vodSortOrder,
          seriesSortOrder: original.seriesSortOrder,
          expiresAt: original.expiresAt,
          maxConnections: original.maxConnections,
          backupServers: original.backupServers,
          lastWorkingServer: original.lastWorkingServer,
        );
        await playlist.updatePlaylist(profile);
      } else {
        // A failed local rollback must be retried before creating another copy.
        if (_pendingNewPlaylistId != null) {
          await playlist.removePlaylist(_pendingNewPlaylistId!);
          _pendingNewPlaylistId = null;
        }
        await playlist.addPlaylist(profile);
        _pendingNewPlaylistId = playlistId;
      }
      stage = mode == 'm3u'
          ? PlaylistFailureStage.download
          : PlaylistFailureStage.connect;
      await playlist.loadPlaylist(playlistId);

      // Authentication failure may set session.error without throwing. Check the foreground
      // add/edit session explicitly before reporting success or leaving the form.
      if (playlist.error != null) {
        failure = playlist.loadFailureFor(playlistId) ??
            PlaylistFailure(stage, PlaylistFailureReason.unknown);
        _saveError = failure.message;
        // Roll back a failed new playlist so retries cannot leave duplicate empty profiles.
        // Preserve an existing profile and its cached data when an edit fails validation.
        if (!isEditing) {
          stage = PlaylistFailureStage.save;
          await playlist.removePlaylist(playlistId);
          _pendingNewPlaylistId = null;
        }
        return;
      }
      _pendingNewPlaylistId = null;

      if (!mounted) return;
      if (profile.isStalker && profile.includeLive && epgUrl.isEmpty) {
        unawaited(epg.refreshPortal(playlistId));
      }
      if (epgUrl.isNotEmpty) {
        // Start the initial guide fetch without blocking navigation. Periodic updates handle
        // later refreshes; a slow or failed XMLTV response must not strand the completed
        // form.
        unawaited(epg.refresh(epgUrl,
            knownChannelIds: playlist.knownChannelIdsFor(playlistId),
            headers: profile.requestHeaders));
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              isEditing ? tr('Playlist updated.') : tr('Playlist added.'))));
      if (isEditing) {
        // Back to PlaylistManagerScreen's detail panel, which is what
        // pushed this screen in edit mode — one level up, not all the way
        // to the app root (unlike a brand-new add, below).
        Navigator.of(context).pop();
      } else {
        // Return to the main app after setup. The shared ScaffoldMessenger can display the
        // result after the form is popped.
        SettingsNavigation.returnToApp(context);
      }
    } on PortalException catch (e) {
      if (submitted) {
        failure = PlaylistFailure.fromError(e, stage);
        _saveError = failure.message;
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      debugPrint('Playlist save failed: ${e.runtimeType}');
      if (mounted) {
        failure = PlaylistFailure.fromError(e, stage);
        _saveError = failure.message;
      }
    } finally {
      if (focusListener != null) {
        FocusManager.instance.removeListener(focusListener!);
      }
      if (mounted) {
        setState(() => _saving = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !submitted ||
              !restoreSaveFocus ||
              ModalRoute.of(context)?.isCurrent != true) {
            return;
          }
          _addButtonFocus.requestFocus();
          final status = _saveStatusKey.currentContext;
          if (_saveError != null && status != null) {
            Scrollable.ensureVisible(status);
          }
        });
        if (failure != null) unawaited(_presentSaveFailure(failure, source));
      }
    }
  }

  // Existing providers restore independently. Only this form's submission
  // blocks a new add; edits retain the guard against changing a loading source.
  bool _formBusy(PlaylistManager playlist) =>
      _saving || (_editingProfile != null && playlist.isLoading);

  Widget _saveAction(PlaylistManager playlist) => FilledButton.icon(
        key: const ValueKey('playlist-save'),
        focusNode: _addButtonFocus,
        onPressed: _formBusy(playlist) ? null : _save,
        icon: _formBusy(playlist)
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, semanticsLabel: tr('Loading...')))
            : Icon(_editingProfile != null ? Icons.check : Icons.add, size: 18),
        label: Text(
            _editingProfile != null ? tr('Save changes') : tr('Add playlist')),
      );

  static Widget _scrollIfNarrow(bool narrow, Widget child) => narrow
      ? SingleChildScrollView(padding: const EdgeInsets.all(8), child: child)
      : child;

  static Widget _expandedUnlessNarrow(bool narrow, Widget child) =>
      narrow ? child : Expanded(child: child);

  Widget _compactSources() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionLabel(tr('Playlist source')),
          const SizedBox(height: 6),
          LayoutBuilder(builder: (context, box) {
            final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
            final columns = box.maxWidth >= 500 && scale <= 1.2
                ? 5
                : box.maxWidth >= 340 && scale <= 1.2
                    ? 3
                    : 2;
            final width = (box.maxWidth - (columns - 1) * 6) / columns;
            return Wrap(spacing: 6, runSpacing: 6, children: [
              for (final choice in [
                ('m3u', 'M3U URL', _modeM3uFocus),
                ('xtream', 'Xtream Codes', _modeXtreamFocus),
                ('stalker', 'Stalker / MAC', _modePortalFocus),
                ('smart', 'Smart Add', _modeSmartFocus),
                ('phone', 'From phone', _modePhoneFocus),
              ])
                SizedBox(
                    width: width,
                    child: ModeButton(
                      key: ValueKey('playlist-mode-${choice.$1}'),
                      focusNode: choice.$3,
                      label: tr(choice.$2),
                      selected: _mode == choice.$1,
                      onTap: () => setState(() => _mode = choice.$1),
                    )),
            ]);
          }),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final narrow = _stacked;

    return withSettingsTheme(
        context,
        (context) => SettingsScaffold(
            title: _editingProfile != null
                ? tr('Edit playlist')
                : tr('Add playlist'),
            // Use three explicit focus zones: modes, scrollable fields and a fixed
            // status/action panel. Keep status and Add Playlist visible even when the form
            // exceeds the viewport.
            body: Focus(
                canRequestFocus: false,
                onKeyEvent: (_, event) => _handleFieldEscapeKey(event)
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored,
                child: CallbackShortcuts(
                  bindings: narrow
                      ? const <ShortcutActivator, VoidCallback>{}
                      : <ShortcutActivator, VoidCallback>{
                          // Strict left-to-right cycle: modes -> fields -> status.
                          // EditableText claims Left/Right for caret movement
                          // whenever a text field has focus, so these only ever
                          // actually fire while focus is on a mode row, a field's
                          // own non-text-field sibling (e.g. the radio list), or
                          // the status/Add-Playlist pane —
                          // never mid-typing.
                          const TvNavigationActivator(
                              LogicalKeyboardKey.arrowLeft): () {
                            if (_statusScope.hasFocus ||
                                _addButtonFocus.hasFocus) {
                              (_mode == 'phone'
                                      ? _phoneToggleFocus
                                      : _nameFocus)
                                  .requestFocus();
                            } else if (_fieldsScope.hasFocus) {
                              _currentModeListFocus.requestFocus();
                            }
                            // Already in the mode list — no-op, nothing further left.
                          },
                          const TvNavigationActivator(
                              LogicalKeyboardKey.arrowRight): () {
                            if (_modeScope.hasFocus) {
                              (_mode == 'phone'
                                      ? _phoneToggleFocus
                                      : _nameFocus)
                                  .requestFocus();
                            } else if (_fieldsScope.hasFocus &&
                                _mode != 'phone') {
                              _addButtonFocus.requestFocus();
                            }
                            // Already in the status pane — no-op, nothing further right.
                          },
                        },
                  // Phone in portrait: the three panes don't fit side by side,
                  // so they stack (modes, form, status) in one scrolling page.
                  child: Column(children: [
                    Expanded(
                        child: _scrollIfNarrow(
                      narrow,
                      Flex(
                        direction: narrow ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: narrow
                            ? CrossAxisAlignment.stretch
                            : CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: narrow ? null : 260,
                            child: FocusScope(
                              node: _modeScope,
                              child: narrow
                                  ? _compactSources()
                                  : ListView(
                                      shrinkWrap: narrow,
                                      physics: narrow
                                          ? const NeverScrollableScrollPhysics()
                                          : null,
                                      padding: const EdgeInsets.all(8),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 4),
                                          child: SectionLabel(
                                              tr('Playlist source')),
                                        ),
                                        const SizedBox(height: 4),
                                        TvMenuTile(
                                          focusNode: _modeM3uFocus,
                                          icon: Icons.link,
                                          title: tr('M3U URL'),
                                          trailing: _mode == 'm3u'
                                              ? Icon(Icons.check,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary)
                                              : const SizedBox.shrink(),
                                          onTap: () =>
                                              setState(() => _mode = 'm3u'),
                                        ),
                                        TvMenuTile(
                                          focusNode: _modeXtreamFocus,
                                          icon: Icons.dns,
                                          title: tr('Xtream Codes'),
                                          trailing: _mode == 'xtream'
                                              ? Icon(Icons.check,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary)
                                              : const SizedBox.shrink(),
                                          onTap: () =>
                                              setState(() => _mode = 'xtream'),
                                        ),
                                        TvMenuTile(
                                            key: const ValueKey(
                                                'playlist-mode-stalker'),
                                            focusNode: _modePortalFocus,
                                            icon: Icons.router_outlined,
                                            title: 'Stalker / MAC',
                                            trailing: _mode == 'stalker'
                                                ? const Icon(Icons.check)
                                                : const SizedBox.shrink(),
                                            onTap: () => setState(
                                                () => _mode = 'stalker')),
                                        TvMenuTile(
                                          focusNode: _modeSmartFocus,
                                          icon: Icons.auto_fix_high,
                                          title: tr('Smart Add'),
                                          trailing: _mode == 'smart'
                                              ? Icon(Icons.check,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary)
                                              : const SizedBox.shrink(),
                                          onTap: () =>
                                              setState(() => _mode = 'smart'),
                                        ),
                                        TvMenuTile(
                                          focusNode: _modePhoneFocus,
                                          icon: Icons.qr_code_2,
                                          title: tr('From phone'),
                                          trailing: _mode == 'phone'
                                              ? Icon(Icons.check,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary)
                                              : const SizedBox.shrink(),
                                          onTap: () =>
                                              setState(() => _mode = 'phone'),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _expandedUnlessNarrow(
                            narrow,
                            FocusScope(
                              node: _fieldsScope,
                              child: ListView(
                                shrinkWrap: narrow,
                                physics: narrow
                                    ? const NeverScrollableScrollPhysics()
                                    : null,
                                padding: const EdgeInsets.all(12),
                                children: [
                                  if (_mode == 'phone')
                                    PhonePairPanel(
                                      toggleFocusNode: _phoneToggleFocus,
                                      onResult: _applyPhoneResult,
                                    )
                                  else ...[
                                    TvTextFieldGate(
                                      focusNode: _nameFocus,
                                      builder: (context, readOnly) => TextField(
                                        controller: _nameController,
                                        focusNode: _nameFocus,
                                        readOnly: readOnly,
                                        decoration: InputDecoration(
                                          labelText: tr('Name'),
                                          hintText: tr('e.g. My Provider'),
                                          border: const OutlineInputBorder(),
                                        ),
                                        textInputAction: TextInputAction.next,
                                        // Goes to the first field *of the current
                                        // mode* now, not a mode row that used to sit
                                        // right below it — [_firstModeFieldFocus]'s
                                        // doc comment has the per-mode mapping
                                        // (including Smart Add's two stages).
                                        onSubmitted: (_) =>
                                            _firstModeFieldFocus.requestFocus(),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (_mode == 'stalker')
                                      ..._portalFields()
                                    else if (_mode == 'm3u') ...[
                                      TvTextFieldGate(
                                        focusNode: _m3uFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _m3uController,
                                          focusNode: _m3uFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr('M3U Playlist URL'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.url,
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) =>
                                              _epgFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TvTextFieldGate(
                                        focusNode: _epgFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _epgController,
                                          focusNode: _epgFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr('EPG (XMLTV) URL'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.url,
                                          textInputAction: TextInputAction.done,
                                          onSubmitted: (_) =>
                                              _addButtonFocus.requestFocus(),
                                        ),
                                      ),
                                    ] else if (_mode == 'smart' &&
                                        !_smartParsed) ...[
                                      // Parse connection fields from a pasted provider message.
                                      Text(
                                        tr('Paste the message your provider sent you — we\'ll pull out the server, username, and password.'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      const SizedBox(height: 8),
                                      TvTextFieldGate(
                                        focusNode: _smartPasteFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _smartPasteController,
                                          focusNode: _smartPasteFocus,
                                          readOnly: readOnly,
                                          maxLines: 6,
                                          minLines: 3,
                                          decoration: InputDecoration(
                                            labelText:
                                                tr('Paste provider message'),
                                            hintText:
                                                'username=...\npassword=...\nhttp://server.example.com/get.php?...',
                                            alignLabelWithHint: true,
                                            border: const OutlineInputBorder(),
                                          ),
                                          // A paste (the normal way this field gets filled, via the
                                          // Fire Stick's QR-code-to-phone-keyboard relay) inserts the
                                          // whole multi-line block directly — it doesn't need the
                                          // IME's own return key to type newlines one at a time, so
                                          // claiming that key for a real "next field" action instead
                                          // costs nothing real.
                                          textInputAction: TextInputAction.done,
                                          onSubmitted: (_) =>
                                              _parseButtonFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      FilledButton.icon(
                                        focusNode: _parseButtonFocus,
                                        icon: const Icon(Icons.auto_fix_high),
                                        label: Text(tr('Parse')),
                                        onPressed: _handleSmartParse,
                                        onFocusChange: (f) {
                                          if (f) _ensureVisible(context);
                                        },
                                      ),
                                    ] else if (_mode == 'smart') ...[
                                      // Stage 2: review. Reuses the exact same server/username/
                                      // password controllers (and fields, below) the Xtream tab
                                      // has — Smart Add is just a different way to fill them in,
                                      // not a different destination for the data.
                                      Text(tr('Confirm the server'),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall),
                                      const SizedBox(height: 4),
                                      if (_smartServerCandidates.isEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 8),
                                          child: Text(
                                            tr('No server URL found in that text — enter it below.'),
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error),
                                          ),
                                        )
                                      else
                                        // Offer all parsed server candidates so malformed copied
                                        // URLs can be replaced by another candidate. RadioGroup
                                        // supplies option traversal.
                                        RadioGroup<String>(
                                          groupValue: _smartSelectedServer,
                                          onChanged: (value) => setState(() {
                                            _smartSelectedServer = value;
                                            _xtreamServerController.text =
                                                value ?? '';
                                          }),
                                          child: Column(
                                            children: _smartServerCandidates
                                                .map((url) =>
                                                    RadioListTile<String>(
                                                      value: url,
                                                      dense: true,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                      title: Text(url,
                                                          style: const TextStyle(
                                                              fontFamily:
                                                                  'monospace')),
                                                    ))
                                                .toList(),
                                          ),
                                        ),
                                      const SizedBox(height: 8),
                                      TvTextFieldGate(
                                        focusNode: _serverFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _xtreamServerController,
                                          focusNode: _serverFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr(
                                                'Server URL (e.g. http://host:port)'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.url,
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) =>
                                              _usernameFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TvTextFieldGate(
                                        focusNode: _usernameFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _xtreamUsernameController,
                                          focusNode: _usernameFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr('Username'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) =>
                                              _passwordFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TvTextFieldGate(
                                        focusNode: _passwordFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _xtreamPasswordController,
                                          focusNode: _passwordFocus,
                                          readOnly: readOnly,
                                          // Shown in plain text on purpose: provider
                                          // passwords are long and random, and typing
                                          // them blind with a remote is error-prone.
                                          decoration: InputDecoration(
                                            labelText: tr('Password'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) =>
                                              _epgFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TvTextFieldGate(
                                        focusNode: _epgFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _epgController,
                                          focusNode: _epgFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr(
                                                'Custom EPG (XMLTV) URL — optional'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.url,
                                          textInputAction: TextInputAction.done,
                                          onSubmitted: (_) =>
                                              _addButtonFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        tr('Optional. Leave blank to use your provider\'s guide. A custom XMLTV guide must use matching channel IDs.'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      const SizedBox(height: 8),
                                      TextButton.icon(
                                        icon: const Icon(Icons.arrow_back),
                                        label: Text(tr('Paste different text')),
                                        onPressed: _resetSmartAdd,
                                        onFocusChange: (f) {
                                          if (f) _ensureVisible(context);
                                        },
                                      ),
                                    ] else ...[
                                      TvTextFieldGate(
                                        focusNode: _serverFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _xtreamServerController,
                                          focusNode: _serverFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr(
                                                'Server URL (e.g. http://host:port)'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.url,
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) =>
                                              _usernameFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TvTextFieldGate(
                                        focusNode: _usernameFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _xtreamUsernameController,
                                          focusNode: _usernameFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr('Username'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) =>
                                              _passwordFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TvTextFieldGate(
                                        focusNode: _passwordFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _xtreamPasswordController,
                                          focusNode: _passwordFocus,
                                          readOnly: readOnly,
                                          // Shown in plain text on purpose: provider
                                          // passwords are long and random, and typing
                                          // them blind with a remote is error-prone.
                                          decoration: InputDecoration(
                                            labelText: tr('Password'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) =>
                                              _epgFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TvTextFieldGate(
                                        focusNode: _epgFocus,
                                        builder: (context, readOnly) =>
                                            TextField(
                                          controller: _epgController,
                                          focusNode: _epgFocus,
                                          readOnly: readOnly,
                                          decoration: InputDecoration(
                                            labelText: tr(
                                                'Custom EPG (XMLTV) URL — optional'),
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.url,
                                          textInputAction: TextInputAction.done,
                                          onSubmitted: (_) =>
                                              _addButtonFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        tr('Optional. Leave blank to use your provider\'s guide. A custom XMLTV guide must use matching channel IDs.'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                          ),
                          // "From my phone" has nothing to add until the phone has
                          // sent its details (then the mode flips to M3U/Xtream and
                          // this pane comes back) — its QR panel gets the room.
                          if (_mode != 'phone') ...[
                            const SizedBox(width: 16),
                            // Fixed width, not Expanded/flex — a status panel and one
                            // button don't need to grow with a wide TV screen the way
                            // the form column benefits from the extra room.
                            SizedBox(
                              width: narrow ? null : 320,
                              child: FocusScope(
                                node: _statusScope,
                                child: SingleChildScrollView(
                                    child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (_mode == 'stalker' ||
                                        _mode == 'xtream' ||
                                        (_mode == 'smart' && _smartParsed)) ...[
                                      TvMenuTile(
                                        focusNode: _contentFocus,
                                        icon: Icons.video_library_outlined,
                                        title: 'Content from this playlist',
                                        subtitle: [
                                          if (_includeLive) 'Live TV',
                                          if (_includeMovies) 'Movies',
                                          if (_includeSeries) 'Series'
                                        ].join(' · '),
                                        enabled: !_formBusy(playlist),
                                        onTap: () async {
                                          final value =
                                              await pickPlaylistContent(context,
                                                  live: _includeLive,
                                                  movies: _includeMovies,
                                                  series: _includeSeries);
                                          if (!mounted || value == null) return;
                                          setState(() {
                                            _includeLive = value.$1;
                                            _includeMovies = value.$2;
                                            _includeSeries = value.$3;
                                          });
                                        },
                                      ),
                                    ],
                                    if (_mode != 'phone') ...[
                                      TvMenuTile(
                                        key: const ValueKey(
                                            'playlist-user-agent'),
                                        focusNode: _userAgentFocus,
                                        icon: Icons.tune,
                                        title: 'User agent',
                                        subtitle: _userAgent.isEmpty
                                            ? 'Default · optional provider setting'
                                            : _userAgent,
                                        enabled: !_formBusy(playlist),
                                        onTap: () async {
                                          final value =
                                              await choosePlaylistUserAgent(
                                                  context, _userAgent);
                                          if (mounted && value != null) {
                                            setState(() => _userAgent = value);
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                    PlaylistOrganisationPicker(
                                        focusNode: _organisationFocus,
                                        value: _categoryLayout == 'auto'
                                            ? context
                                                .read<PlaylistManager>()
                                                .categoryLayoutFor(
                                                    widget.editPlaylistId!)
                                            : _categoryLayout,
                                        onChanged: _formBusy(playlist)
                                            ? null
                                            : (v) => setState(
                                                () => _categoryLayout = v)),
                                    const SizedBox(height: 12),
                                    if (_saving || _saveError != null) ...[
                                      SectionLabel(tr('Status')),
                                      const SizedBox(height: 8),
                                      // Save is fixed outside this scroll view; status only takes
                                      // space when there is progress or an error to show.
                                      ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(minHeight: 40),
                                        child: Builder(builder: (context) {
                                          final error = _saveError;
                                          Color? accent;
                                          Widget content =
                                              const SizedBox.shrink();
                                          if (_saving) {
                                            accent = Theme.of(context)
                                                .colorScheme
                                                .primary;
                                            content = Row(
                                              children: [
                                                SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: accent),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Text(
                                                    playlist.loadingPhase ??
                                                        tr('Loading...'),
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold),
                                                  ),
                                                ),
                                              ],
                                            );
                                          } else if (error != null) {
                                            accent = Theme.of(context)
                                                .colorScheme
                                                .error;
                                            content = Text(
                                              // The raw reason (bad credentials vs. an
                                              // unreachable/timed-out server vs. an
                                              // inactive account all look different, e.g.
                                              // "Invalid Xtream username/password" vs.
                                              // "Xtream request failed... (HTTP 403)") —
                                              // shown instead of a generic "failed" message
                                              // so a typo can actually be told apart from a
                                              // genuinely bad server without guessing.
                                              tr(
                                                  'Could not save playlist: {p}',
                                                  {
                                                    'p': error.replaceFirst(
                                                        'Exception: ', '')
                                                  }),
                                              style: TextStyle(
                                                  color: accent,
                                                  fontWeight: FontWeight.bold),
                                            );
                                          }
                                          return Container(
                                            key: _saveStatusKey,
                                            decoration: accent == null
                                                ? null
                                                : BoxDecoration(
                                                    color: interfaceColor(
                                                            context,
                                                            Colors.white)
                                                        .withValues(
                                                            alpha: 0.07),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            4),
                                                    border: Border(
                                                        left: BorderSide(
                                                            color: accent,
                                                            width: 4)),
                                                  ),
                                            padding: const EdgeInsets.all(12),
                                            child: content,
                                          );
                                        }),
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                  ],
                                )),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )),
                    if (_mode != 'phone')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: SizedBox(
                              width: narrow ? double.infinity : 320,
                              child: _saveAction(playlist)),
                        ),
                      ),
                  ]),
                ))));
  }
}
