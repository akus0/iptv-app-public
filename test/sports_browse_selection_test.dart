import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/sports_browse_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final leagues = ['nhl', 'nba', 'eng.1', 'uefa.champions']
      .map((id) => sportsLeagueById(id)!)
      .toList();
  test('explicit league and sport beat an unrelated first-league fallback', () {
    expect(
        resolveSportsBrowseLeague(leagues, leagueId: 'nba', sport: 'basketball')
            ?.id,
        'nba');
    expect(
        resolveSportsBrowseLeague(leagues, sport: 'soccer', fallbackId: 'nhl')
            ?.id,
        'eng.1');
    expect(
        resolveSportsBrowseLeague(leagues,
                sport: 'soccer', fallbackId: 'uefa.champions')
            ?.id,
        'uefa.champions');
    expect(
        resolveSportsBrowseLeague(leagues,
                leagueId: 'removed', fallbackId: 'nba')
            ?.id,
        'nba');
  });
  test('browse selection survives storage reload without enabling any leagues',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final before = storage.getSportsLeagues();
    await storage.setSportsBrowseSelection('soccer', 'eng.1');
    final restored = StorageService();
    await restored.init();
    expect(restored.getSportsBrowseSelection(), ['soccer', 'eng.1']);
    expect(restored.getSportsLeagues(), before);
    await restored.setSportsBrowseSelection('racing', null);
    expect(restored.getSportsBrowseSelection(), ['racing', '']);
  });
}
