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
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/m3u_group.dart';
import '../models/xtream_series.dart';
import '../services/app_preferences.dart';
import '../services/app_update_service.dart';
import '../services/desktop_window.dart';
import '../services/desktop_mini_player.dart';
import '../services/epg_service.dart';
import '../services/playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/storage_service.dart';
import '../services/viewer_profile_service.dart';
import '../utils/time_format.dart';
import '../utils/scroll_safety.dart';
import '../utils/constants.dart';
import '../utils/display_title.dart';
import '../utils/route_observer.dart';
import '../utils/top_level_tab_route.dart';
import '../widgets/main_navigation_rail.dart';
import '../utils/tv_theme.dart';
import '../utils/image_urls.dart';
import '../widgets/preview_player_controls.dart';
import '../widgets/catalog_warmup_banner.dart';
import '../widgets/detail_header.dart';
import '../widgets/hd_network_image.dart';
import '../widgets/hold_to_activate.dart';
import '../widgets/player_dialog.dart';
import '../widgets/tv_menu_tile.dart';
import '../widgets/live_resume_hint.dart';
import '../widgets/mode_button.dart';
import '../widgets/player_controls.dart';
import '../widgets/poster_card.dart';
import '../widgets/section_label.dart';
import '../widgets/update_prompt.dart';
import '../widgets/settings_scaffold.dart';
import 'catalog_sync_screen.dart';
import 'group_catalog_screen.dart';
import 'desktop_multiview_screen.dart';
import 'desktop_player_screen.dart';
import 'multiview_screen.dart';
import 'movie_detail_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'search_screen.dart';
import 'sports_screen.dart';
import 'archive_screen.dart';
import 'series_detail_screen.dart';
import 'settings/check_updates_screen.dart';
import 'settings/settings_menu_screen.dart';
import '../l10n/l10n.dart';

bool _mobileGuide(BuildContext context) =>
    !context.read<AppPreferences>().isTelevision &&
    MediaQuery.sizeOf(context).shortestSide < 600;
bool _landscapeGuide(BuildContext context) =>
    _mobileGuide(context) &&
    MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
double _guideRowHeight(BuildContext context) =>
    _landscapeGuide(context) ? 36 : 44;
double _guideRulerHeight(BuildContext context) => _landscapeGuide(context)
    ? 24
    : _mobileGuide(context)
        ? 28
        : 30;

/// Directional D-pad focus movement between widgets (arrow keys via the
/// default `FocusTraversalPolicy`) does *not* automatically scroll a newly
/// focused widget into view the way Tab-based traversal does — several
/// rows in this screen's sidebars ended up effectively unreachable by
/// remote for exactly this reason (most recently: a new bottom-of-list
/// button that focus could reach but stayed below the visible viewport,
/// reading as "doesn't exist"). Called from every row's `onFocusChange`
/// rather than added once at the list level, since a `ListView` has no
/// single hook for "one of my descendants just got focused."
void _ensureVisible(BuildContext context) {
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

  /// Movies/TV Shows showing "What's New" (not on a portrait phone): the
  /// current slide's backdrop fills the whole screen behind everything,
  /// like the detail pages, and passed side columns hide completely on a
  /// TV (same as [_fullVideo]). Set each build.
  bool _fullArt = false;

  /// The What's New slide's landscape backdrop, published by
  /// `_WhatsNewCarousel` for the full-screen layer in [build]. Null = no
  /// backdrop (the carousel then shows the poster beside the text itself).
  final ValueNotifier<_WhatsNewArt?> _whatsNewArt = ValueNotifier(null);

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
  String? _focusedTitle;
  String? _focusedImageUrl;

  /// A true landscape TMDB backdrop for whatever's currently focused, when
  /// one's already been enriched — see `_BrowseHero`'s doc comment for why
  /// this is kept separate from [_focusedImageUrl] (a portrait poster/logo)
  /// rather than folded into one fallback chain.
  String? _focusedBackdropUrl;

  /// True while the focused title's backdrop may still arrive (its info
  /// fetch hasn't finished): the hero shows no picture instead of the
  /// portrait poster, so it goes dark -> backdrop rather than poster ->
  /// backdrop ("the old style appears first then the new one").
  /// Cleared once the fetch is done; only then does a title with no
  /// backdrop fall back to its poster.
  bool _focusedArtPending = false;

  /// The stable id of whatever's currently focused in the Movies/TV Shows
  /// browse grid — `_updateBrowseFocus`'s de-dupe key (title alone isn't
  /// unique enough across playlists) and the dwell timer's "is this
  /// still the same thing" guard once it fires.
  String? _focusedId;
  String? _focusedDescription;
  Timer? _descriptionDwellTimer;
  static const _kDescriptionDwell = Duration(milliseconds: 400);

  /// Current focus column: tabs, groups, list or preview. Earlier columns collapse as focus
  /// advances into content.
  int _focusDepth = 0;

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

  /// Per-category-title [GlobalKey]s attached to each browse row (see
  /// [_buildMoviesBrowse]/[_buildShowsBrowse]) so the Movies/TV Shows
  /// groups column can jump straight to a category instead of filtering
  /// the whole view down to it — a shortcut into the existing catalog
  /// scroll, not a second way of browsing.
  final Map<String, GlobalKey> _groupRowKeys = {};
  final GlobalKey _continueWatchingRowKey = GlobalKey();
  final ScrollController _browseScrollController = ScrollController();

  /// Browse rows in rendered order: null for Continue Watching, then (playlistId, title). Use
  /// these identities to move directly between row focus nodes without searching every
  /// poster.
  List<({String playlistId, String title})?> _browseRowKeys = [];

  /// Index into [_browseRowKeys] for whichever row currently has D-pad
  /// focus — kept up to date by every poster's `onFocusGained` in
  /// [_buildMoviesBrowse]/[_buildShowsBrowse], not just each row's first
  /// card, so Up/Down still resolves correctly after moving right within
  /// a row.
  int? _focusedBrowseRowIndex;

  /// Whether Movies/TV Shows is currently showing the "What's New"
  /// carousel instead of the normal poster catalog. The default on
  /// entering either tab (see [_onTabChanged]) and via the pinned
  /// "What's New" row in the groups column; cleared by picking "All", a
  /// category or Favourites.
  bool _showWhatsNew = false;

  /// Movies/TV Shows showing only favourites (the "Favourites" row in the
  /// groups column): starred titles, then every favourited group — what
  /// the old Favorites tab held. Same lifecycle as [_showWhatsNew].
  bool _showFavorites = false;

  /// The carousel's Play button, owned here (like
  /// [_groupFirstPosterFocusNodes]/[_continueWatchingFirstFocusNode]) so
  /// [_enterBrowseColumn] can hand D-pad focus straight to it. Deliberately
  /// not `autofocus` inside the carousel itself: that fires as soon as the
  /// widget is built — i.e. the instant the tab is switched, while focus is
  /// still meant to be on the tabs rail — and would drag the cursor into
  /// the content column unasked.
  ///
  /// One node per content type, not shared — Movies' and TV Shows'
  /// carousels are two separate `_WhatsNewCarousel` widget instances (only
  /// one ever actually mounted at a time, but still two distinct Elements
  /// over the app's lifetime), and a single `FocusNode` is only ever meant
  /// to be attached to one `Focus`/`InkWell` Element at a time. Release
  /// builds strip the assertion that would catch a bad attach/detach
  /// ordering here, so this was a real, silent crash risk, not just a
  /// style nit.
  final FocusNode _moviesWhatsNewPlayFocusNode =
      FocusNode(debugLabel: 'whats-new-play-movies');
  final FocusNode _showsWhatsNewPlayFocusNode =
      FocusNode(debugLabel: 'whats-new-play-shows');

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
  Future<void> _showGroupOptions(String playlistId, String title,
      {String? category}) async {
    final playlist = context.read<PlaylistManager>();
    final isFavorited = playlist.isGroupFavorited(playlistId, title);
    final isPending = _pendingHideGroups.contains(_groupKey(playlistId, title));

    final choice = await showGuardedDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        children: [
          if (category != null)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('expand'),
              child: Text(tr('Expand catalog')),
            ),
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
          _movingGroupType = category ?? 'tv';
        });
      case 'move_top':
        await _moveGroupToTop(playlistId, title, category ?? 'tv');
      case 'expand':
        // Restore the groups column explicitly after the dialog-to-catalogue navigation
        // sequence.
        Navigator.of(context)
            .push(MaterialPageRoute(
                builder: (_) => GroupCatalogScreen(
                    category: category!, playlistId: playlistId, title: title)))
            .then((_) {
          if (!mounted) return;
          setState(() => _focusDepth = 1);
          _col1Scope.requestFocus();
        });
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
    final groups = type == 'tv'
        ? playlist.tvGroups.where((g) => !g.isHidden)
        : _browseRailGroups(playlist);
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
        // Un-hiding (not hiding) is exactly the direct, non-Settings
        // bypass this gate exists for — a restricted viewer could
        // otherwise un-hide a channel from this long-press menu without
        // ever touching Settings or the PIN pad at all. Hiding a channel
        // only makes things stricter, so it stays ungated either way.
        if (isHidden) {
          final unlocked =
              await context.read<ViewerProfileService>().requireUnlock(context);
          if (!unlocked || !mounted) return;
        }
        _toggleHiddenWithFeedback(context, channel);
    }
  }

  GlobalKey _keyForGroup(String playlistId, String title) => _groupRowKeys
      .putIfAbsent(_groupKey(playlistId, title), () => GlobalKey());

  /// A plain [FocusNode] for the *first* poster of each category row —
  /// separate from the scroll position entirely. Scrolling a row into
  /// view (see [_scrollToBrowseGroup]) doesn't by itself move the D-pad
  /// cursor, so pressing Right afterward was restoring whatever card was
  /// previously focused in the browse column (from an earlier visit,
  /// possibly a totally different row), which then dragged the scroll
  /// right back to wherever *that* was.
  ///
  /// A first attempt fixed that by wrapping each row in its own
  /// `FocusScope` and requesting focus on that — which "worked" for the
  /// jump, but broke Up/Down between rows *everywhere*, not just after a
  /// jump: nesting a `FocusScope` per row turns each into its own
  /// traversal boundary, and default directional focus doesn't cross
  /// those to reach a sibling row. A plain `FocusNode.requestFocus()`
  /// moves the cursor without introducing any new boundary, so normal
  /// navigation elsewhere is unaffected.
  final Map<String, FocusNode> _groupFirstPosterFocusNodes = {};

  FocusNode _firstPosterFocusNodeForGroup(String playlistId, String title) =>
      _groupFirstPosterFocusNodes.putIfAbsent(_groupKey(playlistId, title),
          () => FocusNode(debugLabel: 'row-$title-first'));

  /// First card of the Continue Watching row, when present — that row has
  /// no group title to key off of, so it needs its own dedicated node
  /// (see [_enterBrowseColumn]).
  final FocusNode _continueWatchingFirstFocusNode =
      FocusNode(debugLabel: 'continue-watching-first');

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

  /// Keeps a whole row's header visible when D-pad focus lands on one of
  /// its cards, not just the card itself — Flutter's own default
  /// "scroll the focused widget into view" only guarantees the *card* is
  /// visible, which for a tall row can leave its header (e.g. "Continue
  /// Watching") scrolled just above the fold. Runs after the frame so it
  /// applies on top of / overrides that default scroll instead of racing it.
  void _ensureRowVisible(GlobalKey rowKey) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = rowKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0);
      }
    });
  }

  /// Group-list rows were reading noticeably larger than they needed to
  /// at 10-foot viewing distance — this is a logical/DP size, so it comes
  /// out the same physical size on a 1080p or a 4K panel of the same
  /// screen dimensions; the fix is just a smaller number, not a
  /// per-resolution one.
  static const double _groupFontSize = 13;

  static bool _isBrowseTab(String tab) => tab == 'Movies' || tab == 'TV Shows';

  /// Android phones/tablets: a browse poster's first tap previews it in
  /// the hero, a second tap opens it (PosterCard.tapToPreview).
  bool get _touchPreview =>
      Platform.isAndroid && !context.read<AppPreferences>().isTelevision;

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
    _descriptionDwellTimer?.cancel();
    setState(() {
      _resetTimelineSearch(close: true);
      _tab = tab;
      _selectedGroup = null;
      _focusedTitle = null;
      _focusedImageUrl = null;
      _focusedBackdropUrl = null;
      _focusedId = null;
      _focusedDescription = null;
      _focusDepth = 0;
      _phonePage = _compact ? 1 : 0;
      // Movies/TV Shows open on What's New. "All" or a category switches to the posters.
      _showWhatsNew = _isBrowseTab(tab);
      _showFavorites = false;
    });
    // The previous tab's slide must not flash behind the new carousel.
    _whatsNewArt.value = null;
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
    if (tab == 'Movies' || tab == 'TV Shows') _parkLiveChannel();
  }

  /// Browsing Movies/TV Shows stops a live channel playing in the background
  /// (no hidden audio, frees the decoder + provider connection) but keeps it
  /// resumable: it becomes the pending-resume channel, so the "Hold > to
  /// resume" pill and hold-Right still bring it back (a fresh start, same as
  /// the cold-launch resume). Android only — Windows has its own stack.
  Future<void> _parkLiveChannel() async {
    final playback = context.read<PlaybackService>();
    final channel = playback.currentChannel;
    if (channel == null ||
        playback.isFullscreenActive ||
        !Channel.isLiveId(channel.rawId)) {
      return;
    }
    await playback.stop();
    // stop() clears the pending channel, so set it after.
    playback.setPendingResumeChannel(channel);
  }

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
    setState(() {
      _resetTimelineSearch(close: true);
      _selectedGroup = group;
      _selectedLiveCollection = collection;
      if (_compact) _phonePage = 2;
      // Otherwise the Timeline Guide's header keeps describing a program
      // from whichever group was focused before this switch, until the
      // D-pad happens to land on something in the new one.
      _guideFocus.value = (null, null);
    });
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
    if (_tab == 'TV') {
      _resetLiveListFocus();
      _collapseAfterTouchPick();
      return;
    }
    context
        .read<PlaylistManager>()
        .ensureCategoryLoaded(playlistId!, group, _categoryForTab(_tab));
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

  bool _hasContinueWatchingRow(String idPrefix) {
    final playback = context.read<PlaybackService>();
    final storage = context.read<StorageService>();
    return playback.recentlyPlayed.any((c) =>
        c.rawId.startsWith(idPrefix) && storage.getLastPosition(c.id) > 0);
  }

  /// Movies/TV Shows groups column: a fast way to find a category, not a
  /// filter — scrolls that category's row into view in the existing
  /// catalog instead of hiding everything else, since the browse view
  /// already organizes everything by category via its row headers.
  Future<void> _scrollToBrowseGroup(String playlistId, String title) async {
    final playlist = context.read<PlaylistManager>();
    playlist.ensureCategoryLoaded(playlistId, title, _categoryForTab(_tab));
    if (!_browseScrollController.hasClients) return;

    // Resolve against rendered row identities, including playlistId, to avoid offset drift
    // and duplicate category-name collisions.
    final index = _browseRowKeys.indexWhere(
        (k) => k != null && k.playlistId == playlistId && k.title == title);
    if (index < 0) return;

    // Jump directly to distant catalogue rows; animating across them would build every
    // intervening row within a fixed frame budget.
    _browseScrollController.jumpTo(index * _categoryRowHeight);
    // Scrolling the row into view doesn't move the D-pad cursor by
    // itself — without this, pressing Right afterward restored whichever
    // card was focused from an earlier visit (possibly a different row
    // entirely), which then dragged the scroll right back to wherever
    // that was.
    if (mounted) {
      _firstPosterFocusNodeForGroup(playlistId, title).requestFocus();
    }
    // _categoryRowHeight is an exact value now, not a guess (every row is
    // pinned to it — see that getter's own doc comment for the drift bug
    // this replaced), so the jumpTo above should already land precisely.
    // This is just a cheap belt-and-suspenders correction against the
    // row's own real on-screen position, same as `_restoreLiveFocus` does
    // for the live channel list — effectively a no-op once it's already
    // exactly right, but costs nothing to keep.
    _ensureRowVisible(_keyForGroup(playlistId, title));
  }

  /// Right-arrow from the groups rail (browse tabs) when the user hasn't
  /// picked a specific group — [_col2Scope.requestFocus] alone restores
  /// whatever poster was focused on an earlier visit (possibly a
  /// different row's 3rd or 4th card), which read as the selector
  /// randomly landing "a few clicks to the right" of the first title.
  /// Picking a specific group already sets focus itself via
  /// [_scrollToBrowseGroup], so this only needs to cover the plain "just
  /// move right" case.
  void _enterBrowseColumn() {
    // The carousel replaces the poster rows entirely while it's up, so
    // none of the per-group first-poster nodes below exist to focus — its
    // Play button is the deliberate landing spot instead (see
    // [_moviesWhatsNewPlayFocusNode]/[_showsWhatsNewPlayFocusNode]).
    // Falls back to the column's own scope if the carousel is still
    // loading/empty and has no Play button mounted.
    if (_showWhatsNew) {
      final playNode = _tab == 'Movies'
          ? _moviesWhatsNewPlayFocusNode
          : _showsWhatsNewPlayFocusNode;
      if (playNode.context != null) {
        playNode.requestFocus();
      } else {
        _col2Scope.requestFocus();
      }
      return;
    }
    final playlist = context.read<PlaylistManager>();
    final isMovies = _tab == 'Movies';
    final groups = isMovies
        ? playlist.vodGroups.where((g) => !g.isHidden && g.channels.isNotEmpty)
        : playlist.seriesGroups.where((g) =>
            !g.isHidden &&
            playlist
                .visibleSeries(playlistId: g.playlistId, categoryName: g.title)
                .isNotEmpty);
    final firstRow = _browseRowKeys.firstOrNull;
    final targetNode = !_showFavorites &&
            _hasContinueWatchingRow(isMovies ? 'xt_vod_' : 'xt_ep_')
        ? _continueWatchingFirstFocusNode
        // Favourites view: whatever row it starts with.
        : _showFavorites
            ? (firstRow == null
                ? null
                : _firstPosterFocusNodeForGroup(
                    firstRow.playlistId, firstRow.title))
            : groups.isNotEmpty
                ? _firstPosterFocusNodeForGroup(
                    groups.first.playlistId, groups.first.title)
                : null;
    if (targetNode == null) {
      _col2Scope.requestFocus();
      return;
    }
    // The target row's PosterCard (and its focusNode) only exists once
    // `ListView.builder` has actually built it — if a previous group jump
    // left the scroll position far from the top, the first row isn't
    // built yet and requestFocus on it would silently do nothing. Scroll
    // to top first in that case, same as _scrollToBrowseGroup.
    // jumpTo, not animateTo — same fix/reasoning as _scrollToBrowseGroup
    // just above; the distance back to 0 can be just as large.
    if (_browseScrollController.hasClients &&
        _browseScrollController.offset > 0) {
      _browseScrollController.jumpTo(0);
    }
    targetNode.requestFocus();
  }

  void _scrollBrowseToTop() {
    if (_browseScrollController.hasClients) {
      _browseScrollController.jumpTo(0);
    }
  }

  /// Leaves the "What's New" carousel (if it's showing) and then runs the
  /// normal catalog jump. Deferred a frame in that case: the poster list
  /// isn't mounted while the carousel is up, so
  /// [_browseScrollController] has no clients yet and both
  /// [_scrollBrowseToTop] and [_scrollToBrowseGroup] would silently
  /// no-op — and the list, once it does remount, restores its previous
  /// offset from `PageStorage` rather than starting at the top.
  void _leaveWhatsNewThen(VoidCallback jump) {
    // Portrait phone: show the catalog page first, then jump within it.
    if (_compact && _phonePage != 2) {
      setState(() => _phonePage = 2);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _leaveWhatsNewThen(jump);
      });
      return;
    }
    if (!_showWhatsNew && !_showFavorites) {
      jump();
      return;
    }
    setState(() {
      _showWhatsNew = false;
      _showFavorites = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) jump();
    });
  }

  String _categoryForTab(String tab) => switch (tab) {
        'Movies' => 'vod',
        'TV Shows' => 'series',
        _ => 'tv',
      };

  /// Title/backdrop image commit immediately on every focus change, same
  /// as before — [fetchDescription] is the only part that waits, and
  /// only when [id] isn't already cached from an earlier fetch this
  /// session (either from here or from opening the detail screen
  /// directly — see `PlaylistManager`'s description cache). Debounced
  /// (not fetched on every single focus change) so scrolling quickly
  /// through a row of posters doesn't fire a network request per poster
  /// passed over — same cancel-and-restart `Timer` idiom already used in
  /// `search_screen.dart` for exactly this "wait for things to settle"
  /// reason.
  void _updateBrowseFocus({
    required PlaylistManager playlist,
    required String id,
    required String title,
    String? imageUrl,
    String? backdropUrl,
    String? Function()? backdropOf,
    required Future<String?> Function() fetchDescription,
  }) {
    if (_focusedId == id) return;
    _descriptionDwellTimer?.cancel();
    final cached = playlist.hasCachedDescription(id);
    setState(() {
      _focusedId = id;
      _focusedTitle = title;
      _focusedImageUrl = imageUrl;
      _focusedBackdropUrl = backdropUrl;
      _focusedArtPending =
          backdropOf != null && (backdropUrl == null || backdropUrl.isEmpty);
      _focusedDescription = cached ? playlist.peekCachedDescription(id) : null;
    });
    // The plot request (get_vod_info / get_series_info) also brings the
    // provider's fanart — [backdropOf] re-reads it once that's in, so the
    // hero upgrades from the poster to the landscape backdrop (TMDB's
    // first, else the provider's). HdSwapImage keeps the poster painted
    // until the backdrop has loaded, so the swap has no blank frame.
    void refreshBackdrop() {
      final b = backdropOf?.call();
      if (!mounted || _focusedId != id) return;
      setState(() {
        if (b != null && b.isNotEmpty) _focusedBackdropUrl = b;
        _focusedArtPending = false;
      });
    }

    if (cached) {
      // Cache hit = no request; this only stamps an earlier fetch's art
      // onto this (possibly different) object for the same title.
      if (backdropOf != null) {
        unawaited(
            fetchDescription().then((_) => refreshBackdrop(), onError: (_) {
          if (mounted && _focusedId == id) {
            setState(() => _focusedArtPending = false);
          }
        }));
      }
      return;
    }
    _descriptionDwellTimer = Timer(_kDescriptionDwell, () async {
      String? description;
      try {
        description = await fetchDescription();
      } catch (_) {
        // Leave it blank rather than cache a transient failure — a retry
        // is still possible next time this title is focused.
        if (mounted && _focusedId == id) {
          setState(() => _focusedArtPending = false);
        }
        return;
      }
      if (!mounted || _focusedId != id) return;
      playlist.cacheDescription(id, description);
      setState(() => _focusedDescription = description);
      refreshBackdrop();
    });
  }

  void _onColumnFocus(int depth) {
    if (_focusDepth != depth) setState(() => _focusDepth = depth);
  }

  /// Records which browse row currently has focus — see
  /// [_browseRowKeys]'s doc comment. Deliberately not wrapped in
  /// `setState`: nothing on screen depends on this value directly, it's
  /// only read later by [_moveBrowseRowFocus].
  void _setFocusedBrowseRow(int index) => _focusedBrowseRowIndex = index;

  /// Explicit Up/Down between browse rows — see [_browseRowKeys]'s doc
  /// comment for why this exists instead of leaving it to default
  /// traversal. Always lands on the target row's first poster, same
  /// convention already established by the groups-column quick-jump
  /// ([_scrollToBrowseGroup]/[_enterBrowseColumn]) rather than trying to
  /// preserve column position — scrolling the target into view is handled
  /// by the existing `onFocusGained` → `_ensureRowVisible` path once that
  /// node actually takes focus, same as it already does for every other
  /// way of landing on a row.
  void _moveBrowseRowFocus(int delta) {
    final current = _focusedBrowseRowIndex ?? 0;
    final target = current + delta;
    if (target < 0 || target >= _browseRowKeys.length) return;
    final key = _browseRowKeys[target];
    if (key == null) {
      _continueWatchingFirstFocusNode.requestFocus();
    } else {
      _firstPosterFocusNodeForGroup(key.playlistId, key.title).requestFocus();
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
      if (ModalRoute.of(context)?.isCurrent == false) {
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
    unawaited(_checkForUpdateOnLaunch());
  }

  /// Once per app launch (a layout switch rebuilds this screen).
  static bool _updateChecked = false;

  /// Found at launch, waiting for this screen to be on top (the startup
  /// auto-resume may have the player over it) — see [didPopNext].
  UpdateInfo? _pendingUpdate;

  /// Launch update check: quietly does nothing when offline, rate-limited
  /// or up to date, or when the user skipped this exact version.
  Future<void> _checkForUpdateOnLaunch() async {
    if (!AppConstants.updatesEnabled || _updateChecked) return;
    _updateChecked = true;
    // Let the first screen settle (and any auto-resume start) first.
    await Future<void>.delayed(const Duration(seconds: 4));
    UpdateInfo? update;
    try {
      update = await AppUpdateService().checkForUpdate();
    } catch (_) {
      return;
    }
    if (update == null || !mounted) return;
    if (context.read<StorageService>().getSkippedUpdateVersion() ==
        update.version) {
      return;
    }
    _pendingUpdate = update;
    _maybeShowUpdatePrompt();
  }

  Future<void> _maybeShowUpdatePrompt() async {
    final update = _pendingUpdate;
    if (update == null || !mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _pendingUpdate = null;
    final choice = await UpdatePromptDialog.show(context, update);
    if (!mounted) return;
    switch (choice) {
      case UpdatePromptChoice.update:
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => CheckUpdatesScreen(startWith: update)));
      case UpdatePromptChoice.skip:
        await context
            .read<StorageService>()
            .setSkippedUpdateVersion(update.version);
      case UpdatePromptChoice.later:
      case null:
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _releasePreviewHint?.call();
    _guideFocus.dispose();
    _guideSearchDebounce?.cancel();
    _guideSearchRefresh?.cancel();
    _tvTabFocusNode.dispose();
    _leftEdgeArmTimer?.cancel();
    _descriptionDwellTimer?.cancel();
    _leftEdgeHintOverlay?.remove();
    _browseScrollController.dispose();
    _liveListController.dispose();
    _currentChannelFocusNode.dispose();
    _firstLiveChannelFocusNode.dispose();
    _col0Scope.dispose();
    _col1Scope.dispose();
    _col2Scope.dispose();
    for (final node in _groupFirstPosterFocusNodes.values) {
      node.dispose();
    }
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
    _continueWatchingFirstFocusNode.dispose();
    _whatsNewArt.dispose();
    _moviesWhatsNewPlayFocusNode.dispose();
    _showsWhatsNewPlayFocusNode.dispose();
    for (final timer in _pendingHideTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  /// Restore guide position and focus when a route above this screen is popped.
  @override
  void didPopNext() {
    _previewCovered = false;
    _syncPreviewHint(_previewHintWanted);
    if (_pendingUpdate != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeShowUpdatePrompt();
      });
    }
    final isBrowseTab = _isBrowseTab(_tab);
    // Back from Settings with Movies/TV Shows just hidden while one of them
    // was the open tab: fall back to TV. Here rather than in build so the
    // tab switch's focus restore doesn't run under the Settings screen.
    if (isBrowseTab && context.read<AppPreferences>().isTabHidden(_tab)) {
      _onTabChanged('TV');
      return;
    }
    if (!isBrowseTab) {
      // Only restore the playing channel's group when leaving fullscreen. The player flag
      // remains set until deferred disposal; closing Search or Settings must preserve the
      // browsed group.
      if (context.read<PlaybackService>().isFullscreenActive) {
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
    // Restore the last opened browse row through a bounded direct jump. Avoid an expensive
    // implicit focus search across a large catalogue or an unnecessary return to the tabs
    // rail.
    final openedFrom = _lastOpenedBrowseGroup;
    _lastOpenedBrowseGroup = null;
    if (openedFrom != null) {
      _scrollToBrowseGroup(openedFrom.playlistId, openedFrom.title);
    } else {
      _col0Scope.requestFocus();
    }
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
      _liveCategoryCache = playlist.tvGroups
          .where((g) =>
              !g.isHidden &&
              (playlist.profiles.any((p) =>
                      p.id == g.playlistId && p.categoryLayout == 'provider') ||
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
    if (results.isEmpty || ModalRoute.of(context)?.isCurrent == false) {
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
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
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
                layout: playlist.profiles
                        .where((p) => p.id == playing.playlistId)
                        .firstOrNull
                        ?.categoryLayout ??
                    'auto');
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
    if (mounted) _currentChannelFocusNode.requestFocus();
  }

  Future<void> _selectChannel(Channel channel) async {
    if (ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    // Windows has no PlaybackService-compatible player at all (see
    // DesktopPlayerScreen's own doc comment) — a completely separate,
    // standalone screen/player instance, bypassing PlaybackService (and
    // therefore Continue Watching/resume/backup-server retry) entirely
    // rather than routing through the shared mobile player architecture.
    if (Platform.isWindows) {
      // Dispose the minimized desktop session before starting an unrelated channel to prevent
      // duplicate decoding and audio.
      DesktopMiniPlayer.instance.clear();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DesktopPlayerScreen(channel: channel)));
      return;
    }
    // One guarded player entry owns connection setup, including repeated taps.
    await PlayerScreen.open(Navigator.of(context), channel);
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
    if (ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    if (Platform.isWindows) {
      final mini = DesktopMiniPlayer.instance;
      if (mini.channel.value?.id == channel.id) {
        final session = mini.take();
        if (session == null) return;
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DesktopPlayerScreen(
                  channel: channel,
                  existingPlayer: session.$1,
                  existingController: session.$2,
                )));
        return;
      }
      mini.play(channel);
      // DesktopPlayerScreen records these itself; a preview that never goes
      // fullscreen must too, or Windows' startup auto-resume and the History
      // group never see it.
      context.read<StorageService>().setLastChannelId(channel.id);
      context.read<PlaybackService>().recordWatched(channel);
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
          ModalRoute.of(context)?.isCurrent == false) {
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

  /// The catalog row a movie/series was just opened from — see
  /// [didPopNext]'s own doc comment for why. Set right before the push,
  /// consumed (and cleared) by the very next [didPopNext]; a `null` here
  /// (Continue Watching, or anywhere else with no real category row to go
  /// back to) just keeps the old "land on the tabs rail" fallback.
  ({String playlistId, String title})? _lastOpenedBrowseGroup;

  void _openMovie(Channel channel,
      {String? groupPlaylistId, String? groupTitle}) {
    _lastOpenedBrowseGroup = (groupPlaylistId != null && groupTitle != null)
        ? (playlistId: groupPlaylistId, title: groupTitle)
        : null;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MovieDetailScreen(channel: channel)));
  }

  void _openSeries(XtreamSeries series,
      {String? groupPlaylistId, String? groupTitle}) {
    _lastOpenedBrowseGroup = (groupPlaylistId != null && groupTitle != null)
        ? (playlistId: groupPlaylistId, title: groupTitle)
        : null;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SeriesDetailScreen(series: series)));
  }

  bool _settingsOpen = false;
  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    try {
      final unlocked =
          await context.read<ViewerProfileService>().requireUnlock(context);
      if (!unlocked || !mounted) return;
      final route = SettingsRoute<SettingsAction>(
          builder: (_) => const SettingsMenuScreen(includeTools: true));
      final action = await Navigator.of(context).push(route);
      await route.completed;
      if (!mounted) return;
      switch (action) {
        case SettingsAction.live:
          if (_tab != 'TV') _onTabChanged('TV');
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
        case SettingsAction.media:
          _openMediaHub();
        case SettingsAction.disableAndExit:
          await _confirmHardExit();
        case SettingsAction.minimize:
          _minimizeWindow();
        case SettingsAction.window:
          DesktopWindow.setWindowed(!DesktopWindow.windowed.value);
        case SettingsAction.close:
          _closeApp();
        case null:
          break;
      }
    } finally {
      _settingsOpen = false;
    }
  }

  bool _openingMultiview = false;
  Future<void> _openMultiview() async {
    if (_openingMultiview || ModalRoute.of(context)?.isCurrent == false) return;
    _openingMultiview = true;
    try {
      if (Platform.isWindows) {
        DesktopMiniPlayer.instance.clear();
      } else {
        await context.read<PlaybackService>().stop();
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final route = MaterialPageRoute<void>(
          builder: (_) => Platform.isWindows
              ? const DesktopMultiviewScreen()
              : const MultiviewScreen());
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _openingMultiview = false;
    }
  }

  void _openMediaHub() {
    _parkLiveChannel();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ArchiveScreen()));
  }

  /// Sports reuses the active player in its own bounded preview. Navigating
  /// between the two guides must not stop or reconnect the stream.
  bool _sportsOpen = false;
  bool _libraryOpen = false;
  Future<void> _openLibrary({bool series = false}) async {
    if (_libraryOpen) return;
    _libraryOpen = true;
    await _parkLiveChannel();
    if (!mounted) return;
    final route = TopLevelTabRoute<String>(
        builder: (_) => LibraryScreen(initialSeries: series));
    final destination = await Navigator.of(context).push(route);
    await route.completed;
    _libraryOpen = false;
    if (!mounted) return;
    if (destination == 'live') {
      if (_tab != 'TV') _onTabChanged('TV');
      if (_focusDepth != 0) setState(() => _focusDepth = 0);
      _tvTabFocusNode.requestFocus();
    } else if (destination == 'sports') {
      unawaited(_openSports());
    } else if (destination == 'settings') {
      unawaited(_openSettings());
    }
  }

  Future<void> _openSports() async {
    if (_sportsOpen) return;
    setState(() => _sportsOpen = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final route =
        TopLevelTabRoute<String>(builder: (_) => const SportsScreen());
    final destination = await Navigator.of(context).push(route);
    // Native views must not compete for the same ExoPlayer surface during pop.
    await route.completed;
    if (!mounted) return;
    setState(() => _sportsOpen = false);
    if (destination == null) return;
    if (destination == 'settings') {
      unawaited(_openSettings());
    } else if (destination == 'movies' || destination == 'series') {
      unawaited(_openLibrary(series: destination == 'series'));
    } else if (_tab != 'TV') {
      _onTabChanged('TV');
    } else {
      setState(() {
        if (_phonePage == 0) _phonePage = 1;
      });
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

    if (playlist.profiles.any((p) => p.enabled && p.isXtream)) {
      // Shared with Settings > Clear Cache — see its doc comment for why
      // this needed to become a reusable helper rather than living here.
      final didSync = await confirmAndRunFullCatalogSync(context, playlist);
      if (didSync && mounted) _showUpdateToast();
    }

    final m3uProfiles =
        playlist.profiles.where((p) => p.enabled && !p.isXtream).toList();
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
    // A restricted viewer gets a plain close, no confirmation and no
    // playlist-disabling — the "free up this login" framing below doesn't
    // apply to them, and disabling every playlist here would combine badly
    // with Settings being PIN-gated: the next person to open the app would
    // find every playlist disabled with no ungated way back in. Only the
    // *active* viewer's restricted status matters here, not whether any
    // restricted profile exists at all — Main (or any other unrestricted
    // profile) exiting the app behaves exactly as it always has.
    if (context.read<ViewerProfileService>().isActiveRestricted) {
      _closeApp();
      return;
    }
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
    if (Platform.isWindows) {
      windowManager.close();
    } else {
      SystemNavigator.pop();
    }
  }

  /// Leave fullscreen before minimizing. The root window-restore listener re-enters
  /// fullscreen when appropriate.
  Future<void> _minimizeWindow() async {
    await windowManager.setFullScreen(false);
    await windowManager.minimize();
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

    final isBrowseTab = _isBrowseTab(_tab);
    // Only meaningful on the Live TV/Favorites side (the browse tabs have
    // their own poster grid and no concept of this setting) — see
    // _buildLiveRegion for where it actually swaps the content, and the
    // Left/Right binding override just below for why the depth-2 column's
    // own key handling needs to know about it too.
    final showTimelineGuide = !isBrowseTab && prefs.guideViewMode == 'timeline';
    final playbackState = context.watch<PlaybackService>();
    final playing = playbackState.currentChannel;
    final liveChannel =
        playing != null && Channel.isLiveId(playing.rawId) ? playing : null;
    // Only the phone layout has that preview (it sets its own state).
    if (!_compact) _syncPreviewHint(false);
    _fullVideo = _tab == 'TV' &&
        showTimelineGuide &&
        prefs.guideFullVideo &&
        !_compact &&
        // Also with nothing playing: the layout stays put
        // over a dark background instead of jumping when a channel starts.
        !Platform.isWindows;
    _fullArt = isBrowseTab && _showWhatsNew && !_compact;

    return TvPreviewRemoteNavigation(
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
                  if (_fullArt)
                    Positioned.fill(
                      child: ValueListenableBuilder<_WhatsNewArt?>(
                        valueListenable: _whatsNewArt,
                        builder: (context, art, _) =>
                            _WhatsNewBackdrop(art: art),
                      ),
                    ),
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
                              : CallbackShortcuts(
                                  // The 4-column Live TV/Favorites layout gets full
                                  // explicit column-switching. The Movies/TV Shows
                                  // browse view only has two columns (tabs, browse),
                                  // and needs Left/Right free inside the browse
                                  // column for poster-to-poster movement — but it
                                  // still needs an explicit Right from the tabs rail
                                  // to *enter* that column in the first place,
                                  // since default traversal couldn't reliably jump
                                  // there either (same class of bug as the groups
                                  // column getting "stuck").
                                  // Movies/TV Shows are 3 columns now (tabs, groups
                                  // shortcut rail, browse) instead of the 4-column
                                  // Live TV/Favorites layout (tabs, groups, list,
                                  // preview) — but the same per-depth pattern:
                                  // Left/Right always switch columns except inside
                                  // the poster grid itself, where Left/Right move
                                  // card-to-card (see _handleBrowseLeft for the
                                  // "nowhere further left" escape).
                                  bindings: isBrowseTab
                                      ? switch (_focusDepth) {
                                          0 =>
                                            <ShortcutActivator, VoidCallback>{
                                              const SingleActivator(
                                                  LogicalKeyboardKey
                                                      .arrowRight): () =>
                                                  _moveColumnFocus(1, 2),
                                            },
                                          1 =>
                                            <ShortcutActivator, VoidCallback>{
                                              const SingleActivator(
                                                  LogicalKeyboardKey
                                                      .arrowLeft): () =>
                                                  _moveColumnFocus(-1, 2),
                                              const SingleActivator(
                                                      LogicalKeyboardKey
                                                          .arrowRight):
                                                  _enterBrowseColumn,
                                            },
                                          _ =>
                                            <ShortcutActivator, VoidCallback>{
                                              const SingleActivator(
                                                      LogicalKeyboardKey
                                                          .arrowLeft):
                                                  _handleBrowseLeft,
                                              // See _browseRowKeys'/
                                              // _moveBrowseRowFocus's doc
                                              // comments — explicit row-to-row
                                              // jump instead of default
                                              // traversal's expensive search
                                              // across every cached row's
                                              // posters.
                                              const SingleActivator(
                                                  LogicalKeyboardKey
                                                      .arrowDown): () =>
                                                  _moveBrowseRowFocus(1),
                                              const SingleActivator(
                                                  LogicalKeyboardKey
                                                      .arrowUp): () =>
                                                  _moveBrowseRowFocus(-1),
                                            },
                                        }
                                      : <ShortcutActivator, VoidCallback>{
                                          // 3 columns now (tabs, groups, the merged
                                          // live-list-over-video region) — the list
                                          // panel is a plain vertical list like the
                                          // groups column, so Left/Right always
                                          // switching columns (never intra-row) is
                                          // safe here, same as before the merge.
                                          //
                                          // The timeline guide is the one exception: at depth 2 while
                                          // it's showing, Left and Right step the view one 30-minute
                                          // slot (see _TimelineGuideState.moveHorizontal) rather than
                                          // moving column. Left falls back to the "press again to leave
                                          // for the groups" escape (_handleBrowseLeft) only at the edge
                                          // of the guide's window; the Back button is the quick way out.
                                          const SingleActivator(
                                                  LogicalKeyboardKey.arrowLeft):
                                              (_focusDepth == 2 &&
                                                      showTimelineGuide)
                                                  ? _handleTimelineLeft
                                                  : () =>
                                                      _moveColumnFocus(-1, 2),
                                          // Already in the last column: Right has
                                          // nowhere further to go, so it becomes a
                                          // shortcut straight to fullscreen on
                                          // whatever's currently playing instead of
                                          // a dead end — otherwise finding your way
                                          // back to fullscreen meant re-selecting
                                          // the same channel from the list again.
                                          // In the timeline guide, Right steps
                                          // the view one 30-minute slot instead
                                          // (see moveHorizontal).
                                          const SingleActivator(
                                              LogicalKeyboardKey
                                                  .arrowRight): (_focusDepth ==
                                                      2 &&
                                                  showTimelineGuide)
                                              ? () => _timelineGuideKey
                                                  .currentState
                                                  ?.moveHorizontal(1)
                                              : _focusDepth == 2
                                                  ? _goFullscreenIfPlaying
                                                  : () =>
                                                      _moveColumnFocus(1, 2),
                                          // Move vertically by the selected time column, not
                                          // the geometric overlap of programme blocks with
                                          // different lengths.
                                          if (_focusDepth == 2 &&
                                              showTimelineGuide) ...{
                                            const SingleActivator(
                                                LogicalKeyboardKey.info,
                                                includeRepeats:
                                                    false): () =>
                                                showPlayerStreamInfo(context),
                                            const SingleActivator(
                                                LogicalKeyboardKey
                                                    .contextMenu): () =>
                                                _timelineFilterButtonFocusNode
                                                    .requestFocus(),
                                            // Down from the filter button or
                                            // field (two separate nodes — see
                                            // _timelineFilterButtonFocusNode's
                                            // doc comment for why) enters the
                                            // guide via focusEntry() instead of
                                            // moveVertical(1), which operates on
                                            // a row index that's meaningless
                                            // until the guide's actually been
                                            // entered once.
                                            const SingleActivator(
                                                LogicalKeyboardKey
                                                    .arrowDown): () =>
                                                (_timelineFilterButtonFocusNode
                                                            .hasFocus ||
                                                        _timelineFilterFieldFocusNode
                                                            .hasFocus ||
                                                        _timelineKeyboardScope
                                                            .hasFocus)
                                                    ? _timelineGuideKey
                                                        .currentState
                                                        ?.focusEntry()
                                                    : _timelineGuideKey
                                                        .currentState
                                                        ?.moveVertical(1),
                                            const SingleActivator(
                                                    LogicalKeyboardKey.arrowUp):
                                                () => _timelineGuideKey
                                                    .currentState
                                                    ?.moveVertical(-1),
                                          },
                                        },
                                  child: _compact
                                      ? _buildPhoneColumns(playlist, epg,
                                          isBrowseTab, liveChannel)
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
                                            VerticalDivider(
                                                width: prefs.isTelevision &&
                                                        _focusDepth > 0
                                                    ? 0
                                                    : 1,
                                                color: (_fullVideo ||
                                                            _fullArt ||
                                                            prefs
                                                                .isTelevision) &&
                                                        _focusDepth > 0
                                                    ? Colors.transparent
                                                    : null),
                                            _collapsible(
                                              depth: 1,
                                              expandedWidth:
                                                  _mobileGuide(context)
                                                      ? 180
                                                      : 208,
                                              child: _fullVideoScrim(
                                                  _groupsScope(
                                                      playlist, isBrowseTab,
                                                      collapsed: _focusDepth >
                                                              1 &&
                                                          !prefs.isTelevision)),
                                            ),
                                            VerticalDivider(
                                                width: prefs.isTelevision &&
                                                        _focusDepth > 1
                                                    ? 0
                                                    : 1,
                                                color: (_fullVideo ||
                                                            _fullArt ||
                                                            prefs
                                                                .isTelevision) &&
                                                        _focusDepth > 1
                                                    ? Colors.transparent
                                                    : null),
                                            Expanded(
                                                child: _contentScope(playlist,
                                                    epg, isBrowseTab)),
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
            color: (_fullVideo || _fullArt)
                ? Colors.black.withValues(alpha: alpha)
                : Colors.transparent),
        child: child,
      );

  Widget _tabsScope({required bool collapsed}) => FocusTraversalGroup(
        child: FocusScope(
          node: _col0Scope,
          onFocusChange: (has) {
            if (has) _onColumnFocus(0);
          },
          child: _buildTabsColumn(collapsed: collapsed),
        ),
      );

  Widget _groupsScope(PlaylistManager playlist, bool isBrowseTab,
          {required bool collapsed}) =>
      FocusTraversalGroup(
        child: FocusScope(
          node: _col1Scope,
          onFocusChange: (has) {
            if (has) _onColumnFocus(1);
          },
          child: isBrowseTab
              ? _buildBrowseGroupsColumn(playlist, collapsed: collapsed)
              : _buildGroupsColumn(playlist, collapsed: collapsed),
        ),
      );

  Widget _contentScope(
          PlaylistManager playlist, EpgService epg, bool isBrowseTab) =>
      FocusTraversalGroup(
        child: FocusScope(
          node: _col2Scope,
          onFocusChange: (has) {
            if (has) _onColumnFocus(2);
          },
          child: isBrowseTab
              ? _buildMainArea(playlist, epg)
              : _buildLiveRegion(playlist, epg),
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

  @override
  void didPushNext() {
    _previewCovered = true;
    _releasePreviewHint?.call();
    _releasePreviewHint = null;
  }

  /// Portrait phone: the same three columns, one page at a time (see
  /// [_compact]). An IndexedStack, not just the visible column, so the
  /// long groups list keeps its scroll position across Back.
  Widget _buildPhoneColumns(PlaylistManager playlist, EpgService epg,
      bool isBrowseTab, Channel? liveChannel) {
    final String? title = switch (_phonePage) {
      0 => null,
      1 => tr(_tab == 'TV' ? 'Live TV' : _tab),
      _ => isBrowseTab
          ? tr(_tab)
          : switch (
              _tab == 'TV' ? _effectiveLiveGroup(playlist) : _selectedGroup) {
              null => tr(_tab == 'TV' ? 'TV' : 'All'),
              _favoritesGroupSentinel => tr('Favourites'),
              _historyGroupSentinel => tr('History'),
              _allGroupSentinel => tr('All channels'),
              final group => _selectedLiveCollection?.title == group
                  ? _selectedLiveCollection!.displayName
                  : group,
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
              _groupsScope(playlist, isBrowseTab, collapsed: false),
              _contentScope(playlist, epg, isBrowseTab),
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
          } else if (_tab != 'TV') {
            _onTabChanged('TV');
          } else {
            setState(() => _phonePage = 1);
          }
        },
      );

  /// TV hides passed columns; touch layouts retain a narrow icon rail.
  Widget _collapsible({
    required int depth,
    required double expandedWidth,
    required Widget child,
  }) {
    final collapsed = _focusDepth > depth;
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
    final tapToExpand =
        collapsed && !context.read<AppPreferences>().isTelevision;
    return SizedBox(
      key: ValueKey(
          depth == 0 ? 'live-navigation-rail' : 'live-categories-rail'),
      width: collapsed ? collapsedWidth : expandedWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: tapToExpand ? () => setState(() => _focusDepth = depth) : null,
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

  /// Builds each visible group's row via [rowBuilder], inserting a
  /// [_PlaylistDividerRow] wherever two consecutive groups belong to
  /// different playlists — see that widget's doc comment. Only used by
  /// the Live TV and Movies/TV Shows groups columns (per the user's own
  /// scoping: "the same in movies and shows... in favourites it don't
  /// matter" — that column mixes all three group kinds by design already,
  /// so a playlist boundary isn't the distinction that matters there).
  /// No-ops back to a plain row list when every group belongs to the same
  /// playlist — the ordinary single-playlist case, nothing to mark.
  List<Widget> _groupRowsWithPlaylistDividers(
    List<M3uGroup> groups,
    PlaylistManager playlist, {
    required bool collapsed,
    required Widget Function(M3uGroup group) rowBuilder,
  }) {
    final distinctPlaylistIds = groups.map((g) => g.playlistId).toSet();
    final widgets = <Widget>[];
    String? lastPlaylistId;
    for (final group in groups) {
      if (distinctPlaylistIds.length > 1 &&
          lastPlaylistId != null &&
          group.playlistId != lastPlaylistId) {
        widgets.add(_PlaylistDividerRow(
          name: playlist.playlistNameFor(group.playlistId),
          collapsed: collapsed,
        ));
      }
      lastPlaylistId = group.playlistId;
      widgets.add(rowBuilder(group));
    }
    return widgets;
  }

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

    // Keyed by tab — same fix, and same reason, as
    // _buildBrowseGroupsColumn's own ListView key.
    return ListView(
      key: const ValueKey('TV'),
      padding: EdgeInsets.zero,
      children: [
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
        LiveCategoryFolders(
          groups: groups,
          layouts: {for (final p in playlist.profiles) p.id: p.categoryLayout},
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

  /// Groups rail for Movies/TV Shows — a fast way to jump to a category
  /// (see [_scrollToBrowseGroup]), brought back after removing it turned
  /// out to make finding a specific category slower, not simpler: without
  /// it, finding one meant scrolling through the whole poster catalog by
  /// hand instead of scanning a short list of names. Only lists categories
  /// that actually have a row to jump to right now — one that's still
  /// loading in the background isn't selectable here until it appears in
  /// the catalog below, at which point it shows up here too.
  List<M3uGroup> _browseRailGroups(PlaylistManager playlist) =>
      (_tab == 'Movies'
              ? playlist.vodGroups
                  .where((g) => !g.isHidden && g.channels.isNotEmpty)
              : playlist.seriesGroups.where((g) =>
                  !g.isHidden &&
                  playlist
                      .visibleSeries(
                          playlistId: g.playlistId, categoryName: g.title)
                      .isNotEmpty))
          .toList();

  Widget _buildBrowseGroupsColumn(PlaylistManager playlist,
      {required bool collapsed}) {
    final groups = _browseRailGroups(playlist);

    // Key the groups subtree by tab so element reconciliation cannot reuse another tab's row
    // FocusNodes or selection state.
    void showFavorites() {
      setState(() {
        _showFavorites = true;
        _showWhatsNew = false;
        if (_compact) _phonePage = 2;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollBrowseToTop();
      });
    }

    return ListView(
      key: ValueKey(_tab),
      children: [
        // Pinned above the real categories, same shape as the Live TV
        // column's own "Favourites" entry — not a category, a view.
        _SelectableRow(
          icon: Icons.new_releases,
          label: tr("What's New"),
          selected: _showWhatsNew,
          collapsed: collapsed,
          fontSize: _groupFontSize,
          focusNode: _firstGroupRowFocusNode,
          onTap: () => setState(() {
            if (!_showWhatsNew) _whatsNewArt.value = null;
            _showWhatsNew = true;
            _showFavorites = false;
            if (_compact) _phonePage = 2;
          }),
        ),
        // Hold Select = clear this tab's Favourites (after a confirm).
        HoldToActivate(
          onTap: showFavorites,
          onHold: _confirmClearFavorites,
          child: _SelectableRow(
            icon: Icons.star,
            label: tr('Favourites'),
            selected: _showFavorites,
            collapsed: collapsed,
            fontSize: _groupFontSize,
            onTap: showFavorites,
            onLongPress: _confirmClearFavorites,
          ),
        ),
        _SelectableRow(
          icon: Icons.apps,
          label: tr('All'),
          selected: false,
          collapsed: collapsed,
          fontSize: _groupFontSize,
          onTap: () => _leaveWhatsNewThen(_scrollBrowseToTop),
        ),
        ..._groupRowsWithPlaylistDividers(
          groups,
          playlist,
          collapsed: collapsed,
          rowBuilder: (group) => _GroupRow(
            key: ValueKey(_groupKey(group.playlistId, group.title)),
            icon: Icons.grid_view_rounded,
            label: group.title,
            selected: false,
            collapsed: collapsed,
            fontSize: _groupFontSize,
            isFavorited:
                playlist.isGroupFavorited(group.playlistId, group.title),
            isPendingHide: _pendingHideGroups
                .contains(_groupKey(group.playlistId, group.title)),
            onTap: () => _leaveWhatsNewThen(
                () => _scrollToBrowseGroup(group.playlistId, group.title)),
            onLongPress: () => _showGroupOptions(group.playlistId, group.title,
                category: _tab == 'Movies' ? 'vod' : 'series'),
            moving: _movingGroupKey == _groupKey(group.playlistId, group.title),
            onMove: (delta) =>
                _moveGroupStep(group.playlistId, group.title, delta),
            onMoveDone: _endGroupMove,
            focusOnBuild: _focusGroupKeyOnBuild ==
                _groupKey(group.playlistId, group.title),
            onFocusedOnBuild: () => _focusGroupKeyOnBuild = null,
          ),
        ),
      ],
    );
  }

  Widget _buildMainArea(PlaylistManager playlist, EpgService epg) {
    if (_tab == 'Movies') return _buildMoviesBrowse(playlist);
    return _buildShowsBrowse(playlist);
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
  Widget _buildTimelinePreviewBox(Channel? channel) => ColoredBox(
      color: Colors.black, child: _buildTimelinePreviewContent(channel));

  Widget _buildTimelinePreviewContent(Channel? channel) {
    if (_sportsOpen) return const ColoredBox(color: Colors.black);
    if (Platform.isWindows) {
      // A real video feed, unlike the first pass at this box — unlike
      // `video_player_hdr`'s platform views (see `LiveResumeHint`'s own
      // doc comment for the real multi-consumer rendering bug that caused
      // on mobile), `media_kit`'s texture-based rendering supports more
      // than one `Video` widget bound to the same controller at once, and
      // in practice only one is ever actually mounted at a time anyway —
      // this one unmounts (channel.value becomes null, via `take()`) in
      // the same frame `DesktopPlayerScreen`'s own mounts, never both at
      // once. `DesktopMiniPlayer.controller` is read-only here — this box
      // doesn't take ownership of the session, just renders it.
      return ValueListenableBuilder<Channel?>(
        valueListenable: DesktopMiniPlayer.instance.channel,
        builder: (context, minimized, _) {
          if (minimized == null) {
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
          final controller = DesktopMiniPlayer.instance.controller;
          return ExcludeFocus(
            child: InkWell(
              onTap: () {
                final session = DesktopMiniPlayer.instance.take();
                if (session == null) return;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DesktopPlayerScreen(
                          channel: minimized,
                          existingPlayer: session.$1,
                          existingController: session.$2,
                        )));
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller != null)
                    Video(controller: controller, controls: NoVideoControls)
                  else
                    const ColoredBox(color: Colors.black),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 20, 10, 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.8),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(minimized.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          Text(tr('Click to resume'),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

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
            // No mainAxisSize here — it must fill the full tight height
            // this Container passes straight through so the Expanded
            // keyboard grid below has real, bounded constraints to size
            // itself against (see the TV layout bug this already caused
            // once, now fixed, in git history for this file).
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

  void _toggleSeriesFavoriteWithFeedback(
      BuildContext context, XtreamSeries series) {
    context.read<PlaylistManager>().toggleSeriesFavorite(series);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(series.isFavorite
          ? tr('Added to Favorites')
          : tr('Removed from Favorites')),
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

  /// A "Continue Watching" row built from [PlaybackService.recentlyPlayed],
  /// filtered to items of the right content type (movies vs. episodes, via
  /// their `xt_vod_`/`xt_ep_` id prefix from [XtreamApiService]) that
  /// actually have a saved resume position. Null when there's nothing to
  /// resume, so callers can skip it entirely rather than render an empty row.
  Widget? _buildContinueWatchingRow(
      {required String idPrefix, required void Function(Channel) onTap}) {
    final playback = context.watch<PlaybackService>();
    final storage = context.read<StorageService>();
    final playlist = context.read<PlaylistManager>();
    var items = playback.recentlyPlayed
        .where((c) =>
            c.rawId.startsWith(idPrefix) && storage.getLastPosition(c.id) > 0)
        .toList();

    // Episodes: one card per *show*, not per episode. recentlyPlayed is
    // newest-first, so the first episode seen for a given series is the
    // one actually being resumed — without this, finishing episode 4 and
    // starting episode 5 of the same show showed up as two separate
    // cards, and the older one no longer even reflected where playback
    // actually was.
    final isEpisodes = idPrefix == 'xt_ep_';
    if (isEpisodes) {
      final seenSeries = <int>{};
      items = [
        for (final c in items)
          if (c.seriesId == null || seenSeries.add(c.seriesId!)) c
      ];
    }

    if (items.isEmpty) return null;
    return KeyedSubtree(
      key: _continueWatchingRowKey,
      child: _CategoryRow<Channel>(
        title: tr('Continue Watching'),
        items: items,
        itemBuilder: (c, index) {
          // A show resumes into its season/episode list (so the user can
          // actually see what's next and how far along they are), not
          // straight back into playback the way a movie does.
          final asSeries = isEpisodes && c.seriesId != null;
          final title = asSeries ? (c.seriesName ?? c.name) : c.name;
          final imageUrl =
              asSeries ? (c.seriesCoverUrl ?? c.logoUrl) : c.logoUrl;
          return PosterCard(
            title: title,
            imageUrl: imageUrl,
            rating: c.rating,
            watched: storage.isFullyWatched(c.id),
            progressFraction: storage.getWatchedFraction(c.id),
            cardWidth: _browsePosterWidth,
            cardPosterHeight: _browsePosterHeight,
            tapToPreview: _touchPreview,
            focusNode: index == 0 ? _continueWatchingFirstFocusNode : null,
            onTap: () => asSeries
                ? _openSeries(XtreamSeries(
                    seriesId: c.seriesId!,
                    playlistId: c.playlistId,
                    name: c.seriesName ?? c.name,
                    categoryId: '',
                    coverUrl: c.seriesCoverUrl,
                  ))
                : onTap(c),
            onFocusGained: () {
              // asSeries alone isn't a safe "definitely a movie" proxy —
              // an episode with no resolvable seriesId still isn't a
              // movie, and would hit the wrong API call (get_vod_info on
              // an episode's raw id) if it fell into that branch below.
              if (asSeries) {
                final series = XtreamSeries(
                  seriesId: c.seriesId!,
                  playlistId: c.playlistId,
                  name: c.seriesName ?? c.name,
                  categoryId: '',
                  coverUrl: c.seriesCoverUrl,
                );
                _updateBrowseFocus(
                  playlist: playlist,
                  id: series.id,
                  title: title,
                  imageUrl: imageUrl,
                  backdropUrl: c.backdropUrl ?? series.anyBackdropUrl,
                  backdropOf: () => series.anyBackdropUrl,
                  fetchDescription: () =>
                      playlist.getHeroSeriesDescription(series),
                );
              } else if (idPrefix == 'xt_vod_') {
                _updateBrowseFocus(
                  playlist: playlist,
                  id: c.id,
                  title: title,
                  imageUrl: imageUrl,
                  backdropUrl: c.anyBackdropUrl,
                  backdropOf: () => c.anyBackdropUrl,
                  fetchDescription: () => playlist.getHeroVodDescription(c),
                );
              } else {
                // An episode with no seriesId to resolve — nothing
                // sensible to fetch a plot for.
                _updateBrowseFocus(
                  playlist: playlist,
                  id: c.id,
                  title: title,
                  imageUrl: imageUrl,
                  backdropUrl: c.backdropUrl,
                  fetchDescription: () => Future.value(null),
                );
              }
              _ensureRowVisible(_continueWatchingRowKey);
              // Always row 0 when present — see _browseRowKeys' doc
              // comment, it's always inserted first.
              _setFocusedBrowseRow(0);
            },
          );
        },
      ),
    );
  }

  /// Pseudo-group title of the browse "Favourites" rows in
  /// [_browseRowKeys] (playlistId = the row's playlist), so they reuse the
  /// per-group row key / first-poster focus node machinery.
  static const _favoritesRowTitle = '__favorites__';

  /// The starred movies/shows, right under Continue Watching (this
  /// replaced the old Favorites tab): one row, or one row per playlist
  /// ("Favourites · name") when they come from two or more playlists —
  /// the favorite getters already group items by playlist.
  /// [firstRowIndex] = the first row's index in the browse rows.
  ({List<Widget> rows, List<({String playlistId, String title})> keys})
      _buildFavoritesBrowseRows<T>({
    required List<T> items,
    required int firstRowIndex,
    required String Function(T) playlistIdOf,
    required Widget Function(T item, _FavoriteCardExtras extras) card,
  }) {
    final chunks = <List<T>>[];
    for (final item in items) {
      if (chunks.isEmpty ||
          playlistIdOf(chunks.last.first) != playlistIdOf(item)) {
        chunks.add([item]);
      } else {
        chunks.last.add(item);
      }
    }
    final playlist = context.read<PlaylistManager>();
    final rows = <Widget>[];
    final keys = <({String playlistId, String title})>[];
    for (final (i, chunk) in chunks.indexed) {
      final playlistId = playlistIdOf(chunk.first);
      final rowKey = _keyForGroup(playlistId, _favoritesRowTitle);
      final rowIndex = firstRowIndex + i;
      final name = playlist.playlistNameFor(playlistId);
      keys.add((playlistId: playlistId, title: _favoritesRowTitle));
      rows.add(KeyedSubtree(
        key: rowKey,
        child: _CategoryRow<T>(
          title: chunks.length > 1 && name.isNotEmpty
              ? '${tr('Favourites')} · $name'
              : tr('Favourites'),
          items: chunk,
          itemBuilder: (item, index) => card(
            item,
            (
              focusNode: index == 0
                  ? _firstPosterFocusNodeForGroup(
                      playlistId, _favoritesRowTitle)
                  : null,
              onFocused: () {
                _ensureRowVisible(rowKey);
                _setFocusedBrowseRow(rowIndex);
              },
            ),
          ),
        ),
      ));
    }
    return (rows: rows, keys: keys);
  }

  Widget _buildMoviesBrowse(PlaylistManager playlist) {
    // !isHidden matters here, not just in the groups quick-jump column —
    // without it, a category filtered out via the content filter or Group
    // Management still showed up in the actual catalog, just missing from
    // the shortcut list pointing at it.
    final storage = context.read<StorageService>();
    final visibleGroups = playlist.vodGroups.where((g) => !g.isHidden).toList();
    // Kick off the first load for every visible category that isn't
    // loaded yet (fire-and-forget, concurrency-capped — see
    // ensureCategoriesLoaded's doc comment for why a plain per-category
    // loop here caused a real ANR on a brand-new provider with hundreds of
    // categories). Needed since disabling the automatic background warm-up
    // (a real ANR fix on a large catalog) otherwise left nothing to ever
    // trigger a category's *first* load on a plain relaunch: this row list
    // only shows categories that already have items, and the groups
    // quick-jump column requires the same — with nothing pre-populating
    // them, Movies/TV Shows was stuck forever on "Loading movie
    // categories...". Grouped by playlistId first — ensureCategoriesLoaded
    // now targets one specific playlist's session, so a merged list
    // spanning more than one playlist needs one call per playlist.
    for (final entry
        in _groupByPlaylist(visibleGroups.where((g) => g.channels.isEmpty))) {
      unawaited(playlist.ensureCategoriesLoaded(
          entry.playlistId, entry.groups.map((g) => g.title), 'vod'));
    }
    if (_showWhatsNew) {
      return _WhatsNewCarousel<Channel>(
        // A wider pool: the carousel shows the ones with backdrops first.
        loadItems: () => playlist.whatsNewVod(limit: 10),
        titleOf: (c) => c.name,
        imageUrlOf: (c) => c.posterUrl ?? c.logoUrl,
        backdropUrlOf: (c) => c.anyBackdropUrl,
        ratingOf: (c) => c.rating,
        yearOf: (c) => c.releaseDate?.year,
        art: _whatsNewArt,
        ownBackdrop: _compact,
        // One get_vod_info per shown slide per session (cached) — brings
        // the provider's backdrop when TMDB has none.
        prefetch: playlist.getHeroVodDescription,
        onOpen: _openMovie,
        playFocusNode: _moviesWhatsNewPlayFocusNode,
        emptyText: tr('No recently added movies yet'),
      );
    }
    // Favourites view: starred movies, then only the favourited groups.
    final groupsWithItems = visibleGroups
        .where((g) =>
            g.channels.isNotEmpty &&
            (!_showFavorites ||
                playlist.isGroupFavorited(g.playlistId, g.title)))
        .toList();
    final continueRow = _showFavorites
        ? null
        : _buildContinueWatchingRow(idPrefix: 'xt_vod_', onTap: _openMovie);
    final groupSuffix = _favoriteGroupSuffix(groupsWithItems);
    final favorites = _buildFavoritesBrowseRows<Channel>(
      items: _showFavorites ? playlist.favoriteMovies : const [],
      firstRowIndex: continueRow != null ? 1 : 0,
      playlistIdOf: (c) => c.playlistId,
      card: (c, x) => PosterCard(
        title: c.name,
        imageUrl: c.logoUrl,
        rating: c.rating,
        watched: storage.isFullyWatched(c.id),
        progressFraction: storage.getWatchedFraction(c.id),
        cardWidth: _browsePosterWidth,
        cardPosterHeight: _browsePosterHeight,
        tapToPreview: _touchPreview,
        focusNode: x.focusNode,
        isFavorite: true,
        onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
        onTap: () => _openMovie(c),
        onFocusGained: () {
          _updateBrowseFocus(
            playlist: playlist,
            id: c.id,
            title: c.name,
            imageUrl: c.logoUrl,
            backdropUrl: c.anyBackdropUrl,
            backdropOf: () => c.anyBackdropUrl,
            fetchDescription: () => playlist.getHeroVodDescription(c),
          );
          x.onFocused();
        },
      ),
    );
    final topRows = (continueRow != null ? 1 : 0) + favorites.rows.length;
    // See _browseRowKeys' doc comment — parallel to `rows` below, same
    // order (Continue Watching first when present, then Favourites, then
    // one entry per category), rebuilt fresh on every call.
    _browseRowKeys = [
      if (continueRow != null) null,
      ...favorites.keys,
      for (final group in groupsWithItems)
        (playlistId: group.playlistId, title: group.title),
    ];
    return _buildBrowseScaffold(
      rows: [
        if (continueRow != null) continueRow,
        ...favorites.rows,
        for (final (groupIndex, group) in groupsWithItems.indexed)
          KeyedSubtree(
            key: _keyForGroup(group.playlistId, group.title),
            child: _CategoryRow<Channel>(
              // The real category size (which can be well past the
              // _maxItemsPerCategory render cap that group.channels.length
              // is limited to) when known — see
              // PlaylistManager.vodCategoryTotalCount's doc comment.
              title:
                  '${group.title} (${playlist.vodCategoryTotalCount(group.playlistId, group.title) ?? group.channels.length})${groupSuffix(group)}',
              items: group.channels,
              itemBuilder: (c, index) => PosterCard(
                title: c.name,
                imageUrl: c.logoUrl,
                rating: c.rating,
                watched: storage.isFullyWatched(c.id),
                progressFraction: storage.getWatchedFraction(c.id),
                cardWidth: _browsePosterWidth,
                cardPosterHeight: _browsePosterHeight,
                tapToPreview: _touchPreview,
                focusNode: index == 0
                    ? _firstPosterFocusNodeForGroup(
                        group.playlistId, group.title)
                    : null,
                isFavorite: c.isFavorite,
                onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
                onTap: () => _openMovie(c,
                    groupPlaylistId: group.playlistId, groupTitle: group.title),
                onFocusGained: () {
                  _updateBrowseFocus(
                    playlist: playlist,
                    id: c.id,
                    title: c.name,
                    imageUrl: c.logoUrl,
                    backdropUrl: c.anyBackdropUrl,
                    backdropOf: () => c.anyBackdropUrl,
                    fetchDescription: () => playlist.getHeroVodDescription(c),
                  );
                  _ensureRowVisible(
                      _keyForGroup(group.playlistId, group.title));
                  _setFocusedBrowseRow(topRows + groupIndex);
                },
              ),
            ),
          ),
      ],
      emptyText: _showFavorites
          ? (groupsWithItems.isEmpty && favorites.rows.isEmpty
              ? tr(
                  'No favourites yet. Hold Select on a poster or a group to add one.')
              : null)
          : groupsWithItems.isEmpty
              ? tr('Loading movie categories...')
              : null,
    );
  }

  /// Favourites view only: " · playlist" after each group row's title
  /// when the favourited groups come from two or more playlists.
  String Function(M3uGroup) _favoriteGroupSuffix(List<M3uGroup> groups) {
    if (!_showFavorites || groups.map((g) => g.playlistId).toSet().length < 2) {
      return (_) => '';
    }
    final playlist = context.read<PlaylistManager>();
    return (g) {
      final name = playlist.playlistNameFor(g.playlistId);
      return name.isEmpty ? '' : ' · $name';
    };
  }

  /// Splits a merged group list back out by playlist — used wherever an
  /// operation (`ensureCategoriesLoaded`) targets one specific playlist's
  /// session and needs one call per playlist rather than one call for a
  /// list that might span several.
  Iterable<({String playlistId, List<M3uGroup> groups})> _groupByPlaylist(
      Iterable<M3uGroup> groups) {
    final byId = <String, List<M3uGroup>>{};
    for (final g in groups) {
      byId.putIfAbsent(g.playlistId, () => []).add(g);
    }
    return byId.entries.map((e) => (playlistId: e.key, groups: e.value));
  }

  Widget _buildShowsBrowse(PlaylistManager playlist) {
    final groups = playlist.seriesGroups.where((g) => !g.isHidden).toList();
    final rows = <Widget>[];
    // Episodes resume straight into playback (no detail screen in between)
    // — the user already picked this episode once, "Continue Watching"
    // means "keep watching it", not "go re-browse its season".
    final continueRow = _showFavorites
        ? null
        : _buildContinueWatchingRow(idPrefix: 'xt_ep_', onTap: _selectChannel);
    if (continueRow != null) rows.add(continueRow);
    // See _browseRowKeys' doc comment — parallel to `rows`, same order.
    // Built imperatively alongside it (not derived from `groups` by
    // index) because empty groups are skipped below via `continue`, so a
    // group's position in `groups` doesn't match its actual row index.
    final rowKeys = <({String playlistId, String title})?>[
      if (continueRow != null) null,
    ];
    final favorites = playlist.isXtream
        ? _buildFavoritesBrowseRows<XtreamSeries>(
            items: _showFavorites ? playlist.favoriteSeries : const [],
            firstRowIndex: rows.length,
            playlistIdOf: (s) => s.playlistId,
            card: (s, x) => PosterCard(
              title: s.name,
              imageUrl: s.coverUrl,
              rating: s.rating,
              cardWidth: _browsePosterWidth,
              cardPosterHeight: _browsePosterHeight,
              tapToPreview: _touchPreview,
              focusNode: x.focusNode,
              isFavorite: true,
              onToggleFavorite: () =>
                  _toggleSeriesFavoriteWithFeedback(context, s),
              onTap: () => _openSeries(s),
              onFocusGained: () {
                _updateBrowseFocus(
                  playlist: playlist,
                  id: s.id,
                  title: s.name,
                  imageUrl: s.coverUrl,
                  backdropUrl: s.anyBackdropUrl,
                  backdropOf: () => s.anyBackdropUrl,
                  fetchDescription: () => playlist.getHeroSeriesDescription(s),
                );
                x.onFocused();
              },
            ),
          )
        : _buildFavoritesBrowseRows<Channel>(
            items: _showFavorites ? playlist.favoriteShowChannels : const [],
            firstRowIndex: rows.length,
            playlistIdOf: (c) => c.playlistId,
            card: (c, x) => PosterCard(
              title: c.name,
              imageUrl: c.logoUrl,
              cardWidth: _browsePosterWidth,
              cardPosterHeight: _browsePosterHeight,
              tapToPreview: _touchPreview,
              focusNode: x.focusNode,
              isFavorite: true,
              onToggleFavorite: () => _toggleFavoriteWithFeedback(context, c),
              onTap: () => _openMovie(c),
              onFocusGained: () {
                _updateBrowseFocus(
                  playlist: playlist,
                  id: c.id,
                  title: c.name,
                  imageUrl: c.logoUrl,
                  backdropUrl: c.backdropUrl,
                  fetchDescription: () => Future.value(null),
                );
                x.onFocused();
              },
            ),
          );
    rows.addAll(favorites.rows);
    rowKeys.addAll(favorites.keys);
    // Use concurrency-capped category loading, grouped by playlist, rather than starting
    // every category fetch at once.
    final emptyGroups = groups.where((g) => playlist
        .visibleSeries(playlistId: g.playlistId, categoryName: g.title)
        .isEmpty);
    for (final entry in _groupByPlaylist(emptyGroups)) {
      unawaited(playlist.ensureCategoriesLoaded(
          entry.playlistId, entry.groups.map((g) => g.title), 'series'));
    }
    if (_showWhatsNew) {
      return _WhatsNewCarousel<XtreamSeries>(
        loadItems: () => playlist.whatsNewSeries(limit: 10),
        titleOf: (s) => s.name,
        imageUrlOf: (s) => s.posterUrl ?? s.coverUrl,
        backdropUrlOf: (s) => s.anyBackdropUrl,
        ratingOf: (s) => s.rating,
        yearOf: (s) => s.releaseDate?.year,
        art: _whatsNewArt,
        ownBackdrop: _compact,
        prefetch: playlist.getHeroSeriesDescription,
        onOpen: _openSeries,
        playFocusNode: _showsWhatsNewPlayFocusNode,
        emptyText: tr('No recently added shows yet'),
      );
    }
    // Favourites view: starred shows above, then only favourited groups.
    final shownGroups = _showFavorites
        ? groups
            .where((g) => playlist.isGroupFavorited(g.playlistId, g.title))
            .toList()
        : groups;
    final groupSuffix = _favoriteGroupSuffix(shownGroups);
    for (final group in shownGroups) {
      final items = playlist.visibleSeries(
          playlistId: group.playlistId, categoryName: group.title);
      if (items.isEmpty) continue;
      final rowIndex = rowKeys.length;
      rowKeys.add((playlistId: group.playlistId, title: group.title));
      rows.add(KeyedSubtree(
        key: _keyForGroup(group.playlistId, group.title),
        child: _CategoryRow<XtreamSeries>(
          // See _buildMoviesBrowse's identical fix for why this isn't
          // just items.length.
          title:
              '${group.title} (${playlist.seriesCategoryTotalCount(group.playlistId, group.title) ?? items.length})${groupSuffix(group)}',
          items: items,
          itemBuilder: (s, index) => PosterCard(
            title: s.name,
            imageUrl: s.coverUrl,
            rating: s.rating,
            cardWidth: _browsePosterWidth,
            cardPosterHeight: _browsePosterHeight,
            tapToPreview: _touchPreview,
            focusNode: index == 0
                ? _firstPosterFocusNodeForGroup(group.playlistId, group.title)
                : null,
            isFavorite: s.isFavorite,
            onToggleFavorite: () =>
                _toggleSeriesFavoriteWithFeedback(context, s),
            onTap: () => _openSeries(s,
                groupPlaylistId: group.playlistId, groupTitle: group.title),
            onFocusGained: () {
              _updateBrowseFocus(
                playlist: playlist,
                id: s.id,
                title: s.name,
                imageUrl: s.coverUrl,
                backdropUrl: s.anyBackdropUrl,
                backdropOf: () => s.anyBackdropUrl,
                fetchDescription: () => playlist.getHeroSeriesDescription(s),
              );
              _ensureRowVisible(_keyForGroup(group.playlistId, group.title));
              _setFocusedBrowseRow(rowIndex);
            },
          ),
        ),
      ));
    }
    _browseRowKeys = rowKeys;
    return _buildBrowseScaffold(
      rows: rows,
      emptyText: rows.isEmpty
          ? (_showFavorites
              ? tr(
                  'No favourites yet. Hold Select on a poster or a group to add one.')
              : tr('Loading TV show categories...'))
          : null,
    );
  }

  Widget _buildBrowseScaffold({required List<Widget> rows, String? emptyText}) {
    return Column(
      children: [
        _BrowseHero(
            title: _focusedTitle == null
                ? null
                : cleanDisplayTitle(_focusedTitle!),
            imageUrl: _focusedArtPending ? null : _focusedImageUrl,
            backdropUrl: _focusedBackdropUrl,
            description: _focusedDescription),
        Expanded(
          child: emptyText != null
              ? Center(child: Text(emptyText))
              : ListView.builder(
                  controller: _browseScrollController,
                  itemCount: rows.length,
                  // Every row is exactly _categoryRowHeight tall (see its
                  // own doc comment) — telling Flutter that explicitly
                  // lets it compute scroll geometry analytically instead
                  // of needing to lay out every row to know where they
                  // are, which is what makes _scrollToBrowseGroup's
                  // direct jumpTo to an unbuilt row exact.
                  itemExtent: _categoryRowHeight,
                  itemBuilder: (context, i) => rows[i],
                ),
        ),
      ],
    );
  }
}

/// What [_TvHomeScreenState._buildFavoritesBrowseRow] hands each card.
typedef _FavoriteCardExtras = ({
  FocusNode? focusNode,
  VoidCallback onFocused,
});

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

/// Platform-dependent poster dimensions. Keep these as getters because PosterCard's
/// compile-time defaults cannot depend on Platform.isWindows.
const double _windowsPosterScale = 1.26;
double get _browsePosterWidth => Platform.isWindows
    ? PosterCard.width * _windowsPosterScale
    : PosterCard.width;
double get _browsePosterHeight => Platform.isWindows
    ? PosterCard.posterHeight * _windowsPosterScale
    : PosterCard.posterHeight;
double get _browseCardHeight =>
    _browsePosterHeight +
    (Platform.isWindows
        ? PosterCard.titleHeight * _windowsPosterScale
        : PosterCard.titleHeight);

/// [_CategoryRow]'s own section-title bar — a fixed height (not left to
/// whatever `SectionLabel`'s text happens to measure out to) specifically
/// so [_categoryRowHeight] below is an exact, enforced number rather than
/// a guess about font-metric-dependent text layout.
const double _categoryRowHeaderHeight = 40;
const double _categoryRowBottomPadding = 10;

/// Room above/below the poster strip for a focused card's 1.10x scale —
/// without it the strip's own clip cut the 2nd line of the focused title.
const double _posterFocusPad = 9;

/// Derive row height from the actual card layout and use it as itemExtent. This makes direct
/// jumps to unbuilt rows exact without laying out every intervening row.
double get _categoryRowHeight =>
    _categoryRowBottomPadding +
    _categoryRowHeaderHeight +
    _browseCardHeight +
    2 * _posterFocusPad;

/// One horizontally-scrolling row of [PosterCard]s under a category title
/// — the Netflix/Apple-TV "browse" pattern. Builds cards lazily as they
/// scroll into view — a category can hold thousands of items.
class _CategoryRow<T> extends StatelessWidget {
  const _CategoryRow(
      {required this.title, required this.items, required this.itemBuilder});

  final String title;
  final List<T> items;

  /// Takes the index too — the caller (see [_buildMoviesBrowse]/
  /// [_buildShowsBrowse]) gives the first card in each row a dedicated
  /// [FocusNode] so the groups quick-jump can focus it directly.
  final Widget Function(T item, int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    // The *whole row* is pinned to _categoryRowHeight (header slot +
    // poster strip + bottom padding, exactly the values that make up
    // that getter) rather than letting it size to its own intrinsic
    // content — see _categoryRowHeight's own doc comment for why this
    // enforcement, not just a matching number elsewhere, is the actual
    // point: it's what makes that getter *true* instead of a guess.
    return SizedBox(
      height: _categoryRowHeight,
      child: Padding(
        padding: const EdgeInsets.only(bottom: _categoryRowBottomPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: _categoryRowHeaderHeight,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SectionLabel(
                    title,
                    style: TextStyle(
                        color: interfaceColor(context, Colors.white),
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
              ),
            ),
            SizedBox(
              // Compact poster height; desktop scaling is applied by _browseCardHeight.
              height: _browseCardHeight + 2 * _posterFocusPad,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: _posterFocusPad),
                itemCount: items.length,
                // Flutter's default (250px, ~2 cards) only starts
                // building/decoding a card just barely before it's
                // visible, so a steady scroll still shows the grey-then-
                // fade-in pop-in right at the edge of the screen. Roughly
                // 5 cards' worth gives posters a head start decoding
                // before they're seen — some extra memory (the image
                // cache ceiling still bounds the total), traded for a
                // visibly smoother scroll.
                scrollCacheExtent:
                    ScrollCacheExtent.pixels(_browsePosterWidth * 5),
                itemBuilder: (context, i) => itemBuilder(items[i], i),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Big backdrop header showing whatever poster card currently has D-pad
/// focus, with its title overlaid — mirrors the hero-banner pattern from
/// Apple TV / Android TV browse screens.
class _BrowseHero extends StatelessWidget {
  const _BrowseHero(
      {required this.title,
      required this.imageUrl,
      this.backdropUrl,
      this.description});

  final String? title;

  /// A portrait poster/logo — the safe fallback image when [backdropUrl]
  /// isn't available yet (used by Android/TV's full-bleed crop, which
  /// already reads fine at its small fixed height, and by Windows' own
  /// poster-beside-text layout, which exists specifically to avoid
  /// stretching a portrait image edge-to-edge).
  final String? imageUrl;

  /// A true landscape TMDB backdrop — see `Channel.backdropUrl`'s doc
  /// comment. When this is set, both platforms prefer it over [imageUrl]
  /// for the full-bleed background; Windows additionally switches its
  /// *whole layout* to the full-bleed style for it (see [build]) instead
  /// of the poster-beside-text compromise, since a real landscape image
  /// doesn't have that layout's stretching problem to work around in the
  /// first place.
  final String? backdropUrl;

  /// Null while nothing's been focused yet, while it's still being
  /// fetched (see `_TvHomeScreenState._updateBrowseFocus`'s debounce), or
  /// when the title genuinely has none — the description area just shows
  /// nothing in all three cases, same as leaving a field blank rather
  /// than showing a misleading "no description" for something that might
  /// still arrive a moment later.
  final String? description;

  /// How far the backdrop continues below the banner, fading out behind
  /// the first category row (no bottom border, picture going lower).
  static double get _bleed => _categoryRowHeight * 0.75;

  static const double _bottomGap = 18;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = Platform.isWindows
        ? (MediaQuery.of(context).size.height * 0.32).clamp(220.0, 480.0)
        : 210.0;
    final big = Platform.isWindows;
    if (!big || (backdropUrl != null && backdropUrl!.isNotEmpty)) {
      // Fixed-height slot; the backdrop overflows it downward (painted
      // first, so the rows draw on top) and the title/description stay
      // exactly where they were. Overflow isn't hit-tested, so the rows
      // underneath keep their taps.
      return SizedBox(
        height: height + _bottomGap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height + _bottomGap + _bleed,
              child: _buildFadingBackdrop(scheme, height),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height,
              child: _buildHeroText(scheme, big: big),
            ),
          ],
        ),
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      // Scale the desktop hero with available window height and clamp the extremes. Reserve
      // enough space below its text for the next row label.
      height: Platform.isWindows
          ? (MediaQuery.of(context).size.height * 0.32).clamp(220.0, 480.0)
          : 210,
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        // Was a custom-painted gradient border (GradientBoxBorder) — a
        // Canvas shader repainting every time this rebuilds (every focus
        // change while scrolling) turned out to be part of the same
        // flicker cost as _SelectableRow's Ink change. A blended flat
        // color border keeps the duo-tone edge with a plain, cheap Border.
        border: Border.all(
            color: Color.lerp(scheme.primary, scheme.secondary, 0.5)!,
            width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      // Use a full-width desktop hero only with landscape artwork. Fall back to a portrait
      // poster beside text instead of cropping portrait art across the banner.
      child: _buildWindowsHeroContent(scheme),
    );
  }

  Widget _buildWindowsHeroContent(ColorScheme scheme) {
    return ColoredBox(
      color: Colors.grey.shade900,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            // Standard poster aspect — matches PosterCard's own ~0.70
            // width:height ratio elsewhere in this app.
            aspectRatio: 2 / 3,
            child: imageUrl != null && imageUrl!.isNotEmpty
                ? Builder(
                    builder: (context) => HdNetworkImage(
                      url: imageUrl!,
                      key: ValueKey(imageUrl),
                      kind: ImageKind.poster,
                      // The banner is at most 480 tall -> 320-wide poster.
                      decodeWidth: HdNetworkImage.cardDecodeWidth(context, 320,
                          oversample: 1),
                      errorWidget: (_) =>
                          Container(color: Colors.grey.shade900),
                    ),
                  )
                : Container(color: Colors.grey.shade900),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color.alphaBlend(scheme.primary.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.92)),
                    Color.alphaBlend(scheme.secondary.withValues(alpha: 0.2),
                        Colors.black.withValues(alpha: 0.8)),
                  ],
                ),
              ),
              // Allow the hero text to scroll when long content exceeds a short viewport or
              // larger text scale.
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                            width: 5, height: 36, color: scheme.secondary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title ?? tr('Browse'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 44,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: description == null
                          ? const SizedBox.shrink()
                          : Padding(
                              key: ValueKey(description),
                              padding: const EdgeInsets.only(left: 17),
                              child: Text(
                                description!,
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                                // Keep description text legible at desktop viewing distances.
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 34,
                                    height: 1.35),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Full-bleed, TiviMate-style hero — a real landscape backdrop behind a
  /// bottom-anchored gradient and title/description, text sized and
  /// padded larger ([big]) on Windows' much taller banner than Android/
  /// TV's compact 210px one. Prefers [backdropUrl] (a true landscape
  /// image, safe to `BoxFit.cover`) over [imageUrl] (a portrait poster/
  /// logo, used only until this item's own backdrop has been enriched) —
  /// see [backdropUrl]'s doc comment for why cropping a portrait image
  /// this way was the actual bug this exists to avoid repeating.
  ///
  /// Split in two: [_buildFadingBackdrop] (image + border, running [_bleed]
  /// past the banner and masked to transparent, so there's no bottom
  /// border) and [_buildHeroText] (unchanged spot inside the banner).
  Widget _buildFadingBackdrop(ColorScheme scheme, double bannerHeight) {
    final effectiveImageUrl = (backdropUrl != null && backdropUrl!.isNotEmpty)
        ? backdropUrl
        : imageUrl;
    final total = bannerHeight + _bottomGap + _bleed;
    final textBottom = bannerHeight / total;
    final tint =
        Color.alphaBlend(scheme.primary.withValues(alpha: 0.35), Colors.black);
    // RepaintBoundary: the mask's layer only redraws when the focused title
    // changes, not while the rows above it scroll.
    return RepaintBoundary(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Colors.white, Colors.white, Colors.transparent],
          stops: [0, textBottom * 0.8, 1],
        ).createShader(rect),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: Color.lerp(scheme.primary, scheme.secondary, 0.5)!,
                width: 2),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (effectiveImageUrl != null && effectiveImageUrl.isNotEmpty)
                // No ValueKey: HdSwapImage keeps the previous title's image
                // painted until the newly focused one has loaded, so moving
                // across posters (or the late poster -> backdrop upgrade)
                // never flashes an empty banner. Decode capped at the
                // screen width (1920 max on Android, 3840 on Windows).
                Builder(
                  builder: (context) => HdSwapImage(
                    url: effectiveImageUrl,
                    kind: (backdropUrl != null && backdropUrl!.isNotEmpty)
                        ? ImageKind.backdrop
                        : ImageKind.poster,
                    decodeWidth: HdNetworkImage.screenDecodeWidth(
                        context, MediaQuery.of(context).size.width),
                    // Same reasoning as _WhatsNewCarousel's identical fix:
                    // key-art subjects sit in the upper part of a backdrop.
                    alignment: Alignment.topCenter,
                    fadeInDuration: const Duration(milliseconds: 250),
                  ),
                ),
              // Darkest right under the title/description, then eased off
              // so the picture still shows behind the first row.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      tint.withValues(alpha: 0.85),
                      tint.withValues(alpha: 0.6),
                    ],
                    stops: [0, textBottom, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroText(ColorScheme scheme, {required bool big}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: big ? 28 : 20,
          bottom: big ? 24 : 16,
          right: big ? 28 : 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                      width: big ? 5 : 4,
                      height: big ? 36 : 22,
                      color: scheme.secondary),
                  SizedBox(width: big ? 12 : 10),
                  Expanded(
                    child: Text(
                      title ?? tr('Browse'),
                      maxLines: big ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: big ? 44 : 22,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              SizedBox(height: big ? 12 : 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: description == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(description),
                        padding: EdgeInsets.only(left: big ? 17 : 14),
                        child: Text(
                          description!,
                          // Bottom-anchored, not filling the whole banner
                          // the way the poster-beside-text layout's own
                          // scrollable column did — fewer lines keeps the
                          // text block short enough to actually fit above
                          // the bottom edge on a shorter window instead of
                          // needing to scroll to be readable at all.
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: big ? 34 : 14,
                              height: big ? 1.35 : 1.3),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// An opt-in view for the Movies/TV Shows tabs, reached via the pinned
/// "What's New" row in the groups column (not shown by default — see
/// [_TvHomeScreenState._showWhatsNew]): the handful of titles the
/// provider added most recently, as an auto-advancing slideshow that fills
/// the content area, in [_BrowseHero]'s visual language scaled up from a
/// header strip to a full page.
///
/// Generic over the item type for the same reason [_CategoryRow] is — the
/// movies and TV shows variants differ only in which field holds the title
/// and the artwork, not in any of the paging/focus behavior below.
/// What's New's full-screen picture: a landscape backdrop, or (when the
/// title has none) its poster.
typedef _WhatsNewArt = ({String url, bool poster});

/// Paints [art] the detail-page way. A poster isn't stretched to the
/// screen's width (soft, cropped to a slice): it fills the full height on
/// the right, uncropped, and fades into black toward the text and the
/// small poster beside the title. Plain gradients only —
/// no blur (Fire Stick GPUs).
class _WhatsNewBackdrop extends StatelessWidget {
  const _WhatsNewBackdrop({required this.art});

  final _WhatsNewArt? art;

  @override
  Widget build(BuildContext context) {
    final art = this.art;
    if (art == null || !art.poster) {
      return DetailBackdrop(url: art?.url, fadeLeft: true);
    }
    return LayoutBuilder(builder: (context, c) {
      // Full height, poster-shaped, but at least half the screen wide (a
      // little top/bottom crop then) so the fade has room on a wide TV.
      final w = math.max(c.maxHeight * 2 / 3, c.maxWidth * 0.5);
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: w,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  HdNetworkImage(
                    url: art.url,
                    kind: ImageKind.poster,
                    decodeWidth: HdNetworkImage.cardDecodeWidth(context, w,
                        oversample: 1),
                    alignment: Alignment.topCenter,
                    errorWidget: (_) => const SizedBox.shrink(),
                  ),
                  // Fades into the black toward the text, and a little at
                  // the bottom where the buttons sit.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Colors.black,
                          Color(0x99000000),
                          Color(0x00000000)
                        ],
                        stops: [0.0, 0.3, 0.65],
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0xCC000000)],
                        stops: [0.6, 1.0],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _WhatsNewCarousel<T> extends StatefulWidget {
  const _WhatsNewCarousel({
    required this.loadItems,
    required this.titleOf,
    required this.imageUrlOf,
    this.backdropUrlOf,
    this.ratingOf,
    this.yearOf,
    required this.art,
    this.ownBackdrop = false,
    this.prefetch,
    required this.onOpen,
    required this.playFocusNode,
    required this.emptyText,
  });

  /// A loader, deliberately not an already-created `Future`: this widget's
  /// parent rebuilds on every `PlaylistManager` notification, and taking a
  /// future directly would hand the `FutureBuilder` below a brand-new one
  /// each time — flashing back to the loading state over and over while
  /// the catalog is busy.
  final Future<List<T>> Function() loadItems;

  final String Function(T item) titleOf;
  final String? Function(T item) imageUrlOf;

  /// A true landscape TMDB backdrop, preferred over [imageUrlOf]'s
  /// portrait poster/logo when set — see `Channel.backdropUrl`'s doc
  /// comment. Optional (not every `_WhatsNewCarousel` instantiation needs
  /// to pass one, though both current ones do) since this carousel is
  /// generic over item type and some future one might have nothing of the
  /// kind to offer.
  final String? Function(T item)? backdropUrlOf;

  final String? Function(T item)? ratingOf;
  final int? Function(T item)? yearOf;

  /// Owned by `_TvHomeScreenState`, which paints it full screen behind
  /// everything (detail-page style). Set here only from callbacks, never
  /// during build — the listener lives earlier in the same tree.
  final ValueNotifier<_WhatsNewArt?> art;

  /// Portrait phone (no full-screen layer there): paint the backdrop
  /// inside this area instead.
  final bool ownBackdrop;

  /// Run once per slide as it's shown (the provider-info fetch that also
  /// stamps the provider's backdrop onto the item and returns its plot);
  /// the slide rebuilds when it completes, so a late backdrop and the
  /// description appear then.
  final Future<Object?> Function(T item)? prefetch;
  final void Function(T item) onOpen;

  /// Owned by `_TvHomeScreenState` — see its own doc comment on why the
  /// Play button's focus is requested from out there rather than
  /// autofocused from in here.
  final FocusNode playFocusNode;

  final String emptyText;

  @override
  State<_WhatsNewCarousel<T>> createState() => _WhatsNewCarouselState<T>();
}

class _WhatsNewCarouselState<T> extends State<_WhatsNewCarousel<T>>
    with RouteAware {
  /// Was 4 s with a title only; a slide now carries a description to read.
  static const _advanceInterval = Duration(seconds: 7);

  final FocusNode _prevFocusNode = FocusNode(debugLabel: 'whats-new-prev');
  final FocusNode _nextFocusNode = FocusNode(debugLabel: 'whats-new-next');
  late final Future<List<T>> _itemsFuture;
  Timer? _timer;
  int _index = 0;
  int _itemCount = 0;

  /// Slides shown, picked from the larger pool [loadItems] returns.
  static const _shown = 6;

  @override
  void initState() {
    super.initState();
    _itemsFuture = widget.loadItems().then(_preferArt).then((items) {
      if (mounted) {
        _itemCount = items.length;
        _items = items;
        _startTimer();
        _publishArt();
      }
      return items;
    });
  }

  List<T> _items = const [];

  /// Plots returned by [prefetch], per item.
  final Map<Object?, String> _plots = {};

  /// Fetches every candidate's info up front (at most ~5 s, cached per
  /// session) and puts the titles with a real landscape backdrop first —
  /// a slide with only a poster on black looked empty. The rest
  /// still fill in when fewer than [_shown] have one.
  Future<List<T>> _preferArt(List<T> pool) async {
    final prefetch = widget.prefetch;
    if (prefetch != null && pool.isNotEmpty) {
      await Future.wait([
        for (final item in pool)
          prefetch(item).then((plot) {
            if (plot is String && plot.trim().isNotEmpty) {
              _plots[item] = plot.trim();
            }
          }, onError: (_) {}),
      ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    }
    final withArt = [
      for (final i in pool)
        if (_backdropOf(i) != null) i
    ];
    final rest = [
      for (final i in pool)
        if (_backdropOf(i) == null) i
    ];
    return [...withArt, ...rest].take(_shown).toList();
  }

  String? _backdropOf(T item) {
    final b = widget.backdropUrlOf?.call(item);
    return (b != null && b.isNotEmpty) ? b : null;
  }

  /// Hands the current slide's picture to the full-screen layer: its
  /// backdrop, else its poster (drawn dimmed there).
  void _publishArt() {
    if (_items.isEmpty) return;
    widget.art.value = _artOf(_items[_index.clamp(0, _items.length - 1)]);
  }

  _WhatsNewArt? _artOf(T item) {
    final backdrop = _backdropOf(item);
    if (backdrop != null) return (url: backdrop, poster: false);
    final poster = widget.imageUrlOf(item);
    return (poster != null && poster.isNotEmpty)
        ? (url: poster, poster: true)
        : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _timer?.cancel();
    _prevFocusNode.dispose();
    _nextFocusNode.dispose();
    super.dispose();
  }

  /// Something now covers this screen (a movie/series detail screen, the
  /// fullscreen player). An auto-advance that keeps firing `setState` on a
  /// covered-but-still-mounted carousel is pure waste for as long as that
  /// route is up — the same "timer outlives what it's actually for" bug
  /// class already fixed for the player's seek buttons, avoided here by
  /// design rather than patched afterwards.
  @override
  void didPushNext() => _timer?.cancel();

  @override
  void didPopNext() => _startTimer();

  void _startTimer() {
    _timer?.cancel();
    if (_itemCount < 2) return;
    _timer = Timer.periodic(_advanceInterval, (_) => _goTo(_index + 1));
  }

  /// Modulo, so the slideshow wraps around instead of stopping after the
  /// last title. A plain index (no PageView): the picture is the
  /// full-screen layer behind the whole screen, so slides cross-fade.
  void _goTo(int target) {
    if (_itemCount == 0 || !mounted) return;
    setState(() => _index = target % _itemCount);
    _publishArt();
  }

  void _step(int delta) {
    _goTo(_index + delta);
    // Restarted, not left running: a deliberate press shouldn't be
    // overridden a fraction of a second later by the next auto-tick.
    _startTimer();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<T>>(
      future: _itemsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(child: Text(tr('Loading...')));
        }
        final items = snapshot.data ?? <T>[];
        if (items.isEmpty) return Center(child: Text(widget.emptyText));
        final item = items[_index.clamp(0, items.length - 1)];
        // Same scale rule as the detail pages, from the screen size (this
        // area narrows while the side columns are open).
        final size = MediaQuery.sizeOf(context);
        final s = math
            .min(size.width / 960, size.height / 540)
            .clamp(1.0, 2.2)
            .toDouble();
        return GestureDetector(
          // Touch: swipe between titles (the PageView used to do this).
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v.abs() > 200) _step(v < 0 ? 1 : -1);
          },
          child: LayoutBuilder(builder: (context, c) {
            final content = Padding(
              // Bottom clearance: LiveResumeHint (the "Hold -> to resume"
              // pill) is a global overlay 24px from the screen's bottom.
              padding: EdgeInsets.fromLTRB(16 * s, 0, 16 * s, 56),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Spacer(),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.bottomLeft,
                      children: [...previous, if (current != null) current],
                    ),
                    child: KeyedSubtree(
                      key: ValueKey<Object?>(item),
                      child: _buildInfo(context, item, s, c.maxWidth),
                    ),
                  ),
                  SizedBox(height: 16 * s),
                  _buildNavRow(context, item, s),
                  SizedBox(height: 12 * s),
                  _buildDots(context, items.length, s),
                ],
              ),
            );
            if (!widget.ownBackdrop) return content;
            return Stack(
              fit: StackFit.expand,
              children: [
                _WhatsNewBackdrop(art: _artOf(item)),
                content,
              ],
            );
          }),
        );
      },
    );
  }

  /// Title, rating/year chips and plot, detail-page style.
  Widget _buildInfo(BuildContext context, T item, double s, double maxW) {
    final scheme = Theme.of(context).colorScheme;
    final rawRating = widget.ratingOf?.call(item);
    final ratingValue = rawRating == null ? null : double.tryParse(rawRating);
    final rating = (ratingValue != null && ratingValue > 0) ? rawRating : null;
    final year = widget.yearOf?.call(item);
    final plot = _plots[item];
    // No landscape backdrop: the poster card beside the title (the same
    // poster also fills the right side behind, faded — _WhatsNewBackdrop).
    final poster = _backdropOf(item) == null ? widget.imageUrlOf(item) : null;
    final showPoster = poster != null && poster.isNotEmpty;
    final posterW = 130 * s;
    final textW =
        math.min(560 * s, maxW * 0.55 - (showPoster ? posterW + 20 * s : 0));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showPoster) ...[
          DetailPoster(url: poster, width: posterW),
          SizedBox(width: 20 * s),
        ],
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.max(textW, 120)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                cleanDisplayTitle(widget.titleOf(item)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 34 * s,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  shadows: const [
                    Shadow(color: Colors.black87, blurRadius: 12)
                  ],
                ),
              ),
              if (rating != null || year != null) ...[
                SizedBox(height: 10 * s),
                Wrap(
                  spacing: 6 * s,
                  runSpacing: 6 * s,
                  children: [
                    if (rating != null)
                      DetailMetaChip(
                        scale: s,
                        leading: Icon(Icons.star_rounded,
                            size: 14 * s, color: scheme.primary),
                        label: rating,
                        strong: true,
                      ),
                    if (year != null) DetailMetaChip(scale: s, label: '$year'),
                  ],
                ),
              ],
              if (plot != null) ...[
                SizedBox(height: 10 * s),
                Text(
                  plot,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 13.5 * s,
                    height: 1.4,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDots(BuildContext context, int count, double s) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: (i == _index ? 18 : 7) * s,
            height: 7 * s,
            margin: EdgeInsets.only(right: 6 * s),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4 * s),
              color: i == _index ? scheme.primary : Colors.white30,
            ),
          ),
      ],
    );
  }

  /// Play first (where focus lands), then Previous / Next. Left/Right
  /// between them is ordinary directional traversal, same as the detail
  /// pages' pill row. The artwork itself isn't focusable.
  Widget _buildNavRow(BuildContext context, T current, double s) {
    return Row(
      children: [
        DetailPillButton(
          focusNode: widget.playFocusNode,
          scale: s,
          icon: Icons.play_arrow_rounded,
          label: tr('Play'),
          emphasized: true,
          onPressed: () => widget.onOpen(current),
        ),
        SizedBox(width: 10 * s),
        DetailPillButton(
          focusNode: _prevFocusNode,
          scale: s,
          icon: Icons.chevron_left,
          label: tr('Previous'),
          onPressed: () => _step(-1),
        ),
        SizedBox(width: 10 * s),
        DetailPillButton(
          focusNode: _nextFocusNode,
          scale: s,
          icon: Icons.chevron_right,
          label: tr('Next'),
          onPressed: () => _step(1),
        ),
      ],
    );
  }
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
          : const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(program?.title ?? channel!.name,
              style: (compact
                      ? Theme.of(context).textTheme.titleSmall
                      : Theme.of(context).textTheme.titleLarge)
                  ?.copyWith(color: interfaceColor(context, Colors.white)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          if (program != null && channel != null)
            Text(channel.name,
                style: TextStyle(
                    color: interfaceColor(context, Colors.white54),
                    fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          if (program != null) ...[
            Row(
              children: [
                Flexible(
                  flex: 3,
                  child: Text(
                      '${timeFormat.format(program.start)} - ${timeFormat.format(program.stop)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: interfaceColor(context, Colors.white70),
                          fontSize:
                              compact || _mobileGuide(context) ? 12 : null)),
                ),
                if (program.isNowPlaying(now)) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Builder(builder: (context) {
                      final totalMs =
                          program.stop.difference(program.start).inMilliseconds;
                      final elapsedMs =
                          now.difference(program.start).inMilliseconds;
                      final ratio = totalMs == 0
                          ? 0.0
                          : (elapsedMs / totalMs).clamp(0.0, 1.0);
                      return LinearProgressIndicator(value: ratio);
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
                  child: Text(program.description!,
                      style: TextStyle(
                          color: interfaceColor(context, Colors.white70))),
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

  double _xFor(DateTime t) =>
      t.difference(_windowStart).inMinutes * _pixelsPerMinute;

  /// Reveal the target row with the minimum vertical scroll before programme-level
  /// ensureVisible runs, avoiding a top-aligned page jump on each Down press.
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
    return Column(
      children: [
        SizedBox(
          height: _rulerHeight,
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
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: Text('Hold Left · Guide tools',
                              key: const ValueKey('guide-tools-hint'),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ))),
                ]),
              ),
            ],
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
                                      fontSize: 13,
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
                                                  color: interfaceColor(context,
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
                        color: interfaceColor(context, Colors.white70),
                        fontSize: 12)),
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
                  color: _focused
                      ? null
                      : interfaceColor(context, Colors.white)
                          .withValues(alpha: 0.06),
                  gradient: _focused
                      ? LinearGradient(colors: [
                          scheme.primaryContainer,
                          scheme.primaryContainer
                        ])
                      : null,
                  border: Border.all(
                      color: _focused
                          ? scheme.primary
                          : interfaceColor(context, Colors.white24)),
                  borderRadius: BorderRadius.circular(2),
                ),
                alignment: Alignment.center,
                // `scheme.tertiary` — a dedicated icon/symbol-glyph
                // accent, separate from the border/gradient accent
                // (`scheme.primary`) — see `buildPaletteColorScheme`'s
                // own doc comment for why (Habs: white contour, blue
                // icons).
                child: Tooltip(
                    message: 'Search · hold Left for guide tools',
                    child: Icon(Icons.search,
                        size: 16,
                        color: _focused
                            ? scheme.tertiary
                            : interfaceColor(context, Colors.white70))),
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
  final logo = _landscapeGuide(context)
      ? 24
      : _mobileGuide(context)
          ? 28
          : 30;
  return 8 + logo + (_mobileGuide(context) ? 6 : 8);
}

class _ChannelLabel extends StatelessWidget {
  const _ChannelLabel({required this.channel, this.playlistTag});

  final Channel channel;

  /// Gold playlist name in the top-left corner (see
  /// _TimelineGuideState._playlistTagFor).
  final String? playlistTag;

  @override
  Widget build(BuildContext context) {
    final tag = playlistTag;
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
                      fontWeight: FontWeight.w700))),
        ]),
      );
    }
    final row = SizedBox(
      height: _guideRowHeight(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, tag == null ? 0 : 12, 8, 0),
        child: Row(
          children: [
            SizedBox(
              width: _landscapeGuide(context)
                  ? 24
                  : _mobileGuide(context)
                      ? 28
                      : 30,
              height: _landscapeGuide(context)
                  ? 24
                  : _mobileGuide(context)
                      ? 28
                      : 30,
              child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
                  ? LiveChannelLogo(url: channel.logoUrl!)
                  : const Icon(Icons.tv),
            ),
            SizedBox(width: _mobileGuide(context) ? 6 : 8),
            Expanded(
              child: Text(
                channel.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: interfaceColor(context, Colors.white),
                    fontSize: _landscapeGuide(context)
                        ? 11.5
                        : _mobileGuide(context)
                            ? 12.5
                            : 13),
              ),
            ),
          ],
        ),
      ),
    );
    if (tag == null) return row;
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
                color: scheme.primary.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
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
          padding:
              EdgeInsets.symmetric(vertical: _mobileGuide(context) ? 3 : 4),
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
                      top: _mobileGuide(context) ? 3 : 4,
                      bottom: _mobileGuide(context) ? 3 : 4,
                      child: _ProgramBlock(
                        program: program,
                        isNow: program.isNowPlaying(now),
                        translucent: translucent,
                        onOpen: onOpen,
                        onShowOptions: onShowOptions,
                        blockLeft: leftFor(program),
                        blockWidth: widthFor(program),
                        hScroll: hScroll,
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
      this.placeholderLabel,
      this.onRegister,
      this.onUnregister,
      this.translucent = false});

  final bool translucent;

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
    if (widget.hScroll.hasClients) {
      final pos = widget.hScroll.position;
      final viewLeft = pos.pixels;
      final viewRight = viewLeft + pos.viewportDimension;
      final overlaps = widget.blockLeft < viewRight &&
          widget.blockLeft + widget.blockWidth > viewLeft;
      if (overlaps) return;
    }
    Scrollable.ensureVisible(context, duration: Duration.zero);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Flat focus fill; selection keeps a quieter accent outline.
    final accent = scheme.primary;
    // Flat focus fill; selection keeps a quieter accent outline.

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
            // Instant, not animated — the same "jumpTo, never animateTo
            // on a real device" reasoning as the rest of this widget;
            // only relevant once these blocks are numerous enough to
            // scroll. onFocusGained runs first so the vertical axis has
            // already been edge-scrolled (see
            // _TimelineGuideState._ensureRowVisible) by the time
            // ensureVisible looks at it — leaving it only the horizontal
            // axis to settle.
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
                              : interfaceColor(context, Colors.white),
                      fontSize: _landscapeGuide(context)
                          ? 10.5
                          : _mobileGuide(context)
                              ? 11.5
                              : 12,
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
