import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import 'hold_to_activate.dart';
import 'sports_hub_layout.dart';

final _panelOrigins = Expando<bool>();

/// Keeps Sports and its preview mounted behind a bounded, instant overlay.
/// Embedded content owns its close action and result; Back and barrier taps
/// respect its PopScope, including screens that return immediately saved edits.
Future<T?> showSportsPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 600,
  double maxHeight = 760,
  bool barrierDismissible = true,
  bool besidePreview = false,
  bool fullWidth = false,
}) async {
  assert(maxWidth > 0 && maxHeight > 0);
  if (!context.mounted) return null;
  final origin = ModalRoute.of(context);
  if (origin != null && !origin.isCurrent) return null;
  final originKey = origin ?? context;
  if (_panelOrigins[originKey] == true) return null;
  _panelOrigins[originKey] = true;
  try {
    final navigator = Navigator.of(context, rootNavigator: true);
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    final television = context.read<AppPreferences>().isTelevision;
    final route = RawDialogRoute<T>(
      settings: const RouteSettings(name: 'sports-panel'),
      transitionDuration: Duration.zero,
      barrierDismissible: barrierDismissible,
      barrierColor: Colors.transparent,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      requestFocus: true,
      pageBuilder: (context, animation, secondaryAnimation) => themes.wrap(
        SwallowHeldActivate(
          child: SafeArea(
            minimum: const EdgeInsets.all(12),
            child: Padding(
              padding: MediaQuery.viewInsetsOf(context),
              child: SportsPopupRegion(
                enabled: !fullWidth &&
                    (television ||
                        (besidePreview &&
                            MediaQuery.sizeOf(context).width >= 700)),
                outerInset: 12,
                child: LayoutBuilder(builder: (context, constraints) {
                  final width = maxWidth.clamp(0.0, constraints.maxWidth);
                  final height = maxHeight.clamp(0.0, constraints.maxHeight);
                  return Align(
                    alignment: Alignment.center,
                    child: SizedBox(
                      key: const ValueKey('sports-panel-surface'),
                      width: width,
                      height: height,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        elevation: 0,
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant),
                        ),
                        // Feedback belongs above this route's barrier. A root
                        // snackbar leaves actions such as Undo inaccessible.
                        child: ScaffoldMessenger(
                          child: Scaffold(
                            backgroundColor: Colors.transparent,
                            resizeToAvoidBottomInset: false,
                            body: Builder(builder: builder),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
    final result = await navigator.push(route);
    await route.completed;
    return result;
  } finally {
    _panelOrigins[originKey] = null;
  }
}
