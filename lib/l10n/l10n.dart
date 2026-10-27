import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'es.dart';
import 'fr.dart';
import 'it.dart';

/// App-wide UI language. English strings in the code are the keys
/// (`tr('Settings')`); [_dictionaries] maps them to each other language
/// ([kFr], [kEs], [kIt]). A missing entry falls back to the English text, so
/// a forgotten string shows in English, never blank.
///
/// Deliberately not Flutter's gen-l10n: many strings live in services and
/// dialogs without a BuildContext, and English-as-key keeps the code readable.
/// The language is applied once at startup (before `runApp`) and again from
/// Settings > General, which remounts the UI so every screen rebuilds.
///
/// Adding a language: a dictionary file like fr.dart, an entry in
/// [_dictionaries] + [supportedLocales], a row in General settings'
/// `_languages`, and its words for [trSports] in [_sportsLanguages].
class L10n {
  L10n._();

  /// The setting: 'auto' (follow the device) or a language code.
  static String setting = 'auto';

  /// The resolved language actually in use: 'en', 'fr', 'es' or 'it'.
  static String code = 'en';

  static Locale get locale => Locale(code);

  static const supportedLocales = [
    Locale('en'),
    Locale('fr'),
    Locale('es'),
    Locale('it'),
  ];

  static bool _supported(String c) => c == 'en' || _dictionaries.containsKey(c);

  static Future<void> apply(String newSetting) async {
    setting = newSetting;
    final device = PlatformDispatcher.instance.locale.languageCode;
    code = _supported(newSetting)
        ? newSetting
        : (_supported(device) ? device : 'en');
    await initializeDateFormatting(code);
    Intl.defaultLocale = code;
  }
}

const Map<String, Map<String, String>> _dictionaries = {
  'fr': kFr,
  'es': kEs,
  'it': kIt,
};

/// Translate [en] into the current language. `{name}` placeholders are filled
/// from [args], e.g. `tr('Version {version}', {'version': v})`.
String tr(String en, [Map<String, Object?> args = const {}]) {
  var s = _dictionaries[L10n.code]?[en] ?? en;
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// Per-language words and ordinal style for [trSports].
class _SportsLanguage {
  const _SportsLanguage({
    required this.words,
    required this.ordinal,
    required this.overtime,
    required this.shootout,
  });

  final Map<String, String> words;

  /// "7" -> "7e" / "7.º" / "7º".
  final String Function(String n) ordinal;

  /// Word used after an ordinal: "2OT" -> "2e prol.", "2SO" -> "2e TB".
  final String overtime;
  final String shootout;
}

String _frOrdinal(String n) => n == '1' ? '1re' : '${n}e';
String _esOrdinal(String n) => '$n.º';
String _itOrdinal(String n) => '$nº';

const Map<String, _SportsLanguage> _sportsLanguages = {
  'fr': _SportsLanguage(
    ordinal: _frOrdinal,
    overtime: 'prol.',
    shootout: 'TB',
    words: {
      'Final': 'Fin',
      'Halftime': 'Mi-temps',
      'Half': 'demie',
      'Delayed': 'Retardé',
      'Rain Delay': 'Retard (pluie)',
      'Postponed': 'Reporté',
      'Canceled': 'Annulé',
      'Cancelled': 'Annulé',
      'Suspended': 'Suspendu',
      'Forfeit': 'Forfait',
      'End of': 'Fin',
      'End': 'Fin',
      'Top': 'Haut',
      'Bot': 'Bas',
      'Bottom': 'Bas',
      'Mid': 'Mil.',
      'Middle': 'Mil.',
      'OT': 'Prol.',
      'SO': 'TB',
      'FT': 'Fin',
      'HT': 'Mi-temps',
      'AET': 'Prol.',
      'Pens': 'TAB',
      'Intermission': 'Entracte',
      'Quarter': 'quart',
      'Period': 'période',
      'Inning': 'manche',
      // Golf / racing.
      'Round': 'Ronde',
      'Race': 'Course',
      'Qualifying': 'Qualifications',
      'Complete': 'Terminé',
      'In Progress': 'En cours',
      'Play Complete': 'Ronde terminée',
      'Scheduled': 'Prévu',
      'Lap': 'Tour',
    },
  ),
  'es': _SportsLanguage(
    ordinal: _esOrdinal,
    overtime: 'TE',
    shootout: 'pen.',
    words: {
      'Final': 'Final',
      'Halftime': 'Descanso',
      'Half': 'tiempo',
      'Delayed': 'Retrasado',
      'Rain Delay': 'Retraso (lluvia)',
      'Postponed': 'Aplazado',
      'Canceled': 'Cancelado',
      'Cancelled': 'Cancelado',
      'Suspended': 'Suspendido',
      'Forfeit': 'Abandono',
      'End of': 'Fin',
      'End': 'Fin',
      'Top': 'Alta',
      'Bot': 'Baja',
      'Bottom': 'Baja',
      'Mid': 'Mitad',
      'Middle': 'Mitad',
      'OT': 'TE',
      'SO': 'Pen.',
      'FT': 'Final',
      'HT': 'Descanso',
      'AET': 'Prórr.',
      'Pens': 'Pen.',
      'Intermission': 'Intermedio',
      'Quarter': 'cuarto',
      'Period': 'periodo',
      'Inning': 'entrada',
      // Golf / racing.
      'Round': 'Ronda',
      'Race': 'Carrera',
      'Qualifying': 'Clasificación',
      'Complete': 'Terminado',
      'In Progress': 'En curso',
      'Play Complete': 'Ronda terminada',
      'Scheduled': 'Programado',
      'Lap': 'Vuelta',
    },
  ),
  'it': _SportsLanguage(
    ordinal: _itOrdinal,
    overtime: 'suppl.',
    shootout: 'rig.',
    words: {
      'Final': 'Finale',
      'Halftime': 'Intervallo',
      'Half': 'tempo',
      'Delayed': 'Ritardata',
      'Rain Delay': 'Ritardo (pioggia)',
      'Postponed': 'Rinviata',
      'Canceled': 'Annullata',
      'Cancelled': 'Annullata',
      'Suspended': 'Sospesa',
      'Forfeit': 'Forfait',
      'End of': 'Fine',
      'End': 'Fine',
      'Top': 'Alto',
      'Bot': 'Basso',
      'Bottom': 'Basso',
      'Mid': 'Metà',
      'Middle': 'Metà',
      'OT': 'Suppl.',
      'SO': 'Rig.',
      'FT': 'Finale',
      'HT': 'Intervallo',
      'AET': 'd.t.s.',
      'Pens': 'Rig.',
      'Intermission': 'Intervallo',
      'Quarter': 'quarto',
      'Period': 'periodo',
      'Inning': 'inning',
      // Golf / racing.
      'Round': 'Giro',
      'Race': 'Gara',
      'Qualifying': 'Qualifiche',
      'Complete': 'Concluso',
      'In Progress': 'In corso',
      'Play Complete': 'Giro concluso',
      'Scheduled': 'In programma',
      'Lap': 'Giro',
    },
  ),
};

/// ESPN's English game statuses and standing lines ("Final/OT", "End of 2nd",
/// "Top 5th", "7th in Pacific Division") in the current language. Pattern
/// based, so an unknown status passes through untouched.
String trSports(String s) {
  final lang = _sportsLanguages[L10n.code];
  if (lang == null || s.isEmpty) return s;
  // "7th in Pacific Division" -> "7e – Pacific Division" (ties: "T-3rd in").
  var out = s.replaceFirstMapped(RegExp(r'^(T-)?(\d+)(st|nd|rd|th) in (the )?'),
      (m) => '${m[1] ?? ''}${m[2]}th – ');
  // "2OT" / "Final/2OT" -> "2e prol.", "2SO" -> "2e TB".
  out = out.replaceAllMapped(
      RegExp(r'\b(\d)(OT|SO)\b'),
      (m) => '${lang.ordinal(m[1]!)} '
          '${m[2] == 'OT' ? lang.overtime : lang.shootout}');
  out = out.replaceAllMapped(
      RegExp(r'\b(\d+)(st|nd|rd|th)\b'), (m) => lang.ordinal(m[1]!));
  out = out.replaceAllMapped(
      RegExp(r'\b(Rain Delay|End of|In Progress|Play Complete|'
          r'[A-Z][a-z]+|OT|SO|FT|HT|AET)\b'),
      (m) => lang.words[m[0]] ?? m[0]!);
  return out;
}

/// Picks the singular or plural English form by [n] (French treats 0 as
/// singular; Spanish and Italian, like English, only 1), then translates it.
/// `{n}` is filled with [n].
String trPlural(int n, String one, String other,
    [Map<String, Object?> args = const {}]) {
  final singular = L10n.code == 'fr' ? n.abs() < 2 : n == 1;
  return tr(singular ? one : other, {'n': n, ...args});
}
