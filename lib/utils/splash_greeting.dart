import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import 'constants.dart';

/// The small kind word under the logo on the splash — a compliment, as
/// positive reinforcement — one per cold start,
/// cycling through [bank] in order (wraps at the end). A new greeting =
/// one line here plus its fr/es/it entries in lib/l10n.
class SplashGreeting {
  static const bank = [
    'Hey beautiful Human',
    'Welcome back, legend',
    'You have great taste',
    'Looking sharp today',
    'You make this place better',
    'Hey superstar',
    'You deserve this break',
    "You're doing amazing",
    'Hello, wonderful you',
    'Smart choice, as always',
    'You light up the room',
    "Keep shining, you've got this",
    'You earned some fun today',
    'The world is better with you in it',
    'Hey champ, welcome in',
  ];

  static String _text = bank.first;

  /// Translated greeting for this launch.
  static String get text => tr(_text);

  /// Called once in main(), before runApp: picks this launch's greeting
  /// and stores the next one's index.
  static Future<void> pickNext(SharedPreferences prefs) async {
    final i = (prefs.getInt(AppConstants.keySplashGreeting) ?? 0) % bank.length;
    _text = bank[i];
    await prefs.setInt(AppConstants.keySplashGreeting, (i + 1) % bank.length);
  }
}
