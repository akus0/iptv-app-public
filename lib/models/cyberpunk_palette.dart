import 'package:flutter/material.dart';

/// A curated duo-tone accent pair for the TV UI — deliberately two distinct
/// hues (primary + secondary) rather than Material's single-seed tonal
/// ramp, which can't represent "purple *and* magenta" as two intentional
/// accents at once.
class CyberpunkPalette {
  const CyberpunkPalette({
    required this.id,
    required this.label,
    required this.primary,
    required this.secondary,
    this.isMinimal = false,
    this.highlight,
    this.trueBlack = false,
    this.vivid = false,
  });

  /// A seeded duo-tone palette (gradient background like Neon Purple) whose
  /// [primary] is used as-is instead of `ColorScheme.fromSeed`'s tone — the
  /// seeded tone of a neon green is a soft mint. Dark text sits on it.
  final bool vivid;

  /// Stored in prefs — stable even if [label] wording changes later.
  final String id;
  final String label;

  /// Focus border/gradient/text accent, for every palette except
  /// [isMinimal] ones, where these stay reserved for the app
  /// wordmark specifically (see `_TvTopBar`) rather than the theme's own
  /// derived `ColorScheme.primary`, which [withTvThemeIfNeeded]
  /// substitutes a neutral white for instead.
  final Color primary;

  /// Secondary accent for gradients, badges and icons. Highlight palettes keep icon colours
  /// distinct from their primary focus accents.
  final Color secondary;

  /// Optional third color for palettes that need one — always the middle
  /// stop of the wordmark and swatch gradients. Habs uses white here so
  /// the wordmark itself is red, white and blue — but, unlike an earlier
  /// version of this palette, [highlight] no longer replaces the theme's
  /// own `ColorScheme.primary`/`.tertiary` (the focus border/gradient/
  /// text every screen reads): that made the gradient-sheen focus
  /// treatment blend toward white instead of Habs' actual red, and read
  /// as "a lot of white" generally. [primary] now drives the focus
  /// border/gradient/text directly for every palette, [highlight] stays
  /// purely the wordmark/swatch decoration. Null for every palette that
  /// doesn't need a third color.
  final Color? highlight;

  /// True for the single "Minimalist" palette: flat black backgrounds
  /// (no duo-tone gradient) and a translucent white "glass" focus style
  /// instead of every other palette's solid, saturated fill — see
  /// [withTvThemeIfNeeded] and `SettingsGradientBackground`. [primary]/
  /// [secondary] are still real colors on this palette (not black/white)
  /// specifically so the wordmark keeps its own accent regardless of
  /// which palette is active.
  final bool isMinimal;

  /// Preserve explicit palette accents instead of HCT-derived tones and use a flat background
  /// where the palette requires it.
  final bool trueBlack;
}
