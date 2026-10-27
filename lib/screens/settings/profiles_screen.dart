import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/viewer_profile.dart';
import '../../services/parental_pin.dart';
import '../../services/playlist_manager.dart';
import '../../services/viewer_profile_service.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/pin_pad.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_app_bar_button.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../widgets/tv_switch_list_tile.dart';
import '../../widgets/tv_text_field_gate.dart';
import 'group_management_screen.dart';
import 'hidden_channels_screen.dart';
import '../../l10n/l10n.dart';

/// Every color swatch a profile's avatar can use — just `colorIndex` into
/// this fixed list rather than a full color picker, which would be a lot
/// of extra D-pad-navigable UI for something purely decorative.
const _profileColors = [
  Colors.deepPurple,
  Colors.teal,
  Colors.orange,
  Colors.pink,
  Colors.blue,
  Colors.green,
];

/// Same focusable-swatch shape as `ThemeScreen`'s `_PaletteSwatch` — a
/// real focusable widget (`InkWell`), not the bare unfocusable
/// `GestureDetector` this used to be. That alone isn't what makes the row
/// reachable by D-pad, though — see `_AddProfileScreenState`'s own doc
/// comment for the actual fix: escaping *out of* the Name field above via
/// arrow keys needs an explicit handler regardless of what's focusable
/// below it. [focusNode] is that explicit escape target, requested
/// directly by that handler rather than left to default traversal.
class _ColorSwatch extends StatefulWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.focusNode,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<_ColorSwatch> createState() => _ColorSwatchState();
}

class _ColorSwatchState extends State<_ColorSwatch> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _focused = f),
      onTap: widget.onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            border: widget.selected
                ? Border.all(color: Colors.white, width: 3)
                : null,
            boxShadow: _focused
                ? [
                    const BoxShadow(
                        color: Colors.white, blurRadius: 0, spreadRadius: 3)
                  ]
                : null,
          ),
          child: widget.selected
              ? const Icon(Icons.check, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

/// Settings > Profiles: list every viewer profile, add a new one, or drill
/// into one to rename/configure/delete it. Plain vertical lists throughout
/// (both here and in [_ProfileDetailScreen]/[_AddProfileScreen]) with no
/// custom D-pad handling — see `SettingsMenuScreen`'s own doc comment for
/// why default Flutter focus traversal is the proven-reliable choice for
/// this shape of screen, not a new exception to it.
class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewers = context.watch<ViewerProfileService>();
    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: tr('Profiles'),
        body: ListView(
          children: [
            for (final profile in viewers.profiles)
              _ProfileTile(
                  profile: profile, isActive: profile.id == viewers.active.id),
            TvMenuTile(
              leading: const CircleAvatar(child: Icon(Icons.add)),
              title: tr('Add Profile'),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _AddProfileScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.profile, required this.isActive});
  final ViewerProfile profile;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return TvMenuTile(
      leading: CircleAvatar(
        backgroundColor:
            _profileColors[profile.colorIndex % _profileColors.length],
        child: Text(profile.name.isEmpty ? '?' : profile.name[0].toUpperCase()),
      ),
      title: profile.displayName,
      subtitle: profile.isRestricted ? tr('Restricted') : null,
      trailing:
          isActive ? const Icon(Icons.check_circle) : const SizedBox.shrink(),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _ProfileDetailScreen(profileId: profile.id))),
    );
  }
}

class _ProfileDetailScreen extends StatefulWidget {
  const _ProfileDetailScreen({required this.profileId});
  final String profileId;

  @override
  State<_ProfileDetailScreen> createState() => _ProfileDetailScreenState();
}

class _ProfileDetailScreenState extends State<_ProfileDetailScreen> {
  Future<void> _rename(ViewerProfile profile) async {
    final controller = TextEditingController(text: profile.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Rename profile')),
        content: FocusNodeOwner(
          builder: (context, node) => TvTextFieldGate(
            focusNode: node,
            builder: (context, readOnly) => TextField(
                controller: controller,
                focusNode: node,
                readOnly: readOnly,
                autofocus: true),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await context.read<ViewerProfileService>().renameProfile(profile.id, name);
  }

  /// Switches to this profile first (if it isn't already active) so the
  /// pushed screen — whichever already-correct, viewer-transparent
  /// `PlaylistSession` scoping `GroupManagementScreen`/`HiddenChannelsScreen`
  /// already have — ends up configuring *this* profile's groups, not
  /// whichever one happened to be active before. No separate "edit a
  /// non-active profile's groups" code path needed: switching first and
  /// reusing the existing screens as-is is simpler and reuses code that's
  /// already proven correct for the active viewer.
  Future<bool> _ensureActive(ViewerProfile profile) async {
    final viewers = context.read<ViewerProfileService>();
    if (viewers.active.id == profile.id) return true;
    return viewers.switchTo(context, profile.id);
  }

  Future<void> _delete(ViewerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete "{name}"?', {'name': profile.name})),
        content: Text(tr(
            'Their favorites, hidden groups, and watch history are deleted too. This can\'t be undone.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('Cancel'))),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('Delete'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final deleted =
        await context.read<ViewerProfileService>().deleteProfile(profile.id);
    if (!mounted) return;
    if (deleted) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(tr('Switch to another profile before deleting this one'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewers = context.watch<ViewerProfileService>();
    final playlist = context.watch<PlaylistManager>();
    final profile = viewers.profiles.firstWhere((p) => p.id == widget.profileId,
        orElse: ViewerProfile.main);
    final isActive = viewers.active.id == profile.id;
    final isMain = profile.isMain;

    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: profile.displayName,
        // Keep Delete in the toolbar and omit it for the main profile.
        actions: isMain
            ? null
            : [
                TvAppBarButton.icon(
                  icon: Icons.delete_outline,
                  tooltip: tr('Delete profile'),
                  onTap: () => _delete(profile),
                ),
              ],
        body: ListView(
          children: [
            TvMenuTile(
              icon: Icons.swap_horiz,
              title: isActive
                  ? tr('This is the active profile')
                  : tr('Switch to this profile'),
              enabled: !isActive,
              onTap: () => viewers.switchTo(context, profile.id),
            ),
            TvMenuTile(
              icon: Icons.edit,
              title: tr('Rename'),
              onTap: () => _rename(profile),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(tr('What this profile can see'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final p in playlist.profiles) ...[
              TvMenuTile(
                icon: Icons.folder_outlined,
                title: tr('Groups — {name}', {'name': p.name}),
                onTap: () async {
                  final ok = await _ensureActive(profile);
                  if (!ok) return;
                  if (!context.mounted) return;
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => GroupManagementScreen(playlistId: p.id)));
                },
              ),
              TvMenuTile(
                icon: Icons.visibility_off_outlined,
                title: tr('Hidden channels — {name}', {'name': p.name}),
                onTap: () async {
                  final ok = await _ensureActive(profile);
                  if (!ok) return;
                  if (!context.mounted) return;
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => HiddenChannelsScreen(playlistId: p.id)));
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddProfileScreen extends StatefulWidget {
  const _AddProfileScreen();

  @override
  State<_AddProfileScreen> createState() => _AddProfileScreenState();
}

class _AddProfileScreenState extends State<_AddProfileScreen> {
  final _nameController = TextEditingController();
  final _nameFocus = FocusNode();

  /// One per swatch in `_profileColors`, explicit escape targets for
  /// [_handleNameFieldEscapeKey] — see that method's doc comment.
  final List<FocusNode> _colorFocuses =
      List.generate(_profileColors.length, (_) => FocusNode());
  int _colorIndex = 0;
  bool _isRestricted = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleNameFieldEscapeKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleNameFieldEscapeKey);
    _nameController.dispose();
    _nameFocus.dispose();
    for (final node in _colorFocuses) {
      node.dispose();
    }
    super.dispose();
  }

  /// Explicit Up/Down handling lets the remote leave EditableText and reach the colour
  /// selector or toolbar.
  bool _handleNameFieldEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) return false;
    if (FocusManager.instance.primaryFocus != _nameFocus) return false;
    _colorFocuses.first.requestFocus();
    return true;
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    final pin = context.read<ParentalPin>();
    if (_isRestricted && !pin.isSet) {
      // A restricted profile must never exist without a PIN already set —
      // run setup *before* creating it, and bail out (not create an
      // unprotected restricted profile) if it's cancelled partway.
      final didSetPin = await setupPinFlow(context);
      if (!mounted) return;
      if (!didSetPin) {
        setState(() => _saving = false);
        return;
      }
    }
    final viewers = context.read<ViewerProfileService>();
    final profile = await viewers.createProfile(
        name: name, colorIndex: _colorIndex, isRestricted: _isRestricted);
    if (!mounted) return;
    await viewers.switchTo(context, profile.id);
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (_isRestricted) {
      // Open visibility settings after creating a restricted profile, whose groups initially
      // remain hidden.
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _ProfileDetailScreen(profileId: profile.id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: tr('Add Profile'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TvTextFieldGate(
              focusNode: _nameFocus,
              builder: (context, readOnly) => TextField(
                controller: _nameController,
                focusNode: _nameFocus,
                readOnly: readOnly,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('Name'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: List.generate(_profileColors.length, (i) {
                return _ColorSwatch(
                  color: _profileColors[i],
                  selected: i == _colorIndex,
                  focusNode: _colorFocuses[i],
                  onTap: () => setState(() => _colorIndex = i),
                );
              }),
            ),
            const SizedBox(height: 16),
            TvSwitchListTile(
              title: Text(tr('Restricted')),
              subtitle: Text(tr(
                  'For a child — hides every group, including adult content, by default. A parent unhides specific categories per playlist afterward in Group Management. A PIN is required to switch away from this profile or to open Settings while it\'s active.')),
              value: _isRestricted,
              onChanged: (v) => setState(() => _isRestricted = v),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('Create')),
            ),
          ],
        ),
      ),
    );
  }
}
