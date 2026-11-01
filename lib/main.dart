import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/desktop_player_screen.dart';
import 'services/desktop_mini_player.dart';
import 'services/desktop_window.dart';
import 'screens/player_screen.dart';
import 'screens/settings/add_playlist_screen.dart';
import 'screens/tv_home_screen.dart';
import 'screens/welcome_add_playlist_screen.dart';
import 'services/app_preferences.dart';
import 'services/catalog_database.dart';
import 'services/database_runtime.dart';
import 'services/device_memory_service.dart';
import 'services/epg_service.dart';
import 'services/parental_pin.dart';
import 'services/persistent_image_cache.dart';
import 'services/playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/storage_service.dart';
import 'services/viewer_profile_service.dart';
import 'utils/constants.dart';
import 'utils/route_observer.dart';
import 'utils/splash_greeting.dart';
import 'utils/tv_theme.dart';
import 'widgets/desktop_live_resume_hint.dart';
import 'widgets/live_resume_hint.dart';
import 'widgets/preview_pip_launcher.dart';
import 'l10n/l10n.dart';
import 'services/archive_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) await configureAndroidDatabaseWorkers();
  // Use sqflite_common_ffi on Windows/Linux; mobile and macOS retain their native sqflite
  // implementations.
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Only ever used by DesktopPlayerScreen — see its own doc comment and
    // pubspec.yaml's media_kit comment. Every other platform keeps using
    // video_player_hdr exclusively and never touches this at all.
    MediaKit.ensureInitialized();
  }
  if (Platform.isWindows) {
    // Restore the saved fullscreen/windowed mode before creating the window,
    // avoiding a visible transition through the default window size.
    await DesktopWindow.init(await SharedPreferences.getInstance());
  }
  // Before runApp so the splash text is already in the right language.
  // Read straight from SharedPreferences: StorageService isn't up yet.
  try {
    final prefs = await SharedPreferences.getInstance();
    await L10n.apply(prefs.getString(AppConstants.keyLanguage) ?? 'auto');
    await SplashGreeting.pickNext(prefs);
  } catch (_) {
    await L10n.apply('auto');
  }
  await _configureImageCache();
  // Keep image files and their cache index in persistent storage so OS cleanup cannot leave
  // valid index entries pointing to missing posters.
  CachedNetworkImageProvider.defaultCacheManager = persistentImageCacheManager;
  runApp(const NoxIptvApp());
}

/// Bound decoded artwork independently of the catalogue size. The player,
/// guide database and OS need headroom while the TV is decoding video.
Future<void> _configureImageCache() async {
  final info = await DeviceMemoryService.getMemoryInfo();
  PaintingBinding.instance.imageCache.maximumSize = 512;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      imageCacheBudgetBytes(info);
}

/// Restores settings before opening the app. Playlist caches and the guide
/// continue loading in the background so startup does not wait on the network.
class NoxIptvApp extends StatefulWidget {
  const NoxIptvApp({super.key});

  @override
  State<NoxIptvApp> createState() => _NoxIptvAppState();
}

class _NoxIptvAppState extends State<NoxIptvApp> with WindowListener {
  late final StorageService _storage;
  late final CatalogDatabase _catalogDb;
  late final AppPreferences _preferences;
  late final PlaylistManager _playlistManager;
  late final EpgService _epgService;
  late final PlaybackService _playbackService;
  late final ViewerProfileService _viewerProfileService;
  late final ParentalPin _parentalPin;
  late final ArchiveService _archiveService;
  bool _ready = false;

  /// True while waiting on [WelcomeAddPlaylistScreen]'s answer — shown once,
  /// right after [PlaylistManager.init] confirms a brand-new install has
  /// zero playlists configured, since nothing else in the app hints that
  /// content lives behind Settings > Playlist Manager rather than just
  /// showing up on its own.
  bool _newUserPromptPending = false;
  Completer<bool>? _newUserPromptCompleter;

  /// Set from [WelcomeAddPlaylistScreen]'s answer, consumed once `_ready`
  /// flips true (see `_buildReadyContent`'s `build` doc comment below) —
  /// can't just push [AddPlaylistScreen] directly from the prompt itself,
  /// since the real `MaterialApp`/`Navigator` this screen's bootstrap gate
  /// runs ahead of doesn't exist yet at that point.
  bool _pendingAutoOpenAddPlaylist = false;

  Future<bool> _confirmNewUserWantsPlaylist() {
    final completer = Completer<bool>();
    _newUserPromptCompleter = completer;
    if (mounted) setState(() => _newUserPromptPending = true);
    return completer.future;
  }

  void _respondToNewUserPrompt(bool wantsToAddPlaylist) {
    if (mounted) setState(() => _newUserPromptPending = false);
    _newUserPromptCompleter?.complete(wantsToAddPlaylist);
    _newUserPromptCompleter = null;
  }

  /// Lets background work (the initial playlist load finishing, "Update
  /// content" finishing) show a brief toast without needing a BuildContext
  /// tied to whatever screen happens to be on top — same trick other IPTV
  /// players use for their "refresh complete" notification.
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Lets [LiveResumeHint] push the fullscreen player back on top from
  /// its own position in the tree — it sits as a *sibling* of the
  /// Navigator (see `builder` below), deliberately, so its hold-Right
  /// gesture and reminder text work from any screen; `Navigator.of
  /// (context)` from there would find nothing, since siblings aren't
  /// ancestors.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  String _splashStatus = tr('Starting...');
  String? _bootstrapError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // Restore fullscreen when the desktop window returns from minimization. Minimizing first
    // requires leaving fullscreen; the listener belongs at the app root.
    if (Platform.isWindows) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowRestore() {
    if (Platform.isWindows) DesktopWindow.onRestore();
  }

  @override
  void onWindowResized() => DesktopWindow.onBoundsChanged();

  @override
  void onWindowMoved() => DesktopWindow.onBoundsChanged();

  Future<void> _bootstrap() async {
    setState(() => _bootstrapError = null);
    try {
      _storage = StorageService();
      await _storage.init();
      if (mounted) setState(() => _splashStatus = tr('Loading settings...'));
      LiveResumeHint.pillEnabled.value = _storage.getShowResumePill();

      _preferences = AppPreferences(_storage);
      await _preferences.init();
      // Asked once per launch, before anything decides a layout — see
      // DeviceTypeService for why screen width couldn't answer this.
      _preferences.isTelevision = await DeviceTypeService.isTelevision();

      _catalogDb = CatalogDatabase();

      _playlistManager = PlaylistManager(_storage, _catalogDb);
      _epgService = EpgService(_storage);
      _epgService.supplementarySources =
          () => _playlistManager.supplementaryGuideSources(_epgService);
      _epgService.onSupplementaryGuidesUpdated =
          () => _playlistManager.finishSupplementaryGuides(_epgService);
      // Started during the splash, not after it: it only opens the EPG
      // database and preloads now/next for every channel (a few thousand
      // rows, SQLite on its own thread), so it doesn't compete with the
      // catalog for the CPU the way the old full JSON decode would have.
      // Not awaited — the splash never waits on it; the post-splash chain
      // below awaits the same future.
      unawaited(_epgService.init());
      _playbackService = PlaybackService(_storage, _playlistManager);
      _parentalPin = ParentalPin(_storage);
      _archiveService = ArchiveService(_storage);
      _viewerProfileService =
          ViewerProfileService(_storage, _playlistManager, _playbackService);

      // Restore local settings first. The Live TV/Sports layout remains usable
      // while a missing cache is recovered; it never needs the movie/series
      // catalogue to finish before opening.
      if (mounted) setState(() => _splashStatus = tr('Loading playlists...'));
      // Keep startup independent of movie/series library size. Libraries fetch
      // category names and the selected category only when opened.
      await _playlistManager.init(restoreInBackground: true);
      if (_playlistManager.profiles.isEmpty) {
        _pendingAutoOpenAddPlaylist = await _confirmNewUserWantsPlaylist();
      }
      if (mounted) setState(() => _ready = true);
      if (_pendingAutoOpenAddPlaylist) {
        // Same reasoning as the toast above — the real Navigator this
        // pushes onto doesn't exist until this build lands.
        _pendingAutoOpenAddPlaylist = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigatorKey.currentState?.push(
              MaterialPageRoute(builder: (_) => const AddPlaylistScreen()));
        });
      }
      // `_epgService.init()` was started during the splash (see above);
      // awaiting it here only makes sure startAutoRefresh sees whether the
      // database has data — which decides if a refresh is due right away.
      unawaited(() async {
        await _playbackService.init();
        await Future.wait([
          _playlistManager.whenRestored.then((_) => _autoResumeLastChannel()),
          _epgService.init(),
        ]);
        _epgService.startAutoRefresh(
            _storage.getRefreshInterval(), _epgSources);
        // Library metadata is fetched only when a title is opened.
      }());
    } catch (e) {
      // Surfaces any unexpected startup failure as a retryable screen
      // instead of leaving the app stuck on the splash spinner forever.
      if (mounted) setState(() => _bootstrapError = e.toString());
    }
  }

  /// Resume the last live channel according to startup preferences: fullscreen, guide preview
  /// or a pending-resume hint. Resolve the stored channel only after the live catalogue is
  /// available.
  Future<void> _autoResumeLastChannel() async {
    if (const bool.fromEnvironment('IPTV_DISABLE_AUTOPLAY')) return;
    if (_playbackService.isPlayingSomething) return;
    final lastId = _storage.getLastChannelId();
    if (lastId == null) return;
    await _playlistManager.ensureLiveChannelsLoaded();
    // Settings > General > Startup (both platforms): full screen (default),
    // or playing in the guide's preview box, or neither.
    final fullscreen = _storage.getResumeLastChannelAtStartup();
    final inGuide = !fullscreen && _storage.getResumeLastChannelInGuide();
    // visibleChannels, not the raw `channels` getter — a restricted
    // viewer's last-played channel may have had its group hidden since
    // they last watched (by whoever set up their profile), and silently
    // offering it to resume into would bypass that the same way an
    // unfiltered search result would.
    for (final channel in _playlistManager.visibleChannels(category: 'tv')) {
      if (channel.id == lastId) {
        if (Platform.isWindows) {
          if (fullscreen) {
            _navigatorKey.currentState?.push(MaterialPageRoute(
                builder: (_) => DesktopPlayerScreen(channel: channel)));
          } else if (inGuide &&
              DesktopMiniPlayer.instance.channel.value == null) {
            DesktopMiniPlayer.instance.play(channel);
          }
        } else if (inGuide) {
          if (_playbackService.isPlayingSomething) return;
          await _playbackService.play(channel);
        } else if (fullscreen) {
          // Back on by default since 1.0.x: the heavy part of the old
          // cold-start load (decoding the whole EPG, ~25 s) is gone — the
          // guide now opens from SQLite in ~0.3 s during the splash, and the
          // first EPG refresh waits >= 30 s. Settings > General turns it off
          // (then only the pill below). Same push the pill's own resume
          // does; PlayerScreen.initState starts playback.
          if (_playbackService.isPlayingSomething) return;
          final navigator = _navigatorKey.currentState;
          if (navigator != null) PlayerScreen.open(navigator, channel);
        } else {
          _playbackService.setPendingResumeChannel(channel);
        }
        return;
      }
    }
  }

  /// Sources for the normal programme-guide refresh.
  List<EpgSource> _epgSources() => _playlistManager.epgSources();

  @override
  Widget build(BuildContext context) {
    if (_bootstrapError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.white70, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    tr('Startup failed:\n{bootstrapError}',
                        {'bootstrapError': _bootstrapError}),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _bootstrap, child: Text(tr('Retry'))),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Keep the initial splash outside MultiProvider: bootstrap has not yet assigned the late
    // service fields when the first frame builds. The splash only needs local widget state.
    if (!_ready && !_newUserPromptPending) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF171D25),
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.live_tv_outlined,
                size: 64, color: Color(0xFF90CAF9)),
            const SizedBox(height: 20),
            const Text(AppConstants.appName,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 20),
            Text(_splashStatus,
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ])),
        ),
      );
    }

    // Everything below only ever becomes reachable after
    // `_playlistManager.init()` (which itself runs after every `late
    // final` service field above is assigned) has already completed —
    // `_newUserPromptPending` is only ever
    // set true later in `_bootstrap()`, well past that point — so
    // referencing all of them in this MultiProvider is genuinely safe here,
    // unlike in the splash branch above.
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: _storage),
        Provider<CatalogDatabase>.value(value: _catalogDb),
        ChangeNotifierProvider<AppPreferences>.value(value: _preferences),
        ChangeNotifierProvider<PlaylistManager>.value(value: _playlistManager),
        ChangeNotifierProvider<EpgService>.value(value: _epgService),
        ChangeNotifierProvider<PlaybackService>.value(value: _playbackService),
        Provider<ParentalPin>.value(value: _parentalPin),
        ChangeNotifierProvider<ArchiveService>.value(value: _archiveService),
        ChangeNotifierProvider<ViewerProfileService>.value(
            value: _viewerProfileService),
      ],
      child: _buildReadyContent(context),
    );
  }

  Widget _buildReadyContent(BuildContext context) {
    if (_newUserPromptPending) {
      return WelcomeAddPlaylistScreen(onRespond: _respondToNewUserPrompt);
    }

    return Consumer<AppPreferences>(
      builder: (context, prefs, _) {
        return MaterialApp(
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: _scaffoldMessengerKey,
          navigatorKey: _navigatorKey,
          navigatorObservers: [appRouteObserver],
          // Flutter's own widget strings (text-selection menu, tooltips)
          // follow the app language, not the device's (see L10n).
          locale: L10n.locale,
          supportedLocales: L10n.supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          // Renders above the Navigator's own output rather than inside
          // it, so the hold-Right-to-resume gesture and reminder text
          // work from any screen instead of only the one route they
          // happened to be built into (see LiveResumeHint's doc
          // comment).
          builder: (context, child) => Stack(
            children: [
              if (child != null) child,
              PreviewPipLauncher(navigatorKey: _navigatorKey),
              LiveResumeHint(navigatorKey: _navigatorKey),
              // Windows-only equivalent — see DesktopPlayerScreen's own
              // doc comment for why it's a separate widget/holder rather
              // than reusing LiveResumeHint/PlaybackService.
              if (Platform.isWindows)
                DesktopLiveResumeHint(navigatorKey: _navigatorKey),
            ],
          ),
          // The selected app palette controls appearance independently of system light/dark
          // mode.
          theme: buildAppTheme(prefs.palette),
          themeAnimationDuration: Duration.zero,
          home: Builder(
            builder: (context) {
              // TvHomeScreen adapts to phone and TV layouts. Key it by active viewer so
              // profile changes rebuild screen state and cannot retain another viewer's
              // selection or content.
              return Consumer<ViewerProfileService>(
                builder: (context, viewerService, _) {
                  // The language is part of the key for the same reason:
                  // a language change remounts home so every tr() string
                  // is rebuilt (General settings pops back here first).
                  final key =
                      ValueKey('${viewerService.active.id}|${L10n.code}');
                  return TvHomeScreen(key: key);
                },
              );
            },
          ),
        );
      },
    );
  }
}
