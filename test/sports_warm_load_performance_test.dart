import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/services/sports_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('repeated warm all-league visits use no additional network requests',
      () async {
    var requests = 0;
    final service = SportsService.withClient(MockClient((_) async {
      requests++;
      return http.Response('{"events":[]}', 200);
    }));
    final leagues = kDefaultSportsLeagueIds
        .map(sportsLeagueById)
        .whereType<SportsLeague>()
        .where((l) => l.source == 'ESPN')
        .take(80)
        .toList();
    final day = DateTime.now();
    await service.gamesForDay(leagues, day);
    final coldRequests = requests;
    final watch = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      await service.gamesForDay(leagues, day);
    }
    watch.stop();
    expect(requests, coldRequests);
    // A diagnostic measurement, not a machine-dependent timing assertion.
    // ignore: avoid_print
    print(
        'SPORTS_WARM_LOAD leagues=${leagues.length} visits=100 requests=$coldRequests warm_us=${watch.elapsedMicroseconds}');
  });
}
