import 'package:flutter/material.dart';

enum SettingsAction {
  live,
  sports,
  search,
  multiview,
  refresh,
  movies,
  shows,
  disableAndExit
}

/// Keeps app navigation separate from the settings pane's own page stack.
class SettingsNavigation extends InheritedWidget {
  const SettingsNavigation(
      {super.key, required this.onExit, required super.child});
  final ValueChanged<SettingsAction?> onExit;

  static SettingsNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsNavigation>();

  static void returnToApp(BuildContext context) {
    final workspace = maybeOf(context);
    if (workspace != null) {
      workspace.onExit(SettingsAction.live);
    } else {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  bool updateShouldNotify(SettingsNavigation oldWidget) =>
      onExit != oldWidget.onExit;
}
