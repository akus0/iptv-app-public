import '../widgets/tv_text_field_gate.dart';
import '../utils/guarded_dialog.dart';
import '../utils/open_multiview.dart';
import '../utils/interface_colors.dart';
import '../widgets/tv_preview_remote_navigation.dart';
import '../widgets/player_stream_info.dart';
import '../widgets/guide_fast_browse_row.dart';
import '../utils/epg_timeline.dart';
import '../utils/guide_scroll_acceleration.dart';
import '../widgets/guide_browse_position.dart';
import '../widgets/guide_programme_row.dart';
import 'package:flutter/foundation.dart';
import '../widgets/live_channel_logo.dart';
import '../widgets/live_navigation_body.dart';
import '../utils/guide_section_index.dart';
import '../widgets/sticky_guide_header.dart';
import '../utils/live_category_folders.dart';
import '../widgets/live_category_icon.dart';
import '../widgets/live_category_folders.dart';
import '../utils/live_guide_search.dart';
import '../widgets/guide_section_picker.dart';
import '../widgets/iptv_bottom_bar.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/m3u_group.dart';
import '../services/app_preferences.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../utils/time_format.dart';
import '../utils/scroll_safety.dart';
import '../utils/constants.dart';
import '../utils/route_observer.dart';
import '../utils/top_level_tab_route.dart';
import '../widgets/main_navigation_rail.dart';
import '../widgets/vertical_rail_focus.dart';
import '../utils/tv_theme.dart';
import '../widgets/preview_player_controls.dart';
import '../widgets/catalog_warmup_banner.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/player_dialog.dart';
import '../widgets/tv_menu_tile.dart';
import '../widgets/live_resume_hint.dart';
import '../widgets/mode_button.dart';
import '../widgets/player_controls.dart';
import '../widgets/settings_scaffold.dart';
import 'catalog_sync_screen.dart';

import 'multiview_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'search_screen.dart';
import 'sports_screen.dart';

import 'settings/settings_menu_screen.dart';
import 'settings/settings_workspace.dart';
import '../l10n/l10n.dart';

bool _mobileGuide(BuildContext context) =>
    !context.read<AppPreferences>().isTelevision &&
    MediaQuery.sizeOf(context).shortestSide < 600;
bool _landscapeGuide(BuildContext context) =>
    _mobileGuide(context) &&
    MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
double _guideRowHeight(BuildContext context) =>
    context.read<AppPreferences>().isTelevision
        ? 38
        : _landscapeGuide(context)
            ? 36
            : 44;
double _guideRulerHeight(BuildContext context) => _landscapeGuide(context)
    ? 24
    : _mobileGuide(context)
        ? 28
        : 30;

double _guideLogoSize(BuildContext context) => _landscapeGuide(context)
    ? 24
    : context.read<AppPreferences>().isTelevision
        ? 26
        : _mobileGuide(context)
            ? 28
            : 30;

double _guideBlockGap(BuildContext context) =>
    context.read<AppPreferences>().isTelevision
        ? 2
        : _mobileGuide(context)
            ? 3
            : 4;

/// Keep sidebar rows visible after traversal or explicit focus handoffs.
/// TV reveals only clipped rows immediately; touch keeps its centered reveal.
void _ensureVisible(BuildContext context) {
  if (context.read<AppPreferences>().isTelevision) {
    // Remote focus should only reveal a clipped row, without recentering
    // already-visible rows or animating the rail behind the next keypress.
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    Scrollable.ensureVisible(context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    return;
  }
  Scrollable.ensureVisible(context,
      duration: const Duration(milliseconds: 150), alignment: 0.5);
}

/// Responsive app shell with Live TV categories, guide and preview, plus navigation to
/// Sports and the on-demand libraries. Phone portrait uses a bottom bar; wide layouts
/// use columns that collapse as focus advances. All layouts share the same playback and
/// catalogue services.
class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({super.key});

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> with RouteAware {
  String _tab = 'TV';
  bool _retrying = false;

  /// Settings > Theme "Full-screen video behind the guide", in effect right
  /// now: Timeline guide on the TV tab, landscape, Android — playing or
  /// not (a dark screen until a channel starts). Set each build. The video then lives in one
  /// full-screen layer behind everything (see [build]) and the corner box
  /// is left empty — never both, a second platform view of the same
  /// controller is the bug LiveResumeHint's doc comment describes.
  bool _fullVideo = false;

  /// Phone held in portrait: the side-by-side columns don't fit, so only
  /// one is shown at a time (tabs -> groups -> content), [_phonePage]
  /// picks which, and Back walks back through them. Refreshed every build.
  bool _compact = false;
  int _phonePage = 2;

  /// Group identity is `(playlistId, title)` now that more than one
  /// playlist can exist (two providers can share a category name), but
  /// this field itself stays a bare title — every place that reads it
  /// back either re-resolves its playlistId itself when it actually needs
  /// one (Favorites-tab selections, via `_favoriteGroupCategory`) or
  /// merges across playlists by title on purpose (Live TV's
  /// `visibleChannels`/`_effectiveLiveGroup`, an accepted edge case if two
  /// playlists ever share an exact live group name).
  String? _selectedGroup;
  LiveCategoryCollection? _selectedLiveCollection;
  Object? _inferredLiveCollectionKey;
  LiveCategoryCollection? _inferredLiveCollection;

  /// Current focus column: tabs, groups, list or preview. Earlier columns collapse as focus
  /// advances into content.
  // Column navigation changes geometry and shortcuts, not guide/catalogue data.
  // Keep those expensive children stable while TV rails hide or reappear.
  final _columnDepth = ValueNotifier<int>(0);
  final _liveRailTraversal = VerticalRailTraversalPolicy();
  int get _focusDepth => _columnDepth.value;
  set _focusDepth(int value) => _columnDepth.value = value;

  /// One FocusScopeNode per column. Explicit column jumps avoid geometric traversal between
  /// collapsed columns of different widths; each scope restores its last focused item.
  final FocusScopeNode _col0Scope = FocusScopeNode(debugLabel: 'tv-tabs');
  // Not final — see _onTabChanged, which replaces these with fresh
  // instances on every tab switch specifically (not just cleared) to
  // guarantee no stale focus memory survives, while every other use of
  // these two (_moveColumnFocus, column-to-column movement within the
  // *same* tab) keeps relying on FocusScopeNode's own restore-last-
  // focused-child behavior exactly as the doc comment above describes —
  // that's genuinely desirable there, just not across a tab switch.
  FocusScopeNode _col1Scope = FocusScopeNode(debugLabel: 'tv-col1');
  FocusScopeNode _col2Scope = FocusScopeNode(debugLabel: 'tv-col2');

  /// The "TV" row in the tabs rail. Focused once at launch (see initState)
  /// so the D-pad cursor starts somewhere visible — before, nothing was
  /// focused until the first key press, which then landed at an arbitrary
  /// spot (top, bottom or inside the channel list).
  final FocusNode _tvTabFocusNode = FocusNode(debugLabel: 'tv-tab-TV');

  /// Explicit focus target for the first groups-row action. Only one of Favourites, All or
  /// What's New is mounted at a time, so they can share the node.
  final FocusNode _firstGroupRowFocusNode =
      FocusNode(debugLabel: 'first-group-row');

  /// True once a Left press at the leftmost poster in the browse grid has
  /// found nowhere further left to go, but hasn't yet been confirmed by a
  /// second such press — see [_handleBrowseLeft]. Requiring two in a row
  /// stops one slightly-too-eager Left press from accidentally bouncing
  /// all the way out of the catalog and back to the tabs rail.
  bool _leftEdgeArmed = false;
  Timer? _leftEdgeArmTimer;

  /// Whichever programme block last took focus in the Timeline Guide —
  /// lifted up here (not kept inside [_TimelineGuide]) because the header
  /// that describes it, [_GuideNowPanel], sits above the guide as a
  /// sibling, not inside it. Null until the guide is first navigated,
  /// which is when [_GuideNowPanel] falls back to the playing channel's
  /// own live programme instead.
  // A remote focus move must not rebuild the catalogue, video or guide.
  final _guideFocus = ValueNotifier<(Channel?, EpgProgram?)>((null, null));

  /// Anchor the second-Left hint to the focused poster's captured global bounds. No
  /// continuous tracking is needed during this interaction.
  OverlayEntry? _leftEdgeHintOverlay;

  /// Groups mid-way through the "grey out for 30s, then actually hide"
  /// flow — long-pressing one of these again cancels the hide instead of
  /// (necessarily) hiding it, since it hasn't actually disappeared yet.
  final Set<String> _pendingHideGroups = {};
  final Map<String, Timer> _pendingHideTimers = {};

  static const _pendingHideDuration = Duration(seconds: 30);

  /// `_pendingHideGroups`/`_pendingHideTimers`/`_groupRowKeys` are all
  /// keyed by this composite instead of a bare title — two playlists can
  /// share a category name, and a bare-title key would let one playlist's
  /// "pending hide"/browse-row-scroll-target state bleed into another's
  /// same-named group.
  String _groupKey(String playlistId, String title) => '$playlistId::$title';

  void _startPendingHide(String playlistId, String title) {
    final key = _groupKey(playlistId, title);
    _pendingHideTimers[key]?.cancel();
    setState(() => _pendingHideGroups.add(key));
    _pendingHideTimers[key] = Timer(_pendingHideDuration, () {
      _pendingHideTimers.remove(key);
      if (!mounted) return;
      setState(() => _pendingHideGroups.remove(key));
      context.read<PlaylistManager>().setGroupHidden(playlistId, title, true);
    });
  }

  void _cancelPendingHide(String playlistId, String title) {
    final key = _groupKey(playlistId, title);
    _pendingHideTimers.remove(key)?.cancel();
    setState(() => _pendingHideGroups.remove(key));
  }

  /// Long-press menu for a real category row — "add/remove favorites"
  /// (the whole group's channels, not one at a time) and hide/cancel-hide.
  /// [category] is 'vod'/'series' for a Movies/TV Shows group (enables the
  /// "Expand catalog" option — see [GroupCatalogScreen]'s doc comment) or
  /// null for a Live TV group, which has no poster-grid concept to expand
  /// into.
  Future<void> _showGroupOptions(String playlistId, String title) async {
    final playlist = context.read<PlaylistManager>();
    final isFavorited = playlist.isGroupFavorited(playlistId, title);
    final isPending = _pendingHideGroups.contains(_groupKey(playlistId, title));

    final choice = await showGuardedDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('favorite'),
            child: Text(isFavorited
                ? tr('Remove from Favourites')
                : tr('Add to Favourites')),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(isPending ? 'cancel_hide' : 'hide'),
            child: Text(isPending ? tr('Cancel Hide') : tr('Hide Group')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('move'),
            child: Text(tr('Move Up / Down')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('move_top'),
            child: Text(tr('Move to Top')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Cancel')),
          ),
        ],
      ),
    );
    if (!mounted) return;

    switch (choice) {
      case 'move':
        setState(() {
          _movingGroupKey = _groupKey(playlistId, title);
          _movingGroupType = 'tv';
        });
      case 'move_top':
        await _moveGroupToTop(playlistId, title, 'tv');
      case 'favorite':
        playlist.setGroupFavorited(playlistId, title, !isFavorited);
      case 'hide':
        _startPendingHide(playlistId, title);
      case 'cancel_hide':
        _cancelPendingHide(playlistId, title);
    }
  }

  /// Titles of [playlistId]'s groups exactly as the groups column shows
  /// them right now, in order — what "position N of M" and a move step are
  /// measured against (see [PlaylistSession.moveGroup]'s `shown`).
  List<String> _shownGroupTitles(
      PlaylistManager playlist, String playlistId, String type) {
    final groups = playlist.tvGroups.where((g) => !g.isHidden);
    return groups
        .where((g) => g.playlistId == playlistId)
        .map((g) => g.title)
        .toList();
  }

  /// Group currently in "Move Up / Down" mode (a [_groupKey]), or null.
  /// While set, that row's own key handler turns Up/Down into moves and
  /// Select/Back into "done" — focus never leaves the row, so the user just
  /// follows the highlighted group to where it should go. No dialog.
  String? _movingGroupKey;
  String _movingGroupType = 'tv';

  Future<void> _moveGroupStep(
      String playlistId, String title, int delta) async {
    final playlist = context.read<PlaylistManager>();
    await playlist.moveGroup(playlistId, _movingGroupType, title, delta,
        shown: _shownGroupTitles(playlist, playlistId, _movingGroupType));
    if (!mounted) return;
    // Keep the keyed, focused row visible after reordering with a direct scroll jump.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null && focused.mounted) {
        Scrollable.ensureVisible(focused,
            alignmentPolicy: delta < 0
                ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
                : ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      }
    });
  }

  void _endGroupMove() {
    if (_movingGroupKey == null) return;
    setState(() => _movingGroupKey = null);
  }

  /// Group to grab focus on its next build — used by [_moveGroupToTop],
  /// whose row usually isn't built at all at its old scroll position.
  String? _focusGroupKeyOnBuild;

  /// "Move to Top" from [_showGroupOptions]: first among its playlist's
  /// visible groups. Scrolls the column to the top and keeps focus on it.
  Future<void> _moveGroupToTop(
      String playlistId, String title, String type) async {
    final playlist = context.read<PlaylistManager>();
    final shown = _shownGroupTitles(playlist, playlistId, type);
    await playlist.moveGroup(playlistId, type, title, -shown.length,
        shown: shown);
    if (!mounted) return;
    setState(() => _focusGroupKeyOnBuild = _groupKey(playlistId, title));
    final topRow = _firstGroupRowFocusNode.context;
    if (topRow != null && topRow.mounted) Scrollable.ensureVisible(topRow);
  }

  /// Shared channel actions for the guide and compact channel list.
  Future<void> _showChannelOptions(Channel channel) async {
    final playlist = context.read<PlaylistManager>();
    final isFavorited = channel.isFavorite;
    final isHidden = playlist.isChannelHidden(channel);

    final choice = await showGuardedDialog<String>(
      context: context,
      builder: (context) => SwallowHeldActivate(
        child: PlayerDialog(
          title: 'Channel options',
          subtitle: channel.name,
          icon: Icons.live_tv,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (canOpenMultiview(context) && !isGuideSection(channel))
              TvMenuTile(
                  autofocus: true,
                  icon: Icons.grid_view,
                  title: 'Open in multiview',
                  onTap: () => Navigator.pop(context, 'multiview')),
            TvMenuTile(
                autofocus:
                    !canOpenMultiview(context) || isGuideSection(channel),
                icon: isFavorited ? Icons.star : Icons.star_border,
                title: isFavorited
                    ? tr('Remove from Favourites')
                    : tr('Add to Favourites'),
                onTap: () => Navigator.pop(context, 'favorite')),
            TvMenuTile(
                icon:
                    isHidden ? Icons.visibility : Icons.visibility_off_outlined,
                title: isHidden
                    ? tr('Unhide this channel')
                    : tr('Hide this channel'),
                onTap: () => Navigator.pop(context, 'hide')),
          ]),
        ),
      ),
    );

    if (!mounted) return;
    switch (choice) {
      case 'multiview':
        await openChannelInMultiview(context, channel);
      case 'favorite':
        _toggleFavoriteWithFeedback(context, channel);
      case 'hide':
        _toggleHiddenWithFeedback(context, channel);
    }
  }

  /// Live TV channel list — lets [_restoreLiveFocus] jump back to a known
  /// row offset directly instead of guessing from the current scroll
  /// position.
  final ScrollController _liveListController = ScrollController();

  /// Whichever row currently matches [PlaybackService.currentChannel] —
  /// only one row can match at a time, so a single shared node is enough
  /// (see [_restoreLiveFocus]).
  final FocusNode _currentChannelFocusNode =
      FocusNode(debugLabel: 'current-channel-row');

  /// The plain live list's first row, when it isn't also the currently-
  /// playing channel (which already owns [_currentChannelFocusNode]) —
  /// see [_onGroupSelected]'s own doc comment for why this exists:
  /// without an explicit target, switching groups left the list's scroll
  /// offset and D-pad focus memory wherever they'd physically been in the
  /// *previous* group's list instead of resetting to the new one's first
  /// channel.
  final FocusNode _firstLiveChannelFocusNode =
      FocusNode(debugLabel: 'first-live-channel-row');

  /// Imperative access to the Timeline Guide's own State — lets
  /// [didPopNext] and the Up/Down key bindings below call
  /// [_TimelineGuideState.restoreFocusToChannel]/`.moveVertical` directly.
  /// A GlobalKey (not a plain field reference) because [_buildLiveRegion]
  /// creates a fresh [_TimelineGuide] widget on every rebuild — the key
  /// is what keeps Flutter reusing the same underlying State instead of
  /// a new one each time. Not `final`: swapped out for a brand new
  /// `GlobalKey` (in a `setState`) when that State's own
  /// `onWindowStale` fires — the one deliberate exception to "keeps
  /// reusing the same State", forcing exactly the fresh remount that
  /// call is asking for. See `_TimelineGuideState._windowStart`'s doc
  /// comment for why that's ever needed at all.
  GlobalKey<_TimelineGuideState> _timelineGuideKey = GlobalKey();

  /// Keep separate nodes for the filter button and text field. The field needs a fresh
  /// focus-gain event to establish its platform input connection.
  final FocusNode _timelineFilterButtonFocusNode =
      FocusNode(debugLabel: 'timeline-filter-button');
  final FocusNode _timelineFilterFieldFocusNode =
      FocusNode(debugLabel: 'timeline-filter-field');
  final TextEditingController _timelineFilterController =
      TextEditingController();

  /// Whether the Timeline guide's per-group channel filter bar is showing
  /// in place of the live preview box — see `_buildTimelineFilterBar`.
  bool _timelineFilterActive = false;

  /// Current filter text — applied only to the Timeline guide's own
  /// channel list (`_filteredLiveChannelsForGuide`), never the plain
  /// "Live" list view.
  String _timelineFilterQuery = '';
  bool _timelineSearchAll = false;
  Object? _allSearchChannelsKey;
  List<Channel> _allSearchChannels = const [];
  final _timelineSearchOptionNodes = [
    FocusNode(debugLabel: 'guide-search-group'),
    FocusNode(debugLabel: 'guide-search-all'),
    FocusNode(debugLabel: 'guide-search-clear'),
  ];

  /// Backs [_TimelineVirtualKeyboard] on real TV/remote-control devices —
  /// see `_buildTimelineFilterBar`'s own doc comment for why this exists
  /// instead of just the `TextField` above. `hasFocus` is true if *any*
  /// key in the grid currently has it, which is what the `arrowDown`/
  /// `onReachedTop` focus-coordination below actually needs (unlike a
  /// single `FocusNode`, which only reports true for one specific key).
  final FocusScopeNode _timelineKeyboardScope =
      FocusScopeNode(debugLabel: 'timeline-keyboard');

  /// One [FocusNode] per key, index-matched to `_TimelineVirtualKeyboard
  /// ._keyRows` so row/column arithmetic in its own `_moveFocus` and the
  /// "focus the first key" calls below line up by index — same shape as
  /// `pin_pad.dart`'s `_nodes`/`_keyValues`. Built once here (not inside
  /// the keyboard widget itself) so requesting focus on the first key
  /// from outside (opening the filter, or Up from the guide's top row)
  /// doesn't need a `GlobalKey`/`State` reference into the keyboard.
  late final List<List<FocusNode>> _timelineKeyboardNodes = List.generate(
      _TimelineVirtualKeyboard.keyRows.length,
      (r) => List.generate(_TimelineVirtualKeyboard.keyRows[r].length,
          (_) => FocusNode(debugLabel: 'timeline-keyboard-key')));

  /// A starting estimate only — rows can grow to two lines for a long
  /// channel name — refined by `Scrollable.ensureVisible` once the target
  /// row is close enough to the viewport to have actually been built.
  static const double _liveRowHeightEstimate = 72;

  /// Group-list rows were reading noticeably larger than they needed to
  /// at 10-foot viewing distance — this is a logical/DP size, so it comes
  /// out the same physical size on a 1080p or a 4K panel of the same
  /// screen dimensions; the fix is just a smaller number, not a
  /// per-resolution one.
  static const double _groupFontSize = 13;

  static bool _isBrowseTab(String tab) => tab == 'Movies' || tab == 'TV Shows';

  void _onTabChanged(String tab) {
    if (_isBrowseTab(tab)) {
      unawaited(_openLibrary(series: tab == 'TV Shows'));
      return;
    }
    _disarmLeftEdge();
    // Replace shared content scopes when tabs change to discard focus history from the
    // previous tab. unfocus() is insufficient when those scopes are already inactive.
    _col1Scope.dispose();
    _col2Scope.dispose();
    _col1Scope = FocusScopeNode(debugLabel: 'tv-col1');
    _col2Scope = FocusScopeNode(debugLabel: 'tv-col2');

    setState(() {
      _resetTimelineSearch(close: true);
      _tab = tab;
      _selectedGroup = null;

      _focusDepth = 0;
      _phonePage = _compact ? 1 : 0;
    });

    // Switching back to the TV tab clears the explicit group selection —
    // _effectiveLiveGroup falls back to the playing channel's own group
    // (or the first group) rather than an unfiltered "All" — but never
    // scrolled the channel list to whatever's actually playing — it just
    // showed the list from the top, which read as "the guide shows the
    // wrong channel" (a completely unrelated live channel happened to sort
    // first). _restoreLiveFocus already does exactly this scroll/focus,
    // today only wired to firing when *popping back from fullscreen*
    // (didPopNext) — this is the same restoration, just for the other way
    // of returning to this tab. Needs a frame so the channel list has
    // actually rebuilt for the new group/tab before scrolling within it.
    if (tab == 'TV') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreLiveFocus();
      });
    }
  }

  /// Browsing Movies/TV Shows stops a live channel playing in the background
  /// (no hidden audio, frees the decoder + provider connection) but keeps it
  /// resumable: it becomes the pending-resume channel, so the "Hold > to
  /// resume" pill and hold-Right still bring it back (a fresh start, same as
  /// the cold-launch resume).
  Future<void> _parkLiveChannel() =>
      context.read<PlaybackService>().parkLiveChannel();

  /// Left inside the poster grid should still move card-to-card normally.
  /// Only once that fails (nothing further left in the current row) does
  /// this arm a one-shot "confirm" window — a second Left press with
  /// nowhere to go, within [_leftEdgeArmWindow], is what actually exits
  /// back to the tabs rail. Any successful move, or letting the window
  /// lapse, disarms it.
  static const _leftEdgeArmWindow = Duration(seconds: 2);

  void _handleBrowseLeft() {
    final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.left) ??
        false;
    if (moved) {
      _disarmLeftEdge();
      return;
    }
    if (_leftEdgeArmed) {
      _disarmLeftEdge();
      _moveColumnFocus(-1, 2);
    } else {
      _leftEdgeArmed = true;
      _showLeftEdgeHint();
      _leftEdgeArmTimer?.cancel();
      _leftEdgeArmTimer = Timer(_leftEdgeArmWindow, _disarmLeftEdge);
    }
  }

  void _disarmLeftEdge() {
    _leftEdgeArmTimer?.cancel();
    _leftEdgeArmTimer = null;
    _leftEdgeArmed = false;
    _leftEdgeHintOverlay?.remove();
    _leftEdgeHintOverlay = null;
  }

  // Show the second-Left hint during the armed interval. OverlayEntry accepts the focused
  // poster's global position directly.
  void _showLeftEdgeHint() {
    final renderObject =
        FocusManager.instance.primaryFocus?.context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final overlay = Overlay.of(context, rootOverlay: true);
    _leftEdgeHintOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: topLeft.dx,
        top: topLeft.dy + size.height + 6,
        width: size.width,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: Theme.of(context).colorScheme.primary, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tr('Double'),
                      style: TextStyle(
                          color: interfaceColor(context, Colors.white),
                          fontSize: 12)),
                  Icon(Icons.keyboard_arrow_left,
                      color: interfaceColor(context, Colors.white), size: 16),
                  Icon(Icons.keyboard_arrow_left,
                      color: interfaceColor(context, Colors.white), size: 16),
                  const SizedBox(width: 4),
                  Text(tr('for groups'),
                      style: TextStyle(
                          color: interfaceColor(context, Colors.white),
                          fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_leftEdgeHintOverlay!);
  }

  /// Not a real category — a pinned entry at the top of the TV tab's
  /// groups column so favorited channels are reachable without leaving
  /// the tab (the separate "Favorites" tab still exists too).
  static const _favoritesGroupSentinel = '__favorites__';
  static const _historyGroupSentinel = '__history__';
  static const _allGroupSentinel = '__all_live__';

  /// [playlistId] is required for a real group selection (from a
  /// `_GroupRow`, which always has its own `M3uGroup.playlistId` on
  /// hand), null for the sentinels ("All", "Favourites") — Favorites-tab
  /// selections re-resolve their own playlistId via
  /// [_favoriteGroupCategory] instead of trusting the caller, since that
  /// column mixes bare titles pulled from every playlist's favorited
  /// groups together with no single caller-known playlist.
  void _onGroupSelected(String? group,
      {String? playlistId, LiveCategoryCollection? collection}) {
    final changed = group != _selectedGroup ||
        !identical(collection, _selectedLiveCollection) ||
        _timelineFilterActive ||
        _timelineFilterQuery.isNotEmpty ||
        _timelineSearchAll ||
        (_compact && _phonePage != 2);
    void select() {
      _resetTimelineSearch(close: true);
      _selectedGroup = group;
      _selectedLiveCollection = collection;
      if (_compact) _phonePage = 2;
      // Otherwise the Timeline Guide's header keeps describing a program
      // from whichever group was focused before this switch, until the
      // D-pad happens to land on something in the new one.
      _guideFocus.value = (null, null);
    }

    // Reselecting still resets search, details and list focus. Unchanged
    // catalogue widgets do not need another full build/layout pass.
    if (changed) {
      setState(select);
    } else {
      select();
    }
    if (group == null) return;
    if (group == _favoritesGroupSentinel ||
        group == _historyGroupSentinel ||
        group == _allGroupSentinel) {
      // Reset focus when opening Favourites so the previous group's row state cannot consume
      // a stray Select release.
      _resetLiveListFocus();
      _collapseAfterTouchPick();
      return;
    }

    _resetLiveListFocus();
    _collapseAfterTouchPick();
    return;
  }

  /// Reset the channel list's scroll and focus when changing groups. Touch enters the content
  /// column; remote navigation stays on the group until Right is pressed.
  void _collapseAfterTouchPick() {
    if (_compact || context.read<AppPreferences>().isTelevision) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!(_timelineGuideKey.currentState?.focusEntry() ?? false) &&
          !_col2Scope.hasFocus) {
        _col2Scope.requestFocus();
      }
      if (_focusDepth != 2) setState(() => _focusDepth = 2);
    });
  }

  void _resetLiveListFocus() {
    if (_liveListController.hasClients) _liveListController.jumpTo(0);
    final playlist = context.read<PlaylistManager>();
    final channels = _currentLiveChannels(playlist);
    if (channels.isEmpty) return;
    final playback = context.read<PlaybackService>();
    final firstIsPlaying = playback.currentChannel?.id == channels.first.id;
    (firstIsPlaying ? _currentChannelFocusNode : _firstLiveChannelFocusNode)
        .requestFocus();
  }

  void _onColumnFocus(int depth) {
    if (_focusDepth == depth) return;
    if (context.read<AppPreferences>().isTelevision) {
      _focusDepth = depth;
    } else {
      // Touch layouts also change the rail icons and the guide Back button.
      setState(() => _focusDepth = depth);
    }
  }

  /// Shared by system Back and the compact wide-layout guide button.
  void _handleBack() {
    // Back mid "Move Up / Down" just finishes the move.
    if (_movingGroupKey != null) {
      _endGroupMove();
      return;
    }
    if (_compact) {
      // The bottom bar replaced the tabs page as the way between
      // tabs: content -> groups -> exit; legacy page 0 -> groups.
      if (_phonePage == 2) {
        if (_timelineFilterActive) _closeTimelineFilter();
        setState(() => _phonePage = 1);
      } else if (_phonePage == 0) {
        setState(() => _phonePage = 1);
      } else {
        _confirmExit();
      }
      return;
    }
    if (_focusDepth == 0) {
      _confirmExit();
      return;
    }
    // Back from the filter keyboard clears the query and returns focus to the guide.
    if (_timelineKeyboardScope.hasFocus ||
        _timelineSearchOptionNodes.any((node) => node.hasFocus)) {
      _closeTimelineFilter(toGuide: true);
      return;
    }
    final previousDepth = (_focusDepth - 1).clamp(0, 2);
    _moveColumnFocus(-1, 2);
    // Port upstream's resize fix: touch Back must change the visible column
    // even if its focus node cannot take focus after a fold/unfold.
    if (!context.read<AppPreferences>().isTelevision &&
        _focusDepth != previousDepth) {
      setState(() => _focusDepth = previousDepth);
    }
  }

  /// Explicitly jumps D-pad focus one column left/right, clamped to
  /// [maxDepth]. Bound to the arrow keys via [CallbackShortcuts] in
  /// [build] instead of relying on default directional traversal — see the
  /// field doc on the `_colNScope` nodes for why.
  void _moveColumnFocus(int delta, int maxDepth) {
    final target = (_focusDepth + delta).clamp(0, maxDepth);
    if (target == _focusDepth) return;
    final scope = switch (target) {
      0 => _col0Scope,
      1 => _col1Scope,
      _ => _col2Scope,
    };
    if (target == 2 &&
        (_timelineGuideKey.currentState?.focusEntry() ?? false)) {
      return;
    }
    // See _firstGroupRowFocusNode's own doc comment — only when nothing's
    // already focused in the groups column (so returning to a previously-
    // browsed group still restores where you left off, same as before).
    if (target == 1 && _col1Scope.focusedChild == null) {
      _firstGroupRowFocusNode.requestFocus();
      return;
    }
    scope.requestFocus();
    // Safety net: a scope whose remembered child can't take focus any more
    // silently ignores this. Restore focus after toggling the full-video guide.
    // Land on the column's first row instead.
    if (target == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _col1Scope.hasFocus || !_col2Scope.hasFocus) return;
        _firstGroupRowFocusNode.requestFocus();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only when this screen is on top (the startup auto-resume or the
      // welcome prompt may already have pushed a route over it) and nothing
      // real holds focus yet — never steal focus from another screen.
      if (_route?.isCurrent == false) {
        return;
      }
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary is FocusScopeNode) {
        _tvTabFocusNode.requestFocus();
      }
    });
    _guideSearchRefresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _timelineFilterQuery.isNotEmpty && !_previewCovered) {
        setState(() {});
      }
    });
  }

  // Read current route state in callbacks without subscribing the large Live
  // screen to every push/pop. RouteAwareRegion owns that dependency.
  ModalRoute<dynamic>? _route;

  @override
  void dispose() {
    _releasePreviewHint?.call();
    _guideFocus.dispose();
    _columnDepth.dispose();
    _sharedPreviewAway.dispose();
    _guideSearchDebounce?.cancel();
    _guideSearchRefresh?.cancel();
    _tvTabFocusNode.dispose();
    _leftEdgeArmTimer?.cancel();

    _leftEdgeHintOverlay?.remove();

    _liveListController.dispose();
    _currentChannelFocusNode.dispose();
    _firstLiveChannelFocusNode.dispose();
    _col0Scope.dispose();
    _col1Scope.dispose();
    _col2Scope.dispose();

    _firstGroupRowFocusNode.dispose();
    _timelineFilterButtonFocusNode.dispose();
    _timelineFilterFieldFocusNode.dispose();
    _timelineFilterController.dispose();
    for (final node in _timelineSearchOptionNodes) {
      node.dispose();
    }
    _timelineKeyboardScope.dispose();
    for (final row in _timelineKeyboardNodes) {
      for (final node in row) {
        node.dispose();
      }
    }

    for (final timer in _pendingHideTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  /// Restore guide position and focus when a route above this screen is popped.
  @override
  void didPopNext() {
    _previewCovered = false;
    if (_contentChangedWhileCovered) {
      _contentChangedWhileCovered = false;
      setState(() {});
    }
    _syncPreviewHint(_previewHintWanted);
    if (_sportsRoute != null && !_compact) {
      _onColumnFocus(0);
      _tvTabFocusNode.requestFocus();
      return;
    }

    // Back from Settings with Movies/TV Shows just hidden while one of them
    // was the open tab: fall back to TV. Here rather than in build so the
    // tab switch's focus restore doesn't run under the Settings screen.

    // The fullscreen owner survives until route disposal, even though the
    // surface has already moved back. Search/Settings keep the browsed group.
    if (context.read<PlaybackService>().hasFullscreenOwner) {
      // Preserve the synthetic Favourites selection when it still contains the playing
      // channel; normal group fallback cannot reconstruct that selection.
      final playing = context.read<PlaybackService>().currentChannel;
      final stayOnFavorites = _selectedGroup == _favoritesGroupSentinel &&
          playing != null &&
          context
              .read<PlaylistManager>()
              .favoriteLiveChannels
              .any((c) => c.id == playing.id);
      final stayOnHistory = _selectedGroup == _historyGroupSentinel &&
          playing != null &&
          context
              .read<PlaybackService>()
              .recentLiveChannels(limit: 30)
              .any((c) => c.id == playing.id);
      final stayOnCollection = playing != null &&
          _selectedGroup == _selectedLiveCollection?.title &&
          (_selectedLiveCollection?.contains(playing) ?? false);
      if (!stayOnFavorites &&
          !stayOnHistory &&
          !stayOnCollection &&
          _selectedGroup != _allGroupSentinel) {
        setState(() => _selectedGroup = null);
      }
    }
    // Timeline mode needs its own playing-channel focus restoration; the plain-list focus
    // node does not control programme cells.
    if (context.read<AppPreferences>().guideViewMode == 'timeline') {
      final channel = context.read<PlaybackService>().currentChannel;
      if (channel != null) {
        _timelineGuideKey.currentState?.restoreFocusToChannel(channel.id);
      } else {
        _col0Scope.requestFocus();
      }
    } else {
      _restoreLiveFocus();
    }
    return;
  }

  /// Same channel-list filtering [_buildLiveList] renders, factored out so
  /// [_restoreLiveFocus] can find the playing channel's index in the exact
  /// same list instead of risking the two falling out of sync.
  Object? _guideChannelsKey;
  List<Channel> _guideChannels = const [];
  Object? _guideSearchKey;
  final _guideSearchSession = LiveGuideSearchSession();
  List<Channel> _guideSearchResults = const [];
  List<Channel>? _guideSearchSource;
  bool _guideSearching = false;
  bool _guideSearchSubmitRequested = false;
  Timer? _guideSearchDebounce;
  Timer? _guideSearchRefresh;

  Object? _liveCategoryCacheKey;
  List<M3uGroup> _liveCategoryCache = const [];
  Object? _liveFavoriteCacheKey;
  Set<String> _liveFavoriteCache = const {};

  List<M3uGroup> _liveCategories(PlaylistManager playlist) {
    final key = (playlist, playlist.liveRevision);
    if (_liveCategoryCacheKey != key) {
      _liveCategoryCacheKey = key;
      final providerLayouts = {
        for (final profile in playlist.profiles)
          if (playlist.categoryLayoutFor(profile.id) == 'provider') profile.id
      };
      _liveCategoryCache = playlist.tvGroups
          .where((g) =>
              !g.isHidden &&
              (providerLayouts.contains(g.playlistId) ||
                  !isLivePlaylistInformation(g.title)))
          .toList(growable: false);
    }
    return _liveCategoryCache;
  }

  bool _isFavoriteLiveChannel(PlaylistManager playlist, String id) {
    final key = (playlist, playlist.liveRevision);
    if (_liveFavoriteCacheKey != key) {
      _liveFavoriteCacheKey = key;
      _liveFavoriteCache =
          playlist.favoriteLiveChannels.map((c) => c.id).toSet();
    }
    return _liveFavoriteCache.contains(id);
  }

  List<Channel> _currentLiveChannels(PlaylistManager playlist) {
    final group = _effectiveLiveGroup(playlist);
    final history = group == _historyGroupSentinel
        ? context.read<PlaybackService>().recentLiveChannels(limit: 30)
        : null;
    var collection = _selectedLiveCollection?.title == group
        ? _selectedLiveCollection
        : null;
    final key = (
      playlist.liveRevision,
      group,
      collection?.playlistId,
      history?.map((c) => c.id).join('|')
    );
    if (_guideChannelsKey != key) {
      _guideChannelsKey = key;
      if (collection != null &&
          playlist.profiles.any((p) =>
              p.id == collection!.playlistId &&
              p.categoryLayout == 'provider')) {
        collection = null;
        _selectedLiveCollection = null;
        _selectedGroup = _allGroupSentinel;
      }
      if (collection != null) {
        collection = refreshLiveCategoryCollection(
            collection, _liveCategories(playlist));
        _selectedLiveCollection = collection;
      }
      _guideChannels = List<Channel>.unmodifiable(collection != null
          ? collection.select(playlist.visibleChannels(
              playlistId: collection.playlistId, category: 'tv'))
          : history ??
              (group == _favoritesGroupSentinel
                  ? playlist.favoriteLiveChannelsWithGroups
                  : playlist.visibleChannels(
                      groupTitle: group == _allGroupSentinel ||
                              (collection == null &&
                                  group?.startsWith('__live_collection__:') ==
                                      true)
                          ? null
                          : group,
                      category: 'tv')));
    }
    return _guideChannels;
  }

  List<Channel> _filteredLiveChannelsForGuide(PlaylistManager playlist) {
    final List<Channel> channels;
    if (_timelineSearchAll) {
      final key = (playlist, playlist.liveRevision);
      if (_allSearchChannelsKey != key) {
        _allSearchChannelsKey = key;
        _allSearchChannels =
            List<Channel>.unmodifiable(playlist.visibleLiveChannels);
      }
      channels = _allSearchChannels;
    } else {
      channels = _currentLiveChannels(playlist);
    }
    final q = _timelineFilterQuery.trim().toLowerCase();
    if (q.isEmpty) {
      _guideSearchDebounce?.cancel();
      _guideSearchKey = null;
      _guideSearchSession.clear();
      _guideSearchSource = null;
      _guideSearchResults = const [];
      _guideSearching = false;
      return channels;
    }
    final epg = context.read<EpgService>();
    final key = (
      channels,
      q,
      epg.changeRevision,
      DateTime.now().millisecondsSinceEpoch ~/ 30000
    );
    if (_guideSearchKey != key) {
      _guideSearchKey = key;
      _guideSearching = true;
      // Keep mounted results while the query refines. Clearing them first
      // disposes both guide columns and then lays them out again per key.
      // A different catalogue must never retain another category's results.
      if (!identical(_guideSearchSource, channels)) {
        _guideSearchResults = const [];
        _guideSearchSource = channels;
      }
      _guideSearchDebounce?.cancel();
      _guideSearchDebounce = Timer(const Duration(milliseconds: 160), () async {
        final results = await _guideSearchSession.search(
            channels, q, epg.getCurrentProgram,
            nextProgram: epg.getNextProgram,
            revision: () => (epg.changeRevision, epg.guideRowsLoaded.value),
            cancelled: () => !mounted || _guideSearchKey != key);
        if (!mounted || _guideSearchKey != key) return;
        setState(() {
          _guideSearchResults = results;
          _guideSearching = false;
        });
        if (_guideSearchSubmitRequested) _finishTimelineSearch();
      });
    }
    return _guideSearchResults;
  }

  void _resetTimelineSearch({bool close = false, bool resetScope = true}) {
    _guideSearchDebounce?.cancel();
    _guideSearchKey = null;
    _guideSearchSession.clear();
    _guideSearchSource = null;
    _guideSearchResults = const [];
    _guideSearching = _guideSearchSubmitRequested = false;
    _timelineFilterQuery = '';
    _timelineFilterController.clear();
    if (resetScope) _timelineSearchAll = false;
    if (close) _timelineFilterActive = false;
  }

  void _setTimelineSearchScope(bool all) {
    if (_timelineSearchAll == all) return;
    setState(() {
      _guideSearchSubmitRequested = false;
      _timelineSearchAll = all;
    });
  }

  Widget _buildTimelineSearchOptions({required bool television}) {
    return SizedBox(
      height: 30,
      child: Focus(
        onKeyEvent: (node, event) {
          if (!television ||
              (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
            return KeyEventResult.ignored;
          }
          final index =
              _timelineSearchOptionNodes.indexWhere((n) => n.hasFocus);
          if (index < 0) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight) {
            final next =
                (index + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1))
                    .clamp(0, 2);
            _timelineSearchOptionNodes[next].requestFocus();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowDown) {
            _timelineKeyboardNodes.first.first.requestFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Row(children: [
          Expanded(
              flex: 2,
              child: _TimelineKeyboardKey(
                  key: const ValueKey('guide-search-scope-group'),
                  focusNode: _timelineSearchOptionNodes[0],
                  label: 'This group',
                  selected: !_timelineSearchAll,
                  onPressed: () => _setTimelineSearchScope(false))),
          Expanded(
              flex: 2,
              child: _TimelineKeyboardKey(
                  key: const ValueKey('guide-search-scope-all'),
                  focusNode: _timelineSearchOptionNodes[1],
                  label: 'All channels',
                  selected: _timelineSearchAll,
                  onPressed: () => _setTimelineSearchScope(true))),
          Expanded(
              child: _TimelineKeyboardKey(
                  key: const ValueKey('guide-search-clear'),
                  focusNode: _timelineSearchOptionNodes[2],
                  label: 'Clear',
                  onPressed: () =>
                      setState(() => _resetTimelineSearch(resetScope: false)))),
        ]),
      ),
    );
  }

  void _editTimelineFilter(String value) {
    setState(() {
      _guideSearchSubmitRequested = false;
      _timelineFilterQuery = value;
    });
  }

  void _submitTimelineFilter() {
    _guideSearchSubmitRequested = true;
    _filteredLiveChannelsForGuide(context.read<PlaylistManager>());
    if (!_guideSearching) _finishTimelineSearch();
  }

  void _finishTimelineSearch() {
    _guideSearchSubmitRequested = false;
    // Wait for the latest query before choosing a result. Keep the keyboard
    // available when nothing matches so the user can correct their search.
    final results =
        _filteredLiveChannelsForGuide(context.read<PlaylistManager>());
    if (_guideSearching) {
      _guideSearchSubmitRequested = true;
      return;
    }
    if (results.isEmpty || _route?.isCurrent == false) {
      return;
    }
    _timelineFilterFieldFocusNode.unfocus();
    _closeTimelineFilter(
        toGuide: true, clearQuery: false, focusChannelId: results.first.id);
  }

  void _openTimelineFilter() {
    setState(() => _timelineFilterActive = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_timelineFilterActive) return;
      if (context.read<AppPreferences>().isTelevision) {
        _timelineKeyboardNodes.first.first.requestFocus();
      } else {
        _timelineFilterFieldFocusNode.requestFocus();
      }
    });
  }

  void _jumpToPlayingChannel() {
    final channel = context.read<PlaybackService>().currentChannel;
    if (channel == null) return;
    _timelineFilterFieldFocusNode.unfocus();
    setState(() {
      _resetTimelineSearch(close: true);
      if (!_currentLiveChannels(context.read<PlaylistManager>())
          .any((c) => c.id == channel.id)) {
        _selectedGroup = channel.group;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _timelineGuideKey.currentState?.restoreFocusToChannel(channel.id);
      }
    });
  }

  /// [toGuide] returns focus to the guide after closing the keyboard. [clearQuery] also ends
  /// filtering rather than only hiding the input.
  void _closeTimelineFilter(
      {bool toGuide = false, bool clearQuery = true, String? focusChannelId}) {
    _guideSearchSubmitRequested = false;
    setState(() {
      _timelineFilterActive = false;
      if (clearQuery) _resetTimelineSearch();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!(_route?.isCurrent ?? true)) return;
      if (focusChannelId != null) {
        _timelineGuideKey.currentState?.restoreFocusToChannel(focusChannelId);
      } else if (toGuide) {
        _timelineGuideKey.currentState?.focusEntry();
      } else {
        _timelineFilterButtonFocusNode.requestFocus();
      }
    });
  }

  /// The Live TV groups column has no standalone "All" entry anymore — it
  /// read as a confusing dumping-ground, and made returning from a stream
  /// feel like the app "forgot" which real group you were in (see
  /// [_onTabChanged], which resets [_selectedGroup] to null on every tab
  /// switch). Every visit now resolves to an actual group: whichever one
  /// is explicitly selected, otherwise the currently playing channel's own
  /// group (so switching tabs and back, or returning from fullscreen,
  /// lands exactly where playback left off), otherwise just the first
  /// visible group. [_buildGroupsColumn] and [_currentLiveChannels] both
  /// read through this instead of the raw field so the highlighted row
  /// always matches the list actually being shown.
  String? _effectiveLiveGroup(PlaylistManager playlist) {
    if (_selectedGroup != null) return _selectedGroup;
    final groups = _liveCategories(playlist);
    if (groups.isEmpty) return null;
    final playback = context.read<PlaybackService>();
    // Include the pending-resume channel when choosing an initial group, since currentChannel
    // is null before playback starts.
    final playing = playback.currentChannel ?? playback.pendingResumeChannel;
    if (playing != null) {
      // Prefer the synthetic Favourites group for a favourited channel before falling back to
      // its provider group.
      if (_isFavoriteLiveChannel(playlist, playing.id)) {
        return _favoritesGroupSentinel;
      }
      if (groups.any((g) => g.title == playing.group)) {
        if (context.read<StorageService>().getLiveCategoryFolders()) {
          final key =
              (playlist.liveRevision, playing.playlistId, playing.group);
          if (_inferredLiveCollectionKey != key) {
            _inferredLiveCollectionKey = key;
            _inferredLiveCollection = liveCollectionForSource(
                groups, playing.playlistId, playing.group,
                layout: playlist.categoryLayoutFor(playing.playlistId));
          }
          if (_inferredLiveCollection != null) {
            _selectedLiveCollection = _inferredLiveCollection;
            return _inferredLiveCollection!.title;
          }
        }
        return playing.group;
      }
    }
    return groups.first.title;
  }

  /// Scrolls/focuses the Live TV list back to whatever's actually playing.
  /// Popping the fullscreen player leaves the underlying list's scroll
  /// position and remembered focus technically intact, but a handful of
  /// things can invalidate them while covered (the list re-filtering, an
  /// EPG-driven rebuild, etc.) — rather than chase each of those down,
  /// this just re-asserts the one thing that's supposed to be true
  /// whenever this screen becomes visible again: the playing channel's
  /// row is what's in view and focused.
  Future<void> _restoreLiveFocus() async {
    if (!mounted || _route?.isCurrent == false) return;
    final playback = context.read<PlaybackService>();
    final channel = playback.currentChannel;
    // Use a bounded explicit focus fallback when the playing channel is absent from the
    // filtered list; avoid an implicit search across the entire catalogue.
    if (channel == null) {
      _col0Scope.requestFocus();
      return;
    }
    final playlist = context.read<PlaylistManager>();
    final channels = _currentLiveChannels(playlist);
    final index = channels.indexWhere((c) => c.id == channel.id);
    if (index < 0) {
      _col0Scope.requestFocus();
      return;
    }

    if (_liveListController.hasClients) {
      final target = (index * _liveRowHeightEstimate)
          .clamp(0, _liveListController.position.maxScrollExtent)
          .toDouble();
      // Jump for the coarse long-distance move, then refine over a short distance. Animating
      // the full distance would lay out intervening rows unnecessarily.
      _liveListController.jumpTo(target);
    }
    if (!mounted) return;
    // The coarse jump above is only an estimate (rows can grow to two
    // lines) — refine with the real row's own position once it's close
    // enough to the viewport to have actually been built.
    final targetContext = _currentChannelFocusNode.context;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(targetContext,
          duration: const Duration(milliseconds: 150));
    }
    if (mounted && _route?.isCurrent != false) {
      _currentChannelFocusNode.requestFocus();
    }
  }

  /// The last channel [_previewOrOpenChannel] started, and its still-running
  /// `PlaybackService.play` — set synchronously so a quick second press
  /// (before `play` has torn down the old stream and set currentChannel)
  /// still counts as "again" and goes fullscreen instead of starting the
  /// same channel twice. Android only; Windows' DesktopMiniPlayer.play sets
  /// its channel synchronously.
  String? _previewChannelId;
  Future<void>? _previewFuture;

  /// Live list / Timeline guide Select (remote, touch and mouse alike):
  /// the first press plays the channel in the preview box and stays in the
  /// guide; pressing it again while it's the one playing goes fullscreen.
  /// Changing channel used to mean going fullscreen and
  /// backing out. Deliberately not a timed double-press: telling a single
  /// from a double would delay every press ~300 ms, and D-pad remotes
  /// (Fire Stick, Bluetooth lag, key repeat) misread the timing; "again"
  /// needs none, and a double click/press still reads as two presses.
  /// Other entry points (History dialog, Continue Watching) keep
  /// [_selectChannel]'s straight-to-fullscreen behaviour.
  Future<void> _previewOrOpenChannel(Channel channel) async {
    if (_route?.isCurrent == false) {
      return;
    }

    final playback = context.read<PlaybackService>();
    // CH+/CH- in the player follow this exact list (e.g. Favourites order).
    playback.zapList = _currentLiveChannels(context.read<PlaylistManager>());
    final pending = _previewChannelId == channel.id ? _previewFuture : null;
    if (pending != null || playback.currentChannel?.id == channel.id) {
      // Wait for the preview's play() to finish first — same
      // create/dispose race _selectChannel's own comment describes.
      if (pending != null) await pending;
      if (!mounted ||
          playback.currentChannel?.id != channel.id ||
          _route?.isCurrent == false) {
        return;
      }
      PlayerScreen.open(Navigator.of(context), channel);
      return;
    }
    // The plain Live list hands the playing row `_currentChannelFocusNode`
    // instead of its own internal node, so the row just pressed swaps nodes
    // the moment currentChannel changes and the D-pad cursor would drop
    // (it used to be gone into fullscreen by then). Re-focus it once that
    // rebuild lands — only if the pressed node actually lost focus, so the
    // Timeline guide (no swap) and a cursor already moved elsewhere are
    // left alone.
    final pressed = FocusManager.instance.primaryFocus;
    void refocus() {
      if (playback.currentChannel?.id != channel.id) return;
      playback.removeListener(refocus);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || pressed == null || pressed.hasPrimaryFocus) return;
        final now = FocusManager.instance.primaryFocus;
        if (now != null && now is! FocusScopeNode) return;
        if (_currentChannelFocusNode.context != null) {
          _currentChannelFocusNode.requestFocus();
        }
      });
    }

    playback.addListener(refocus);
    final future = playback.play(channel);
    _previewChannelId = channel.id;
    _previewFuture = future;
    try {
      await future;
    } finally {
      playback.removeListener(refocus);
      if (_previewFuture == future) {
        _previewChannelId = null;
        _previewFuture = null;
      }
    }
  }

  /// Right, once there's no further column to move into, jumps straight to
  /// fullscreen on whatever's actually playing (PlaybackService's
  /// currentChannel) — not whichever row the D-pad cursor happens to be
  /// sitting on. No-ops if nothing's playing yet.
  /// Timeline guide's Left: step one 30-minute slot back in time, and
  /// only once the guide's time window has no earlier slot left fall back
  /// to the usual "press again to leave for the groups" edge behaviour.
  void _handleTimelineLeft() {
    final moved = _timelineGuideKey.currentState?.moveHorizontal(-1) ?? false;
    if (!moved) _handleBrowseLeft();
  }

  void _goFullscreenIfPlaying() {
    final channel = context.read<PlaybackService>().currentChannel;
    if (channel == null) return;
    PlayerScreen.open(Navigator.of(context), channel);
  }

  bool _settingsOpen = false;
  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    _sharedPreviewAway.value = true;
    try {
      final route = SettingsRoute<SettingsAction>(
          builder: (_) => const SettingsWorkspace());
      final action = await Navigator.of(context).push(route);
      if (!mounted) return;
      _sharedPreviewAway.value = false;
      switch (action) {
        case SettingsAction.live:
          break;
        case SettingsAction.sports:
          unawaited(_openSports());
        case SettingsAction.search:
          _openSearch();
        case SettingsAction.multiview:
          _openMultiview();
        case SettingsAction.refresh:
          await _refreshPlaylist(context);
        case SettingsAction.movies:
          _onTabChanged('Movies');
        case SettingsAction.shows:
          _onTabChanged('TV Shows');
        case SettingsAction.disableAndExit:
          await _confirmHardExit();
        case null:
          break;
      }
      // The surface moves with the destination in the same frame; retain the
      // entry guard until the old route has finished focus restoration.
      await route.completed;
    } finally {
      _settingsOpen = false;
    }
  }

  bool _openingMultiview = false;
  Future<void> _openMultiview() async {
    if (_openingMultiview || _route?.isCurrent == false) return;
    _openingMultiview = true;
    try {
      await context.read<PlaybackService>().stop();

      if (!mounted || _route?.isCurrent == false) return;
      final route =
          MaterialPageRoute<void>(builder: (_) => const MultiviewScreen());
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _openingMultiview = false;
    }
  }

  /// Sports reuses the active player in its own bounded preview. Navigating
  /// between the two guides must not stop or reconnect the stream.
  final _sharedPreviewAway = ValueNotifier<bool>(false);
  Route<String>? _sportsRoute;
  bool _libraryOpen = false;
  Future<void> _openLibrary({bool series = false}) async {
    if (_libraryOpen) return;
    _libraryOpen = true;
    unawaited(_parkLiveChannel());
    final route = TopLevelTabRoute<String>(
        builder: (_) => LibraryScreen(initialSeries: series));
    final destination = await Navigator.of(context).push(route);
    // This route contains only library UI. Waiting for its overlay disposal
    // would render Live TV for an extra frame between top-level destinations.
    _libraryOpen = false;
    if (!mounted) return;
    if (destination == 'live') {
      if (_focusDepth != 0) setState(() => _focusDepth = 0);
      _tvTabFocusNode.requestFocus();
    } else if (destination == 'sports') {
      unawaited(_openSports());
    } else if (destination == 'settings') {
      unawaited(_openSettings());
    }
  }

  Future<void> _openSports() async {
    if (_sportsRoute != null) return;
    // Both destinations update in one frame so the shared video surface moves
    // with its existing native controller instead of restarting the decoder.
    _sharedPreviewAway.value = true;
    if (!mounted) return;
    final route =
        TopLevelTabRoute<String>(builder: (_) => const SportsScreen());
    _sportsRoute = route;
    final destination = await Navigator.of(context).push(route);
    if (!mounted) return;
    _sharedPreviewAway.value = false;
    // Presentation moves now; retain the navigation guard until the outgoing
    // route has finished disposal and focus restoration.
    await route.completed;
    _sportsRoute = null;
    if (!mounted) return;
    if ((destination == null || destination == 'live') && !_compact) {
      // Return to the Live entry point even when Sports was opened from a
      // drilled-in guide. Change column geometry without rebuilding its data.
      _onColumnFocus(0);
      _tvTabFocusNode.requestFocus();
    }
    if (destination == null) return;
    if (destination == 'settings') {
      unawaited(_openSettings());
    } else if (destination == 'movies' || destination == 'series') {
      unawaited(_openLibrary(series: destination == 'series'));
    } else if (_phonePage == 0) {
      setState(() => _phonePage = 1);
    }
  }

  void _openSearch() {
    _parkLiveChannel();
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SearchScreen(initialScope: _tab)));
  }

  /// Re-syncs every enabled playlist — Xtream ones via a full catalog
  /// sync (one confirm covers all of them), M3U ones via a plain re-fetch
  /// of their flat list.
  Future<void> _refreshPlaylist(BuildContext context) async {
    final playlist = context.read<PlaylistManager>();
    if (playlist.profiles.isEmpty) return;

    if (playlist.profiles.any((p) => p.enabled && p.hasCatalog)) {
      // Shared with Settings > Clear Cache — see its doc comment for why
      // this needed to become a reusable helper rather than living here.
      final didSync = await confirmAndRunFullCatalogSync(context, playlist);
      if (didSync && mounted) _showUpdateToast();
    }

    final m3uProfiles =
        playlist.profiles.where((p) => p.enabled && !p.hasCatalog).toList();
    if (m3uProfiles.isEmpty || !context.mounted) return;

    // M3U mode: no per-category concept to re-sync, just a plain re-fetch
    // of the flat list — still confirms first since a stray remote press
    // on this menu entry shouldn't kick off a re-fetch unintentionally.
    final confirmed = await showGuardedDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Update content now?')),
        content:
            Text(tr('Re-checks your M3U playlist URL(s) for new content.')),
        actions: [
          ModeButton(
              label: tr('Cancel'),
              selected: false,
              onTap: () => Navigator.of(context).pop(false)),
          ModeButton(
              label: tr('Update'),
              selected: false,
              onTap: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    for (final profile in m3uProfiles) {
      await playlist.loadPlaylist(profile.id);
    }
  }

  /// Some Xtream providers cap concurrent connections per login — just
  /// backgrounding/minimizing the app doesn't release that slot, but
  /// disabling the playlist does (same mechanism as the manual toggle in
  /// Content Manager: stop touching the server, keep the cached
  /// credentials/catalog). Confirmed first since it's a deliberate
  /// "free this login up for another device" action, not an accidental
  /// tap consequence.
  Future<void> _confirmHardExit() async {
    final confirmed = await showGuardedDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Exit and free up this login?')),
        content: Text(
          tr('This disconnects your login here so it can be used on another device, then fully closes iptv-app. Your channels/movies will need to reload next time you open it.'),
        ),
        actions: [
          ModeButton(
            label: tr('Cancel'),
            selected: false,
            onTap: () => Navigator.of(context).pop(false),
          ),
          ModeButton(
            label: tr('Exit'),
            selected: false,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed == true) _hardExit();
  }

  void _hardExit() {
    // Disables every currently-enabled playlist (not just one, now that
    // more than one can exist) — see this button's own dialog copy:
    // freeing up "this login" for another device meant *every* login
    // this device was actively holding a connection slot on.
    final playlist = context.read<PlaylistManager>();
    for (final profile in playlist.profiles.where((p) => p.enabled)) {
      playlist.setPlaylistEnabled(profile.id, false);
    }
    _closeApp();
  }

  /// Use windowManager.close() on Windows and SystemNavigator.pop() on mobile; the desktop
  /// embedder does not implement mobile activity closing.
  bool _exitPromptOpen = false;

  /// Back from the tabs column: "Are you sure?" instead of closing at once.
  /// Stay is focused by default so a stray extra Back/Select press can't
  /// close the app by accident.
  Future<void> _confirmExit() async {
    if (_exitPromptOpen) return;
    _exitPromptOpen = true;
    final exit = await showGuardedDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Exit {appName}?', {'appName': AppConstants.appName})),
        content: Text(tr('Are you sure you want to exit {appName}?',
            {'appName': AppConstants.appName})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Exit')),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Stay')),
          ),
        ],
      ),
    );
    _exitPromptOpen = false;
    if (exit == true && mounted) _closeApp();
  }

  /// Hold Select on the History row: clears the live channel History only
  /// (Settings > General also clears recent searches). Cancel is focused
  /// first so a stray Select can't wipe anything.
  Future<void> _confirmClearChannelHistory() async {
    final ok = await showGuardedDialog<bool>(
      context: context,
      // SwallowHeldActivate: the still-held Select's repeats otherwise hit
      // the autofocused Cancel and close this before it's ever seen.
      builder: (dialogContext) => SwallowHeldActivate(
          child: AlertDialog(
        title: Text(tr('Delete watched history?')),
        content: Text(tr('Removes the History list of live channels.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Delete')),
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
    await context.read<PlaybackService>().clearRecentlyPlayed(live: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Watched history deleted.'))));
  }

  /// Hold Select on this tab's Favourites row: empty this tab's Favourites
  /// (starred items + favourited groups) after a confirm.
  Future<void> _confirmClearFavorites() async {
    final tab = _tab;
    final ok = await showGuardedDialog<bool>(
      context: context,
      // Opened by a hold: see _confirmClearChannelHistory.
      builder: (dialogContext) => SwallowHeldActivate(
          child: AlertDialog(
        title: Text(tr('Clear favourites?')),
        content: Text(tr(
            'Removes every starred item and favourite group from this tab\'s Favourites.')),
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
    if (ok != true || !mounted) return;
    final playlist = context.read<PlaylistManager>();
    final groups = switch (tab) {
      'Movies' => playlist.vodGroups,
      'TV Shows' => playlist.seriesGroups,
      _ => playlist.tvGroups,
    }
        .where((g) => playlist.isGroupFavorited(g.playlistId, g.title))
        .map((g) => (playlistId: g.playlistId, title: g.title))
        .toList();
    await playlist.clearFavorites(tab, groups);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Favourites cleared.'))));
  }

  void _closeApp() {
    SystemNavigator.pop();
  }

  void _showUpdateToast() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(tr('Content updated')),
          duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_previewCovered && _lastContent != null) {
      _contentChangedWhileCovered = true;
      return _lastContent!;
    }
    final playlist = context.watch<PlaylistManager>();
    final epg = context.watch<EpgService>();
    final prefs = context.watch<AppPreferences>();
    final screen = MediaQuery.sizeOf(context);
    _compact = screen.width < 600 && screen.height > screen.width;
    // Turning the phone to portrait lands on the content page (what was
    // on the right in landscape); Back then walks to groups and tabs.
    if (!_compact) _phonePage = 2;

    // Streaming-app convention: always dark on the TV screen, regardless of
    // the phone's light/dark setting, but still keyed off the user's chosen
    // cyberpunk palette so Settings > Theme actually drives this screen and
    // not just the Settings menu itself. Goes through the same shared
    // buildPaletteColorScheme every other palette-aware screen uses (see
    // its own doc comment) rather than reimplementing the seeding/override
    // here a second time — this screen (top bar, sidebar, live list) is
    // exactly the surface a second copy would silently diverge from.

    // Only meaningful on the Live TV/Favorites side (the browse tabs have
    // their own poster grid and no concept of this setting) — see
    // _buildLiveRegion for where it actually swaps the content, and the
    // Left/Right binding override just below for why the depth-2 column's
    // own key handling needs to know about it too.
    final showTimelineGuide = prefs.guideViewMode == 'timeline';
    final playbackState = context.watch<PlaybackService>();
    final playing = playbackState.currentChannel;
    final liveChannel =
        playing != null && Channel.isLiveId(playing.rawId) ? playing : null;
    // Only the phone layout has that preview (it sets its own state).
    if (!_compact) _syncPreviewHint(false);
    _fullVideo =
        _tab == 'TV' && showTimelineGuide && prefs.guideFullVideo && !_compact;

    final child = TvPreviewRemoteNavigation(
        enabled: prefs.isTelevision &&
            liveChannel != null &&
            (_tab == 'TV' || _tab == 'Sports'),
        onFullscreen: _goFullscreenIfPlaying,
        child: Theme(
          data: buildAppTheme(prefs.palette),
          // Back walks out one column at a time — content -> groups -> tabs —
          // and only exits the app from the tabs column (it used to exit
          // straight from anywhere, including deep inside the guide).
          child: PopScope(
            // Never pops on its own: Back from the tabs column asks first
            // (_confirmExit) instead of closing the app straight away.
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && TvTextFieldGate.editingFocusedField) return;
              if (!didPop) _handleBack();
            },
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  // Same bright, saturated two-color diagonal used across every
                  // Settings screen (see SettingsGradientBackground's doc
                  // comment) — was a muted 3-stop alpha-blend-onto-black here,
                  // which read as "still basically black/grey" next to the
                  // Settings redesign. Reusing the shared widget instead of a
                  // second copy of the same gradient math keeps both screens in
                  // sync automatically if the recipe ever changes again.
                  const Positioned.fill(child: SettingsGradientBackground()),
                  if (_fullVideo)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black,
                        child: _buildTimelinePreviewBox(liveChannel),
                      ),
                    ),
                  ...[],
                  SafeArea(
                    // Full-video mode: the guide sits right down at the TV's
                    // bottom edge instead of 16px above it.
                    minimum: _fullVideo
                        ? const EdgeInsets.fromLTRB(16, 16, 16, 4)
                        : _mobileGuide(context)
                            ? const EdgeInsets.fromLTRB(10, 4, 10, 4)
                            : const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        const CatalogWarmupBanner(),
                        Expanded(
                          child: (playlist.anyPlaylistError != null &&
                                  !playlist.hasLiveChannels)
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (playlist.anyPlaylistError != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 16),
                                            child: Text(
                                                playlist.anyPlaylistError!,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .error)),
                                          ),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            OutlinedButton(
                                              onPressed: _retrying
                                                  ? null
                                                  : () async {
                                                      setState(() =>
                                                          _retrying = true);
                                                      await playlist
                                                          .retryFailedConnections();
                                                      if (mounted) {
                                                        setState(() =>
                                                            _retrying = false);
                                                      }
                                                    },
                                              child: _retrying
                                                  ? const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child:
                                                          CircularProgressIndicator(
                                                              strokeWidth: 2))
                                                  : Text(tr('Retry')),
                                            ),
                                            const SizedBox(width: 12),
                                            FilledButton(
                                                onPressed: _openSettings,
                                                child:
                                                    Text(tr('Open Settings'))),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : ValueListenableBuilder<int>(
                                  valueListenable: _columnDepth,
                                  builder: (context, depth, child) =>
                                      CallbackShortcuts(
                                    bindings: _columnShortcuts(
                                      depth: depth,
                                      showTimelineGuide: showTimelineGuide,
                                    ),
                                    child: child!,
                                  ),
                                  child: _compact
                                      ? _buildPhoneColumns(
                                          playlist, epg, liveChannel)
                                      : Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _collapsible(
                                              depth: 0,
                                              expandedWidth:
                                                  _mobileGuide(context)
                                                      ? 112
                                                      : 132,
                                              child: _fullVideoScrim(_tabsScope(
                                                  collapsed: _focusDepth > 0 &&
                                                      !prefs.isTelevision)),
                                            ),
                                            _columnDivider(0),
                                            _collapsible(
                                              depth: 1,
                                              expandedWidth:
                                                  _mobileGuide(context)
                                                      ? 180
                                                      : 208,
                                              child: _fullVideoScrim(
                                                  _groupsScope(playlist,
                                                      collapsed: _focusDepth >
                                                              1 &&
                                                          !prefs.isTelevision)),
                                            ),
                                            _columnDivider(1),
                                            Expanded(
                                                child: _contentScope(
                                                    playlist, epg)),
                                          ],
                                        ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  // Hidden while filtering: the filter keyboard uses that area.
                  if (_fullVideo && !_timelineFilterActive)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: SafeArea(
                        child: IgnorePointer(
                            // Nothing playing yet: the cold-launch resume
                            // channel, so the card isn't empty.
                            child: _buildFullVideoNowCard(
                                liveChannel ??
                                    playbackState.pendingResumeChannel,
                                epg)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ));
    return _lastContent = RouteAwareRegion(
        listener: this,
        onRouteChanged: (route) => _route = route,
        child: child);
  }

  /// Full-video mode's description card, pinned in the screen's top-right
  /// corner, above the top bar's row.
  Widget _buildFullVideoNowCard(Channel? channel, EpgService epg) => Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: _buildGuideSummary(channel, epg, compact: true),
      );

  /// Dark see-through fill behind a column while [_fullVideo] puts the
  /// video behind the whole screen; transparent otherwise. Always the same
  /// wrapper (only the color changes) so flipping the mode never remounts
  /// the column and loses its focus or scroll position.
  Widget _fullVideoScrim(Widget child, {double alpha = 0.55}) => DecoratedBox(
        decoration: BoxDecoration(
            color: (_fullVideo)
                ? Colors.black.withValues(alpha: alpha)
                : Colors.transparent),
        child: child,
      );

  // Remote arrows switch columns until the guide/poster grid takes over.
  // Rebind at each depth without rebuilding the retained column contents.
  Map<ShortcutActivator, VoidCallback> _columnShortcuts({
    required int depth,
    required bool showTimelineGuide,
  }) =>
      <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            (depth == 2 && showTimelineGuide)
                ? _handleTimelineLeft
                : () => _moveColumnFocus(-1, 2),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            (depth == 2 && showTimelineGuide)
                ? () => _timelineGuideKey.currentState?.moveHorizontal(1)
                : depth == 2
                    ? _goFullscreenIfPlaying
                    : () => _moveColumnFocus(1, 2),
        if (depth == 2 && showTimelineGuide) ...{
          const SingleActivator(LogicalKeyboardKey.info, includeRepeats: false):
              () => showPlayerStreamInfo(context),
          const SingleActivator(LogicalKeyboardKey.contextMenu): () =>
              _timelineFilterButtonFocusNode.requestFocus(),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              (_timelineFilterButtonFocusNode.hasFocus ||
                      _timelineFilterFieldFocusNode.hasFocus ||
                      _timelineKeyboardScope.hasFocus)
                  ? _timelineGuideKey.currentState?.focusEntry()
                  : _timelineGuideKey.currentState?.moveVertical(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _timelineGuideKey.currentState?.moveVertical(-1)
        }
      };

  Widget _tabsScope({required bool collapsed}) => FocusTraversalGroup(
        child: FocusScope(
          node: _col0Scope,
          onFocusChange: (has) {
            if (has) _onColumnFocus(0);
          },
          child: _railSurface(0.018, _buildTabsColumn(collapsed: collapsed)),
        ),
      );

  Widget _groupsScope(PlaylistManager playlist, {required bool collapsed}) =>
      FocusTraversalGroup(
        policy: context.read<AppPreferences>().isTelevision
            ? _liveRailTraversal
            : null,
        child: FocusScope(
          node: _col1Scope,
          onFocusChange: (has) {
            if (has) _onColumnFocus(1);
          },
          child: _railSurface(
              0.038, _buildGroupsColumn(playlist, collapsed: collapsed)),
        ),
      );

  Widget _railSurface(double tone, Widget child) => Builder(
      builder: (context) => ColoredBox(
          color: _fullVideo
              ? Colors.transparent
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: tone),
          child: child));

  Widget _contentScope(PlaylistManager playlist, EpgService epg) =>
      FocusTraversalGroup(
        child: FocusScope(
          node: _col2Scope,
          onFocusChange: (has) {
            if (has) _onColumnFocus(2);
          },
          child: _buildLiveRegion(playlist, epg),
        ),
      );

  /// Portrait phone: the "Hold > to resume" pill hides while the live
  /// preview above the pages is showing (it named the channel already in
  /// the box, over the list). Called from build with whether the preview
  /// shows; returns it. The pill's count changes after the frame.
  bool _syncPreviewHint(bool shown) {
    _previewHintWanted = shown;
    if ((shown && !_previewCovered) != (_releasePreviewHint != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final want = mounted && _previewHintWanted && !_previewCovered;
        if (want && _releasePreviewHint == null) {
          _releasePreviewHint = LiveResumeHint.hideWhileMounted();
        } else if (!want && _releasePreviewHint != null) {
          _releasePreviewHint!();
          _releasePreviewHint = null;
        }
      });
    }
    return shown;
  }

  bool _previewHintWanted = false;
  VoidCallback? _releasePreviewHint;

  /// A screen is pushed over this one: the preview isn't visible there, so
  /// the pill comes back (Sports etc. hide it themselves).
  bool _previewCovered = false;
  // Provider updates can arrive while Library or another page covers Live.
  // Defer its expensive category layout, then rebuild from current data when
  // that page closes. Dialogs still leave the visible guide updating normally.
  Widget? _lastContent;
  bool _contentChangedWhileCovered = false;

  @override
  void didPushNext() {
    _previewCovered = true;
    _releasePreviewHint?.call();
    _releasePreviewHint = null;
  }

  /// Portrait phone: the same three columns, one page at a time (see
  /// [_compact]). An IndexedStack, not just the visible column, so the
  /// long groups list keeps its scroll position across Back.
  Widget _buildPhoneColumns(
      PlaylistManager playlist, EpgService epg, Channel? liveChannel) {
    final String? title = switch (_phonePage) {
      0 => null,
      1 => tr('Live TV'),
      _ => switch (_effectiveLiveGroup(playlist)) {
          null => tr('TV'),
          _favoritesGroupSentinel => tr('Favourites'),
          _historyGroupSentinel => tr('History'),
          _allGroupSentinel => tr('All channels'),
          final group => _selectedLiveCollection?.title == group
              ? _selectedLiveCollection!.displayName
              : group
        },
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          InkWell(
            canRequestFocus: false,
            // Groups is the top level now (the bottom bar switches tabs).
            onTap:
                _phonePage == 2 ? () => setState(() => _phonePage = 1) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  if (_phonePage == 2)
                    Icon(Icons.arrow_back,
                        color: interfaceColor(context, Colors.white), size: 21)
                  else
                    const SizedBox(width: 4),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: interfaceColor(context, Colors.white),
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                  // Search without going back to the tabs page first.
                  IconButton(
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    padding: const EdgeInsets.all(6),
                    icon: Icon(Icons.search,
                        color: interfaceColor(context, Colors.white), size: 21),
                    tooltip: tr('Search'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _openSearch,
                  ),
                ],
              ),
            ),
          ),
        // TV tab: the live preview, one instance above both the groups and
        // the channels page (a second video_player_hdr view on the same
        // controller doesn't render — see LiveResumeHint). On the groups
        // page only while something live is playing.
        if (_syncPreviewHint(_tab == 'TV' &&
            !_timelineFilterActive &&
            (_phonePage == 2 || (_phonePage == 1 && liveChannel != null)))) ...[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                border: Border.all(
                    color: interfaceColor(context, Colors.white)
                        .withValues(alpha: 0.18),
                    width: 1.5),
              ),
              child: _buildTimelinePreviewBox(liveChannel),
            ),
          ),
          const SizedBox(height: 5),
        ],
        Expanded(
          child: IndexedStack(
            index: _phonePage,
            sizing: StackFit.expand,
            children: [
              const SizedBox.shrink(),
              _groupsScope(playlist, collapsed: false),
              _contentScope(playlist, epg),
            ],
          ),
        ),
        _buildPhoneTabBar(),
      ],
    );
  }

  Widget _buildPhoneTabBar() => IptvBottomBar(
        selected: 'live',
        onSelect: (destination) {
          if (destination == 'movies' || destination == 'series') {
            _openLibrary(series: destination == 'series');
          } else if (destination == 'sports') {
            _openSports();
          } else if (destination == 'settings') {
            _openSettings();
          } else {
            setState(() => _phonePage = 1);
          }
        },
      );

  Widget _columnDivider(int depth) => ValueListenableBuilder<int>(
        valueListenable: _columnDepth,
        builder: (context, focusDepth, _) {
          final tv = context.read<AppPreferences>().isTelevision;
          final collapsed = focusDepth > depth;
          return VerticalDivider(
            width: tv && collapsed ? 0 : 1,
            color: (_fullVideo || tv) && collapsed ? Colors.transparent : null,
          );
        },
      );

  /// TV hides passed columns; touch layouts retain a narrow icon rail.
  Widget _collapsible({
    required int depth,
    required double expandedWidth,
    required Widget child,
  }) {
    return ValueListenableBuilder<int>(
      valueListenable: _columnDepth,
      child: child,
      builder: (context, focusDepth, child) {
        final collapsed = focusDepth > depth;
        final minWidth = _mobileGuide(context) ? 30.0 : 32.0;
        var collapsedWidth = minWidth;
        // Remote navigation restores the remembered focus when Back/Left opens
        // a hidden column. Touch layouts retain their tappable icon rails.
        final tv = context.read<AppPreferences>().isTelevision;
        if (_fullVideo || tv) collapsedWidth = 0;
        // Touch/mouse: a tap on a collapsed strip opens it back up instead of
        // hitting one of its look-alike icons. Always the same wrappers (only
        // their flags change) so the column never remounts and keeps its
        // scroll position.
        final tapToExpand = collapsed && !tv;
        return SizedBox(
          key: ValueKey(
              depth == 0 ? 'live-navigation-rail' : 'live-categories-rail'),
          width: collapsed ? collapsedWidth : expandedWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap:
                tapToExpand ? () => setState(() => _focusDepth = depth) : null,
            child: AbsorbPointer(
              absorbing: tapToExpand,
              // Keep hidden TV columns at their expanded layout size. Back restores
              // their focus and scroll offset without reflowing every category row.
              child: ClipRect(
                child: LayoutBuilder(builder: (context, constraints) {
                  // Clipping hides the retained column without remounting it.
                  final width = !collapsed || tv
                      ? expandedWidth
                      : constraints.maxWidth < minWidth
                          ? minWidth
                          : constraints.maxWidth;
                  return OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: width,
                    maxWidth: width,
                    child: child,
                  );
                }),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabsColumn({required bool collapsed}) => MainNavigationRail(
      selected: switch (_tab) {
        'Movies' => 'movies',
        'TV Shows' => 'series',
        _ => 'live'
      },
      collapsed: collapsed,
      focusNodes: {'live': _tvTabFocusNode},
      onSelect: (destination) {
        switch (destination) {
          case 'sports':
            _openSports();
          case 'movies':
            _onTabChanged('Movies');
          case 'series':
            _onTabChanged('TV Shows');
          case 'settings':
            _openSettings();
          default:
            _onTabChanged('TV');
        }
      });

  Future<void> _showCollectionSources(LiveCategoryCollection collection) async {
    final source = await showGuardedDialog<M3uGroup>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(collection.displayName),
                contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                content: SizedBox(
                    width: 440,
                    child: ListView(shrinkWrap: true, children: [
                      Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: Text('Browse an individual feed group',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: interfaceColor(
                                      context, Colors.white60)))),
                      for (final group in collection.sources)
                        ListTile(
                            dense: true,
                            leading: LiveCategoryIcon(label: group.title),
                            title: Text(liveCategoryLabel(group.title),
                                style: const TextStyle(fontSize: 13)),
                            onTap: () => Navigator.pop(context, group)),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ]));
    if (source != null && mounted) {
      _onGroupSelected(source.title, playlistId: source.playlistId);
    }
  }

  Widget _buildGroupsColumn(PlaylistManager playlist,
      {required bool collapsed}) {
    final groups = _liveCategories(playlist);
    final effectiveGroup = _effectiveLiveGroup(playlist);

    // Keep scroll state per tab and mount only nearby categories. The selected
    // category stays available for focus when returning from the guide.
    return CustomScrollView(
      key: const ValueKey('TV'),
      slivers: [
        SliverList.list(children: [
          // Hold Select = clear this tab's Favourites (after a confirm).
          HoldToActivate(
            onTap: () => _onGroupSelected(_favoritesGroupSentinel),
            onHold: _confirmClearFavorites,
            child: _SelectableRow(
              navigation: true,
              icon: Icons.star,
              label: tr('Favourites'),
              selected: effectiveGroup == _favoritesGroupSentinel,
              collapsed: collapsed,
              fontSize: _groupFontSize,
              focusNode: _firstGroupRowFocusNode,
              onTap: () => _onGroupSelected(_favoritesGroupSentinel),
              onLongPress: _confirmClearFavorites,
            ),
          ),
          // Hold Select = shortcut to Settings > General's channel-history
          // clear (same HoldToActivate-over-InkWell shape as the live list).
          HoldToActivate(
            onTap: () => _onGroupSelected(_historyGroupSentinel),
            onHold: _confirmClearChannelHistory,
            child: _SelectableRow(
              navigation: true,
              icon: Icons.history,
              label: tr('History'),
              selected: effectiveGroup == _historyGroupSentinel,
              collapsed: collapsed,
              fontSize: _groupFontSize,
              onTap: () => _onGroupSelected(_historyGroupSentinel),
              onLongPress: _confirmClearChannelHistory,
            ),
          ),
          _SelectableRow(
            navigation: true,
            key: const ValueKey('all-live-channels'),
            icon: Icons.list,
            label: tr('All channels'),
            selected: effectiveGroup == _allGroupSentinel,
            collapsed: collapsed,
            fontSize: _groupFontSize,
            onTap: () => _onGroupSelected(_allGroupSentinel),
          ),
        ]),
        LiveCategoryFolders(
          sliver: true,
          groups: groups,
          layouts: {
            for (final p in playlist.profiles)
              p.id: playlist.categoryLayoutFor(p.id)
          },
          storage: context.read<StorageService>(),
          playlistName: playlist.playlistNameFor,
          selectedKey: _selectedLiveCollection != null &&
                  _selectedLiveCollection!.title == effectiveGroup
              ? _groupKey(_selectedLiveCollection!.playlistId, effectiveGroup!)
              : groups
                  .where((g) => g.title == effectiveGroup)
                  .map((g) => _groupKey(g.playlistId, g.title))
                  .firstOrNull,
          revealKey: _focusGroupKeyOnBuild,
          forceFlat: _movingGroupKey != null,
          collapsed: collapsed,
          rowBuilder: (group, label) => _GroupRow(
            // Keyed so a moved group keeps its row Element (and focus)
            // when the list reorders — see _movingGroupKey.
            key: ValueKey(_groupKey(group.playlistId, group.title)),
            icon: Icons.grid_view_rounded,
            label: label ?? group.title,
            leading: LiveCategoryIcon(
                label: group is LiveCategoryCollection
                    ? group.sources.firstOrNull?.title ?? group.displayName
                    : group.title),
            selected: group is LiveCategoryCollection
                ? (effectiveGroup == group.title
                    ? group.playlistId == _selectedLiveCollection?.playlistId
                    : group.sourceTitles.contains(effectiveGroup))
                : effectiveGroup == group.title,
            collapsed: collapsed,
            fontSize: _groupFontSize,
            isFavorited:
                playlist.isGroupFavorited(group.playlistId, group.title),
            isPendingHide: _pendingHideGroups
                .contains(_groupKey(group.playlistId, group.title)),
            onTap: () => _onGroupSelected(group.title,
                playlistId: group.playlistId,
                collection: group is LiveCategoryCollection ? group : null),
            onLongPress: () => group is LiveCategoryCollection
                ? _showCollectionSources(group)
                : _showGroupOptions(group.playlistId, group.title),
            moving: _movingGroupKey == _groupKey(group.playlistId, group.title),
            onMove: (delta) =>
                _moveGroupStep(group.playlistId, group.title, delta),
            onMoveDone: _endGroupMove,
            focusOnBuild:
                _movingGroupKey == _groupKey(group.playlistId, group.title) ||
                    _focusGroupKeyOnBuild ==
                        _groupKey(group.playlistId, group.title),
            onFocusedOnBuild: () => _focusGroupKeyOnBuild = null,
          ),
        ),
      ],
    );
  }

  // --- Live TV / Favorites: translucent list over the live video ----------
  //
  // The channel list used to be an opaque column next to a separate video
  // preview column. Merged into one region instead: the video plays
  // full-bleed behind everything, and the channel list floats over its
  // left portion on a solid dark scrim — translucent enough that the live
  // stream is visibly playing behind it, opaque enough that channel names
  // stay clearly readable. A real blur (`BackdropFilter`) would look more
  // "glass", but blurring a live video texture every frame is real GPU
  // cost — not worth risking on the weaker Formuler/Firestick hardware
  // this app has spent this whole session getting stable.

  Widget _buildGuideSummary(Channel? channel, EpgService epg,
          {bool compact = false}) =>
      ValueListenableBuilder<(Channel?, EpgProgram?)>(
        valueListenable: _guideFocus,
        builder: (context, focus, _) => _GuideNowPanel(
          focusedChannel: focus.$1,
          focusedProgram: focus.$2,
          playingChannel: channel,
          epg: epg,
          compact: compact,
        ),
      );

  void _onGuideFocusChanged(Channel channel, EpgProgram? program) {
    // Section markers describe navigation, not a playable programme.
    if (isGuideSection(channel)) return;
    _guideFocus.value = (channel, program);
  }

  /// Shared preview for both guide layouts. Android watches PlaybackService; Windows watches
  /// DesktopMiniPlayer because its playback controller is separate.
  Widget _buildTimelinePreviewBox(
          Channel? channel) =>
      ValueListenableBuilder<bool>(
          valueListenable: _sharedPreviewAway,
          builder: (context, sportsOpen, _) => ColoredBox(
              color: Colors.black,
              child:
                  sportsOpen ? null : _buildTimelinePreviewContent(channel)));

  Widget _buildTimelinePreviewContent(Channel? channel) {
    if (channel == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tv_off, color: Colors.white54),
            const SizedBox(height: 6),
            Text(tr('Nothing playing'),
                style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return ExcludeFocus(
      // Excluded from focus, not just tap-only — this box sits directly
      // above the grid's top row, and default D-pad traversal reaching Up
      // from there would otherwise land here instead of stopping cleanly
      // at the guide's own edge.
      child: PreviewPlayerControls(
        // Off while the pane shows an error: its buttons need the taps.
        onFullscreen: context.watch<PlaybackService>().error != null
            ? null
            : () => PlayerScreen.open(Navigator.of(context), channel),
        // Key by channel to avoid stale frames. Use compact preview controls instead of the
        // full player control bar.
        child: VideoPlayerPane(
            key: ValueKey(channel.id), showEpgBar: false, showControls: false),
      ),
    );
  }

  /// Use the in-app key grid on TV and a normal text field on phone/desktop. Reserve filter
  /// space without unnecessarily obscuring the guide or preview.
  Widget _buildTimelineFilterBar(Channel? channel) {
    final isTv = context.watch<AppPreferences>().isTelevision;
    if (!isTv) {
      return Container(
        clipBehavior: Clip.antiAlias,
        // Centered, not top-pinned — this box keeps the normal preview
        // row's full height rather than collapsing (see the Column
        // children construction in _buildLiveRegion), so without this the
        // filter bar would otherwise sit awkwardly at the very top of a
        // tall, mostly-empty box.
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color:
                  interfaceColor(context, Colors.white).withValues(alpha: 0.18),
              width: 1.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(Icons.search,
                color: interfaceColor(context, Colors.white70), size: 20),
            const SizedBox(width: 8),
            Expanded(
              // tv-text-field-gate: exempt — opened on purpose by the filter
              // button, so the keyboard coming up at once is the point.
              child: TextField(
                controller: _timelineFilterController,
                // Give the text field a fresh autofocus node so mounting it produces a real
                // input-focus transition.
                focusNode: _timelineFilterFieldFocusNode,
                autofocus: true,
                style: TextStyle(color: interfaceColor(context, Colors.white)),
                decoration: InputDecoration(
                  hintText: tr('Channels or shows on now…'),
                  hintStyle:
                      TextStyle(color: interfaceColor(context, Colors.white54)),
                  border: InputBorder.none,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submitTimelineFilter(),
                onChanged: _editTimelineFilter,
              ),
            ),
            IconButton(
              tooltip: tr('Close filter'),
              icon: Icon(Icons.close,
                  color: interfaceColor(context, Colors.white70), size: 18),
              onPressed: _closeTimelineFilter,
            ),
          ]),
          _buildTimelineSearchOptions(television: false),
        ]),
      );
    }
    // Keep the TV search panel narrow and translucent so the current preview remains visible.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // Full-video mode: the video is already the full-screen layer
          // behind this — leave the slot empty instead of a second view.
          child: _fullVideo
              ? const SizedBox.shrink()
              : Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: interfaceColor(context, Colors.white)
                            .withValues(alpha: 0.18),
                        width: 1.5),
                  ),
                  child: _buildTimelinePreviewBox(channel),
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: interfaceColor(context, Colors.white)
                      .withValues(alpha: 0.18),
                  width: 1.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            // Fill the available height so the Expanded keyboard grid receives
            // bounded constraints on short TV layouts.
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.search,
                        color: interfaceColor(context, Colors.white70),
                        size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _timelineFilterQuery.isEmpty
                            ? tr('Channels or shows on now…')
                            : _timelineFilterQuery,
                        style: TextStyle(
                            color: _timelineFilterQuery.isEmpty
                                ? interfaceColor(context, Colors.white54)
                                : interfaceColor(context, Colors.white)),
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Close filter'),
                      icon: Icon(Icons.close,
                          color: interfaceColor(context, Colors.white70),
                          size: 18),
                      onPressed: _closeTimelineFilter,
                    ),
                  ],
                ),
                _buildTimelineSearchOptions(television: true),
                const SizedBox(height: 4),
                Expanded(
                  child: _TimelineVirtualKeyboard(
                    scope: _timelineKeyboardScope,
                    nodes: _timelineKeyboardNodes,
                    onChar: (c) =>
                        _editTimelineFilter(_timelineFilterQuery + c),
                    onSpace: () =>
                        _editTimelineFilter('$_timelineFilterQuery '),
                    onBackspace: () {
                      if (_timelineFilterQuery.isNotEmpty) {
                        _editTimelineFilter(_timelineFilterQuery.substring(
                            0, _timelineFilterQuery.length - 1));
                      }
                    },
                    onSubmit: _submitTimelineFilter,
                    onExitUp: () =>
                        _timelineSearchOptionNodes[_timelineSearchAll ? 1 : 0]
                            .requestFocus(),
                    onExitDown: () =>
                        _timelineGuideKey.currentState?.focusEntry(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveRegion(PlaylistManager playlist, EpgService epg) {
    // Kick off the live channel list's first load the moment this tab is
    // actually shown — see ensureLiveChannelsLoaded's doc comment for why
    // it's no longer loaded eagerly on launch. Fire-and-forget/no-op once
    // loaded or already loading, same shape as the Movies/TV Shows
    // category kick-off in _buildMoviesBrowse.
    unawaited(playlist.ensureLiveChannelsLoaded());

    final playback = context.watch<PlaybackService>();
    // Only live content belongs in this preview; leaving VOD fullscreen may keep its
    // controller alive for resuming elsewhere.
    final rawChannel = playback.currentChannel;
    // rawChannel.rawId, not rawChannel.id — Channel.isLiveId expects the
    // raw, unprefixed id.
    final channel = rawChannel != null && Channel.isLiveId(rawChannel.rawId)
        ? rawChannel
        : null;

    // Opt-in alternate view (Settings > Theme > "Guide view") — see
    // _TimelineGuide's own doc comment. Checked after the two branches
    // above, not before: a favorited movies/shows group still needs its
    // own catalog UI regardless of this setting, same as it would with
    // the normal live-list view.
    if (context.watch<AppPreferences>().guideViewMode == 'timeline') {
      // Place preview and summary above the guide so channel labels do not overlap them.
      // Filtering can reuse this header area for input.
      final previewRow = _timelineFilterActive
          ? _buildTimelineFilterBar(channel)
          : _compact
              // Portrait phone: no room beside the video for the
              // description panel — just the video, full width.
              ? Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: interfaceColor(context, Colors.white)
                            .withValues(alpha: 0.18),
                        width: 1.5),
                  ),
                  child: _buildTimelinePreviewBox(channel),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_fullVideo)
                      AspectRatio(
                        aspectRatio: 16 / 9,
                        child: _buildTimelinePreviewBox(channel),
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _fullVideo
                          ? const SizedBox.shrink()
                          : _buildGuideSummary(channel, epg),
                    ),
                  ],
                );

      final guide = _TimelineGuide(
        key: _timelineGuideKey,
        channels: _filteredLiveChannelsForGuide(playlist),
        searching: _guideSearching,
        emptyLabel: playlist.isLoading
            ? tr('Loading channels...')
            : _effectiveLiveGroup(playlist) == _historyGroupSentinel &&
                    _timelineFilterQuery.isEmpty
                ? tr('No channels watched yet.')
                : tr('No channels found.'),
        epg: epg,
        // Close the filter before opening a channel so its keyboard does not remain active
        // when fullscreen playback closes.
        onOpen: (channel) {
          if (isGuideSection(channel)) return;
          if (_timelineSearchAll) {
            setState(() {
              _selectedGroup = channel.group;
              _selectedLiveCollection = null;
            });
            _closeTimelineFilter(focusChannelId: channel.id);
          } else if (_timelineFilterActive) {
            _closeTimelineFilter(focusChannelId: channel.id);
          }
          _previewOrOpenChannel(channel);
        },
        onFocusChanged: _onGuideFocusChanged,
        onShowOptions: _showChannelOptions,
        onWindowStale: () => setState(() => _timelineGuideKey = GlobalKey()),
        translucent: _fullVideo,
        filterFocusNode: _timelineFilterButtonFocusNode,
        onFilterToggle: _openTimelineFilter,
        onBack: !_compact &&
                !context.read<AppPreferences>().isTelevision &&
                _focusDepth > 0
            ? _handleBack
            : null,
        onPlayingChannel: channel == null ? null : _jumpToPlayingChannel,
        onRemoteLeft: _handleTimelineLeft,
        // While filtering, focus belongs to whichever input is actually
        // showing (the virtual keyboard's first key on TV, the TextField
        // elsewhere); otherwise to the button. Only the button is actually
        // mounted above the guide when not filtering, so requesting focus
        // on the field/keyboard here while inactive would land nowhere —
        // neither widget exists yet in that state.
        onReachedTop: () {
          if (!_timelineFilterActive) {
            _timelineFilterButtonFocusNode.requestFocus();
          } else if (context.read<AppPreferences>().isTelevision) {
            _timelineKeyboardNodes.first.first.requestFocus();
          } else {
            _timelineFilterFieldFocusNode.requestFocus();
          }
        },
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        // Reserve extra filter height only for real TV devices using the virtual key grid.
        // Phone and desktop text fields retain their normal preview layout.
        children: _compact
            ? [
                if (_timelineFilterActive) ...[
                  SizedBox(height: 92, child: previewRow),
                  const Divider(height: 12),
                ],
                Expanded(child: guide),
              ]
            : _timelineFilterActive &&
                    context.read<AppPreferences>().isTelevision
                ? [
                    SizedBox(height: 200, child: previewRow),
                    const Divider(height: 12),
                    Expanded(child: _fullVideoScrim(guide)),
                  ]
                : _fullVideo
                    // Full-video mode: a 3-row guide at the bottom,
                    // the video showing through everything above it.
                    ? [
                        Expanded(child: previewRow),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: _guideRulerHeight(context) +
                              1 +
                              3 * _guideRowHeight(context),
                          child: _fullVideoScrim(guide),
                        ),
                      ]
                    : [
                        SizedBox(height: 144, child: previewRow),
                        Divider(height: _mobileGuide(context) ? 5 : 8),
                        Expanded(child: _fullVideoScrim(guide)),
                      ],
      );
    }

    // Square video frame, matching the timeline preview.
    // Portrait phone: the list can't float beside the video (it would
    // cover all of it) — video on top, list below.
    // The video itself is drawn once above the phone pages
    // (_buildPhoneColumns), so it stays on the groups page too.
    if (_compact) return _buildLiveList(playlist);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(
            color:
                interfaceColor(context, Colors.white).withValues(alpha: 0.18),
            width: 1.5),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            // Reuse the shared preview so Windows observes DesktopMiniPlayer. Rendering its
            // existing controller does not open another stream.
            child: _buildTimelinePreviewBox(channel),
          ),
          if (channel != null)
            Positioned(
              // A couple px further in than before — right up against the
              // pane's own new rounded corner (above), an 8px inset let the
              // button's circular edge clip visually into the curve.
              top: 12,
              right: 12,
              child: IconButton.filledTonal(
                icon: const Icon(Icons.fullscreen),
                onPressed: () =>
                    PlayerScreen.open(Navigator.of(context), channel),
              ),
            ),
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: 380,
            child: Container(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.62),
              child: Column(
                children: [
                  Expanded(child: _buildLiveList(playlist)),
                  if (channel != null)
                    SizedBox(
                        height: 170,
                        child: _ProgramDetails(channel: channel, epg: epg)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleFavoriteWithFeedback(BuildContext context, Channel channel) {
    context.read<PlaylistManager>().toggleFavorite(channel);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(channel.isFavorite
          ? tr('Added to Favorites')
          : tr('Removed from Favorites')),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Live TV only — for a duplicate feed within an otherwise-wanted group
  /// (e.g. the same channel offered in both HD and HEVC) that whole-group
  /// hiding can't target. `toggleChannelHidden` mutates the underlying
  /// Set synchronously before its own `await` (same shape as
  /// `toggleFavorite`/`Channel.isFavorite` above), so `isChannelHidden`
  /// already reflects the new state by the time the snackbar reads it.
  void _toggleHiddenWithFeedback(BuildContext context, Channel channel) {
    final playlist = context.read<PlaylistManager>();
    playlist.toggleChannelHidden(channel);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(playlist.isChannelHidden(channel)
          ? tr(
              'Hidden — find it again in Settings > Playlist Manager > Hidden Channels')
          : tr('Unhidden')),
      duration: const Duration(seconds: 2),
    ));
  }

  Widget _buildLiveList(PlaylistManager playlist) {
    final channels = _currentLiveChannels(playlist);
    // Favourites from two or more playlists: a playlist label above each
    // one's first channel (the getter already groups them by playlist).
    // Inside the row's item, not an extra list item, so row indexes stay
    // what _restoreLiveFocus expects.
    final labelPlaylists = (_selectedGroup ?? _effectiveLiveGroup(playlist)) ==
            _favoritesGroupSentinel &&
        channels.map((c) => c.playlistId).toSet().length > 1;

    if (channels.isEmpty) {
      return Center(
        child: Text(
          _selectedGroup == _favoritesGroupSentinel
              ? tr(
                  'No favorite channels yet — press Down while watching one to add it.')
              : tr('No channels found.'),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Consumer<PlaybackService>(
      builder: (context, playback, _) => ListView.builder(
        // Key by displayed group to prevent row state and orphaned key-up events from
        // carrying into a different channel list.
        key: ValueKey(
            '$_tab::${_selectedGroup ?? _effectiveLiveGroup(playlist)}'),
        controller: _liveListController,
        itemCount: channels.length,
        itemBuilder: (context, i) {
          final channel = channels[i];
          final row = _buildLiveRow(playback, channel, i);
          if (!labelPlaylists ||
              (i > 0 && channels[i - 1].playlistId == channel.playlistId)) {
            return row;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PlaylistDividerRow(
                name: playlist.playlistNameFor(channel.playlistId),
                collapsed: false,
              ),
              row,
            ],
          );
        },
      ),
    );
  }

  Widget _buildLiveRow(PlaybackService playback, Channel channel, int i) {
    final isSelected = playback.currentChannel?.id == channel.id;
    // Exclude the favourite star from remote traversal so Up/Down selects rows.
    // HoldToActivate supplies remote long-press actions alongside touch handling.
    return HoldToActivate(
      onTap: () => _previewOrOpenChannel(channel),
      onHold: () => _showChannelOptions(channel),
      child: _SelectableRow(
        selected: isSelected,
        focusNode: isSelected
            ? _currentChannelFocusNode
            : (i == 0 ? _firstLiveChannelFocusNode : null),
        onTap: () => _previewOrOpenChannel(channel),
        onLongPress: () => _showChannelOptions(channel),
        leading: SizedBox(
          width: 40,
          height: 40,
          child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
              ? CachedNetworkImage(
                  imageUrl: channel.logoUrl!,
                  fit: BoxFit.contain,
                  memCacheWidth:
                      (40 * MediaQuery.of(context).devicePixelRatio).round(),
                  memCacheHeight:
                      (40 * MediaQuery.of(context).devicePixelRatio).round(),
                  errorWidget: (_, __, ___) => const Icon(Icons.tv))
              : const Icon(Icons.tv),
        ),
        label: channel.name,
        // epgId (rawId, or a manual override), not the composite `id`
        // — see
        // PlaylistManager.knownChannelIdsFor's doc comment.
        subtitle: _CurrentProgramLine(channelId: channel.epgId),
        trailing: ExcludeFocus(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // For a duplicate feed within this same group (e.g.
              // the same channel in HD and HEVC) — see
              // AppConstants.keyHiddenChannels's doc comment.
              IconButton(
                icon: Icon(Icons.visibility_off_outlined,
                    color: interfaceColor(context, Colors.white70)),
                tooltip: tr('Hide this channel'),
                onPressed: () => _toggleHiddenWithFeedback(context, channel),
              ),
              IconButton(
                icon: Icon(channel.isFavorite ? Icons.star : Icons.star_border,
                    color: channel.isFavorite
                        ? Colors.amber
                        : interfaceColor(context, Colors.white70)),
                onPressed: () => _toggleFavoriteWithFeedback(context, channel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Movies / TV Shows: poster-row browse ---------------------------------
  //
  // No group-picker column — the browse view already organizes everything
  // by category via row headers, so a separate "pick a group" step was
  // just showing an empty row until that one category happened to be
  // fetched. Straight from the tab into the catalog instead.
}

/// A tab/group/channel row styled with a solid highlight bar when selected,
/// instead of relying on default `ListTile` selected-tint (which reads as
/// too subtle at 10-foot viewing distance). Collapses to an icon-only
/// square when [collapsed].
class _SelectableRow extends StatefulWidget {
  const _SelectableRow({
    this.navigation = false,
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.collapsed = false,
    this.icon,
    this.leading,
    this.subtitle,
    this.trailing,
    this.fontSize,
    this.focusNode,
  });

  final bool navigation;
  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData? icon;
  final Widget? leading;
  final Widget? subtitle;
  final Widget? trailing;

  /// Only needed by the currently-playing channel row (see
  /// `_restoreLiveFocus`), so it can be re-focused explicitly after
  /// returning from fullscreen — every other row leaves this null and gets
  /// its own internal node from `InkWell` as usual.
  final FocusNode? focusNode;

  /// Defaults to the ambient text style's size when null (tabs/channel
  /// list rows) — group rows pass a smaller explicit size instead.
  final double? fontSize;

  @override
  State<_SelectableRow> createState() => _SelectableRowState();
}

class _SelectableRowState extends State<_SelectableRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (widget.navigation) {
      return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Material(
              color: Colors.transparent,
              animationDuration: Duration.zero,
              child: InkWell(
                  focusNode: widget.focusNode,
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  onFocusChange: (value) {
                    setState(() => _focused = value);
                    if (value) _ensureVisible(context);
                  },
                  child: LiveNavigationBody(
                      label: widget.label,
                      leading: widget.leading ?? Icon(widget.icon),
                      trailing: widget.trailing,
                      collapsed: widget.collapsed,
                      focused: _focused,
                      selected: widget.selected))));
    }
    final scheme = Theme.of(context).colorScheme;
    // Flat focus fill; selection keeps a quieter accent outline.
    final isPlaying = widget.selected && !_focused;
    final unfocusedColor = isPlaying
        ? Colors.transparent
        : interfaceColor(context, Colors.white).withValues(alpha: 0.04);
    final focusedForeground = scheme.onPrimaryContainer;
    final foregroundColor = _focused
        ? focusedForeground
        : (isPlaying ? scheme.primary : interfaceColor(context, Colors.white));
    // `scheme.tertiary` — a dedicated icon/symbol-glyph accent, separate
    // from the text/border/gradient accent (`scheme.primary`) — see
    // `buildPaletteColorScheme`'s own doc comment for why (Habs: white
    // contour/text, blue icons).
    final iconColor = _focused
        ? scheme.onPrimaryContainer
        : (isPlaying
            ? scheme.tertiary
            : interfaceColor(context, Colors.white70));
    final leadingWidget =
        widget.leading ?? Icon(widget.icon, color: iconColor, size: 20);

    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: widget.collapsed
              ? 2
              : _mobileGuide(context)
                  ? 4
                  : 6,
          vertical: _mobileGuide(context) ? 2 : 3),
      child: Container(
        // Always present (even with an empty shadow list) rather than
        // conditionally wrapped — MinimalGlassFocus's own doc comment just
        // below has the full story on why changing a focus widget's
        // ancestor shape between builds corrupts its FocusNode on real
        // hardware; the same rule applies one level up, here.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          // Flat focus fill; selection keeps a quieter accent outline.
          gradient: _focused
              ? LinearGradient(
                  colors: [scheme.primaryContainer, scheme.primaryContainer])
              : null,
          boxShadow: const [],
        ),
        // Flat focus fill; selection keeps a quieter accent outline.
        child: MinimalGlassFocus(
          active: false,
          borderRadius: 3,
          child: Material(
            color: _focused ? Colors.transparent : unfocusedColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(3),
              // Keep the active-item marker independent of keyboard focus so browsing another
              // row does not look like a selection change.
              side: _focused
                  ? BorderSide(color: scheme.primary, width: 2.5)
                  : widget.selected
                      ? BorderSide(color: scheme.primary, width: 1.5)
                      : BorderSide.none,
            ),
            child: InkWell(
              focusNode: widget.focusNode,
              borderRadius: BorderRadius.circular(3),
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              onFocusChange: (f) {
                setState(() => _focused = f);
                if (f) _ensureVisible(context);
              },
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: widget.collapsed
                        ? 1
                        : _mobileGuide(context)
                            ? 6
                            : 8,
                    vertical: _mobileGuide(context) ? 8 : 10),
                child: widget.collapsed
                    ? Tooltip(
                        message: widget.label,
                        child: Center(
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              leadingWidget,
                              if (isPlaying)
                                Positioned(
                                  right: -3,
                                  top: -3,
                                  child: Icon(Icons.circle,
                                      size: 8, color: scheme.tertiary),
                                ),
                            ],
                          ),
                        ))
                    : Row(
                        children: [
                          leadingWidget,
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    if (isPlaying) ...[
                                      Icon(Icons.play_arrow,
                                          size: 14, color: scheme.tertiary),
                                      const SizedBox(width: 4),
                                    ],
                                    Expanded(
                                      child: Text(
                                        widget.label,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: foregroundColor,
                                          fontSize: _mobileGuide(context)
                                              ? (widget.fontSize ?? 16) - .5
                                              : widget.fontSize,
                                          fontWeight: (_focused || isPlaying)
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          // The Live TV list floats translucent
                                          // over the video now — a shadow keeps
                                          // the name readable no matter how
                                          // bright/busy whatever's playing
                                          // behind it is. Harmless on the solid
                                          // backgrounds this row is also used
                                          // on (tabs, groups).
                                          shadows: const [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 4)
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (widget.subtitle != null)
                                  DefaultTextStyle.merge(
                                    style: TextStyle(
                                      color: _focused
                                          ? focusedForeground.withValues(
                                              alpha: 0.85)
                                          : interfaceColor(
                                              context, Colors.white54),
                                    ),
                                    child: widget.subtitle!,
                                  ),
                              ],
                            ),
                          ),
                          if (widget.trailing != null) widget.trailing!,
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Non-focusable playlist separator in a merged category column. Collapsed mode renders a
/// divider instead of a label.
class _PlaylistDividerRow extends StatelessWidget {
  const _PlaylistDividerRow({required this.name, required this.collapsed});

  final String name;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return Divider(
          height: 16, color: interfaceColor(context, Colors.white24));
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          name.isEmpty ? tr('Playlist') : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.bold,
            fontSize: 12,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

/// A real category row (unlike "All"/"Favourites", which are pseudo-entries
/// with no group-level actions) — long-press brings up "add/remove
/// favorites" and "hide" for the whole group.
///
/// Deliberately its own widget rather than adding this to [_SelectableRow]:
/// touch long-press is trivial (`GestureDetector.onLongPress` already
/// works), but there's no equivalent for a D-pad — Flutter doesn't have a
/// "key held for N ms" primitive, so this hand-rolls one from raw
/// KeyDownEvent/KeyUpEvent timing instead of reusing `InkWell`'s built-in
/// Enter/Select activation (which fires immediately on key-down and can't
/// be delayed to distinguish a tap from a hold). Keeping that experiment
/// contained to group rows means every other list in the app (tabs,
/// channels, settings) keeps using the already-proven `_SelectableRow`
/// untouched.
class _GroupRow extends StatefulWidget {
  const _GroupRow({
    super.key,
    required this.icon,
    this.leading,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    required this.onLongPress,
    this.isFavorited = false,
    this.isPendingHide = false,
    this.fontSize,
    this.moving = false,
    this.onMove,
    this.onMoveDone,
    this.focusOnBuild = false,
    this.onFocusedOnBuild,
  });

  final IconData icon;
  final Widget? leading;
  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool isFavorited;
  final bool isPendingHide;
  final double? fontSize;

  /// "Move Up / Down" mode — see `_TvHomeScreenState._movingGroupKey`.
  final bool moving;
  final ValueChanged<int>? onMove;
  final VoidCallback? onMoveDone;

  /// Request focus once built (after "Move to Top"), then report back.
  final bool focusOnBuild;
  final VoidCallback? onFocusedOnBuild;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _focused = false;
  Timer? _longPressTimer;
  bool _longPressFired = false;

  static const _longPressDuration = Duration(milliseconds: 550);

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  /// Set by an activate-key *down* while moving, so the key-*up* left over
  /// from picking "Move Up / Down" in the menu doesn't instantly confirm.
  bool _activateDownWhileMoving = false;

  final FocusNode _focusNode = FocusNode(debugLabel: 'group-row');

  @override
  void initState() {
    super.initState();
    _maybeFocusOnBuild();
  }

  @override
  void didUpdateWidget(_GroupRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.moving) _activateDownWhileMoving = false;
    if (widget.focusOnBuild && !oldWidget.focusOnBuild) _maybeFocusOnBuild();
  }

  void _maybeFocusOnBuild() {
    if (!widget.focusOnBuild) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      widget.onFocusedOnBuild?.call();
    });
  }

  KeyEventResult _handleMovingKey(KeyEvent event, bool isActivateKey) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (isPress) {
        widget.onMove?.call(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
      }
      return KeyEventResult.handled;
    }
    // Stay on the row while moving.
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.handled;
    }
    if (isActivateKey) {
      if (event is KeyDownEvent) _activateDownWhileMoving = true;
      if (event is KeyUpEvent && _activateDownWhileMoving) {
        _activateDownWhileMoving = false;
        widget.onMoveDone?.call();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      if (event is KeyUpEvent) widget.onMoveDone?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final isActivateKey = event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA;
    if (widget.moving) return _handleMovingKey(event, isActivateKey);
    if (!isActivateKey) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _longPressFired = false;
      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPressDuration, () {
        _longPressFired = true;
        widget.onLongPress();
      });
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _longPressTimer?.cancel();
      if (!_longPressFired) widget.onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlighted = widget.selected || _focused;
    // Flat focus fill; selection keeps a quieter accent outline.
    final iconColor = _focused
        ? scheme.onPrimaryContainer
        : (highlighted
            ? scheme.tertiary
            : interfaceColor(context, Colors.white70));

    final iconWidget = Stack(
      clipBehavior: Clip.none,
      children: [
        IconTheme(
            data: IconThemeData(color: iconColor, size: 20),
            child: widget.moving
                ? const Icon(Icons.swap_vert)
                : widget.leading ?? Icon(widget.icon)),
        if (widget.isFavorited)
          Positioned(
            right: -2,
            top: -2,
            child: Icon(Icons.star,
                size: widget.collapsed ? 8 : 10,
                color: highlighted ? scheme.tertiary : Colors.amber),
          ),
      ],
    );

    return Opacity(
        opacity: widget.isPendingHide ? .4 : 1,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Focus(
                focusNode: _focusNode,
                onKeyEvent: _handleKeyEvent,
                onFocusChange: (value) {
                  setState(() => _focused = value);
                  if (value) _ensureVisible(context);
                  if (!value && widget.moving) widget.onMoveDone?.call();
                },
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.moving ? widget.onMoveDone : widget.onTap,
                    onLongPress: widget.moving ? null : widget.onLongPress,
                    child: LiveNavigationBody(
                        label: widget.label,
                        leading: iconWidget,
                        collapsed: widget.collapsed,
                        focused: _focused,
                        selected: widget.selected,
                        trailing: widget.moving
                            ? Row(mainAxisSize: MainAxisSize.min, children: [
                                _moveTapIcon(Icons.arrow_upward,
                                    () => widget.onMove?.call(-1), iconColor),
                                _moveTapIcon(Icons.arrow_downward,
                                    () => widget.onMove?.call(1), iconColor),
                                _moveTapIcon(Icons.check,
                                    () => widget.onMoveDone?.call(), iconColor),
                              ])
                            : null)))));
  }

  Widget _moveTapIcon(IconData icon, VoidCallback onTap, Color color) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(icon, size: 22, color: color),
        ),
      );
}

/// Just the app name/clock — Search, Update Content, and Settings live in
/// the tabs rail now (below Favorites), not as top-right icon buttons.
/// Those buttons were effectively unreachable by remote: nothing in the
/// main content area ever handed D-pad focus up to them, so they needed a
/// mouse/touch to use at all. The tabs rail is already a single reliably
/// D-pad-navigable list, so putting them there instead — with Search
/// pinned at the very top of it, "at the top and accessible from
/// everywhere" the way a search entry point should be — costs nothing and
/// actually works with a remote.
class _CurrentProgramLine extends StatelessWidget {
  const _CurrentProgramLine({required this.channelId});
  final String channelId;

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final current = epg.getCurrentProgram(channelId);
    if (current == null) {
      return Text(tr('No program data'), style: const TextStyle(fontSize: 12));
    }
    return Text(current.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12));
  }
}

/// Right-panel program info card — current show, time range with a
/// progress bar, description, and the next show.
class _ProgramDetails extends StatelessWidget {
  const _ProgramDetails({required this.channel, required this.epg});

  final Channel channel;
  final EpgService epg;

  @override
  Widget build(BuildContext context) {
    // epgId (rawId, or a manual override), not the composite `id`
    // — see
    // PlaylistManager.knownChannelIdsFor's doc comment.
    final current = epg.getCurrentProgram(channel.epgId);
    final next = epg.getNextProgram(channel.epgId);
    final timeFormat = TimeFormat.hm;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(channel.name,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          if (current != null) ...[
            Text(current.title,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 4),
            Builder(builder: (context) {
              final now = DateTime.now();
              final totalMs =
                  current.stop.difference(current.start).inMilliseconds;
              final elapsedMs = now.difference(current.start).inMilliseconds;
              final ratio =
                  totalMs == 0 ? 0.0 : (elapsedMs / totalMs).clamp(0.0, 1.0);
              return Row(
                children: [
                  Text(
                      '${timeFormat.format(current.start)} - ${timeFormat.format(current.stop)}',
                      style: const TextStyle(color: Colors.white70)),
                  const SizedBox(width: 12),
                  Expanded(child: LinearProgressIndicator(value: ratio)),
                ],
              );
            }),
            if (current.description != null) ...[
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(current.description!,
                      style: const TextStyle(color: Colors.white70)),
                ),
              ),
            ],
          ] else
            Text(tr('No program data available'),
                style: const TextStyle(color: Colors.white70)),
          if (next != null) ...[
            const SizedBox(height: 8),
            Text(
                tr('Next: {title} ({p})',
                    {'title': next.title, 'p': timeFormat.format(next.start)}),
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// The Timeline Guide's description header — the programme currently
/// focused in the grid, not only the one playing. Kept separate from
/// [_ProgramDetails] rather than parameterising it: that one always
/// describes a channel's *live* programme plus what's next, while this one
/// has to describe any block the D-pad lands on, including ones hours
/// ahead, where a progress bar would be meaningless.
class _GuideNowPanel extends StatelessWidget {
  const _GuideNowPanel({
    required this.focusedChannel,
    required this.focusedProgram,
    required this.playingChannel,
    required this.epg,
    this.compact = false,
  });

  /// Full-video mode: a small shrink-wrapped card (smaller title, two
  /// description lines) instead of filling the 160px header row.
  final bool compact;

  final Channel? focusedChannel;
  final EpgProgram? focusedProgram;
  final Channel? playingChannel;
  final EpgService epg;

  @override
  Widget build(BuildContext context) {
    final timeFormat = TimeFormat.hm;
    // Whichever channel the guide is actually focused on, even if that
    // row turned out to have no programme data (focusedProgram null but
    // focusedChannel set) — only falls back to whatever's playing when
    // nothing in the guide has been focused at all yet.
    final channel = focusedChannel ?? playingChannel;
    // epgId (rawId, or a manual override), not the composite `id`
    // — see
    // PlaylistManager.knownChannelIdsFor's doc comment.
    final program = focusedProgram ??
        (channel == null
            ? null
            : epg.getCurrentProgram(channel.epgId) ??
                epg.getNextProgram(channel.epgId));

    if (channel == null && program == null) {
      return Center(
        child: Text(tr('Focus a program to see details'),
            style: TextStyle(color: interfaceColor(context, Colors.white70))),
      );
    }

    final now = DateTime.now();
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(12, 6, 12, 8)
          : const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Column(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(program?.title ?? channel!.name,
              style: TextStyle(
                  color: interfaceColor(context, Colors.white),
                  fontSize: compact ? 14 : 18,
                  height: 1.15,
                  fontWeight: FontWeight.w600),
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 5),
          if (program != null) ...[
            Row(
              children: [
                if (channel != null) ...[
                  Flexible(
                    child: Text(channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: interfaceColor(context, Colors.white70),
                            fontSize: 11.5)),
                  ),
                  const SizedBox(width: 10),
                ],
                Text(
                    '${timeFormat.format(program.start)} – ${timeFormat.format(program.stop)}',
                    style: TextStyle(
                        color: interfaceColor(context, Colors.white54),
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontSize: 11)),
                if (program.isNowPlaying(now)) ...[
                  const SizedBox(width: 12),
                  SizedBox(
                    width: compact ? 40 : 64,
                    child: Builder(builder: (context) {
                      final totalMs =
                          program.stop.difference(program.start).inMilliseconds;
                      final elapsedMs =
                          now.difference(program.start).inMilliseconds;
                      final ratio = totalMs == 0
                          ? 0.0
                          : (elapsedMs / totalMs).clamp(0.0, 1.0);
                      return LinearProgressIndicator(
                          value: ratio, minHeight: 2);
                    }),
                  ),
                ],
              ],
            ),
            if (program.description != null && compact) ...[
              const SizedBox(height: 4),
              Text(program.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: interfaceColor(context, Colors.white70),
                      fontSize: 12)),
            ] else if (program.description != null) ...[
              const SizedBox(height: 6),
              Expanded(
                child: SingleChildScrollView(
                  // Start each newly focused programme at its opening sentence.
                  key: ValueKey((channel?.id, program.start, program.title)),
                  child: Text(program.description!,
                      style: TextStyle(
                          color: interfaceColor(context, Colors.white70),
                          fontSize: 12.5,
                          height: 1.3)),
                ),
              ),
            ],
          ] else
            Text(tr('No program data available'),
                style:
                    TextStyle(color: interfaceColor(context, Colors.white70))),
        ],
      ),
    );
  }
}

/// Selection-only surface sharing Live TV's virtual timeline renderer. This
/// mounts no preview, navigation shell or extra playback controller.
class LiveGuideSelectionViewport extends StatefulWidget {
  const LiveGuideSelectionViewport(
      {super.key,
      required this.channels,
      required this.onChoose,
      required this.onSearch,
      required this.onToolbar,
      this.statusFor,
      this.initialChannelId,
      this.onCategories});
  final List<Channel> channels;
  final String? initialChannelId;
  final ValueChanged<Channel> onChoose;
  final VoidCallback onSearch, onToolbar;
  final VoidCallback? onCategories;
  final String? Function(Channel)? statusFor;
  @override
  State<LiveGuideSelectionViewport> createState() =>
      LiveGuideSelectionViewportState();
}

class LiveGuideSelectionViewportState
    extends State<LiveGuideSelectionViewport> {
  var _guide = GlobalKey<_TimelineGuideState>();
  final _search = FocusNode(debugLabel: 'multiview-guide-search');
  void focusEntry() => _guide.currentState?.focusEntry();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = widget.initialChannelId;
      if (id != null && widget.channels.any((c) => c.id == id)) {
        _guide.currentState?.restoreFocusToChannel(id);
      } else {
        focusEntry();
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TimelineGuide(
      key: _guide,
      channels: widget.channels,
      epg: context.read<EpgService>(),
      onOpen: widget.onChoose,
      onFocusChanged: _ignoreFocus,
      onShowOptions: widget.onChoose,
      selectionStatus: widget.statusFor,
      filterFocusNode: _search,
      onFilterToggle: widget.onSearch,
      onReachedTop: widget.onToolbar,
      onRemoteLeft: widget.onCategories ?? widget.onToolbar,
      onPlayingChannel: widget.initialChannelId != null &&
              widget.channels.any((c) => c.id == widget.initialChannelId)
          ? () => _guide.currentState
              ?.restoreFocusToChannel(widget.initialChannelId!)
          : null,
      onWindowStale: () =>
          setState(() => _guide = GlobalKey<_TimelineGuideState>()));
  static void _ignoreFocus(Channel channel, EpgProgram? programme) {}
}

class _TimelineGuide extends StatefulWidget {
  const _TimelineGuide(
      {super.key,
      required this.channels,
      required this.epg,
      required this.onOpen,
      required this.onFocusChanged,
      required this.onShowOptions,
      required this.filterFocusNode,
      required this.onFilterToggle,
      this.onBack,
      this.onPlayingChannel,
      this.onRemoteLeft,
      this.searching = false,
      this.emptyLabel = 'No channels found.',
      this.selectionStatus,
      this.onReachedTop,
      this.onWindowStale,
      this.translucent = false});

  /// Full-video mode (`_TvHomeScreenState._fullVideo`): lighter "now"
  /// blocks so the video shows through the grid.
  final bool translucent;

  final List<Channel> channels;
  final EpgService epg;
  final void Function(Channel channel) onOpen;
  final void Function(Channel channel, EpgProgram? program) onFocusChanged;

  /// Hold-Select on a block — see [_TvHomeScreenState._showChannelOptions].
  final void Function(Channel channel) onShowOptions;

  /// Backs the filter toggle button rendered above the channel column
  /// (`_TimelineFilterButton`). A dedicated node, not shared with the
  /// filter field's own — see
  /// `_TvHomeScreenState._timelineFilterButtonFocusNode`'s doc comment
  /// for why that sharing was tried and abandoned.
  final FocusNode filterFocusNode;

  /// Select on the filter button — see
  /// `_TvHomeScreenState._openTimelineFilter`.
  final VoidCallback onFilterToggle;
  final VoidCallback? onBack;
  final VoidCallback? onPlayingChannel;
  final VoidCallback? onRemoteLeft;
  final bool searching;
  final String emptyLabel;
  final String? Function(Channel)? selectionStatus;

  /// Move Up from the first guide row to the visible filter button or field.
  final VoidCallback? onReachedTop;

  /// This instance's fixed [_TimelineGuideState._windowStart]/`_windowEnd`
  /// has gone (or is about to go) stale — see that field's own doc
  /// comment for why. The parent's only real fix is discarding this whole
  /// widget/State and mounting a fresh one (a new key), which is outside
  /// what this State can do to itself.
  final VoidCallback? onWindowStale;

  @override
  State<_TimelineGuide> createState() => _TimelineGuideState();
}

class _TimelineGuideState extends State<_TimelineGuide>
    with RouteAware, WidgetsBindingObserver {
  List<Channel>? _tagsFor;
  bool _mixedPlaylists = false;

  /// The playlist name on the first channel of each playlist's run when
  /// the rows mix playlists (Favourites) — a tag inside the label cell,
  /// not an extra row, so row indexes keep matching the programme rows.
  String? _playlistTagFor(int i) {
    final channels = widget.channels;
    if (!identical(_tagsFor, channels)) {
      _tagsFor = channels;
      _mixedPlaylists = channels.map((c) => c.playlistId).toSet().length > 1;
    }
    if (!_mixedPlaylists) return null;
    if (i > 0 && channels[i - 1].playlistId == channels[i].playlistId) {
      return null;
    }
    final name =
        context.read<PlaylistManager>().playlistNameFor(channels[i].playlistId);
    return name.isEmpty ? tr('Playlist') : name;
  }

  static const double _pixelsPerMinute = 6;
  static const Duration _windowBefore = Duration(hours: 1);
  static const Duration _windowAfter = Duration(hours: 5);
  double get _rowHeight => _guideRowHeight(context);
  double get _channelColumnWidth => _landscapeGuide(context)
      ? 132
      : _mobileGuide(context)
          ? 152
          : 156;
  double get _rulerHeight => _guideRulerHeight(context);

  /// Move the clock line independently; programme rows only need a new
  /// now/later style when a mounted programme crosses a time boundary.
  static const Duration _nowTickInterval = Duration(seconds: 30);

  /// Fixed time-window origin for this State. Once stale, request a fresh keyed guide through
  /// onWindowStale; offsets and focus positions cannot safely be rebased independently.
  late final DateTime _windowStart;
  late final DateTime _windowEnd;
  late final double _totalWidth;
  bool _staleReported = false;

  // Both vertical lists accept gestures. Mirror offsets with a re-entry
  // guard so the driving list keeps its own fling physics.
  bool _syncingVertical = false;
  final _playingButtonFocus = FocusNode(debugLabel: 'guide-playing-channel');
  final _nowButtonFocus = FocusNode(debugLabel: 'guide-now');
  final _sectionButtonFocus = FocusNode(debugLabel: 'guide-next-section');
  List<Channel>? _sectionsFor;
  List<GuideSection> _sections = const [];
  GuideSectionIndex _sectionIndex = GuideSectionIndex(const []);
  int? _lastSectionJump;
  double? _lastSectionOffset;

  int get _sectionAnchor =>
      _lastSectionJump ??
      (_gridVScroll.hasClients
          ? (_gridVScroll.offset / _rowHeight).floor()
          : 0);

  List<GuideSection> get _guideSections {
    if (!identical(_sectionsFor, widget.channels)) {
      _sectionsFor = widget.channels;
      _lastSectionJump = null;
      _lastSectionOffset = null;
      _sectionIndex = GuideSectionIndex(widget.channels);
      _sections = [
        for (final span in _sectionIndex.sections)
          (
            index: span.start,
            title: guideSectionTitle(span.header),
            logoUrl: span.header.logoUrl
          )
      ];
    }
    return _sections;
  }

  void _jumpToSection(int index) {
    if (index < 0 ||
        index >= widget.channels.length ||
        !jumpToIfLaidOut(_gridVScroll, index * _rowHeight)) {
      return;
    }
    // A short final section cannot align with the top of the viewport.
    // Remember the selected header so the next tap can still wrap around.
    _lastSectionJump = index;
    _lastSectionOffset = _gridVScroll.offset;
    _focusedRowIndex = index;
    _focusedProgram = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final blocks = _rowBlocks[index];
      final best =
          blocks == null ? null : _bestBlockFor(blocks, DateTime.now());
      if (best != null) _focusBlock(best.node);
    });
  }

  void _jumpNextSection() {
    final sections = _guideSections;
    if (sections.isEmpty || !_gridVScroll.hasClients) return;
    final top = _sectionAnchor;
    final next =
        sections.where((s) => s.index > top).firstOrNull ?? sections.first;
    _jumpToSection(next.index);
  }

  Future<void> _pickSection() async {
    final sections = _guideSections;
    if (sections.isEmpty) return;
    final top = _sectionAnchor;
    final current = sections.lastIndexWhere((s) => s.index <= top);
    final index = await showGuardedDialog<int>(
        context: context,
        builder: (_) => GuideSectionPicker(
            sections: sections, current: current < 0 ? 0 : current));
    if (mounted && index != null && identical(sections, _guideSections)) {
      _jumpToSection(index);
    }
  }

  KeyEventResult _toolbarKey(FocusNode node, KeyEvent event) {
    // The hold can still be repeating after focus arrives here. Own its
    // release so those remaining Left repeats cannot escape into the guide.
    if (_toolsOpened && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyUpEvent) _toolsOpened = false;
      return KeyEventResult.handled;
    }
    _toolsOpened = false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final nodes = [
      widget.filterFocusNode,
      if (widget.onPlayingChannel != null) _playingButtonFocus,
      _nowButtonFocus,
      if (_guideSections.isNotEmpty) _sectionButtonFocus,
    ];
    final index = nodes.indexWhere((n) => n.hasFocus);
    if (index < 0) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final next = index + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      if (next < 0) return KeyEventResult.ignored;
      nodes[next.clamp(0, nodes.length - 1)].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      focusEntry();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.gameButtonA)) {
      if (_playingButtonFocus.hasFocus) {
        widget.onPlayingChannel?.call();
      } else if (_nowButtonFocus.hasFocus) {
        _jumpToNow();
      } else if (_sectionButtonFocus.hasFocus) {
        return KeyEventResult.ignored; // HoldToActivate owns short/long Select.
      } else {
        widget.onFilterToggle();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  final _holdScroll = GuideScrollAcceleration();
  Timer? _toolsHold;
  bool _toolsDown = false,
      _toolsRepeat = false,
      _toolsElapsed = false,
      _toolsOpened = false;

  void _cancelToolsHold() {
    _toolsHold?.cancel();
    _toolsDown = _toolsRepeat = _toolsElapsed = false;
  }

  void _openToolsOnHold() {
    if (!_toolsDown || !_toolsRepeat || !_toolsElapsed || _toolsOpened) return;
    _toolsOpened = true;
    widget.filterFocusNode.requestFocus();
  }

  KeyEventResult _leftForTools(KeyEvent event) {
    if (event is KeyDownEvent) {
      _finishHold(hide: true);
      _toolsDown = true;
      _toolsOpened = false;
      _toolsHold = Timer(const Duration(milliseconds: 650), () {
        _toolsElapsed = true;
        _openToolsOnHold();
      });
    } else if (event is KeyRepeatEvent) {
      _toolsRepeat = true;
      _openToolsOnHold();
    } else if (event is KeyUpEvent) {
      final shortPress = _toolsDown && !_toolsOpened;
      _cancelToolsHold();
      if (shortPress) widget.onRemoteLeft?.call();
    }
    return KeyEventResult.handled;
  }

  // Android's legacy key path can emit zero timestamps for every repeat.
  // This monotonic input clock also drops a backlog delivered in one burst.
  final _holdClock = WidgetsBinding.instance.samplingClock.stopwatch()..start();
  final _fastBrowsing = ValueNotifier<bool>(false);
  final _browseRow = ValueNotifier<int>(0);
  final _browsePosition = ValueNotifier<GuideBrowsePosition?>(null);
  final _scrollParkingFocus =
      FocusNode(debugLabel: 'guide-scroll-landing', skipTraversal: true);
  Timer? _browseDismiss;
  int? _pendingVerticalRow;
  int _verticalRequest = 0;
  int? _repeatFrame;
  int _repeatDelta = 0;

  void _finishHold({bool hide = false, bool cancelPending = false}) {
    _cancelToolsHold();
    _holdScroll.reset();
    if (_repeatFrame != null) {
      WidgetsBinding.instance.cancelFrameCallbackWithId(_repeatFrame!);
      _repeatFrame = null;
    }
    final wasFast = _fastBrowsing.value;
    _fastBrowsing.value = false;
    _browseDismiss?.cancel();
    if (cancelPending) {
      _verticalRequest++;
      _pendingVerticalRow = null;
    }
    if (wasFast && !cancelPending && _pendingVerticalRow != null) {
      final row = _pendingVerticalRow!;
      final request = ++_verticalRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            request != _verticalRequest ||
            !_visible ||
            !_gridFocusScope.hasFocus) {
          return;
        }
        final blocks = _rowBlocks[row];
        final best = blocks == null
            ? null
            : _bestBlockFor(blocks, _referenceTime(_focusedProgram));
        if (best != null) _focusBlock(best.node);
      });
    }
    final position = _browsePosition.value;
    if (hide) {
      _browsePosition.value = null;
    } else if (position != null) {
      _browsePosition.value = GuideBrowsePosition(
          row: position.row,
          total: position.total,
          category: position.category,
          channel: position.channel,
          fast: false);
      _browseDismiss = Timer(const Duration(milliseconds: 1100),
          () => _browsePosition.value = null);
    }
  }

  KeyEventResult _guideKey(FocusNode node, KeyEvent event) {
    if (!context.read<AppPreferences>().isTelevision || !_visible) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        widget.onRemoteLeft != null) {
      return _leftForTools(event);
    }
    final direction = event.logicalKey == LogicalKeyboardKey.arrowDown
        ? 1
        : event.logicalKey == LogicalKeyboardKey.arrowUp
            ? -1
            : 0;
    if (direction == 0) {
      if (event is KeyDownEvent) _finishHold(hide: true);
      // A large jump parks focus until its visible row is mounted. Never open
      // the old offscreen channel if Select arrives in that one-frame gap.
      if (_pendingVerticalRow != null &&
          (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      if (_holdScroll.direction == direction) _finishHold();
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final delta = _holdScroll.step(direction, _holdClock.elapsed,
        repeat: event is KeyRepeatEvent, count: widget.channels.length);
    if (delta == 0) return KeyEventResult.handled;
    if (event is KeyRepeatEvent) {
      // A busy frame may receive several queued remote repeats at once. Keep
      // only its latest intent, and never scroll after the release event.
      _repeatDelta = delta;
      _repeatFrame ??= WidgetsBinding.instance.scheduleFrameCallback((_) {
        _repeatFrame = null;
        if (mounted && _visible && _gridFocusScope.hasFocus) {
          _applyRemoteStep(_repeatDelta);
        }
      });
    } else {
      if (_repeatFrame != null) {
        WidgetsBinding.instance.cancelFrameCallbackWithId(_repeatFrame!);
        _repeatFrame = null;
      }
      _applyRemoteStep(delta);
    }
    return KeyEventResult.handled;
  }

  void _applyRemoteStep(int delta) {
    _browseDismiss?.cancel();
    if (delta.abs() > 1 && !_fastBrowsing.value) {
      _scrollParkingFocus.requestFocus();
    }
    _fastBrowsing.value = delta.abs() > 1;
    moveVertical(delta);
    if (_fastBrowsing.value) {
      final row = _pendingVerticalRow ?? _focusedRowIndex;
      if (row != null && row < widget.channels.length) {
        final channel = widget.channels[row];
        _browsePosition.value = GuideBrowsePosition(
            row: row,
            total: widget.channels.length,
            category: liveCategoryLabel(channel.group),
            channel: isGuideSection(channel)
                ? guideSectionTitle(channel)
                : channel.name,
            fast: true);
      }
    }
  }

  final ScrollController _gridHScroll = ScrollController();
  final _timeViewport = ValueNotifier<(double, double)>((0, 2160));

  void _updateTimeViewport() {
    if (!mounted || !_gridHScroll.hasClients) return;
    final position = _gridHScroll.position;
    if (!position.hasContentDimensions) return;
    const step = 30 * _pixelsPerMinute;
    // One remote step of overscan on each side. Only crossing a half-hour
    // boundary rebuilds programme membership, never each pixel of a swipe.
    _timeViewport.value = (
      ((position.pixels / step).floor() - 1) * step,
      ((position.pixels + position.viewportDimension) / step).ceil() * step +
          step,
    );
  }

  final ScrollController _rulerHScroll = ScrollController();
  final ScrollController _gridVScroll = ScrollController();
  final ScrollController _labelVScroll = ScrollController();

  /// Check whether focus is currently inside the grid. The last focused row is historical
  /// state and must not trigger focus restoration while typing in the filter.
  final FocusScopeNode _gridFocusScope =
      FocusScopeNode(debugLabel: 'timeline-grid');
  Timer? _nowTimer;
  final _guideClock = ValueNotifier<DateTime>(DateTime.now());
  bool _routeCovered = false;
  bool _backgrounded = false;
  bool get _visible => !_routeCovered && !_backgrounded;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _backgrounded = state != AppLifecycleState.resumed;
    if (_backgrounded) _finishHold(hide: true, cancelPending: true);
    if (_visible) {
      _resumeGuide();
    } else {
      _nowTimer?.cancel();
    }
  }

  void _resumeGuide() {
    if (!_visible) return;
    _checkWindowStale();
    if (mounted) setState(() {});
    _startNowTimer();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _windowStart = now.subtract(_windowBefore);
    _windowEnd = now.add(_windowAfter);
    _totalWidth =
        _windowEnd.difference(_windowStart).inMinutes * _pixelsPerMinute;
    _gridHScroll.addListener(_mirrorRuler);
    _gridVScroll.addListener(_mirrorLabels);
    _labelVScroll.addListener(_mirrorGrid);
    // Guide rows load from the EPG database on demand — see
    // EpgService.getPrograms. Repaints only this guide when they arrive.
    _startNowTimer();
    // Open at the current time using a direct jump, avoiding intermediate layout during a
    // long animated scroll.
    _queueGuideReset();
  }

  int _layoutReset = 0;

  void _queueGuideReset(
      {bool resetVertical = false, bool restoreFocus = false}) {
    final reset = ++_layoutReset;
    final navigation = _verticalRequest;
    void afterLayout(int framesLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            reset != _layoutReset ||
            navigation != _verticalRequest ||
            widget.channels.isEmpty) {
          return;
        }
        if (laidOutScrollPosition(_gridHScroll) == null ||
            laidOutScrollPosition(_gridVScroll) == null) {
          if (framesLeft > 0) afterLayout(framesLeft - 1);
          return;
        }
        if (resetVertical) jumpToIfLaidOut(_gridVScroll, 0);
        _jumpToNow();
        if (restoreFocus) focusEntry();
      });
      WidgetsBinding.instance.scheduleFrame();
    }

    afterLayout(5);
  }

  @override
  void didUpdateWidget(_TimelineGuide old) {
    super.didUpdateWidget(old);
    final oldGroup = old.channels.isEmpty ? null : old.channels.first.group;
    final newGroup =
        widget.channels.isEmpty ? null : widget.channels.first.group;
    // Length is also checked, not just group — the Timeline filter bar
    // narrows/widens this same group's own channel list without changing
    // its group at all, and would otherwise leave _focusedRowIndex/
    // _rowBlocks pointing at rows that no longer exist (or no longer mean
    // what they used to) in the filtered list.
    if (oldGroup == newGroup && identical(old.channels, widget.channels)) {
      return;
    }
    // Use current grid focus, not the last focused row, when deciding whether to restore
    // guide focus during an update.
    _finishHold(hide: true, cancelPending: true);
    _densityAnchor = null;
    final hadRowFocus = _gridFocusScope.hasFocus;
    // Reset scroll and focus when the displayed group changes. Jump directly rather than
    // animating across a large channel list.
    _focusedRowIndex = null;
    _focusedProgram = null;
    _cursorSlot = null;
    // Empty search results detach the grid. Wait for the replacement layout;
    // a newer filter or explicit channel navigation cancels this reset.
    _queueGuideReset(resetVertical: true, restoreFocus: hadRowFocus);
  }

  void _mirrorRuler() {
    _updateTimeViewport();
    final source = laidOutScrollPosition(_gridHScroll);
    if (source != null) jumpToIfLaidOut(_rulerHScroll, source.pixels);
  }

  void _mirrorLabels() {
    _mirrorVertical(_gridVScroll, _labelVScroll);
  }

  void _mirrorGrid() => _mirrorVertical(_labelVScroll, _gridVScroll);

  void _mirrorVertical(ScrollController source, ScrollController target) {
    if (_syncingVertical) return;
    final sourcePosition = laidOutScrollPosition(source);
    final targetPosition = laidOutScrollPosition(target);
    if (sourcePosition == null || targetPosition == null) return;
    if (_lastSectionOffset != null &&
        (sourcePosition.pixels - _lastSectionOffset!).abs() > .1) {
      _lastSectionJump = null;
      _lastSectionOffset = null;
    }
    final offset = sourcePosition.pixels
        .clamp(targetPosition.minScrollExtent, targetPosition.maxScrollExtent);
    if ((targetPosition.pixels - offset).abs() < .01) return;
    _syncingVertical = true;
    try {
      target.jumpTo(offset);
    } finally {
      _syncingVertical = false;
    }
  }

  void _jumpToNow() {
    _cursorSlot = null;
    if (jumpToIfLaidOut(_gridHScroll, _xFor(_floorToSlot(DateTime.now())))) {
      _mirrorRuler();
    }
  }

  void _startNowTimer() {
    _nowTimer?.cancel();
    if (!_visible) return;
    _guideClock.value = DateTime.now();
    _nowTimer = Timer.periodic(_nowTickInterval, (_) {
      if (!mounted) return;
      _checkWindowStale();
      final previous = _guideClock.value;
      final now = DateTime.now();
      _guideClock.value = now;
      final crossedBoundary = _rowBlocks.values.any((blocks) => blocks.any(
          (b) =>
              (!previous.isBefore(b.start) && previous.isBefore(b.end)) !=
              (!now.isBefore(b.start) && now.isBefore(b.end))));
      if (crossedBoundary) setState(() {});
    });
  }

  /// See [_windowStart]'s doc comment. Triggered with an hour of margin
  /// before "now" would actually leave the window — not right at the
  /// edge — so the remount happens while everything still looks fine,
  /// never as a visible jump cutting off whatever's on screen. Reports
  /// once per State (guarded by [_staleReported]): the parent's remount
  /// destroys this whole State shortly after anyway, and without the
  /// guard every 30s tick between here and that remount actually landing
  /// would call it again for nothing.
  void _checkWindowStale() {
    if (_staleReported) return;
    if (!DateTime.now()
        .isBefore(_windowEnd.subtract(const Duration(hours: 1)))) {
      _staleReported = true;
      widget.onWindowStale?.call();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() {
    _routeCovered = true;
    _finishHold(hide: true, cancelPending: true);
    _nowTimer?.cancel();
  }

  @override
  void didPopNext() {
    _routeCovered = false;
    _resumeGuide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    _nowTimer?.cancel();
    _gridHScroll.removeListener(_mirrorRuler);
    _gridVScroll.removeListener(_mirrorLabels);
    _labelVScroll.removeListener(_mirrorGrid);
    _browseDismiss?.cancel();
    _holdClock.stop();
    if (_repeatFrame != null) {
      WidgetsBinding.instance.cancelFrameCallbackWithId(_repeatFrame!);
    }
    _fastBrowsing.dispose();
    _toolsHold?.cancel();
    _browseRow.dispose();
    _browsePosition.dispose();
    _scrollParkingFocus.dispose();
    _guideClock.dispose();
    _timeViewport.dispose();
    _gridHScroll.dispose();
    _rulerHScroll.dispose();
    _gridVScroll.dispose();
    _labelVScroll.dispose();
    _playingButtonFocus.dispose();
    _nowButtonFocus.dispose();
    _sectionButtonFocus.dispose();
    _gridFocusScope.dispose();
    super.dispose();
  }

  void _ensureRowVisible(int rowIndex) {
    final pos = laidOutScrollPosition(_gridVScroll);
    if (pos == null) return;
    final top = rowIndex * _rowHeight;
    final bottom = top + _rowHeight;
    final viewTop = pos.pixels;
    final viewBottom = viewTop + pos.viewportDimension;
    final visibleTop = _sectionIndex.focusTop(rowIndex, _rowHeight);
    if (visibleTop < viewTop) {
      _gridVScroll.jumpTo(visibleTop.clamp(0.0, pos.maxScrollExtent));
    } else if (bottom > viewBottom) {
      _gridVScroll.jumpTo(
          (bottom - pos.viewportDimension).clamp(0.0, pos.maxScrollExtent));
    }
  }

  double _xFor(DateTime t) =>
      t.difference(_windowStart).inMinutes * _pixelsPerMinute;

  // Every currently-mounted programme block registers its own FocusNode
  // here on mount (see _ProgramBlockState.initState/dispose) — lets
  // moveVertical/restoreFocusToChannel below jump straight to a specific
  // block instead of trusting Flutter's default directional traversal.
  final Map<int, List<({DateTime start, DateTime end, FocusNode node})>>
      _rowBlocks = {};

  @visibleForTesting
  int get mountedProgrammeRowCount => _rowBlocks.length;

  void _registerBlock(
      int rowIndex, DateTime start, DateTime end, FocusNode node) {
    (_rowBlocks[rowIndex] ??= []).add((start: start, end: end, node: node));
  }

  void _unregisterBlock(int rowIndex, FocusNode node) {
    final blocks = _rowBlocks[rowIndex];
    blocks?.removeWhere((b) => b.node == node);
    if (blocks?.isEmpty ?? false) _rowBlocks.remove(rowIndex);
  }

  /// Whichever block last took focus, as a row + the programme itself
  /// (not a fixed moment in time) — [moveVertical] derives its actual
  /// reference moment fresh, on every call, via [_referenceTime]. Two
  /// earlier attempts at a fixed reference both broke on a currently-
  /// airing programme that started well before "now" (a long block —
  /// its own `start` landed Down/Up on whatever aired back then instead
  /// of "now"; clamping to the scroll position instead landed on
  /// whatever a since-changed scroll offset happened to show, which
  /// drifted the *other* direction once `Scrollable.ensureVisible`
  /// re-aligned it for an over-wide block). Neither a stored time survives
  /// contact with "the wall clock keeps advancing while a block sits
  /// focused" anyway. [null] for a placeholder block with no real
  /// programme.
  int? _focusedRowIndex;
  EpgProgram? _focusedProgram;

  void _trackFocus(int rowIndex, EpgProgram? program) {
    _focusedRowIndex = rowIndex;
    if (_pendingVerticalRow == rowIndex) _pendingVerticalRow = null;
    _focusedProgram = program;
    if (_guideDrivenFocus) {
      _guideDrivenFocus = false;
      return;
    }
    // Focus arrived from outside the guide's own Up/Down/Left/Right
    // (a tap, or default traversal): adopt that block's column so the
    // next Up/Down stays on it.
    final now = DateTime.now();
    if (program == null || program.isNowPlaying(now)) {
      _cursorSlot = null;
    } else {
      final start =
          program.start.isBefore(_windowStart) ? _windowStart : program.start;
      _cursorSlot = _floorToSlot(start);
    }
  }

  /// Selected 30-minute time slot; null follows the live slot. Horizontal steps change this
  /// slot and vertical steps preserve it.
  DateTime? _cursorSlot;

  static const Duration _slot = Duration(minutes: 30);

  DateTime _floorToSlot(DateTime t) =>
      DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % 30);

  /// The moment to look for blocks at, for [slot] (null = live/"now").
  DateTime _timeForSlot(DateTime? slot) {
    final now = DateTime.now();
    return (slot == null || slot == _floorToSlot(now)) ? now : slot;
  }

  /// Steps the guide one 30-minute slot left (-1) or right (+1): scrolls
  /// the view by that amount and focuses whichever block in the current
  /// row covers the new slot (which may be the very same long block —
  /// then only the view moves, and the sticky label keeps its title
  /// readable). Returns false when there's nowhere further that way (the
  /// edge of the guide's time window), so the caller can fall back to
  /// its own edge behaviour.
  bool moveHorizontal(int dir) {
    final rowIndex = _focusedRowIndex;
    if (rowIndex == null) return false;
    final now = DateTime.now();
    final program = _focusedProgram;
    final current = _cursorSlot ??
        _floorToSlot((program == null || program.isNowPlaying(now))
            ? now
            : (program.start.isBefore(_windowStart)
                ? _windowStart
                : program.start));
    final target = current.add(_slot * dir);
    if (target.isBefore(_floorToSlot(_windowStart)) ||
        !target.isBefore(_windowEnd)) {
      return false;
    }
    final live = target == _floorToSlot(now);
    _cursorSlot = live ? null : target;
    if (_gridHScroll.hasClients) {
      // Align to the slot start so the complete current time block remains visible.
      jumpToIfLaidOut(_gridHScroll, _xFor(target));
    }
    final blocks = _rowBlocks[rowIndex];
    final best = blocks == null
        ? null
        : _bestBlockFor(blocks, _timeForSlot(_cursorSlot));
    final moment = _timeForSlot(_cursorSlot);
    if (best != null &&
        !moment.isBefore(best.start) &&
        moment.isBefore(best.end)) {
      _focusBlock(best.node);
    } else {
      final slot = _cursorSlot;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_gridFocusScope.hasFocus ||
            _focusedRowIndex != rowIndex ||
            _cursorSlot != slot) {
          return;
        }
        final fresh = _rowBlocks[rowIndex];
        final next = fresh == null ? null : _bestBlockFor(fresh, moment);
        if (next != null) _focusBlock(next.node);
      });
    }
    return true;
  }

  /// "Now" for a programme that's actually airing right now (recomputed
  /// fresh, never the stale value from whenever focus first landed on
  /// it) — that's the case that actually matters, since it's what makes
  /// Down/Up from a long "now playing" block land on the *other*
  /// channel's own currently-airing block instead of on whatever aired
  /// back when the focused block's own (possibly hours-old) start time
  /// was. A block deliberately drilled into via Left/Right (a future or
  /// past slot, not currently airing) instead keeps its own start —
  /// staying on that same time column is exactly what's wanted there.
  ///
  /// The time column is owned by [_cursorSlot] alone (null = live/"now"),
  /// never re-derived from whichever block a vertical move happened to
  /// land on. Deriving it from the landed block's own `start` made the
  /// column drift: landing on a row with a gap at "now" fell back to the
  /// nearest block (possibly hours away), and the *next* Up/Down then
  /// followed that block's start instead of the column the user was on.
  /// A focus that didn't come from the guide's own moves (touch, default
  /// traversal) re-seeds the column in [_trackFocus] instead.
  DateTime _referenceTime(EpgProgram? program) => _timeForSlot(_cursorSlot);

  /// Set right before the guide itself calls `requestFocus`, so
  /// [_trackFocus] can tell a guide-driven focus change (keep the column)
  /// from an external one (adopt the block's column). Cleared by the next
  /// [_trackFocus] or, if focus didn't actually change (already on that
  /// node), after the frame.
  bool _guideDrivenFocus = false;

  void _focusBlock(FocusNode node) {
    _guideDrivenFocus = true;
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _guideDrivenFocus = false;
    });
  }

  ({DateTime start, DateTime end, FocusNode node})? _bestBlockFor(
      List<({DateTime start, DateTime end, FocusNode node})> blocks,
      DateTime time) {
    if (blocks.isEmpty) return null;
    for (final b in blocks) {
      if (!b.start.isAfter(time) && b.end.isAfter(time)) return b;
    }
    // A gap at [time]: nearest block by distance to its *interval* (its
    // start or its end, whichever is closer) — not just its start, which
    // preferred a block hours ahead over the one that ended a minute ago.
    Duration gap(({DateTime start, DateTime end, FocusNode node}) b) =>
        time.isBefore(b.start)
            ? b.start.difference(time)
            : time.difference(b.end);
    return blocks.reduce((a, c) => gap(c) < gap(a) ? c : a);
  }

  /// Move to the target row's programme covering the selected time. Explicit time-based
  /// navigation avoids geometry-dependent jumps between differently sized blocks.
  void moveVertical(int delta) {
    final rowIndex = _pendingVerticalRow ?? _focusedRowIndex;
    if (rowIndex == null || widget.channels.isEmpty) return;
    if (rowIndex == 0 && delta < 0) {
      _finishHold(hide: true, cancelPending: true);
      widget.onReachedTop?.call();
      return;
    }
    final targetRow = (rowIndex + delta).clamp(0, widget.channels.length - 1);
    if (targetRow == rowIndex) return;
    final request = ++_verticalRequest;
    _pendingVerticalRow = targetRow;
    final time = _referenceTime(_focusedProgram);
    _ensureRowVisible(targetRow);
    if (_fastBrowsing.value) {
      _focusedRowIndex = targetRow;
      _browseRow.value = targetRow;
      return;
    }
    bool focusTarget() {
      final blocks = _rowBlocks[targetRow];
      final best = blocks == null ? null : _bestBlockFor(blocks, time);
      if (best == null) return false;
      _focusBlock(best.node);
      return true;
    }

    if (focusTarget()) return;
    _scrollParkingFocus.requestFocus();
    // Coalesce to the latest requested row. No backlog of repeat callbacks may
    // pull focus back, open an old channel, or steal it after Back/Menu.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _verticalRequest ||
          !_visible ||
          !_gridFocusScope.hasFocus) {
        return;
      }
      focusTarget();
    });
  }

  /// Enter the guide at the selected time and last focused or top visible row. Return false
  /// when no programme is available so the caller can fall back to scope focus.
  bool focusEntry() {
    if (widget.channels.isEmpty) return false;
    var rowIndex = _focusedRowIndex;
    if (rowIndex == null || rowIndex >= widget.channels.length) {
      rowIndex = _gridVScroll.hasClients
          ? (_gridVScroll.offset / _rowHeight)
              .ceil()
              .clamp(0, widget.channels.length - 1)
          : 0;
    }
    final row = rowIndex;
    // A refreshed/reselected list can reuse an already-focused programme
    // element. requestFocus then emits no callback: seed the row explicitly.
    _focusedRowIndex = row;
    final time = _referenceTime(_focusedProgram);
    _ensureRowVisible(row);
    final blocks = _rowBlocks[row];
    final best = blocks == null ? null : _bestBlockFor(blocks, time);
    if (best != null) {
      _focusBlock(best.node);
      return true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final retry = _rowBlocks[row];
      final r = retry == null ? null : _bestBlockFor(retry, time);
      if (r != null) _focusBlock(r.node);
    });
    return true;
  }

  /// Restore the playing channel after fullscreen closes; Timeline mode cannot use the
  /// plain-list current-channel FocusNode.
  void restoreFocusToChannel(String channelId) {
    final rowIndex = widget.channels.indexWhere((c) => c.id == channelId);
    if (rowIndex < 0) return;
    final request = ++_verticalRequest;
    _focusedRowIndex = rowIndex;
    _pendingVerticalRow = rowIndex;
    _ensureRowVisible(rowIndex);
    _scrollParkingFocus.requestFocus();
    // Always deferred, not tried synchronously first — unlike
    // moveVertical's single-row step, this jump can be arbitrarily far
    // from wherever the guide happened to be scrolled, so the target row
    // is very unlikely to already be built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_visible || request != _verticalRequest) return;
      final blocks = _rowBlocks[rowIndex];
      final best =
          blocks == null ? null : _bestBlockFor(blocks, DateTime.now());
      if (best == null) return;
      _cursorSlot = null;
      // Return to the current slot rather than the earlier start of a long programme.
      _jumpToNow();
      _focusBlock(best.node);
    });
  }

  double? _previousRowHeight;
  double? _densityAnchor;

  void _preserveDensityAnchor() {
    final height = _rowHeight;
    final previous = _previousRowHeight;
    _previousRowHeight = height;
    if (previous == null || previous == height || !_gridVScroll.hasClients) {
      return;
    }
    _densityAnchor ??= _gridVScroll.offset / previous;
    final channels = widget.channels;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_gridVScroll.hasClients ||
          _rowHeight != height ||
          !identical(channels, widget.channels)) {
        return;
      }
      final anchor = _densityAnchor;
      _densityAnchor = null;
      if (anchor != null) {
        jumpToIfLaidOut(_gridVScroll, anchor * height);
      }
    });
  }

  Widget _buildProgrammeRows(bool epgLoading) => ValueListenableBuilder<bool>(
      valueListenable: _fastBrowsing,
      builder: (context, fast, child) => ListView.builder(
            key: const ValueKey('guide-programme-scroll'),
            controller: _gridVScroll,
            // Adjacent steps benefit from overscan. Accelerated jumps skip
            // those rows, so build only the visible window until release.
            scrollCacheExtent: context.read<AppPreferences>().isTelevision
                ? ScrollCacheExtent.pixels(
                    fast || widget.selectionStatus != null ? 0 : _rowHeight * 2)
                : null,
            physics: const ClampingScrollPhysics(),
            itemCount: widget.channels.length,
            itemExtent: _rowHeight,
            itemBuilder: (context, i) => fast
                ? _buildFastGuideRow(i)
                : GuideProgrammeRow(
                    epg: widget.epg,
                    fastBrowsing: _fastBrowsing,
                    renderKey: (
                      i,
                      widget.channels[i],
                      _windowStart,
                      _windowEnd,
                      _guideClock.value,
                      epgLoading,
                      widget.translucent,
                      widget.onFocusChanged,
                    ),
                    enabled: !isGuideSection(widget.channels[i]),
                    channelId: widget.channels[i].epgId,
                    isActive: () => _visible,
                    builder: (programs) => _TimelineRow(
                          rowIndex: i,
                          channel: widget.channels[i],
                          programs: isGuideSection(widget.channels[i])
                              ? const []
                              : programs,
                          windowStart: _windowStart,
                          windowEnd: _windowEnd,
                          pixelsPerMinute: _pixelsPerMinute,
                          onOpen: () => widget.onOpen(widget.channels[i]),
                          onShowOptions: () =>
                              widget.onShowOptions(widget.channels[i]),
                          ensureRowVisible: _ensureRowVisible,
                          onFocusChanged: widget.onFocusChanged,
                          onFocusTracked: _trackFocus,
                          onRegisterBlock: _registerBlock,
                          onUnregisterBlock: _unregisterBlock,
                          hScroll: _gridHScroll,
                          timeViewport: _timeViewport,
                          keepFocused: (p) =>
                              _rowBlocks[i]?.any((b) =>
                                  b.start == p.start &&
                                  b.end == p.stop &&
                                  b.node.hasFocus) ??
                              false,
                          epgLoading: epgLoading,
                          translucent: widget.translucent,
                        )),
          ));

  Widget _buildFastGuideRow(int index) {
    final channel = widget.channels[index];
    final section = isGuideSection(channel);
    final program = section
        ? null
        : programmeAt(widget.epg.peekPrograms(channel.epgId),
            _referenceTime(_focusedProgram));
    final label = section ? guideSectionTitle(channel) : program?.title ?? '';
    final left = _gridHScroll.hasClients ? _gridHScroll.offset : 0.0;
    final width = _gridHScroll.hasClients
        ? _gridHScroll.position.viewportDimension
        : 400.0;
    return GuideFastBrowseRow(
        text: label,
        index: index,
        selected: _browseRow,
        height: _rowHeight,
        left: left,
        textWidth: math.max(0, width - 20));
  }

  @override
  Widget build(BuildContext context) {
    _preserveDensityAnchor();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateTimeViewport());
    // Keep loading and empty-guide states distinct, with focusable placeholders until
    // programme data arrives.
    final epgLoading = widget.epg.isLoading || widget.epg.lastUpdated == null;
    final scheme = Theme.of(context).colorScheme;
    final toolbarColor = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: .035),
        Theme.of(context).scaffoldBackgroundColor);
    return Column(
      children: [
        Container(
          height: _rulerHeight,
          color: widget.translucent ? Colors.transparent : toolbarColor,
          child: IconButtonTheme(
            data: IconButtonThemeData(
                style: ButtonStyle(
              foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.focused)
                      ? scheme.onPrimaryContainer
                      : states.contains(WidgetState.disabled)
                          ? scheme.onSurface.withValues(alpha: .25)
                          : scheme.onSurfaceVariant.withValues(alpha: .8)),
            )),
            child: Row(
              children: [
                SizedBox(
                  width: _channelColumnWidth,
                  child: Focus(
                    onKeyEvent: _toolbarKey,
                    child: Row(children: [
                      if (widget.onBack != null)
                        Expanded(
                            child: ExcludeFocus(
                                child: IconButton(
                          key: const ValueKey('guide-back'),
                          tooltip: tr('Back'),
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          onPressed: widget.onBack,
                          icon: const Icon(Icons.arrow_back),
                        ))),
                      Expanded(
                          child: _TimelineFilterButton(
                        focusNode: widget.filterFocusNode,
                        onPressed: widget.onFilterToggle,
                      )),
                      Expanded(
                          child: IconButton(
                        key: const ValueKey('guide-playing-channel'),
                        focusNode: _playingButtonFocus,
                        tooltip: 'Go to playing channel',
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        onPressed: widget.onPlayingChannel,
                        icon: const Icon(Icons.my_location),
                      )),
                      Expanded(
                          child: IconButton(
                        key: const ValueKey('guide-now'),
                        focusNode: _nowButtonFocus,
                        tooltip: 'Back to now',
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        onPressed: () {
                          _nowButtonFocus.requestFocus();
                          _jumpToNow();
                        },
                        icon: const Icon(Icons.update),
                      )),
                      Expanded(
                          child: TooltipTheme(
                              data: const TooltipThemeData(
                                  triggerMode: TooltipTriggerMode.manual),
                              child: HoldToActivate(
                                onTap: _jumpNextSection,
                                onHold: _pickSection,
                                child: IconButton(
                                  key: const ValueKey('guide-next-section'),
                                  focusNode: _sectionButtonFocus,
                                  tooltip: 'Next section · hold to choose',
                                  padding: EdgeInsets.zero,
                                  iconSize: 18,
                                  onPressed: _guideSections.isEmpty
                                      ? null
                                      : _jumpNextSection,
                                  icon: const Icon(Icons.segment),
                                ),
                              ))),
                    ]),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Stack(fit: StackFit.expand, children: [
                    ClipRect(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        key: const ValueKey('guide-ruler-scroll'),
                        controller: _rulerHScroll,
                        physics: const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: _totalWidth,
                          child: _TimeRuler(
                              windowStart: _windowStart,
                              windowEnd: _windowEnd,
                              pixelsPerMinute: _pixelsPerMinute),
                        ),
                      ),
                    ),
                    if (context.read<AppPreferences>().isTelevision)
                      Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          child: IgnorePointer(
                              child: Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            color: widget.translucent
                                ? Colors.transparent
                                : toolbarColor,
                            child: Text('Hold Left · Guide tools',
                                key: const ValueKey('guide-tools-hint'),
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: .7))),
                          ))),
                  ]),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: widget.channels.isEmpty
              ? Center(
                  child: widget.searching
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(widget.emptyLabel))
              : Stack(children: [
                  Positioned.fill(
                      child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: _channelColumnWidth,
                        child: ClipRect(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _fastBrowsing,
                            builder: (context, fast, _) => ListView.builder(
                              key: const ValueKey('guide-channel-scroll'),
                              controller: _labelVScroll,
                              // Match the timeline's visible-only fast window.
                              scrollCacheExtent:
                                  context.read<AppPreferences>().isTelevision
                                      ? ScrollCacheExtent.pixels(
                                          fast || widget.selectionStatus != null
                                              ? 0
                                              : _rowHeight * 2)
                                      : null,
                              physics: const ClampingScrollPhysics(),
                              itemCount: widget.channels.length,
                              itemExtent: _rowHeight,
                              itemBuilder: (context, i) => fast
                                  ? GuideFastBrowseRow(
                                      text: isGuideSection(widget.channels[i])
                                          ? guideSectionTitle(
                                              widget.channels[i])
                                          : widget.channels[i].name,
                                      index: i,
                                      selected: _browseRow,
                                      height: _rowHeight,
                                      textInset: _guideLabelTextInset(
                                          context, widget.channels[i]),
                                      fontSize: context
                                              .read<AppPreferences>()
                                              .isTelevision
                                          ? 12
                                          : 13,
                                      topInset:
                                          _playlistTagFor(i) == null ? 0 : 12,
                                      label: true)
                                  : GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: widget.selectionStatus == null
                                          ? null
                                          : () =>
                                              widget.onOpen(widget.channels[i]),
                                      child: _ChannelLabel(
                                          channel: widget.channels[i],
                                          playlistTag: widget.selectionStatus
                                                  ?.call(widget.channels[i]) ??
                                              _playlistTagFor(i))),
                            ),
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: FocusScope(
                          node: _gridFocusScope,
                          onKeyEvent: _guideKey,
                          onFocusChange: (focused) {
                            if (!focused) {
                              _finishHold(hide: true, cancelPending: true);
                            }
                          },
                          child: Focus(
                            focusNode: _scrollParkingFocus,
                            // Rail changes resize this viewport without rebuilding
                            // the guide. Refresh culling when layout reports its size.
                            child:
                                NotificationListener<ScrollMetricsNotification>(
                              onNotification: (notification) {
                                if (notification.depth == 0 &&
                                    notification.metrics.axis ==
                                        Axis.horizontal) {
                                  _updateTimeViewport();
                                }
                                return false;
                              },
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                key: const ValueKey('guide-time-scroll'),
                                controller: _gridHScroll,
                                child: SizedBox(
                                  width: _totalWidth,
                                  height: widget.channels.length * _rowHeight,
                                  child: Stack(
                                    children: [
                                      _buildProgrammeRows(epgLoading),
                                      ValueListenableBuilder<DateTime>(
                                        valueListenable: _guideClock,
                                        child: IgnorePointer(
                                            child: SizedBox(
                                                width: 2,
                                                child: ColoredBox(
                                                    color: interfaceColor(
                                                        context,
                                                        Colors.redAccent)))),
                                        builder: (context, now, child) =>
                                            Positioned(
                                                left: _xFor(now)
                                                    .clamp(0.0, _totalWidth),
                                                top: 0,
                                                bottom: 0,
                                                child: child!),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )),
                  Positioned.fill(
                      child: StickyGuideHeader(
                          index: _sectionIndex,
                          controller: _gridVScroll,
                          rowHeight: _rowHeight)),
                  Positioned.fill(
                      child: GuideBrowsePositionOverlay(
                          position: _browsePosition)),
                  if (widget.searching)
                    Positioned(
                        top: 4,
                        right: 8,
                        child: IgnorePointer(
                            child: DecoratedBox(
                                decoration: const BoxDecoration(
                                    color: Color(0xEE171D25)),
                                child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    child: Text(tr('Updating results…'),
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: interfaceColor(
                                                context, Colors.white70))))))),
                ]),
        ),
      ],
    );
  }
}

/// Hour/half-hour tick labels across the guide's fixed time window —
/// visually paired with the grid via [_TimelineGuideState._mirrorRuler],
/// not an independently-scrolled view of its own.
class _TimeRuler extends StatelessWidget {
  const _TimeRuler(
      {required this.windowStart,
      required this.windowEnd,
      required this.pixelsPerMinute});

  final DateTime windowStart;
  final DateTime windowEnd;
  final double pixelsPerMinute;

  @override
  Widget build(BuildContext context) {
    final timeFormat = TimeFormat.hm;
    final firstTick = DateTime(
            windowStart.year,
            windowStart.month,
            windowStart.day,
            windowStart.hour,
            windowStart.minute - windowStart.minute % 30)
        .add(const Duration(minutes: 30));
    final ticks = <DateTime>[
      for (var t = firstTick;
          t.isBefore(windowEnd);
          t = t.add(const Duration(minutes: 30)))
        t,
    ];
    return Stack(
      children: [
        for (final tick in ticks)
          Positioned(
            left: tick.difference(windowStart).inMinutes * pixelsPerMinute,
            top: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(timeFormat.format(tick),
                    style: TextStyle(
                        color: interfaceColor(context,
                            tick.minute == 0 ? Colors.white70 : Colors.white54),
                        fontWeight: tick.minute == 0
                            ? FontWeight.w500
                            : FontWeight.w400,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontSize: context.read<AppPreferences>().isTelevision
                            ? 11
                            : 12)),
              ),
            ),
          ),
      ],
    );
  }
}

/// Opens the guide search above the channel column. The parent owns the focus
/// node so remote navigation can move between this button and the search field.
class _TimelineFilterButton extends StatefulWidget {
  const _TimelineFilterButton(
      {required this.focusNode, required this.onPressed});

  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  State<_TimelineFilterButton> createState() => _TimelineFilterButtonState();
}

class _TimelineFilterButtonState extends State<_TimelineFilterButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Flat focus fill; selection keeps a quieter accent outline.
    return SizedBox(
      key: const ValueKey('guide-search'),
      height: _guideRulerHeight(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        // HoldToActivate recognizes the supported Select/Enter/gamepad activation keys
        // consistently across remotes.
        child: HoldToActivate(
          onTap: () {
            widget.focusNode.requestFocus();
            widget.onPressed();
          },
          child: Focus(
            focusNode: widget.focusNode,
            onFocusChange: (f) => setState(() => _focused = f),
            child: InkWell(
              canRequestFocus: false,
              // Request focus explicitly; an InkWell tap does not necessarily focus its
              // wrapping node.
              onTap: () {
                widget.focusNode.requestFocus();
                widget.onPressed();
              },
              borderRadius: BorderRadius.circular(2),
              child: Container(
                decoration: BoxDecoration(
                  color:
                      _focused ? scheme.primaryContainer : Colors.transparent,
                  border: Border.all(
                      color: _focused
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: .09)),
                  borderRadius: BorderRadius.circular(2),
                ),
                alignment: Alignment.center,
                child: Tooltip(
                    message: 'Search · hold Left for guide tools',
                    child: Icon(Icons.search,
                        size: 16,
                        color: _focused
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant.withValues(alpha: .8))),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// TV filter keyboard with explicit row/column navigation. Avoid a platform TextField in the
/// key grid so system keyboard overlays cannot intercept remote navigation.
class _TimelineVirtualKeyboard extends StatelessWidget {
  const _TimelineVirtualKeyboard({
    required this.scope,
    required this.nodes,
    required this.onChar,
    required this.onSpace,
    required this.onBackspace,
    required this.onSubmit,
    required this.onExitDown,
    required this.onExitUp,
  });

  /// A-Z, 0-9, space/backspace/search — three uniform rows of 13 so the
  /// row/column arithmetic in [_moveFocus] stays as simple as
  /// `pin_pad.dart`'s own (no ragged rows to special-case, same reason
  /// its 4x3 grid is uniform).
  static const keyRows = [
    ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M'],
    ['N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'],
    [
      '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', //
      'space', 'back', 'search',
    ],
  ];

  /// Reports true if *any* key in the grid currently has focus — see its
  /// own field doc comment in `_TvHomeScreenState` for why the Up/Down
  /// focus-coordination with the guide needs this instead of a single
  /// node's `hasFocus`.
  final FocusScopeNode scope;

  /// Index-matched to [keyRows]; owned by `_TvHomeScreenState` (not this
  /// widget) so "focus the first key" can be requested from outside
  /// (opening the filter, or Up from the guide's top row) without a
  /// `GlobalKey`/`State` reference into this widget.
  final List<List<FocusNode>> nodes;

  final void Function(String char) onChar;
  final VoidCallback onSpace;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;

  /// Down from the bottom row — exits into the (now live-filtered) guide
  /// below instead of clamping, via the same `focusEntry()` path Up from
  /// the guide's top row already uses to come back here. See this
  /// widget's instantiation site for the exact callback wiring.
  final VoidCallback onExitDown;
  final VoidCallback onExitUp;

  void _moveFocus(int rowDelta, int colDelta) {
    final current = FocusManager.instance.primaryFocus;
    for (var r = 0; r < nodes.length; r++) {
      for (var c = 0; c < nodes[r].length; c++) {
        if (nodes[r][c] != current) continue;
        final nr = r + rowDelta;
        if (nr < 0) {
          onExitUp();
          return;
        }
        if (nr >= nodes.length) {
          onExitDown();
          return;
        }
        final clampedR = nr.clamp(0, nodes.length - 1);
        final clampedC = (c + colDelta).clamp(0, nodes[clampedR].length - 1);
        nodes[clampedR][clampedC].requestFocus();
        return;
      }
    }
  }

  void _handleKey(String value) {
    switch (value) {
      case 'space':
        onSpace();
      case 'back':
        onBackspace();
      case 'search':
        onSubmit();
      default:
        onChar(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveFocus(-1, 0),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveFocus(1, 0),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _moveFocus(0, -1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _moveFocus(0, 1),
      },
      child: FocusScope(
        node: scope,
        child: Column(
          children: [
            for (var r = 0; r < keyRows.length; r++)
              Expanded(
                child: Row(
                  children: [
                    for (var c = 0; c < keyRows[r].length; c++)
                      Expanded(
                        flex: keyRows[r][c] == 'search' ? 2 : 1,
                        child: _TimelineKeyboardKey(
                          focusNode: nodes[r][c],
                          label: keyRows[r][c],
                          onPressed: () => _handleKey(keyRows[r][c]),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimelineKeyboardKey extends StatefulWidget {
  const _TimelineKeyboardKey(
      {super.key,
      required this.focusNode,
      required this.label,
      required this.onPressed,
      this.selected = false});

  final FocusNode focusNode;
  final String label;
  final VoidCallback onPressed;
  final bool selected;

  @override
  State<_TimelineKeyboardKey> createState() => _TimelineKeyboardKeyState();
}

class _TimelineKeyboardKeyState extends State<_TimelineKeyboardKey> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = switch (widget.label) {
      'space' => tr('Space'),
      'back' => '⌫',
      'search' => tr('Search'),
      final c => c,
    };
    return Semantics(
        selected: widget.selected,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            animationDuration: Duration.zero,
            color: _focused
                ? scheme.primary
                : (widget.label == 'search' || widget.selected)
                    ? scheme.primary.withValues(alpha: 0.18)
                    : interfaceColor(context, Colors.white)
                        .withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(2),
            // HoldToActivate, not a plain InkWell's own keyboard activation —
            // see _TimelineFilterButton's identical doc comment for why: a
            // plain InkWell doesn't reliably respond to every "Select"-
            // equivalent key this app's real remotes send.
            child: HoldToActivate(
              onTap: () {
                widget.focusNode.requestFocus();
                widget.onPressed();
              },
              child: InkWell(
                // requestFocus() explicitly, not left to InkWell's own tap
                // handling — same reasoning as _TimelineFilterButton/
                // _ProgramBlockState elsewhere in this file.
                focusNode: widget.focusNode,
                onFocusChange: (f) => setState(() => _focused = f),
                onTap: () {
                  widget.focusNode.requestFocus();
                  widget.onPressed();
                },
                borderRadius: BorderRadius.circular(2),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      display,
                      style: TextStyle(
                        fontSize: widget.label == 'space' ? 10 : 13,
                        fontWeight: FontWeight.w600,
                        color: _focused
                            ? scheme.onPrimary
                            : interfaceColor(context, Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
  }
}

/// The left column's per-row channel identity — purely informational, not
/// itself focusable; D-pad focus lives entirely on the programme blocks in
/// [_TimelineRow], same as the plain channel list never puts focus on a
/// row's logo.
double _guideLabelTextInset(BuildContext context, Channel channel) {
  if (isGuideSection(channel)) {
    return 8 + ((channel.logoUrl?.isNotEmpty ?? false) ? 34 : 0);
  }
  final logo = _guideLogoSize(context);
  return 8 + logo + (_mobileGuide(context) ? 6 : 8);
}

class _ChannelLabel extends StatelessWidget {
  const _ChannelLabel({required this.channel, this.playlistTag});

  final Channel channel;

  /// Source context for the first row of each playlist in a mixed guide.
  final String? playlistTag;

  @override
  Widget build(BuildContext context) {
    final tag = playlistTag;
    final tv = context.read<AppPreferences>().isTelevision;
    if (isGuideSection(channel)) {
      return Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        color: Theme.of(context).colorScheme.primary.withValues(alpha: .12),
        child: Row(children: [
          if (channel.logoUrl?.isNotEmpty ?? false) ...[
            SizedBox(
                width: 28,
                height: 28,
                child: LiveChannelLogo(
                    url: channel.logoUrl!, icon: Icons.segment)),
            const SizedBox(width: 6),
          ],
          Expanded(
              child: Text(guideSectionTitle(channel),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600))),
        ]),
      );
    }
    final name = Text(channel.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: interfaceColor(context, Colors.white).withValues(alpha: .82),
            fontSize: tv
                ? 12
                : _landscapeGuide(context)
                    ? 11.5
                    : 12.5,
            fontWeight: FontWeight.w400,
            height: tv ? 1.1 : 1.15));
    final row = SizedBox(
      height: _guideRowHeight(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, tag == null || tv ? 0 : 12, 8, 0),
        child: Row(
          children: [
            SizedBox(
              width: _guideLogoSize(context),
              height: _guideLogoSize(context),
              child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
                  ? LiveChannelLogo(url: channel.logoUrl!)
                  : const Icon(Icons.tv),
            ),
            SizedBox(width: _mobileGuide(context) ? 6 : 8),
            Expanded(
                child: tv && tag != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Text(tag,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 8.5,
                                    height: 1.1,
                                    fontWeight: FontWeight.w500,
                                    color:
                                        Theme.of(context).colorScheme.primary)),
                            name,
                          ])
                    : name),
          ],
        ),
      ),
    );
    if (tag == null || tv) return row;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        row,
        Positioned(
          top: 2,
          left: 6,
          right: 6,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Duration-sized programme blocks share the guide's horizontal scroll offset. Avoid a
/// separate scrollable or focus scope per channel row.
class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.rowIndex,
    required this.channel,
    required this.programs,
    required this.windowStart,
    required this.windowEnd,
    required this.pixelsPerMinute,
    required this.onOpen,
    required this.onShowOptions,
    required this.ensureRowVisible,
    required this.onFocusChanged,
    required this.onFocusTracked,
    required this.onRegisterBlock,
    required this.onUnregisterBlock,
    required this.hScroll,
    required this.timeViewport,
    required this.keepFocused,
    required this.epgLoading,
    this.translucent = false,
  });

  final bool translucent;
  final int rowIndex;
  final Channel channel;
  final List<EpgProgram> programs;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double pixelsPerMinute;
  final VoidCallback onOpen;
  final VoidCallback onShowOptions;
  final void Function(int rowIndex)? ensureRowVisible;
  final void Function(Channel channel, EpgProgram? program)? onFocusChanged;

  /// Feeds [_TimelineGuideState._trackFocus] — see its own doc comment.
  final void Function(int rowIndex, EpgProgram? program)? onFocusTracked;
  final void Function(
          int rowIndex, DateTime start, DateTime end, FocusNode node)
      onRegisterBlock;
  final void Function(int rowIndex, FocusNode node) onUnregisterBlock;

  /// Shared with every block in the grid — drives the sticky-label fix
  /// in [_ProgramBlockState] (each block reacts to the same horizontal
  /// scroll position independently).
  final ScrollController hScroll;
  final ValueListenable<(double, double)> timeViewport;
  final bool Function(EpgProgram) keepFocused;

  /// Whether the EPG fetch hasn't completed at all yet — vs. having
  /// completed with genuinely nothing for this channel (a duplicate with
  /// no EPG mapping, commonly). Only changes which placeholder label an
  /// empty row shows below; doesn't affect real programme blocks.
  final bool epgLoading;

  @override
  Widget build(BuildContext context) {
    final blocks = <EpgProgram, Widget>{};
    return ValueListenableBuilder<(double, double)>(
        valueListenable: timeViewport,
        builder: (context, range, _) => _buildRow(context, range, blocks));
  }

  Widget _buildRow(BuildContext context, (double, double) range,
      Map<EpgProgram, Widget> blocks) {
    final now = DateTime.now();
    // Deduplicate programmes by start/stop before building keyed blocks. Identical intervals
    // would overlap and violate key uniqueness; keep the first entry.
    final seenSlots = <String>{};
    final inWindow = programs
        .where(
            (p) => p.stop.isAfter(windowStart) && p.start.isBefore(windowEnd))
        .where((p) => seenSlots.add(
            '${p.start.millisecondsSinceEpoch}-${p.stop.millisecondsSinceEpoch}'))
        .toList();
    if (inWindow.isEmpty) {
      // A full-window placeholder keeps channels focusable and playable when no guide data is
      // available.
      final totalWidth =
          windowEnd.difference(windowStart).inMinutes * pixelsPerMinute;
      return SizedBox(
        height: _guideRowHeight(context),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: _guideBlockGap(context)),
          child: _ProgramBlock(
            program: null,
            placeholderLabel: isGuideSection(channel)
                ? guideSectionTitle(channel)
                : epgLoading
                    ? tr('Loading EPG…')
                    : tr('No program data available'),
            isNow: false,
            translucent: translucent,
            onOpen: onOpen,
            onShowOptions: onShowOptions,
            blockLeft: 0,
            blockWidth: totalWidth,
            hScroll: hScroll,
            onRegister: (node) =>
                onRegisterBlock(rowIndex, windowStart, windowEnd, node),
            onUnregister: (node) => onUnregisterBlock(rowIndex, node),
            onFocusGained: () {
              ensureRowVisible?.call(rowIndex);
              onFocusChanged?.call(channel, null);
              onFocusTracked?.call(rowIndex, null);
            },
          ),
        ),
      );
    }
    final from = windowStart.add(
        Duration(milliseconds: (range.$1 / pixelsPerMinute * 60000).round()));
    final to = windowStart.add(
        Duration(milliseconds: (range.$2 / pixelsPerMinute * 60000).round()));
    final visible = inWindow
        .where((p) =>
            (p.stop.isAfter(from) && p.start.isBefore(to)) || keepFocused(p))
        .toList();
    // A guide gap must still offer a row to remote navigation.
    if (visible.isEmpty) {
      visible.add(inWindow.where((p) => p.stop.isAfter(from)).firstOrNull ??
          inWindow.last);
    }
    double leftFor(EpgProgram p) => p.start.isBefore(windowStart)
        ? 0.0
        : p.start.difference(windowStart).inMinutes * pixelsPerMinute;
    double widthFor(EpgProgram p) =>
        (p.stop.isAfter(windowEnd) ? windowEnd : p.stop)
            .difference(p.start.isBefore(windowStart) ? windowStart : p.start)
            .inMinutes *
        pixelsPerMinute;
    return SizedBox(
      height: _guideRowHeight(context),
      child: Stack(
        children: [
          for (final program in visible)
            blocks.putIfAbsent(
                program,
                () => Positioned(
                      // Keyed by the programme's own span: a block's registered
                      // start/end (see _registerBlock) is captured once at mount,
                      // so after an EPG refresh an unkeyed block would be matched
                      // by position to a *different* programme and keep answering
                      // Up/Down lookups with the old one's times.
                      key: ValueKey(
                          '${program.start.millisecondsSinceEpoch}-${program.stop.millisecondsSinceEpoch}'),
                      left: leftFor(program),
                      width: widthFor(program),
                      top: _guideBlockGap(context),
                      bottom: _guideBlockGap(context),
                      child: _ProgramBlock(
                        program: program,
                        isNow: program.isNowPlaying(now),
                        translucent: translucent,
                        onOpen: onOpen,
                        onShowOptions: onShowOptions,
                        blockLeft: leftFor(program),
                        blockWidth: widthFor(program),
                        hScroll: hScroll,
                        revealRange: timeViewport,
                        onRegister: (node) => onRegisterBlock(
                            rowIndex, program.start, program.stop, node),
                        onUnregister: (node) =>
                            onUnregisterBlock(rowIndex, node),
                        onFocusGained: () {
                          ensureRowVisible?.call(rowIndex);
                          onFocusChanged?.call(channel, program);
                          onFocusTracked?.call(rowIndex, program);
                        },
                      ),
                    )),
        ],
      ),
    );
  }
}

class _ProgramBlock extends StatefulWidget {
  const _ProgramBlock(
      {required this.program,
      required this.isNow,
      required this.onOpen,
      required this.onShowOptions,
      required this.blockLeft,
      required this.blockWidth,
      required this.hScroll,
      this.onFocusGained,
      this.revealRange,
      this.placeholderLabel,
      this.onRegister,
      this.onUnregister,
      this.translucent = false});

  final bool translucent;

  /// Read at focus time: cached blocks can outlive their original viewport.
  final ValueListenable<(double, double)>? revealRange;

  /// Null for a row with no EPG data at all — [placeholderLabel] is shown
  /// instead of a title, but this block is still focusable and selectable
  /// (Select still opens the channel) exactly like a real one.
  final EpgProgram? program;
  final String? placeholderLabel;
  final bool isNow;
  final VoidCallback onOpen;

  /// Hold-Select — see [_TvHomeScreenState._showChannelOptions]'s doc
  /// comment for why this needs to exist at all here (the focused thing
  /// is a time slot, not the channel itself, so a bare hold-to-favorite
  /// like the plain live list's had nothing to act on).
  final VoidCallback onShowOptions;
  final VoidCallback? onFocusGained;

  /// This block's own left/width within the shared horizontally-scrolled
  /// region — the same values [_TimelineRow] used to position its
  /// `Positioned` wrapper. Needed to keep the title visible once the
  /// block is wider than the viewport and has scrolled partway
  /// off-screen (see the sticky-label [ListenableBuilder] below).
  final double blockLeft;
  final double blockWidth;
  final ScrollController hScroll;

  /// Registers/unregisters this block's own [FocusNode] with
  /// [_TimelineGuideState] on mount/unmount — lets
  /// [_TimelineGuideState.moveVertical]/[_TimelineGuideState
  /// .restoreFocusToChannel] jump straight to a specific block instead of
  /// trusting default directional traversal (see [_TimelineGuideState
  /// .moveVertical]'s doc comment for why that's unreliable here).
  final void Function(FocusNode node)? onRegister;
  final void Function(FocusNode node)? onUnregister;

  @override
  State<_ProgramBlock> createState() => _ProgramBlockState();
}

class _ProgramBlockState extends State<_ProgramBlock> {
  bool _focused = false;
  final FocusNode _node = FocusNode();
  final _labelInset = ValueNotifier<double>(0);

  void _updateLabelInset() {
    final scroll = widget.hScroll.hasClients ? widget.hScroll.offset : 0.0;
    _labelInset.value = (scroll - widget.blockLeft)
        .clamp(0.0, (widget.blockWidth - 40).clamp(0.0, double.infinity));
  }

  @override
  void initState() {
    super.initState();
    widget.onRegister?.call(_node);
    widget.hScroll.addListener(_updateLabelInset);
    _updateLabelInset();
  }

  @override
  void didUpdateWidget(_ProgramBlock old) {
    super.didUpdateWidget(old);
    if (old.hScroll != widget.hScroll) {
      old.hScroll.removeListener(_updateLabelInset);
      widget.hScroll.addListener(_updateLabelInset);
    }
    _updateLabelInset();
    if (old.program?.start != widget.program?.start ||
        old.program?.stop != widget.program?.stop) {
      old.onUnregister?.call(_node);
      widget.onRegister?.call(_node);
    }
  }

  @override
  void dispose() {
    widget.onUnregister?.call(_node);
    widget.hScroll.removeListener(_updateLabelInset);
    _labelInset.dispose();
    _node.dispose();
    super.dispose();
  }

  /// Scroll horizontally only when the programme is entirely off-screen. Partially visible
  /// blocks retain position and use sticky titles; directional handlers position the viewport
  /// explicitly.
  void _revealHorizontally() {
    // A lone future/past listing is retained to keep a guide gap focusable.
    // Moving vertically onto that row must not drag every channel to its time.
    // Explicit Left/Right navigation positions the viewport before focusing.
    final range = widget.revealRange?.value;
    if (range != null &&
        (widget.blockLeft >= range.$2 ||
            widget.blockLeft + widget.blockWidth <= range.$1)) {
      return;
    }
    if (widget.hScroll.hasClients) {
      final pos = widget.hScroll.position;
      final viewLeft = pos.pixels;
      final viewRight = viewLeft + pos.viewportDimension;
      final overlaps = widget.blockLeft < viewRight &&
          widget.blockLeft + widget.blockWidth > viewLeft;
      if (overlaps) return;
    }
    // Vertical reveal is owned by the guide. Walking every ancestor scrollable
    // here would also top-align the row when restoring an off-screen programme.
    jumpToIfLaidOut(widget.hScroll, widget.blockLeft);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Flat focus fill; selection keeps a quieter accent outline.
    final accent = scheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      // Same HoldToActivate-over-InkWell shape as the plain live list's
      // rows — a held Select here now opens _showChannelOptions, the
      // one thing that plain hold-to-favorite couldn't do for a block
      // (the focused thing is a time slot, not the channel).
      child: HoldToActivate(
        onTap: widget.onOpen,
        onHold: widget.onShowOptions,
        child: Focus(
          focusNode: _node,
          onFocusChange: (f) {
            setState(() => _focused = f);
            // Reveal each axis independently; keep the guide's minimal vertical
            // movement when a column transition restores programme focus.
            if (f) {
              widget.onFocusGained?.call();
              _revealHorizontally();
            }
          },
          child: InkWell(
            canRequestFocus: false,
            // One click/tap = preview in the corner box, a second one on
            // the now-playing channel = fullscreen — that logic lives in
            // onOpen (TvHomeScreen._previewOrOpenChannel), so a mouse
            // double-click is simply two clicks and no onDoubleTap is
            // needed (it would also delay every single click). The
            // explicit requestFocus is still needed: InkWell doesn't focus
            // a block on click by itself here (checked on Windows — no
            // focus, no details panel).
            onTap: () {
              _node.requestFocus();
              widget.onOpen();
            },
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: _focused
                    ? scheme.primaryContainer
                    : widget.isNow
                        ? (widget.translucent
                            ? Colors.black.withValues(alpha: 0.45)
                            : scheme.surfaceContainerHighest)
                        : interfaceColor(context, Colors.white)
                            .withValues(alpha: 0.025),
                border: Border.all(
                  color: _focused
                      ? accent
                      : widget.isNow
                          ? scheme.outlineVariant
                          : interfaceColor(context, Colors.white10),
                  width: _focused ? 2 : 0.5,
                ),
                borderRadius: BorderRadius.circular(2),
                boxShadow: const [],
              ),
              alignment: Alignment.centerLeft,
              // Keep titles visible when long blocks extend left of the viewport. Adjust only
              // intersecting labels, clamped within their own blocks, to avoid relayout of
              // off-screen content.
              child: ValueListenableBuilder<double>(
                valueListenable: _labelInset,
                child: Text(
                  widget.program?.title ?? widget.placeholderLabel ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _focused
                          ? scheme.onPrimaryContainer
                          : widget.program == null
                              ? interfaceColor(context, Colors.white54)
                              : widget.isNow || widget.translucent
                                  ? interfaceColor(context, Colors.white)
                                  : scheme.onSurfaceVariant,
                      fontSize: context.read<AppPreferences>().isTelevision
                          ? 11.5
                          : _landscapeGuide(context)
                              ? 10.5
                              : _mobileGuide(context)
                                  ? 11.5
                                  : 12,
                      height: context.read<AppPreferences>().isTelevision
                          ? 1.1
                          : 1.15,
                      fontWeight: widget.isNow || _focused
                          ? FontWeight.w500
                          : FontWeight.w400,
                      fontStyle: widget.program == null
                          ? FontStyle.italic
                          : FontStyle.normal,
                      // Readable over the video in full-video mode.
                      shadows: widget.translucent
                          ? const [Shadow(color: Colors.black, blurRadius: 4)]
                          : null),
                ),
                builder: (context, inset, child) {
                  return Padding(
                    padding: EdgeInsets.fromLTRB(6 + inset, 2, 6, 2),
                    child: child,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
