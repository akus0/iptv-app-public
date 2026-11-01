import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/cyberpunk_palette.dart';
import '../utils/constants.dart';
import '../utils/time_format.dart';
import 'storage_service.dart';

/// App-wide UI/behavior preferences (theme, clock, layout mode, whether
/// this device is allowed to play anything right now).
///
/// Replaces manually threading 8 separate value/callback constructor
/// params through every screen that touches a setting — with the growing
/// number of settings screens, that had become the classic "prop drilling"
/// problem Provider exists to solve. Screens just `watch<AppPreferences>()`
/// and call a setter; everything persists itself.
class AppPreferences extends ChangeNotifier {
  AppPreferences(this._storage);

  final StorageService _storage;

  late bool showClock;
  late CyberpunkPalette palette;
  late String layoutMode; // 'auto', 'tv'
  late String guideViewMode; // 'live', 'timeline'

  /// Timeline guide: video full screen behind a translucent guide.
  late bool guideFullVideo;

  /// Movies / TV Shows tabs (and their search results) hidden, each on its
  /// own switch (Settings > General > Tabs).
  late bool hideMovies;
  late bool hideShows;

  /// The Extras row (the Archive tab; tabs column / phone "More" page)
  /// hidden.
  late bool hideArchive;

  /// The Multiview row and the player's "Open in Multiview" hidden.
  late bool hideMultiview;

  /// Fullscreen player zooms the picture to fill the screen (no black bars).
  late bool videoFill;

  /// Both Movies and TV Shows hidden.
  bool get hideMoviesShows => hideMovies && hideShows;

  /// Whether the tab id 'Movies' / 'TV Shows' is hidden.
  bool isTabHidden(String tab) => switch (tab) {
        'Movies' => hideMovies,
        'TV Shows' => hideShows,
        _ => false,
      };

  /// Set once at startup from Android's own UI mode (see
  /// DeviceTypeService) — what 'auto' actually keys off now. Not
  /// persisted: it's a property of the device, re-detected every launch,
  /// and a stale stored value would be worse than asking again.
  bool isTelevision = false;

  Future<void> init() async {
    showClock = _storage.getShowClock();
    palette = AppConstants.cyberpunkPalettes.firstWhere(
        (p) => p.id == _storage.getPaletteId(),
        orElse: () => AppConstants.cyberpunkPalettes.first);
    layoutMode = 'auto';
    guideViewMode = 'timeline';
    guideFullVideo = false;
    hideMovies = !AppConstants.onDemandEnabled || _storage.getHideMovies();
    hideShows = !AppConstants.onDemandEnabled || _storage.getHideShows();
    hideArchive = true;
    hideMultiview = _storage.getHideMultiview();
    videoFill = _storage.getVideoFill();
    TimeFormat.use24h = _storage.getTime24h();
  }

  Future<void> setPalette(CyberpunkPalette value) async {
    if (palette.id == value.id) return;
    palette = value;
    notifyListeners();
    await _storage.setPaletteId(value.id);
  }

  /// 24-hour vs 12-hour times (see TimeFormat).
  bool get use24h => TimeFormat.use24h;

  void setUse24h(bool value) {
    TimeFormat.use24h = value;
    _storage.setTime24h(value);
    notifyListeners();
  }

  void setShowClock(bool value) {
    showClock = value;
    _storage.setShowClock(value);
    notifyListeners();
  }

  void setLayoutMode(String mode) {
    layoutMode = mode;
    _storage.setLayoutMode(mode);
    notifyListeners();
  }

  /// 'auto' or a language code ('en', 'fr', 'es', 'it') (see L10n). Applied before `runApp` in main.dart;
  /// changing it here re-resolves the language and notifies, and main.dart
  /// remounts the home screen so every string is rebuilt.
  String get language => L10n.setting;

  Future<void> setLanguage(String value) async {
    await L10n.apply(value);
    await _storage.setLanguage(value);
    notifyListeners();
  }

  void setGuideViewMode(String mode) {
    guideViewMode = mode;
    _storage.setGuideViewMode(mode);
    notifyListeners();
  }

  void setGuideFullVideo(bool value) {
    guideFullVideo = value;
    _storage.setGuideFullVideo(value);
    notifyListeners();
  }

  void setHideMovies(bool value) {
    hideMovies = !AppConstants.onDemandEnabled || value;
    _storage.setHideMovies(value);
    notifyListeners();
  }

  void setHideShows(bool value) {
    hideShows = !AppConstants.onDemandEnabled || value;
    _storage.setHideShows(value);
    notifyListeners();
  }

  void setVideoFill(bool value) {
    videoFill = value;
    _storage.setVideoFill(value);
    notifyListeners();
  }

  void setHideArchive(bool value) {
    hideArchive = true;
    _storage.setHideArchive(value);
    notifyListeners();
  }

  void setHideMultiview(bool value) {
    hideMultiview = value;
    _storage.setHideMultiview(value);
    notifyListeners();
  }
}
