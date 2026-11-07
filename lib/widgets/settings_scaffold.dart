import 'settings_navigation.dart';
import 'settings_section.dart';
import 'settings_theme.dart';
export 'settings_theme.dart'
    show SettingsTheme, withSettingsTheme, showSettingsDialog;
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
    final workspace = SettingsNavigation.maybeOf(context);
    final canPop =
        (ModalRoute.of(context)?.canPop ?? false) || workspace != null;
    final scheme = base.colorScheme;
    final theme = SettingsTheme.resolve(context);
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
          toolbarHeight: SettingsTheme.isTelevision(context) ? 44 : 48,
          titleSpacing: canPop ? 4 : 16,
          leadingWidth: canPop ? 44 : 0,
          leading: Builder(
              builder: (context) => canPop
                  ? Center(
                      child: TvAppBarButton.icon(
                          icon: Icons.arrow_back,
                          tooltip: tr('Back'),
                          onTap: () {
                            if (ModalRoute.of(context)?.canPop ?? false) {
                              Navigator.of(context).maybePop();
                            } else {
                              workspace?.onExit(SettingsAction.live);
                            }
                          }))
                  : const SizedBox.shrink()),
          title: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge),
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
          allowSnapshotting: false,
          pageBuilder: (context, animation, secondaryAnimation) =>
              SettingsTheme(child: Builder(builder: builder)),
        );
}
