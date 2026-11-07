import '../utils/interface_colors.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';

import '../utils/constants.dart';
import '../models/sports.dart';
import 'sports_header_controls.dart';
import 'hold_to_activate.dart';
import '../l10n/l10n.dart';

// Pieces shared by the Sports screen and its Standings / My Teams screens.

/// Follow / unfollow [team] (My Teams). True = the user confirmed the
/// change. Opened by a hold, so the held OK is swallowed.
Future<bool> showSportsFollowDialog(BuildContext context,
    {required SportsTeam team, required bool followed}) async {
  final confirmed = await showSportsChoices<bool>(context,
      title: team.name,
      selected: true,
      showSelection: false,
      choices: [
        SportsChoice(
            true,
            followed ? tr('Unfollow') : tr('Follow'),
            followed
                ? tr('Remove from My Teams')
                : tr('Add to My Teams — their games show first in {tab}',
                    {'tab': AppConstants.sportsTabName}),
            icon: followed ? Icons.star_border : Icons.star),
        SportsChoice(false, tr('Cancel'), '', icon: Icons.close),
      ]);
  return confirmed ?? false;
}

Color? sportsTeamColor(String? hex) {
  if (hex == null || hex.length != 6) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Team or league logo in a soft disc; initials on the team colour when
/// there's no logo (or it fails to load).
class SportsLogo extends StatelessWidget {
  const SportsLogo(
      {super.key,
      required this.url,
      required this.size,
      this.fallback,
      this.color,
      this.animate = true});
  final String? url;
  final double size;
  final String? fallback;
  final String? color;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final px = (size * dpr).round();
    final fetchPx = px < 64 ? 64 : (px > 200 ? 200 : px);
    final src = sportsLogoUrl(url, size: fetchPx);
    final darkSrc = sportsLogoUrl(sportsDarkLogoUrl(url), size: fetchPx);
    final initials = Center(
      child: Text(
        (fallback ?? '').length > 3
            ? fallback!.substring(0, 3)
            : (fallback ?? ''),
        style: TextStyle(
            color: interfaceColor(context, Colors.white),
            fontWeight: FontWeight.w800,
            fontSize: size * 0.32),
      ),
    );
    // A plain Image keeps the same disk/memory cache and error fallback without
    // installing fade controllers and placeholder subtrees for static logos.
    Widget staticImage(String url, Widget Function() fallback) => Image(
        image: ResizeImage.resizeIfNeeded(
            px, null, CachedNetworkImageProvider(url)),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) => fallback());
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: sportsTeamColor(color)
                ?.withValues(alpha: src == null ? 0.9 : 0.0) ??
            interfaceColor(context, const Color(0xFF2A2A30)),
      ),
      padding: EdgeInsets.all(size * 0.14),
      child: src == null
          ? initials
          : !animate
              ? staticImage(
                  darkSrc ?? src,
                  () => darkSrc == null
                      ? initials
                      : staticImage(src, () => initials))
              : CachedNetworkImage(
                  // Dark-background variant first, the original if there's none.
                  imageUrl: darkSrc ?? src,
                  fit: BoxFit.contain,
                  memCacheWidth: px,
                  fadeInDuration: const Duration(milliseconds: 200),
                  fadeOutDuration: const Duration(milliseconds: 200),
                  errorWidget: (_, __, ___) => darkSrc == null
                      ? initials
                      : CachedNetworkImage(
                          imageUrl: src,
                          fit: BoxFit.contain,
                          memCacheWidth: px,
                          fadeInDuration: const Duration(milliseconds: 200),
                          fadeOutDuration: const Duration(milliseconds: 200),
                          errorWidget: (_, __, ___) => initials,
                        ),
                ),
    );
  }
}

/// Flat focus fill shared with the guide. Kept as a Decoration gradient
/// so callers can retain their independent idle/selected background colour.
LinearGradient sportsFocusSheen(ColorScheme scheme) => LinearGradient(
      colors: [scheme.primaryContainer, scheme.primaryContainer],
    );

/// Pill used for league/day/option rows. Same language as `_SelectableRow`:
/// focused = sheen + thick accent contour + glow, selected = accent text +
/// faint contour (kept clearly quieter than focus — on the TV the two read
/// alike), idle = faint fill.
class SportsChip extends StatefulWidget {
  const SportsChip({
    super.key,
    required this.focusNode,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onFocus,
    this.logoUrl,
    this.icon,
    this.compact = false,
    this.dense = false,
    this.slim = false,
    this.selectedColor,
    this.moving = false,
    this.enabled = true,
  });

  final FocusNode focusNode;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFocus;
  final String? logoUrl;
  final IconData? icon;
  final bool compact;
  final bool dense;

  /// Tighter horizontal treatment for the phone filter row.
  final bool slim;
  final Color? selectedColor;

  /// "Move" mode (league reorder): arrows either side of the label.
  final bool moving;

  /// False = dimmed and skipped by the D-pad (e.g. the other league chips
  /// while one is being moved).
  final bool enabled;

  @override
  State<SportsChip> createState() => _SportsChipState();
}

class _SportsChipState extends State<SportsChip> {
  // Seeded from the node, and re-read when the node changes: a state that
  // inherits another node never gets the focus-lost callback, which left
  // stale "focused" outlines behind.
  late bool _focused = widget.focusNode.hasFocus;

  @override
  void didUpdateWidget(SportsChip old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      _focused = widget.focusNode.hasFocus;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.selectedColor ?? scheme.primary;
    final fg = _focused
        ? scheme.onPrimaryContainer
        : (widget.selected ? accent : interfaceColor(context, Colors.white));
    return Padding(
      padding: EdgeInsets.only(right: widget.dense ? 4 : 8),
      child: AnimatedOpacity(
        opacity: widget.enabled ? 1 : 0.35,
        duration: context.read<AppPreferences?>()?.isTelevision == true
            ? Duration.zero
            : const Duration(milliseconds: 120),
        child: InkWell(
          focusNode: widget.focusNode,
          canRequestFocus: widget.enabled,
          borderRadius: BorderRadius.circular(3),
          onTap: widget.enabled ? widget.onTap : null,
          onFocusChange: (f) {
            setState(() => _focused = f);
            if (f) widget.onFocus();
          },
          child: AnimatedContainer(
            duration: context.read<AppPreferences?>()?.isTelevision == true
                ? Duration.zero
                : const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(
                horizontal: widget.slim
                    ? 5
                    : widget.dense
                        ? 8
                        : (widget.compact ? 14 : 12),
                vertical: widget.dense ? 3 : 4),
            decoration: BoxDecoration(
              color: _focused
                  ? null
                  : (widget.selected
                      ? accent.withValues(alpha: .09)
                      : interfaceColor(context, Colors.white)
                          .withValues(alpha: 0.07)),
              gradient: _focused ? sportsFocusSheen(scheme) : null,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: _focused
                    ? scheme.primary
                    : (widget.selected
                        ? accent.withValues(alpha: 0.4)
                        : Colors.transparent),
                width: _focused ? 2.5 : 1,
              ),
              boxShadow: const [],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.moving)
                  Icon(Icons.chevron_left, size: 20, color: fg),
                if (widget.logoUrl != null) ...[
                  SportsLogo(url: widget.logoUrl, size: 24),
                  const SizedBox(width: 6),
                ] else if (widget.icon != null) ...[
                  Icon(widget.icon,
                      size: widget.slim
                          ? 13
                          : widget.dense
                              ? 15
                              : 18,
                      color: fg),
                  if (widget.label.isNotEmpty)
                    SizedBox(
                        width: widget.slim
                            ? 3
                            : widget.dense
                                ? 4
                                : 6),
                ],
                Flexible(
                    child: Text(widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: fg,
                            fontSize: widget.slim
                                ? 11.5
                                : widget.dense
                                    ? 12.5
                                    : 14,
                            fontWeight: widget.selected
                                ? FontWeight.w700
                                : FontWeight.w500))),
                if (widget.moving)
                  Icon(Icons.chevron_right, size: 20, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// RedZone shortcut using the same quiet rectangular control as league filters.
class RedZonePill extends StatefulWidget {
  const RedZonePill({
    super.key,
    required this.focusNode,
    required this.onTap,
    required this.onFocus,
    this.onHold,
  });

  final FocusNode focusNode;
  final VoidCallback onTap;
  final VoidCallback onFocus;

  /// Hold OK (or long-press): choose the RedZone channel.
  final VoidCallback? onHold;

  @override
  State<RedZonePill> createState() => _RedZonePillState();
}

class _RedZonePillState extends State<RedZonePill> {
  late bool _focused = widget.focusNode.hasFocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 8),
      child: HoldToActivate(
        onTap: widget.onTap,
        onHold: widget.onHold,
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(3),
          onTap: widget.onTap,
          onLongPress: widget.onHold,
          onFocusChange: (focused) {
            setState(() => _focused = focused);
            if (focused) widget.onFocus();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: _focused
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                  color: _focused ? scheme.primary : Colors.transparent,
                  width: 2),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.sports_football,
                  size: 18,
                  color: interfaceColor(context, const Color(0xFFEF7777))),
              const SizedBox(width: 6),
              Text('NFL RedZone',
                  style: TextStyle(
                      color: interfaceColor(context, Colors.white),
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The Sports screens were laid out for a TV (~960 logical px wide). A big
/// display can make content too small, so wider
/// screens render the same layout at [_designWidth] and scale it up — the
/// whole screen grows together, like on the TV. Never shrinks (TV boxes and
/// smaller windows are untouched). Logos decode at the scaled density so
/// they stay sharp.
class SportsScreenFrame extends StatelessWidget {
  const SportsScreenFrame({super.key, required this.child});

  final Widget child;

  static const double _designWidth = 1440;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final scale = (mq.size.width / _designWidth).clamp(1.0, 3.0);
    Widget content = child;
    if (scale > 1.0) {
      final size = mq.size / scale;
      content = FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: size,
          child: MediaQuery(
            data: mq.copyWith(
              size: size,
              devicePixelRatio: mq.devicePixelRatio * scale,
              padding: mq.padding / scale,
              viewPadding: mq.viewPadding / scale,
              viewInsets: mq.viewInsets / scale,
            ),
            child: child,
          ),
        ),
      );
    }
    return content;
  }
}
