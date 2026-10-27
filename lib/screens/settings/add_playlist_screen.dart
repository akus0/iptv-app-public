import '../../utils/interface_colors.dart';
import '../../widgets/playlist_organisation_picker.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/playlist_profile.dart';
import '../../services/epg_service.dart';
import '../../services/playlist_manager.dart';
import '../../utils/constants.dart';
import '../../utils/smart_add_parser.dart';
import '../../utils/tv_theme.dart';
import '../../utils/xtream.dart';
import '../../services/phone_pairing_service.dart';
import '../../widgets/phone_pair_panel.dart';
import '../../widgets/section_label.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_text_field_gate.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../widgets/tv_switch_list_tile.dart';
import '../../l10n/l10n.dart';

/// Scroll focused controls into view when the playlist form exceeds the viewport, including
/// buttons that do not scroll themselves.
void _ensureVisible(BuildContext context) {
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

  /// Focus nodes for the playlist-source modes, including the Left-arrow destination and
  /// initial active mode.
  final _modeM3uFocus = FocusNode();
  final _modeXtreamFocus = FocusNode();
  final _modeSmartFocus = FocusNode();
  final _modePhoneFocus = FocusNode();

  /// "From my phone"'s Wi-Fi/relay switch — the Right-arrow target into
  /// the middle pane in that mode, which has no Name field of its own (the
  /// phone form carries the name).
  final _phoneToggleFocus = FocusNode();

  FocusNode get _currentModeListFocus => switch (_mode) {
        'xtream' => _modeXtreamFocus,
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
        'smart' => _smartParsed ? _serverFocus : _smartPasteFocus,
        'phone' => _phoneToggleFocus,
        _ => _serverFocus,
      };

  /// Separate focus scopes for the mode list, fields and status panel give Left/Right a
  /// predictable destination.
  final _modeScope = FocusScopeNode(debugLabel: 'add-playlist-modes');
  final _fieldsScope = FocusScopeNode(debugLabel: 'add-playlist-fields');
  final _statusScope = FocusScopeNode(debugLabel: 'add-playlist-status');

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
    _categoryLayout = existing?.categoryLayout ?? 'organised';
    _includeLive = existing?.includeLive ?? true;
    _includeMovies = existing?.includeMovies ?? true;
    _includeSeries = existing?.includeSeries ?? true;

    _mode = existing?.mode ?? 'm3u';
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
    final existingAutoEpg = (existing != null && existing.mode == 'xtream')
        ? XtreamHelper.buildEpgUrl(
            server: existing.xtreamServer ?? '',
            username: existing.xtreamUsername ?? '',
            password: existing.xtreamPassword ?? '')
        : null;
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
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _currentModeListFocus.requestFocus());
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
    _addButtonFocus.dispose();
    _smartPasteFocus.dispose();
    _parseButtonFocus.dispose();
    _modeM3uFocus.dispose();
    _modeXtreamFocus.dispose();
    _modeSmartFocus.dispose();
    _modePhoneFocus.dispose();
    _phoneToggleFocus.dispose();
    _modeScope.dispose();
    _fieldsScope.dispose();
    _statusScope.dispose();
    super.dispose();
  }

  /// Handle Up/Down explicitly because EditableText consumes arrow keys. Do not require the
  /// keyboard to be closed: returning focus can reopen it immediately. IME Next/Done uses a
  /// separate event path.
  bool _handleFieldEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;

    // OK on a field (raising its keyboard) is TvTextFieldGate's job now.
    // This used to reopen the keyboard on any Enter too, and Fire OS sends
    // an Enter when Back closes its keyboard: Back reopened it, forever.

    if (event.logicalKey != LogicalKeyboardKey.arrowDown &&
        event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return false;
    }

    // The field actually being escaped — `current` when it's a tracked
    // field, otherwise the last one this handler saw focused (see
    // [_lastFocusedTextField]'s own doc comment for the real-hardware case
    // that fallback covers).
    final current = FocusManager.instance.primaryFocus;

    final effective =
        (current == _nameFocus || _allTrackedFields.contains(current))
            ? current
            : _lastFocusedTextField;

    // Name is folded in as the first entry below, not handled on its own
    // the way it used to be — that only existed because a whole
    // "Playlist source" `ModeButton` row used to sit between it and the
    // next tracked field, with no sibling relationship otherwise. Now
    // that mode selection lives in its own Left-reached pane (see this
    // class's own doc comment), Name is a genuine sibling of whichever
    // mode-specific field comes right after it, same as any other pair
    // in this list.
    //
    // Smart Add's stage 1 (the paste box) is the one real exception —
    // its own fields aren't part of this tracked-escape mechanism at all
    // (see `_smartPasteFocus`'s doc comment: forward-only via
    // `onSubmitted`, there's nothing to escape *between* on a single-field
    // stage), so Name is the *only* entry there; escaping down past it
    // goes to the paste box directly instead of by index below.
    final fields = switch (_mode) {
      'm3u' => [_nameFocus, _m3uFocus, _epgFocus],
      'smart' => _smartParsed
          ? [
              _nameFocus,
              _serverFocus,
              _usernameFocus,
              _passwordFocus,
              _epgFocus
            ]
          : [_nameFocus],
      'phone' => <FocusNode>[],
      _ => [
          _nameFocus,
          _serverFocus,
          _usernameFocus,
          _passwordFocus,
          _epgFocus
        ],
    };
    final index = fields.indexWhere((n) => n == effective);
    if (index < 0) return false;

    final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
    final next = index + delta;
    if (next < 0) {
      // Escaping UP past Name — genuinely the top of this pane now (the
      // mode list is a separate pane, reached via Left instead), so this
      // is a deliberate no-op rather than a jump anywhere. Still
      // consumed (not `return false`) so it doesn't fall through to
      // Flutter's own default traversal, which is exactly what this
      // whole mechanism exists to avoid trusting (see this method's own
      // doc comment).
      return true;
    }
    if (_mode == 'smart' && !_smartParsed && next >= fields.length) {
      // Only Name is tracked at stage 1 (see the comment above) —
      // escaping down from it goes to the paste box, not by index.
      _smartPasteFocus.requestFocus();
      return true;
    }
    if (next >= fields.length) {
      // Move directly from the last field to Add Playlist instead of relying on geometric
      // focus traversal.
      _addButtonFocus.requestFocus();
      return true;
    }
    fields[next].requestFocus();
    _lastFocusedTextField = fields[next];
    return true;
  }

  /// Every text field this screen's escape mechanism tracks, across every
  /// mode — used by [_handleFieldEscapeKey] to tell "a tracked field lost
  /// bare focus but is still the logical last-known one" apart from "focus
  /// moved somewhere this handler has no opinion about".
  List<FocusNode> get _allTrackedFields => [
        _nameFocus,
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

  Future<void> _save() async {
    if (_saving) return;
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
    setState(() => _saving = true);
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

      if (mode == 'xtream') {
        final server = _xtreamServerController.text.trim();
        final username = _xtreamUsernameController.text.trim();
        final password = _xtreamPasswordController.text.trim();

        if (server.isEmpty || username.isEmpty || password.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    tr('Server, username, and password are all required.'))),
          );
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
        await playlist.addPlaylist(profile);
      }
      await playlist.loadPlaylist(playlistId);

      // Authentication failure may set session.error without throwing. Check the foreground
      // add/edit session explicitly before reporting success or leaving the form.
      if (!mounted) return;
      if (playlist.error != null) {
        // Roll back a failed new playlist so retries cannot leave duplicate empty profiles.
        // Preserve an existing profile and its cached data when an edit fails validation.
        if (!isEditing) await playlist.removePlaylist(playlistId);
        return;
      }

      if (!mounted) return;
      if (epgUrl.isNotEmpty) {
        // Start the initial guide fetch without blocking navigation. Periodic updates handle
        // later refreshes; a slow or failed XMLTV response must not strand the completed
        // form.
        unawaited(epg.refresh(epgUrl,
            knownChannelIds: playlist.knownChannelIdsFor(playlistId)));
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
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static Widget _scrollIfNarrow(bool narrow, Widget child) => narrow
      ? SingleChildScrollView(padding: const EdgeInsets.all(8), child: child)
      : child;

  static Widget _expandedUnlessNarrow(bool narrow, Widget child) =>
      narrow ? child : Expanded(child: child);

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();
    final narrow = MediaQuery.sizeOf(context).width < 600;

    return withTvThemeIfNeeded(
        context,
        (context) => SettingsScaffold(
            title: _editingProfile != null
                ? tr('Edit Playlist')
                : tr('Add Playlist'),
            // Use three explicit focus zones: modes, scrollable fields and a fixed
            // status/action panel. Keep status and Add Playlist visible even when the form
            // exceeds the viewport.
            body: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                // Strict left-to-right cycle: modes -> fields -> status.
                // EditableText claims Left/Right for caret movement
                // whenever a text field has focus, so these only ever
                // actually fire while focus is on a mode row, a field's
                // own non-text-field sibling (e.g. the radio list), or
                // the status/Add-Playlist pane —
                // never mid-typing.
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
                  if (_statusScope.hasFocus) {
                    (_mode == 'phone' ? _phoneToggleFocus : _nameFocus)
                        .requestFocus();
                  } else if (_fieldsScope.hasFocus) {
                    _currentModeListFocus.requestFocus();
                  }
                  // Already in the mode list — no-op, nothing further left.
                },
                const SingleActivator(LogicalKeyboardKey.arrowRight): () {
                  if (_modeScope.hasFocus) {
                    (_mode == 'phone' ? _phoneToggleFocus : _nameFocus)
                        .requestFocus();
                  } else if (_fieldsScope.hasFocus && _mode != 'phone') {
                    _addButtonFocus.requestFocus();
                  }
                  // Already in the status pane — no-op, nothing further right.
                },
              },
              // Phone in portrait: the three panes don't fit side by side,
              // so they stack (modes, form, status) in one scrolling page.
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
                        child: ListView(
                          shrinkWrap: narrow,
                          physics: narrow
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          padding: const EdgeInsets.all(8),
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: SectionLabel(tr('Playlist source')),
                            ),
                            const SizedBox(height: 4),
                            TvMenuTile(
                              focusNode: _modeM3uFocus,
                              icon: Icons.link,
                              title: tr('M3U URL'),
                              trailing: _mode == 'm3u'
                                  ? Icon(Icons.check,
                                      color:
                                          Theme.of(context).colorScheme.primary)
                                  : const SizedBox.shrink(),
                              onTap: () => setState(() => _mode = 'm3u'),
                            ),
                            TvMenuTile(
                              focusNode: _modeXtreamFocus,
                              icon: Icons.dns,
                              title: tr('Xtream Codes'),
                              trailing: _mode == 'xtream'
                                  ? Icon(Icons.check,
                                      color:
                                          Theme.of(context).colorScheme.primary)
                                  : const SizedBox.shrink(),
                              onTap: () => setState(() => _mode = 'xtream'),
                            ),
                            TvMenuTile(
                              focusNode: _modeSmartFocus,
                              icon: Icons.auto_fix_high,
                              title: tr('Smart Add'),
                              trailing: _mode == 'smart'
                                  ? Icon(Icons.check,
                                      color:
                                          Theme.of(context).colorScheme.primary)
                                  : const SizedBox.shrink(),
                              onTap: () => setState(() => _mode = 'smart'),
                            ),
                            TvMenuTile(
                              focusNode: _modePhoneFocus,
                              icon: Icons.qr_code_2,
                              title: tr('From phone'),
                              trailing: _mode == 'phone'
                                  ? Icon(Icons.check,
                                      color:
                                          Theme.of(context).colorScheme.primary)
                                  : const SizedBox.shrink(),
                              onTap: () => setState(() => _mode = 'phone'),
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
                          padding: const EdgeInsets.all(16),
                          children: [
                            if (_mode == 'phone')
                              PhonePairPanel(
                                toggleFocusNode: _phoneToggleFocus,
                                onResult: _applyPhoneResult,
                              )
                            else ...[
                              SectionLabel(tr('Playlist name')),
                              const SizedBox(height: 8),
                              TvTextFieldGate(
                                focusNode: _nameFocus,
                                builder: (context, readOnly) => TextField(
                                  controller: _nameController,
                                  focusNode: _nameFocus,
                                  readOnly: readOnly,
                                  decoration: InputDecoration(
                                    labelText: tr('Name'),
                                    hintText:
                                        tr('e.g. My Provider'),
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
                              const SizedBox(height: 16),
                              if (_mode == 'm3u') ...[
                                TvTextFieldGate(
                                  focusNode: _m3uFocus,
                                  builder: (context, readOnly) => TextField(
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
                                const SizedBox(height: 16),
                                TvTextFieldGate(
                                  focusNode: _epgFocus,
                                  builder: (context, readOnly) => TextField(
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
                              ] else if (_mode == 'smart' && !_smartParsed) ...[
                                // Parse connection fields from a pasted provider message.
                                Text(
                                  tr('Paste the message your provider sent you — we\'ll pull out the server, username, and password.'),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 8),
                                TvTextFieldGate(
                                  focusNode: _smartPasteFocus,
                                  builder: (context, readOnly) => TextField(
                                    controller: _smartPasteController,
                                    focusNode: _smartPasteFocus,
                                    readOnly: readOnly,
                                    maxLines: 6,
                                    minLines: 3,
                                    decoration: InputDecoration(
                                      labelText: tr('Paste provider message'),
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
                                const SizedBox(height: 16),
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
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const SizedBox(height: 4),
                                if (_smartServerCandidates.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
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
                                          .map((url) => RadioListTile<String>(
                                                value: url,
                                                dense: true,
                                                contentPadding: EdgeInsets.zero,
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
                                  builder: (context, readOnly) => TextField(
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
                                const SizedBox(height: 16),
                                TvTextFieldGate(
                                  focusNode: _usernameFocus,
                                  builder: (context, readOnly) => TextField(
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
                                const SizedBox(height: 16),
                                TvTextFieldGate(
                                  focusNode: _passwordFocus,
                                  builder: (context, readOnly) => TextField(
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
                                const SizedBox(height: 16),
                                TvTextFieldGate(
                                  focusNode: _epgFocus,
                                  builder: (context, readOnly) => TextField(
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
                                  tr('Leave blank to use the panel\'s own xmltv.php. Set this if your provider\'s EPG is empty or unreliable (e.g. a third-party feed like EPGgenius) — it only fills in a channel if that feed\'s ids match this panel\'s.'),
                                  style: Theme.of(context).textTheme.bodySmall,
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
                                  builder: (context, readOnly) => TextField(
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
                                const SizedBox(height: 16),
                                TvTextFieldGate(
                                  focusNode: _usernameFocus,
                                  builder: (context, readOnly) => TextField(
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
                                const SizedBox(height: 16),
                                TvTextFieldGate(
                                  focusNode: _passwordFocus,
                                  builder: (context, readOnly) => TextField(
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
                                const SizedBox(height: 16),
                                TvTextFieldGate(
                                  focusNode: _epgFocus,
                                  builder: (context, readOnly) => TextField(
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
                                  tr('Leave blank to use the panel\'s own xmltv.php. Set this if your provider\'s EPG is empty or unreliable (e.g. a third-party feed like EPGgenius) — it only fills in a channel if that feed\'s ids match this panel\'s.'),
                                  style: Theme.of(context).textTheme.bodySmall,
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_mode == 'xtream' ||
                                  (_mode == 'smart' && _smartParsed)) ...[
                                const SectionLabel(
                                    'Content from this playlist'),
                                TvSwitchListTile(
                                    title: const Text('Live TV'),
                                    subtitle: const Text(
                                        'Channels and programme guide'),
                                    value: _includeLive,
                                    onChanged: _saving
                                        ? null
                                        : (v) =>
                                            setState(() => _includeLive = v)),
                                TvSwitchListTile(
                                    title: const Text('Movies'),
                                    subtitle: const Text(
                                        'On-demand films in the Movies tab'),
                                    value: _includeMovies,
                                    onChanged: _saving
                                        ? null
                                        : (v) =>
                                            setState(() => _includeMovies = v)),
                                TvSwitchListTile(
                                    title: const Text('Series'),
                                    subtitle: const Text(
                                        'Seasons and episodes in the Series tab'),
                                    value: _includeSeries,
                                    onChanged: _saving
                                        ? null
                                        : (v) =>
                                            setState(() => _includeSeries = v)),
                                const SizedBox(height: 12),
                              ],
                              PlaylistOrganisationPicker(
                                  value: _categoryLayout == 'auto'
                                      ? context
                                          .read<PlaylistManager>()
                                          .categoryLayoutFor(
                                              widget.editPlaylistId!)
                                      : _categoryLayout,
                                  onChanged: playlist.isLoading || _saving
                                      ? null
                                      : (v) =>
                                          setState(() => _categoryLayout = v)),
                              const SizedBox(height: 16),
                              SectionLabel(tr('Status')),
                              const SizedBox(height: 8),
                              // Reserve status height while idle so the action button does
                              // not move when connecting or error text appears. Paint the
                              // status emphasis only while active.
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(minHeight: 56),
                                child: Builder(builder: (context) {
                                  final error = playlist.error;
                                  Color? accent;
                                  Widget content = const SizedBox.shrink();
                                  if (playlist.isLoading) {
                                    accent =
                                        Theme.of(context).colorScheme.primary;
                                    content = Row(
                                      children: [
                                        SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2, color: accent),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            playlist.loadingPhase ??
                                                tr('Loading...'),
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ],
                                    );
                                  } else if (error != null) {
                                    accent =
                                        Theme.of(context).colorScheme.error;
                                    content = Text(
                                      // The raw reason (bad credentials vs. an
                                      // unreachable/timed-out server vs. an
                                      // inactive account all look different, e.g.
                                      // "Invalid Xtream username/password" vs.
                                      // "Xtream request failed... (HTTP 403)") —
                                      // shown instead of a generic "failed" message
                                      // so a typo can actually be told apart from a
                                      // genuinely bad server without guessing.
                                      tr('Failed to add playlist: {p}', {
                                        'p': error.replaceFirst(
                                            'Exception: ', '')
                                      }),
                                      style: TextStyle(
                                          color: accent,
                                          fontWeight: FontWeight.bold),
                                    );
                                  }
                                  // Idle: no fill, no border, no text — just the
                                  // reserved height above, so there's genuinely
                                  // nothing painted here to compete with or hide
                                  // a real status.
                                  return Container(
                                    decoration: accent == null
                                        ? null
                                        : BoxDecoration(
                                            color: interfaceColor(
                                                    context, Colors.white)
                                                .withValues(alpha: 0.07),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            border: Border(
                                                left: BorderSide(
                                                    color: accent, width: 4)),
                                          ),
                                    padding: const EdgeInsets.all(16),
                                    child: content,
                                  );
                                }),
                              ),
                              const SizedBox(height: 16),
                              // Highlight only on focus. Keep the same ancestor structure to
                              // preserve focus state.
                              FilledButton.icon(
                                focusNode: _addButtonFocus,
                                onPressed: playlist.isLoading || _saving
                                    ? null
                                    : _save,
                                icon: Icon(
                                    _editingProfile != null
                                        ? Icons.check
                                        : Icons.add,
                                    size: 18),
                                label: Text(_editingProfile != null
                                    ? tr('Save changes')
                                    : tr('Add playlist')),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                tr(
                                    'Fill in the form on the left, then press {p} above.',
                                    {
                                      'p': _editingProfile != null
                                          ? tr('Save Changes')
                                          : tr('Add Playlist')
                                    }),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )));
  }
}
