import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final viewer in [AppConstants.mainViewerId, 'saved-viewer']) {
    test('upgrade retains existing saved data namespace: $viewer', () async {
      SharedPreferences.setMockInitialValues({});
      final before = StorageService();
      await before.init();
      await before.setActiveViewerId(viewer);
      await before.setFavorites({'playlist:channel'});
      await before.setFavoriteSeries({'playlist:series'});
      await before.setLastPosition('playlist:episode', 123000);
      await before.setHiddenGroups('playlist', {'Hidden group'});
      final restored = StorageService();
      await restored.init();
      expect(restored.getActiveViewerId(), viewer);
      expect(restored.getFavorites(), {'playlist:channel'});
      expect(restored.getFavoriteSeries(), {'playlist:series'});
      expect(restored.getLastPosition('playlist:episode'), 123000);
      expect(restored.getHiddenGroups('playlist'), {'Hidden group'});
      await restored.setActiveViewerId('another-viewer');
      expect(restored.getFavorites(), isEmpty);
      expect(restored.getLastPosition('playlist:episode'), 0);
    });
  }
}
