import 'settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_theme.dart';

/// Shared focusable settings destination row. Custom leading and trailing widgets retain the
/// same focus treatment as the default icon and chevron.
class TvMenuTile extends StatefulWidget {
  const TvMenuTile({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.autofocus = false,
    this.enabled = true,
    this.focusNode,
    this.titleMaxLines,
    required this.onTap,
  }) : assert(icon != null || leading != null,
            'TvMenuTile needs either icon or leading');

  final IconData? icon;

  /// Overrides the default icon-in-a-circle built from [icon].
  final Widget? leading;
  final String title;
  final String? subtitle;

  /// Overrides the default chevron. Pass `SizedBox.shrink()` for no
  /// trailing content at all, rather than leaving this unset.
  final Widget? trailing;
  final bool autofocus;

  /// Same meaning as `ListTile.enabled` — dimmed, unfocusable, and
  /// [onTap] never fires (e.g. "this is already the active profile").
  final bool enabled;

  /// Lets a caller drive focus onto this specific row from outside —
  /// `autofocus` only fires once, on this Element's first build, so a
  /// caller that needs to re-focus a *specific* row later (e.g. the
  /// multiview channel picker re-focusing the first result after a group
  /// filter changes) needs a node it can call `.requestFocus()` on
  /// directly, same as `ModeButton`/`_SwitchToLinkedChannelButton`
  /// elsewhere in this app. Null (every existing caller) falls back to an
  /// owned, internal node, unchanged from before.
  final FocusNode? focusNode;

  /// Clamp for long titles (e.g. provider event-channel names); null = no
  /// limit, as before.
  final int? titleMaxLines;
  final VoidCallback onTap;

  @override
  State<TvMenuTile> createState() => _TvMenuTileState();
}

class _TvMenuTileState extends State<TvMenuTile> {
  bool _focused = false;

  /// Scrolls the least needed to show this tile once it has focus. D-pad
  /// moves already do this, but `autofocus` doesn't: a sheet opened on its
  /// selected entry (audio track 9 of 12) left the focus off screen.
  void _revealSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focused) return;
      Scrollable.ensureVisible(context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    });
  }

  void _activate() {
    if (!mounted || !widget.enabled) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          final key = event.logicalKey;
          if (event is KeyRepeatEvent &&
              (key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.gameButtonA)) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: _buildContent(context),
      );

  Widget _buildContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (SettingsScope.contains(context)) {
      // A remote focus change should repaint one row, not every tile in its
      // settings section. The explicit fill/border already show focus.
      return RepaintBoundary(
          child: Material(
        animationDuration: Duration.zero,
        color: _focused ? scheme.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(
                width: 1.5,
                color: _focused ? scheme.primary : Colors.transparent)),
        child: ListTile(
          dense: true,
          minTileHeight: 56,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          onFocusChange: (value) {
            setState(() => _focused = value);
            if (value) _revealSoon();
          },
          leading: widget.leading ??
              Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: .09),
                      borderRadius: BorderRadius.circular(5)),
                  child: Icon(widget.icon,
                      size: 19,
                      color: _focused
                          ? scheme.onPrimaryContainer
                          : scheme.primary)),
          title: Text(widget.title,
              maxLines: widget.titleMaxLines,
              overflow:
                  widget.titleMaxLines == null ? null : TextOverflow.ellipsis,
              style: TextStyle(
                  color: _focused ? scheme.onPrimaryContainer : null)),
          subtitle: widget.subtitle == null
              ? null
              : Text(widget.subtitle!,
                  style: TextStyle(
                      color: _focused
                          ? scheme.onPrimaryContainer.withValues(alpha: .85)
                          : scheme.onSurfaceVariant)),
          trailing: widget.trailing ??
              Icon(Icons.chevron_right,
                  size: 18, color: scheme.onSurfaceVariant),
          onTap: widget.enabled ? _activate : null,
        ),
      ));
    }
    // Flat focus fill; selection keeps a quieter accent outline.
    final focusForeground = scheme.onPrimaryContainer;
    return Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment just
      // below has the full story on why changing a focus widget's
      // ancestor shape between builds corrupts its FocusNode on real
      // hardware.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: _focused ? Border.all(color: scheme.primary, width: 2) : null,
        // Flat focus fill; selection keeps a quieter accent outline.
        gradient: _focused
            ? LinearGradient(
                colors: [scheme.primaryContainer, scheme.primaryContainer])
            : null,
        boxShadow: const [],
      ),
      // Flat focus fill; selection keeps a quieter accent outline.
      child: MinimalGlassFocus(
        active: false,
        borderRadius: 3,
        child: ListTile(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          onFocusChange: (f) {
            setState(() => _focused = f);
            if (f) _revealSoon();
          },
          leading: widget.leading ??
              CircleAvatar(
                backgroundColor: _focused
                    ? focusForeground.withValues(alpha: 0.2)
                    : scheme.primary.withValues(alpha: 0.16),
                // `scheme.tertiary` — a dedicated icon/symbol-glyph
                // accent, separate from the text/border/contour accent
                // (`focusForeground`) — see `buildPaletteColorScheme`'s
                // own doc comment for why (Habs: white contour/text,
                // blue icons).
                foregroundColor: scheme.tertiary,
                child: Icon(widget.icon),
              ),
          title: Text(widget.title,
              maxLines: widget.titleMaxLines,
              overflow:
                  widget.titleMaxLines == null ? null : TextOverflow.ellipsis,
              style: TextStyle(color: _focused ? focusForeground : null)),
          subtitle: widget.subtitle == null
              ? null
              : Text(
                  widget.subtitle!,
                  style: TextStyle(
                      color: _focused
                          ? focusForeground.withValues(alpha: 0.85)
                          : null),
                ),
          trailing: widget.trailing ??
              Icon(Icons.chevron_right,
                  color: _focused ? scheme.tertiary : null),
          onTap: widget.enabled ? _activate : null,
        ),
      ),
    );
  }
}
