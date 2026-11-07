// Public catalogue metadata only; does not read playlists or preferences.
import 'dart:convert';
import 'package:nox_iptv/models/sports.dart';

void main() {
  // ignore: avoid_print
  print(jsonEncode([
    for (final league in [...kSportsLeagues, ...kSportsLeagueBank])
      {
        'id': league.id,
        'path': league.espnPath,
        'name': league.name,
        'kind': league.kind.name,
        'source': league.source,
        'soccer': league.soccer,
      }
  ]));
}
