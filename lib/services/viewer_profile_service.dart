import 'package:flutter/material.dart';

import '../models/viewer_profile.dart';
import '../widgets/pin_pad.dart';
import 'playback_service.dart';
import 'playlist_manager.dart';
import 'storage_service.dart';

/// Owns viewer-profile CRUD and the switch sequence — see `ViewerProfile`'s
/// doc comment for the feature. Depends on `PlaylistManager`/
/// `PlaybackService` to apply a switch's effects on catalog/playback state;
/// neither of those depends back on this class (see `PlaylistManager`'s own
/// doc comment on why).
class ViewerProfileService extends ChangeNotifier {
  ViewerProfileService(
      this._storage, this._playlistManager, this._playbackService) {
    _profiles = _storage.getViewerProfiles();
    _activeId = _storage.getActiveViewerId();
    // Catches an impossible-but-cheap-to-guard-against state: an active id
    // that doesn't match any stored profile (a prefs key half-written by a
    // killed process, say). Falling back to Main is the same safe default
    // `_activeViewerIsRestricted` in `PlaylistManager` uses.
    if (!_profiles.any((p) => p.id == _activeId)) {
      _activeId = ViewerProfile.mainId;
    }
  }

  final StorageService _storage;
  final PlaylistManager _playlistManager;
  final PlaybackService _playbackService;

  late List<ViewerProfile> _profiles;
  late String _activeId;

  List<ViewerProfile> get profiles => List.unmodifiable(_profiles);

  ViewerProfile get active => _profiles.firstWhere((p) => p.id == _activeId,
      orElse: ViewerProfile.main);

  // Retain the active storage namespace when upgrading, without exposing profiles.
  bool get isActiveRestricted => false;

  Future<void> _persist() => _storage.setViewerProfiles(_profiles);

  /// Creates a new profile — does not switch to it or prompt for a PIN;
  /// the caller (`ProfilesScreen`'s Add Profile flow) runs [setupPinFlow]
  /// first when [isRestricted] is true (a restricted profile must never
  /// exist without a PIN already set to get out of it), then calls
  /// [switchTo] itself afterward with its own `BuildContext`/`mounted`
  /// handling, rather than this method holding a context across its own
  /// `await` gaps on the caller's behalf.
  Future<ViewerProfile> createProfile(
      {required String name,
      required int colorIndex,
      required bool isRestricted}) async {
    final profile = ViewerProfile(
      id: 'vp${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      colorIndex: colorIndex,
      isRestricted: isRestricted,
      createdAt: DateTime.now(),
    );
    _profiles = [..._profiles, profile];
    await _persist();
    notifyListeners();
    return profile;
  }

  Future<void> renameProfile(String id, String name) async {
    _profiles =
        _profiles.map((p) => p.id == id ? p.copyWith(name: name) : p).toList();
    await _persist();
    notifyListeners();
  }

  /// Refuses Main and the currently-active profile outright — switch away
  /// first. Removes every one of this profile's own storage keys
  /// ([StorageService.deleteViewerData]) and its recently-played cache
  /// file, in addition to the profile entry itself.
  Future<bool> deleteProfile(String id) async {
    if (id == ViewerProfile.mainId || id == _activeId) return false;
    _profiles = _profiles.where((p) => p.id != id).toList();
    await _persist();
    await _storage.deleteViewerData(id);
    await _storage.deleteCacheFile('recently_played_vp_$id');
    notifyListeners();
    return true;
  }

  /// The actual profile switch. Order matters throughout:
  /// 1. A restricted *current* profile needs the PIN before leaving, no
  ///    matter what the target is — a kid picking "Main" from the switcher
  ///    is exactly the case this whole feature exists to gate.
  /// 2. Playback stops (and saves its final position) *before* the active
  ///    viewer id changes — `PlaybackService.stop`'s teardown awaits that
  ///    write, so switching immediately after a stopped video can't land
  ///    the position under the wrong viewer.
  /// 3. The new id is persisted, then [PlaylistManager.applyActiveViewer]
  ///    and [PlaybackService.reloadForViewer] re-derive everything else
  ///    (favorites, hidden groups, recently-played) from storage — no
  ///    network access, so a switch is fast regardless of catalog size.
  /// 4. `notifyListeners()` here is what a `Consumer<ViewerProfileService>`
  ///    further up the tree (see `main.dart`) actually reacts to — without
  ///    it, nothing would ever know to remount the home screen for the
  ///    newly-active viewer, no matter what key it's built with.
  ///
  /// Returns false if a required PIN check failed/was cancelled, or if
  /// [targetId] isn't an id this service actually has — the switch never
  /// happened in either case.
  Future<bool> switchTo(BuildContext context, String targetId) async {
    if (targetId == _activeId) return true;
    if (!_profiles.any((p) => p.id == targetId)) return false;
    if (active.isRestricted) {
      final unlocked = await promptForPin(context);
      if (!unlocked) return false;
    }
    await _playbackService.stop();
    _activeId = targetId;
    await _storage.setActiveViewerId(targetId);
    _playlistManager.applyActiveViewer();
    await _playbackService.reloadForViewer();
    notifyListeners();
    return true;
  }

  /// Gate every Settings entry through the restricted-profile PIN check. Controls that alter
  /// visibility outside Settings must enforce the same restriction at their own entry points.
  Future<bool> requireUnlock(BuildContext context) async {
    if (!isActiveRestricted) return true;
    return promptForPin(context);
  }
}
