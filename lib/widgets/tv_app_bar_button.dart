import 'package:flutter/material.dart';

import '../utils/tv_theme.dart';

/// Toolbar action with a clear focus-only fill. Shared by settings Back actions and explicit
/// Edit/Delete/Done controls.
class TvAppBarButton extends StatefulWidget {
  const TvAppBarButton.icon({
    super.key,
    required IconData this.icon,
    required this.onTap,
    this.tooltip,
    this.focusNode,
  }) : label = null;

  const TvAppBarButton.label({
    super.key,
    required String this.label,
    required this.onTap,
    this.tooltip,
    this.focusNode,
  }) : icon = null;

  final IconData? icon;
  final String? label;
  final String? tooltip;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<TvAppBarButton> createState() => _TvAppBarButtonState();
}

class _TvAppBarButtonState extends State<TvAppBarButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Flat focus fill; selection keeps a quieter accent outline.
    final focusForeground = scheme.onPrimaryContainer;
    final isIcon = widget.icon != null;
    final shape = isIcon ? const CircleBorder() : const StadiumBorder();
    final focusedShape = isIcon
        ? CircleBorder(side: BorderSide(color: scheme.primary, width: 2))
        : StadiumBorder(side: BorderSide(color: scheme.primary, width: 2));

    // `scheme.tertiary` — a dedicated icon/symbol-glyph accent, separate
    // from the text/border/gradient accent (`focusForeground`) — see
    // `buildPaletteColorScheme`'s own doc comment for why (Habs: white
    // contour/text, blue icons).
    Widget content = isIcon
        ? Icon(widget.icon, color: _focused ? focusForeground : scheme.onSurface)
        : Text(widget.label!,
            style: TextStyle(
                color: _focused ? focusForeground : scheme.onSurface,
                fontWeight: FontWeight.w600));

    Widget button = Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment below
      // has the full story on why changing a focus widget's ancestor
      // shape between builds corrupts its FocusNode on real hardware.
      decoration: BoxDecoration(
        shape: isIcon ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isIcon ? null : BorderRadius.circular(20),
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
        borderRadius: isIcon ? 24 : 20,
        child: Material(
          color: Colors.transparent,
          shape: _focused ? focusedShape : shape,
          child: InkWell(
            focusNode: widget.focusNode,
            customBorder: shape,
            onTap: widget.onTap,
            onFocusChange: (f) => setState(() => _focused = f),
            child: Padding(
              padding: isIcon
                  ? const EdgeInsets.all(10)
                  : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: content,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}
