import 'settings_section.dart';
import 'package:flutter/material.dart';

import 'tv_app_bar_button.dart';
import '../l10n/l10n.dart';

/// Shared flat background and quiet app bar for settings and related screens.
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold(
      {super.key,
      required this.title,
      required this.body,
      this.actions,
      this.bottom,
      this.bottomNavigationBar});

  final String title;
  final Widget body;
  final Widget? bottomNavigationBar;
  final List<Widget>? actions;

  /// For screens that need a TabBar in the app bar (Group Management) —
  /// kept optional since most Settings screens don't.
  final PreferredSizeWidget? bottom;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final scheme = base.colorScheme;
    final theme = base.copyWith(
      splashFactory: NoSplash.splashFactory,
      textTheme: base.textTheme.copyWith(
        titleLarge: base.textTheme.titleLarge
            ?.copyWith(fontSize: wide ? 21 : 19, fontWeight: FontWeight.w600),
        titleMedium: base.textTheme.titleMedium
            ?.copyWith(fontSize: wide ? 16 : 14, fontWeight: FontWeight.w500),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: wide ? 15 : 14),
        bodyMedium:
            base.textTheme.bodyMedium?.copyWith(fontSize: wide ? 14 : 13),
        bodySmall: base.textTheme.bodySmall?.copyWith(
            fontSize: 12, height: 1.4, color: scheme.onSurfaceVariant),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        minLeadingWidth: 28,
        horizontalTitleGap: 12,
        titleTextStyle: base.textTheme.bodyLarge?.copyWith(
            fontSize: wide ? 15 : 14,
            color: scheme.onSurface,
            fontWeight: FontWeight.w500),
        subtitleTextStyle: base.textTheme.bodyLarge?.copyWith(
            fontSize: 12, height: 1.35, color: scheme.onSurfaceVariant),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: .5),
        floatingLabelStyle: TextStyle(color: scheme.primary, fontSize: 13),
      ),
      tabBarTheme: base.tabBarTheme.copyWith(
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: scheme.outlineVariant.withValues(alpha: .6),
      ),
    );
    return SettingsScope(
        child: Theme(
      data: theme,
      child: Scaffold(
        bottomNavigationBar: bottomNavigationBar,
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: wide ? 56 : 50,
          titleSpacing: canPop ? 4 : 16,
          leadingWidth: canPop ? 56 : 0,
          leading: Builder(
              builder: (context) => ModalRoute.of(context)?.canPop ?? false
                  ? Center(
                      child: TvAppBarButton.icon(
                          icon: Icons.arrow_back,
                          tooltip: tr('Back'),
                          onTap: () => Navigator.of(context).pop()))
                  : const SizedBox.shrink()),
          title: Text(title, style: theme.textTheme.titleLarge),
          actions: actions,
          bottom: bottom,
        ),
        body: SafeArea(
            top: false,
            child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1040),
                    child: body))),
      ),
    ));
  }
}

/// Standalone so [GroupManagementScreen] (which needs its own `PopScope`
/// wrapping the whole `Scaffold`, not just this background) can paint the
/// identical gradient without going through [SettingsScaffold] itself.
class SettingsGradientBackground extends StatelessWidget {
  const SettingsGradientBackground({super.key});

  @override
  Widget build(BuildContext context) => const _SettingsGradientBackground();
}

class _SettingsGradientBackground extends StatelessWidget {
  const _SettingsGradientBackground();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: Theme.of(context).colorScheme.surface);
  }
}

class SettingsRoute<T> extends PageRouteBuilder<T> {
  SettingsRoute({required WidgetBuilder builder})
      : super(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        );
}
