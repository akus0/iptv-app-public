import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import 'settings_section.dart';

/// Compact settings styling also surrounds each route's State context, so
/// dialogs and controls constructed before the scaffold inherit the same theme.
class SettingsTheme extends StatelessWidget {
  const SettingsTheme({super.key, required this.child});
  final Widget child;
  static final _touch = Expando<ThemeData>();
  static final _tv = Expando<ThemeData>();

  static bool isTelevision(BuildContext context) =>
      Theme.of(context).extension<_SettingsDensity>()?.television ?? false;

  static ThemeData resolve(BuildContext context) {
    final base = Theme.of(context);
    final tv = context.watch<AppPreferences?>()?.isTelevision ?? false;
    if (base.extension<_SettingsDensity>()?.television == tv) return base;
    final cache = tv ? _tv : _touch;
    return cache[base] ??= _create(base, tv);
  }

  static ThemeData _create(ThemeData base, bool tv) {
    final scheme = base.colorScheme;
    ButtonStyle compactButton(ButtonStyle? style) =>
        (style ?? const ButtonStyle()).copyWith(
          textStyle: WidgetStatePropertyAll(base.textTheme.labelLarge
              ?.copyWith(fontSize: 12, fontWeight: FontWeight.w500)),
          minimumSize: const WidgetStatePropertyAll(Size(48, 34)),
          tapTargetSize: tv
              ? MaterialTapTargetSize.shrinkWrap
              : MaterialTapTargetSize.padded,
          iconSize: const WidgetStatePropertyAll(18),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
          animationDuration: Duration.zero,
        );
    return base.copyWith(
      extensions: [...base.extensions.values, _SettingsDensity(tv)],
      appBarTheme: base.appBarTheme.copyWith(
          toolbarHeight: tv ? 44 : 48,
          titleTextStyle: base.textTheme.titleLarge?.copyWith(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: compactButton(base.outlinedButtonTheme.style)),
      filledButtonTheme: FilledButtonThemeData(
          style: compactButton(base.filledButtonTheme.style)),
      textButtonTheme:
          TextButtonThemeData(style: compactButton(base.textButtonTheme.style)),
      iconTheme: base.iconTheme.copyWith(size: 18),
      iconButtonTheme: IconButtonThemeData(
          style: compactButton(base.iconButtonTheme.style).copyWith(
              minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
              padding: const WidgetStatePropertyAll(EdgeInsets.all(6)))),
      splashFactory: NoSplash.splashFactory,
      textTheme: base.textTheme.copyWith(
        titleLarge: base.textTheme.titleLarge
            ?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        titleMedium: base.textTheme.titleMedium
            ?.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 13),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13),
        bodySmall: base.textTheme.bodySmall?.copyWith(
            fontSize: 11.5, height: 1.35, color: scheme.onSurfaceVariant),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minTileHeight: tv ? 40 : 48,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        minLeadingWidth: 28,
        horizontalTitleGap: 12,
        titleTextStyle: base.textTheme.bodyLarge?.copyWith(
            fontSize: 13, color: scheme.onSurface, fontWeight: FontWeight.w500),
        subtitleTextStyle: base.textTheme.bodyLarge?.copyWith(
            fontSize: 11.5, height: 1.25, color: scheme.onSurfaceVariant),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: .5),
        labelStyle: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        helperStyle: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 36),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 36),
        floatingLabelStyle: TextStyle(color: scheme.primary, fontSize: 13),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
            fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface),
        contentTextStyle: base.textTheme.bodyMedium?.copyWith(
            fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      ),
      tabBarTheme: base.tabBarTheme.copyWith(
        labelStyle: base.textTheme.labelLarge
            ?.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: base.textTheme.labelLarge?.copyWith(fontSize: 12),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: scheme.outlineVariant.withValues(alpha: .6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      SettingsScope(child: Theme(data: resolve(context), child: child));
}

class _SettingsDensity extends ThemeExtension<_SettingsDensity> {
  const _SettingsDensity(this.television);
  final bool television;
  @override
  _SettingsDensity copyWith({bool? television}) =>
      _SettingsDensity(television ?? this.television);
  @override
  _SettingsDensity lerp(covariant _SettingsDensity? other, double t) =>
      t < .5 || other == null ? this : other;
}

Widget withSettingsTheme(BuildContext context, WidgetBuilder builder) =>
    SettingsTheme(child: Builder(builder: builder));

Future<T?> showSettingsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = false,
  bool barrierDismissible = true,
  AnimationStyle animationStyle = AnimationStyle.noAnimation,
}) =>
    showDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierDismissible: barrierDismissible,
      animationStyle: animationStyle,
      builder: (_) => SettingsTheme(child: Builder(builder: builder)),
    );
