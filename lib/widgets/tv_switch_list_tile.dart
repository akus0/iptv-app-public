import 'settings_section.dart';
import 'package:flutter/material.dart';

import '../utils/tv_theme.dart';

/// A `SwitchListTile` with an obvious solid-fill focus highlight — see
/// `SettingsMenuScreen`'s `_MenuTile` for why the stock widget's own
/// focus overlay isn't enough on a TV: it's a translucent tint blended
/// under the label, which stays subtle no matter how strong the color.
class TvSwitchListTile extends StatefulWidget {
  const TvSwitchListTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<TvSwitchListTile> createState() => _TvSwitchListTileState();
}

class _TvSwitchListTileState extends State<TvSwitchListTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = SettingsScope.contains(context);
    // Flat focus fill; selection keeps a quieter accent outline.
    final focusForeground = scheme.onPrimaryContainer;
    return Container(
      // Always present (even with an empty shadow list) rather than
      // conditionally wrapped — MinimalGlassFocus's own doc comment below
      // has the full story on why changing a focus widget's ancestor
      // shape between builds corrupts its FocusNode on real hardware.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: settings
            ? Border.all(
                color: _focused ? scheme.primary : Colors.transparent,
                width: 1.5)
            : _focused
                ? Border.all(color: scheme.primary, width: 2)
                : null,
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
            animationDuration: Duration.zero,
            child: SwitchListTile(
              contentPadding: settings
                  ? const EdgeInsets.symmetric(horizontal: 12, vertical: 2)
                  : EdgeInsets.zero,
              onFocusChange: (f) => setState(() => _focused = f),
              title: DefaultTextStyle.merge(
                style: TextStyle(color: _focused ? focusForeground : null),
                child: widget.title,
              ),
              subtitle: widget.subtitle == null
                  ? null
                  : DefaultTextStyle.merge(
                      style: TextStyle(
                          color: _focused
                              ? focusForeground.withValues(alpha: 0.85)
                              : null),
                      child: widget.subtitle!,
                    ),
              value: widget.value,
              onChanged: widget.onChanged,
            )),
      ),
    );
  }
}
