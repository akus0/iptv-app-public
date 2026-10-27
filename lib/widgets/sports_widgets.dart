import '../utils/interface_colors.dart';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';
import '../models/sports.dart';
import 'hold_to_activate.dart';
import 'tv_menu_tile.dart';
import '../l10n/l10n.dart';

// Pieces shared by the Sports screen and its Standings / My Teams screens.

/// Follow / unfollow [team] (My Teams). True = the user confirmed the
/// change. Opened by a hold, so the held OK is swallowed.
Future<bool> showSportsFollowDialog(BuildContext context,
    {required SportsTeam team, required bool followed}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => SwallowHeldActivate(
      child: AlertDialog(
        backgroundColor: interfaceColor(context, const Color(0xFF15151A)),
        title: Row(
          children: [
            SportsLogo(
                url: team.logoUrl,
                size: 40,
                fallback: team.abbreviation,
                color: team.color),
            const SizedBox(width: 12),
            Flexible(child: Text(team.name)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TvMenuTile(
                autofocus: true,
                icon: followed ? Icons.star_border : Icons.star,
                title: followed ? tr('Unfollow') : tr('Follow'),
                subtitle: followed
                    ? tr('Remove from My Teams')
                    : tr('Add to My Teams — their games show first in {tab}',
                        {'tab': AppConstants.sportsTabName}),
                onTap: () => Navigator.of(context).pop(true),
              ),
              TvMenuTile(
                icon: Icons.close,
                title: tr('Cancel'),
                onTap: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
      this.color});
  final String? url;
  final double size;
  final String? fallback;
  final String? color;

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
          : CachedNetworkImage(
              // Dark-background variant first, the original if there's none.
              imageUrl: darkSrc ?? src,
              fit: BoxFit.contain,
              memCacheWidth: px,
              fadeInDuration: const Duration(milliseconds: 200),
              errorWidget: (_, __, ___) => darkSrc == null
                  ? initials
                  : CachedNetworkImage(
                      imageUrl: src,
                      fit: BoxFit.contain,
                      memCacheWidth: px,
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
        duration: const Duration(milliseconds: 120),
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
            duration: const Duration(milliseconds: 120),
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
                      : interfaceColor(context, Colors.white).withValues(alpha: 0.07)),
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
              Icon(Icons.sports_football, size: 18, color: interfaceColor(context, const Color(0xFFEF7777))),
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
/// desktop display (4K at 150 % = 2560 px) showed everything tiny, so wider
/// screens render the same layout at [_designWidth] and scale it up — the
/// whole screen grows together, like on the TV. Never shrinks (TV boxes and
/// smaller windows are untouched). Logos decode at the scaled density so
/// they stay sharp. Windows also gets Esc = Back here (no remote there).
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
    if (!Platform.isWindows) return content;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: content,
    );
  }
}

/// Windows has no remote Back button: a mouse-clickable back arrow before a
/// Sports screen's title. Kept out of D-pad traversal so the screens'
/// explicit zone navigation is unchanged. Nothing on Android.
class SportsBackButton extends StatelessWidget {
  const SportsBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ExcludeFocus(
        child: IconButton(
          tooltip: tr('Back'),
          icon: Icon(Icons.arrow_back, color: interfaceColor(context, Colors.white)),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

/// Desktop mouse arrows for horizontal card rows. Jump about one viewport per click and
/// omit the arrows from remote traversal. Other platforms render only child.
class SportsRowArrows extends StatefulWidget {
  const SportsRowArrows({
    super.key,
    required this.controller,
    required this.arrowAreaHeight,
    required this.child,
  });

  final ScrollController controller;

  /// Height (from the top) the arrows are centred in — the cards themselves,
  /// not the hint line below them.
  final double arrowAreaHeight;
  final Widget child;

  @override
  State<SportsRowArrows> createState() => _SportsRowArrowsState();
}

class _SportsRowArrowsState extends State<SportsRowArrows> {
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void didUpdateWidget(SportsRowArrows old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_update);
      widget.controller.addListener(_update);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted || !widget.controller.hasClients) return;
    final p = widget.controller.position;
    final left = p.pixels > p.minScrollExtent + 1;
    final right = p.pixels < p.maxScrollExtent - 1;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _page(int direction) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final p = c.position;
    c.jumpTo((p.pixels + direction * p.viewportDimension * 0.8)
        .clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  Widget _arrow(IconData icon, int direction) => ExcludeFocus(
        child: Material(
          color: Colors.black.withValues(alpha: 0.65),
          shape: CircleBorder(
              side: BorderSide(color: interfaceColor(context, Colors.white24), width: 1)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _page(direction),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, color: interfaceColor(context, Colors.white), size: 28),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return widget.child;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _update());
        return false;
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_canLeft)
            Positioned(
              left: 0,
              top: 0,
              height: widget.arrowAreaHeight,
              child: Center(child: _arrow(Icons.chevron_left, -1)),
            ),
          if (_canRight)
            Positioned(
              right: 0,
              top: 0,
              height: widget.arrowAreaHeight,
              child: Center(child: _arrow(Icons.chevron_right, 1)),
            ),
        ],
      ),
    );
  }
}
