import 'package:flutter/material.dart';

/// Adapts legacy interface tokens while retaining their original dark palette.
/// Video surfaces and player overlays intentionally keep their own colours.
ColorScheme? _cachedScheme;
final _resolvedColors = <Color, Color>{};

Color interfaceColor(BuildContext context, Color dark) {
  final scheme = Theme.of(context).colorScheme;
  if (scheme.brightness == Brightness.dark) {
    if (scheme.surface == Colors.black &&
        dark.a > .9 &&
        dark.computeLuminance() < .045 &&
        (dark.r - dark.b).abs() < .15) {
      return scheme.surfaceContainerLow;
    }
    return dark;
  }
  if (!identical(scheme, _cachedScheme)) {
    _cachedScheme = scheme;
    _resolvedColors.clear();
  }
  return _resolvedColors.putIfAbsent(dark, () => _lightColor(scheme, dark));
}

Color _lightColor(ColorScheme scheme, Color dark) {
  final hsl = HSLColor.fromColor(dark);
  if (hsl.lightness < .38) {
    return Color.lerp(scheme.surface, scheme.surfaceContainerHighest,
            (hsl.lightness / .38).clamp(0.0, 1.0))!
        .withValues(alpha: dark.a);
  }
  if (hsl.saturation < .3) {
    return (hsl.lightness > .82 ? scheme.onSurface : scheme.onSurfaceVariant)
        .withValues(alpha: dark.a);
  }
  return hsl.withLightness(.36).toColor();
}
