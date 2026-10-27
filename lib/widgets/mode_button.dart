import 'settings_section.dart';
import 'package:flutter/material.dart';

import '../utils/tv_theme.dart';

/// One focusable target per option with normal document-order traversal. Distinguish actual
/// keyboard focus from the persistent selected state.
class ModeButton extends StatefulWidget {
  const ModeButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.focusNode,
  });

  final IconData? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<ModeButton> createState() => _ModeButtonState();
}

class _ModeButtonState extends State<ModeButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Flat focus fill; selection keeps a quieter accent outline.
    final focusForeground = scheme.onPrimaryContainer;
    final borderSide = _focused
        ? BorderSide(color: scheme.primary, width: 2)
        : BorderSide(
            color: widget.selected ? scheme.primary : scheme.outline,
            width: widget.selected ? 1.5 : 1);
    return Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment has
      // the full story on why changing a focus widget's ancestor shape
      // between builds corrupts its FocusNode on real hardware; the same
      // rule applies here, one level up.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
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
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3),
            side: borderSide,
          ),
          child: InkWell(
            focusNode: widget.focusNode,
            borderRadius: BorderRadius.circular(3),
            onTap: widget.onTap,
            onFocusChange: (f) => setState(() => _focused = f),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[
                    // `scheme.tertiary` — a dedicated icon/symbol-glyph
                    // accent, separate from the text/border/gradient
                    // accent (`focusForeground`) — see
                    // `buildPaletteColorScheme`'s own doc comment for why
                    // (Habs: white contour/text, blue icons).
                    Icon(widget.icon,
                        size: 18, color: _focused ? scheme.tertiary : null),
                    const SizedBox(width: 8),
                  ],
                  if (SettingsScope.contains(context))
                    Flexible(
                        child: Text(widget.label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: _focused ? focusForeground : null)))
                  else
                    Text(widget.label,
                        style: TextStyle(
                            color: _focused ? focusForeground : null)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
