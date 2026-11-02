import '../models/sports.dart';

final _unknownTime =
    RegExp(r'\b(TBD|TBA)\b|to be (determined|announced)', caseSensitive: false);
final _changedFixture =
    RegExp(r'postpon|cancel|suspend|delay', caseSensitive: false);

bool sportsFixtureHasUnknownTime(SportsGame game) =>
    _unknownTime.hasMatch(game.statusText);

/// Ordinary pregame provider strings often contain a foreign timezone. Views
/// render the local kickoff separately while retaining meaningful exceptions.
String sportsFixtureStatus(SportsGame game) =>
    game.state != GameState.pre || _changedFixture.hasMatch(game.statusText)
        ? game.statusText
        : sportsFixtureHasUnknownTime(game)
            ? 'Time to be confirmed'
            : 'Scheduled';
