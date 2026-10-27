import '../../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/m3u_group.dart';
import '../../services/playlist_manager.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/mode_button.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/tv_app_bar_button.dart';
import '../../l10n/l10n.dart';

/// Lists every group/category (live, movies, TV shows) — including hidden
/// ones, which is the whole point of this screen — with per-group and
/// bulk "Hide All" / "Show All" controls. Anything hidden here disappears
/// from the corresponding tab on the main screen.
class GroupManagementScreen extends StatefulWidget {
  const GroupManagementScreen(
      {super.key, required this.playlistId, this.deferLoading = false});

  /// Which playlist this screen manages groups for — selecting a playlist
  /// in `PlaylistManagerScreen`'s own list *is* the "which playlist"
  /// picker; this screen itself only ever shows one playlist's groups at
  /// a time, reusing the exact same Hide All/Show All UI it always has.
  final String playlistId;

  /// True when opened from the initial "choose groups first" add-playlist
  /// step — checking a box there doesn't fetch that category immediately
  /// (which was causing rapid-fire loading/jank while picking groups);
  /// [PlaylistManager.warmAllCategories] does one batched pass over
  /// everything chosen right after this screen closes instead.
  final bool deferLoading;

  @override
  State<GroupManagementScreen> createState() => _GroupManagementScreenState();
}

class _GroupManagementScreenState extends State<GroupManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// Block Back until Done or an explicit confirmation allows the pop. Keep accidental exits
  /// separate from completed group setup.
  bool _allowPop = false;

  Future<bool> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Leave group selection?')),
        content: Text(
          tr('Your channel visibility choices are saved.'),
        ),
        // Use a focus-only fill so the focused confirmation action remains distinct from the
        // other button.
        actions: [
          ModeButton(
            label: tr('Stay'),
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: tr('Leave'),
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  /// The AppBar's "Done" button (and the Up-arrow fallback that targets
  /// it) turned out not to be reliably reachable on real remotes — a
  /// Firestick user couldn't find any way to it besides a Bluetooth
  /// mouse. This is the actual fix: a 4th tab, reached by the exact same
  /// Right-arrow tab-switching already used to move between TV/Movies/TV
  /// Shows, with nothing on it but a single always-focused Confirm
  /// button — no hunting for it, no relying on Up-arrow doing the right
  /// thing on unfamiliar hardware.
  Future<void> _confirmDone() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Save playlist?')),
        content: Text(
          tr('Your playlist will be saved with the selected groups. You can always add or remove groups later in Settings > Group Management.'),
        ),
        // Same ModeButton fix as _confirmLeave above — see its comment.
        actions: [
          ModeButton(
            label: tr('Cancel'),
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: tr('Confirm'),
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _allowPop = true);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// One per tab (TV/Movies/TV Shows/Confirm) — lets [_goToTab] jump focus
  /// straight into the newly-selected tab's content instead of leaving
  /// focus wherever it was (which, on the tab that's now hidden behind the
  /// TabBarView animation, would be nowhere useful).
  final List<FocusScopeNode> _tabScopes =
      List.generate(2, (i) => FocusScopeNode(debugLabel: 'group-mgmt-tab-$i'));

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final scope in _tabScopes) {
      scope.dispose();
    }
    _doneButtonFocusNode.dispose();
    super.dispose();
  }

  /// Switches tabs directly, bound to Left/Right (and 1/2/3) below — a
  /// user checking off groups one at a time otherwise has to scroll all
  /// the way back up to the TabBar just to move from TV to Movies.
  void _goToTab(int index) {
    final clamped = index.clamp(0, 1);
    if (clamped == _tabController.index) return;
    setState(() => _tabController.index = clamped);
    _tabScopes[clamped].requestFocus();
  }

  /// Left/Right switching tabs unconditionally made "Show All"/"Hide All"
  /// unreachable from each other — they sit side by side in the same Row,
  /// and Right from "Show All" was jumping straight to the Movies tab
  /// instead of moving to "Hide All" right next to it. Try the normal
  /// move first; only switch tabs once there's nowhere further to go in
  /// that direction (same pattern as the browse grid's edge handling).
  void _handleTabArrow(TraversalDirection direction, int tabDelta) {
    final moved =
        FocusManager.instance.primaryFocus?.focusInDirection(direction) ??
            false;
    if (!moved) _goToTab(_tabController.index + tabDelta);
  }

  /// The AppBar's "Done" button wasn't reachable by D-pad at all — nothing
  /// handed focus up to it, so it was only reachable by touch/mouse (the
  /// physical device Back button still works to leave, via [PopScope]
  /// above, but that's a different action from a deliberate "Done").
  /// Same fallback pattern as the tab arrows: try moving up normally
  /// first (into the checkbox list), and only jump to Done once there's
  /// genuinely nowhere further up to go.
  final FocusNode _doneButtonFocusNode =
      FocusNode(debugLabel: 'group-mgmt-done');

  void _handleUpArrow() {
    final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.up) ??
        false;
    if (!moved) _doneButtonFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistManager>();

    return withTvThemeIfNeeded(
        context,
        (context) => PopScope(
            canPop: _allowPop,
            onPopInvokedWithResult: (didPop, result) async {
              if (didPop) return;
              final leave = await _confirmLeave();
              if (!context.mounted || !leave) return;
              setState(() => _allowPop = true);
              if (!context.mounted) return;
              // Return a completed result after a confirmed exit so the caller can continue
              // the configured catalogue warm-up.
              Navigator.of(context).pop(true);
            },
            child: SettingsScaffold(
              title: tr('Group Management'),
              // Explicit "Done" so the caller can tell a deliberate finish apart
              // from just leaving the screen some other way (physical back, an
              // accidental pop, or confirming "leave" in the prompt above
              // without having pressed Done). See
              // AddPlaylistScreen._promptDownloadScope for why that distinction
              // matters here specifically: it decides whether to start
              // downloading everything not yet hidden.
              actions: [
                TvAppBarButton.label(
                  label: tr('Done'),
                  focusNode: _doneButtonFocusNode,
                  onTap: () {
                    setState(() => _allowPop = true);
                    Navigator.of(context).pop(true);
                  },
                ),
              ],
              bottom: TabBar(
                controller: _tabController,
                tabs: [
                  Tab(text: tr('Live TV')),
                  Tab(text: tr('Confirm')),
                ],
              ),
              body: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                      _handleTabArrow(TraversalDirection.left, -1),
                  const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                      _handleTabArrow(TraversalDirection.right, 1),
                  const SingleActivator(LogicalKeyboardKey.digit1): () =>
                      _goToTab(0),
                  const SingleActivator(LogicalKeyboardKey.digit2): () =>
                      _goToTab(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp):
                      _handleUpArrow,
                },
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    FocusScope(
                      node: _tabScopes[0],
                      child: _GroupList(
                        groups: playlist.tvGroups
                            .where((g) => g.playlistId == widget.playlistId)
                            .toList(),
                        playlist: playlist,
                        playlistId: widget.playlistId,
                        deferLoading: widget.deferLoading,
                      ),
                    ),
                    FocusScope(
                      node: _tabScopes[1],
                      child: _ConfirmTab(onConfirm: _confirmDone),
                    ),
                  ],
                ),
              ),
            )));
  }
}

class _ConfirmTab extends StatelessWidget {
  const _ConfirmTab({required this.onConfirm});

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 48, color: interfaceColor(context, Colors.white70)),
            const SizedBox(height: 16),
            Text(
              tr('If you are done selecting your groups, press Confirm below.\n\nIf you are not done yet, press Left to go back to your categories.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: interfaceColor(context, Colors.white70)),
            ),
            const SizedBox(height: 24),
            FilledButton(
              autofocus: true,
              onPressed: onConfirm,
              child: Text(tr('Confirm')),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.playlist,
    required this.playlistId,
    this.deferLoading = false,
  });

  final List<M3uGroup> groups;
  final PlaylistManager playlist;
  final String playlistId;
  final bool deferLoading;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return Center(
          child: Text(tr('No categories yet — load a playlist first.')));
    }

    final titles = groups.map((g) => g.title);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => playlist.setGroupsHidden(
                      playlistId, titles, false,
                      loadImmediately: !deferLoading),
                  child: Text(tr('Show All')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      playlist.setGroupsHidden(playlistId, titles, true),
                  child: Text(tr('Hide All')),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final group = groups[index];
              // Key only the checkbox glyph by its value to force repaint while keeping the
              // row and its FocusNode stable across toggles.
              return ListTile(
                key: ValueKey(group.title),
                title: Text(group.title),
                trailing: RepaintBoundary(
                  key: ValueKey(group.isHidden),
                  child: Icon(
                    group.isHidden ? Icons.circle_outlined : Icons.check_circle,
                    color: group.isHidden
                        ? interfaceColor(context, Colors.white54)
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                onTap: () => playlist.setGroupHidden(
                  playlistId,
                  group.title,
                  !group.isHidden,
                  loadImmediately: !deferLoading,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
