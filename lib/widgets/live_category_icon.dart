import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'live_navigation_body.dart';

/// Preserve provider pictograms; generated folders use the same visual language.
/// These are local font glyphs, with no network requests or decoded logo cache.
class LiveCategoryIcon extends StatelessWidget {
  const LiveCategoryIcon(
      {super.key, required this.label, this.color, this.size = 20});
  final String label;
  final Color? color;
  final double size;

  static String? _symbol(String label) {
    final first = label.trimLeft().characters.firstOrNull;
    if (first != null) {
      final rune = first.runes.first;
      if (rune >= 0x1f000 || (rune >= 0x2600 && rune <= 0x27bf)) return first;
    }
    final s = label.toLowerCase();
    for (final (keyword, symbol) in const [
      ('australia', '🇦🇺'),
      ('new zealand', '🇳🇿'),
      ('united kingdom', '🇬🇧'),
      ('uk guide', '🇬🇧'),
      ('(uk)', '🇬🇧'),
      ('canada', '🇨🇦'),
      ('ireland', '🇮🇪'),
      ('usa', '🇺🇸'),
      ('us television', '🇺🇸'),
      ('us guide', '🇺🇸'),
      ('world tv', '🌍'),
      ('formula 1', '🏎️'),
      ('motorsport', '🏁'),
      ('rally', '🏁'),
      ('mxgp', '🏍️'),
      ('american football', '🏈'),
      ('college football', '🏈'),
      ('nfl', '🏈'),
      ('football', '⚽'),
      ('soccer', '⚽'),
      ('uefa', '⚽'),
      ('premier', '⚽'),
      ('basket', '🏀'),
      ('nba', '🏀'),
      ('baseball', '⚾'),
      ('mlb', '⚾'),
      ('hockey', '🏒'),
      ('nhl', '🏒'),
      ('rugby', '🏉'),
      ('tennis', '🎾'),
      ('golf', '⛳'),
      ('darts', '🎯'),
      ('pdc', '🎯'),
      ('volley', '🏐'),
      ('pool', '🎱'),
      ('ufc', '🥊'),
      ('fight', '🥊'),
      ('horse', '🏇'),
      ('cricket', '🏏'),
      ('college', '🎓'),
      ('league', '🏆'),
      ('sports channels', '📡'),
      ('sports', '🏆'),
      ('entertainment channels', '🤣'),
      ('entertainment', '🎭'),
      ('documentar', '🌍'),
      ('movie', '🎬'),
      ('series', '🎞️'),
      ('kids', '🧸'),
      ('news', '📰'),
      ('music', '🎵'),
      ('peacock', '🦚'),
      ('directv', '🥏'),
      ('sling', '🌀'),
      ('live events', '🎟️'),
      ('ppv', '🎟️'),
      ('local', '📡'),
      ('24/7', '♾️'),
      ('4k', '📺'),
      ('channels', '📺'),
    ]) {
      if (s.contains(keyword)) return symbol;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final nested = (LiveCategoryLevel.of(context)?.depth ?? 0) > 0;
    final extent = nested ? size - 2 : size;
    final ink = color ?? IconTheme.of(context).color ?? interfaceColor(context, Colors.white70);
    final symbol = _symbol(label);
    if (symbol != null) {
      return ExcludeSemantics(
          child: SizedBox(
              width: extent + 2,
              height: extent + 2,
              child: Center(
                  child: Text(symbol,
                      maxLines: 1,
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                          fontSize: extent, height: 1, color: ink)))));
    }
    final s = label.toLowerCase();
    for (final (keyword, badge) in const [
      ('espn', 'E+'),
      ('sky', 'SKY'),
      ('tnt', 'TNT'),
      ('dazn', 'DAZN'),
      ('bbc', 'BBC'),
    ]) {
      if (!s.contains(keyword)) continue;
      return ExcludeSemantics(
          child: Container(
              width: extent + 2,
              height: extent,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: ink.withValues(alpha: .45)),
                  color: ink.withValues(alpha: .05)),
              child: Text(badge,
                  maxLines: 1,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                      fontSize: badge.length > 3 ? 6.5 : 8,
                      fontWeight: FontWeight.w700,
                      color: ink,
                      height: 1))));
    }
    return Icon(Icons.live_tv_outlined, size: extent, color: ink);
  }
}
