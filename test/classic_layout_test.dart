import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('existing installs adopt the live layout without losing source data',
      () async {
    SharedPreferences.setMockInitialValues({
      AppConstants.keyPaletteId: 'dark_gold',
      AppConstants.keyGuideViewMode: 'live',
      AppConstants.keyM3uUrl: 'https://example.test/my-playlist.m3u',
    });
    final storage = StorageService();
    await storage.init();
    expect(storage.getPaletteId(), 'classic_tv');
    expect(storage.getGuideViewMode(), 'timeline');
    expect(storage.getGuideFullVideo(), isFalse);
    expect(storage.getHideMovies(), isFalse);
    expect(storage.getHideShows(), isFalse);
    expect(storage.getHideArchive(), isTrue);
    expect(storage.getHideMultiview(), isFalse);
    expect(storage.getResumeLastChannelAtStartup(), isFalse);
    expect(storage.getResumeLastChannelInGuide(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConstants.keyM3uUrl),
        'https://example.test/my-playlist.m3u');
  });

  test('subsequent launches preserve changes made in Settings', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await storage.setPaletteId('minimal');
    await storage.setHideMovies(false);
    await storage.setGuideViewMode('live');
    await storage.setGuideFullVideo(true);
    await storage.setResumeLastChannelAtStartup(true);
    final reopened = StorageService();
    await reopened.init();
    expect(reopened.getPaletteId(), 'minimal');
    expect(reopened.getHideMovies(), isFalse);
    expect(reopened.getGuideViewMode(), 'live');
    expect(reopened.getGuideFullVideo(), isTrue);
    expect(reopened.getResumeLastChannelAtStartup(), isTrue);
  });
}
