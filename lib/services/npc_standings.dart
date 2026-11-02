import 'dart:typed_data';
import 'rugby_pass_standings.dart';
import 'sports_standings_service.dart';

/// NPC uses the shared validated public RugbyPass table adapter.
LeagueStandings parseNpcStandings((Uint8List, LeagueStandings, int) input) =>
    parseRugbyPassStandings((input.$1, input.$2, input.$3, 'rugby.270563'));
