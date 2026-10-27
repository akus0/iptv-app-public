import 'package:flutter/material.dart';
import '../widgets/hold_to_activate.dart';

// Keep a closing dialog's origin guarded until its overlay has gone. The
// dialog itself is a different origin, so deliberate nested choices work.
final _dialogOrigins = Expando<bool>();

Future<T?> showGuardedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
}) async {
  if (!context.mounted) return null;
  final origin = ModalRoute.of(context);
  if (origin != null && !origin.isCurrent) return null;
  final key = origin ?? context;
  if (_dialogOrigins[key] == true) return null;
  _dialogOrigins[key] = true;
  try {
    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    final route = DialogRoute<T>(
      context: context,
      builder: (context) => SwallowHeldActivate(child: builder(context)),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor ??
          DialogTheme.of(context).barrierColor ??
          Colors.black54,
    );
    final result = await navigator.push(route);
    await route.completed;
    return result;
  } finally {
    _dialogOrigins[key] = null;
  }
}

/// Ignore queued taps from controls belonging to a route already closing.
bool popRouteIfCurrent<T>(BuildContext context, [T? result]) {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
    return false;
  }
  Navigator.of(context).pop<T>(result);
  return true;
}
