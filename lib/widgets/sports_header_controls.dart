import 'package:provider/provider.dart';
import '../services/app_preferences.dart';
import '../utils/guarded_dialog.dart';
import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'sports_hub_layout.dart';

bool compactSportsPortrait(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width < 600 && size.height > size.width;
}

/// Use the same density on phones rotated into a short landscape viewport.
/// Larger tablets keep their normal touch spacing; text scaling still wins.
bool compactSportsControls(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return compactSportsPortrait(context) ||
      (sportsLandscape(context) && size.height < 600);
}

double sportsTouchControlHeight(BuildContext context) =>
    (compactSportsControls(context) ? 40.0 : 48.0).clamp(
        MediaQuery.textScalerOf(context).scale(12) * 1.25 + 12,
        double.infinity);

/// Compact schedule toolbar shared with its portrait header allocation.
double sportsScheduleControlHeight(BuildContext context,
        {bool television = false}) =>
    (television ? 34.0 : 36.0).clamp(
        MediaQuery.textScalerOf(context).scale(12) * 1.25 + 10,
        double.infinity);

double sportsFilterHeight(BuildContext context) {
  final portrait = compactSportsPortrait(context);
  final landscape = sportsLandscape(context);
  final scaler = MediaQuery.textScalerOf(context);
  final base = (portrait || landscape) && scaler.scale(12) <= 14
      ? (landscape ? 34.0 : 32.0)
      : 42.0;
  // The two text lines must fit at accessibility sizes too. Measure each
  // font independently so nonlinear text scaling is respected.
  final textHeight = (scaler.scale(9) * 1.2 +
          scaler.scale(portrait ? 11 : 11.5) * 1.15 +
          1 +
          6)
      .ceilToDouble();
  return textHeight > base ? textHeight : base;
}

Color sportsPopupBackground(BuildContext context) =>
    Theme.of(context).colorScheme.surface;
ShapeBorder sportsPopupShape(BuildContext context) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(6),
    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant));

class SportsPopupHeader extends StatelessWidget {
  const SportsPopupHeader(
      {super.key,
      required this.title,
      this.description,
      this.closeTooltip = 'Close',
      this.showClose = true});
  final String title;
  final String? description;
  final String closeTooltip;
  final bool showClose;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Tooltip(
                  message: title,
                  child: Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.15)))),
          if (showClose)
            SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                    tooltip: closeTooltip,
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.close_rounded,
                        size: 18,
                        color:
                            interfaceColor(context, const Color(0xFF9AA7B6))),
                    onPressed: () => popRouteIfCurrent(context))),
        ]),
        if (description != null)
          Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 8),
              child: Tooltip(
                  message: description!,
                  child: Text(description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: interfaceColor(
                              context, const Color(0xFF98A6B6)))))),
      ]);
}

/// A labelled value, rather than an ambiguous chip whose meaning disappears
/// after selection. Fixed insets keep TV focus from moving neighbouring text.
class SportsFilterButton extends StatelessWidget {
  const SportsFilterButton(
      {super.key,
      required this.caption,
      required this.value,
      required this.onTap,
      this.focusNode,
      this.onFocus,
      this.selected = false,
      this.liveLabel = false,
      this.minimumHeight = 0,
      this.tooltip,
      this.accent});
  final String caption, value;
  final String? tooltip;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final bool selected;
  final bool liveLabel;
  final double minimumHeight;
  final Color? accent;
  @override
  Widget build(BuildContext context) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
    return Tooltip(
        message: tooltip ?? '$caption: $value',
        child: SizedBox(
            height: sportsFilterHeight(context)
                .clamp(minimumHeight, double.infinity),
            child: TextButton(
              focusNode: focusNode,
              onFocusChange: (focused) {
                if (focused) onFocus?.call();
              },
              onPressed: onTap,
              style: ButtonStyle(
                animationDuration: Duration.zero,
                minimumSize: const WidgetStatePropertyAll(Size.zero),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                overlayColor:
                    WidgetStatePropertyAll(color.withValues(alpha: .08)),
                padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 8)),
                backgroundColor: WidgetStateProperty.resolveWith((s) => s
                        .contains(WidgetState.focused)
                    ? color.withValues(alpha: .22)
                    : selected
                        ? Color.alphaBlend(color.withValues(alpha: .045),
                            interfaceColor(context, const Color(0xFF1B232D)))
                        : interfaceColor(context, const Color(0xFF1B232D))),
                shape: WidgetStateProperty.resolveWith(
                    (s) => RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: BorderSide(
                            width: 1,
                            color: s.contains(WidgetState.focused)
                                ? color
                                : selected
                                    ? color.withValues(alpha: .24)
                                    : Colors.transparent))),
              ),
              child: Row(children: [
                Expanded(
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 9,
                              height: 1.2,
                              color: interfaceColor(
                                  context, const Color(0xFF96A3B1)))),
                      const SizedBox(height: 1),
                      Text.rich(_liveLabel(context, value, liveLabel),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize:
                                  compactSportsPortrait(context) ? 11 : 11.5,
                              height: 1.15,
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? color
                                  : interfaceColor(
                                      context, const Color(0xFFEAF0F6)))),
                    ])),
                const SizedBox(width: 2),
                Icon(Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: interfaceColor(context, const Color(0xFF96A3B1))),
              ]),
            )));
  }
}

/// Quiet utility group at the end of the filters. Keep fixed icon slots so
/// selection/focus never changes toolbar geometry or triggers extra layout.
class SportsToolbarActions extends StatelessWidget {
  const SportsToolbarActions({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
      key: const ValueKey('sports-toolbar-actions'),
      decoration: BoxDecoration(
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: .035),
          borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: children));
}

class SportsChoice<T> {
  const SportsChoice(this.value, this.title, this.description,
      {this.icon, this.key, this.liveLabel = false});
  final T value;
  final String title, description;
  final IconData? icon;
  final Key? key;
  final bool liveLabel;
}

TextSpan _liveLabel(BuildContext context, String value, bool enabled) =>
    enabled && value.startsWith('Live')
        ? TextSpan(children: [
            TextSpan(
                text: 'Live',
                style: TextStyle(
                    color: interfaceColor(context, const Color(0xFFFFA4A4)))),
            TextSpan(text: value.substring(4)),
          ])
        : TextSpan(text: value);

/// TV choices are discrete remote actions; route fades add a frame barrier
/// before a subsequent picker can open. Touch retains its platform transition.
Future<T?> showSportsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) =>
    showGuardedDialog<T>(
        context: context,
        barrierColor: Colors.transparent,
        animationStyle: context.read<AppPreferences?>()?.isTelevision == true
            ? AnimationStyle.noAnimation
            : null,
        builder: (context) => SportsPopupRegion(
            enabled: context.read<AppPreferences?>()?.isTelevision == true ||
                MediaQuery.sizeOf(context).width >= 700,
            child: builder(context)));

Future<T?> showSportsChoices<T>(
  BuildContext context, {
  required String title,
  required T selected,
  required List<SportsChoice<T>> choices,
  String? description,
  bool showSelection = true,
}) =>
    showSportsDialog<T>(
        context: context,
        builder: (context) => SimpleDialog(
              alignment: Alignment.center,
              backgroundColor: sportsPopupBackground(context),
              surfaceTintColor: Colors.transparent,
              shape: sportsPopupShape(context),
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              titlePadding: const EdgeInsets.fromLTRB(16, 4, 8, 2),
              contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              title: SizedBox(
                  width: 380,
                  child: SportsPopupHeader(
                      title: title, description: description)),
              children: [
                for (final choice in choices)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: ListTile(
                        key: choice.key,
                        autofocus: choice.value == selected ||
                            (!showSelection && choice == choices.first),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(3)),
                        selected: showSelection && choice.value == selected,
                        selectedTileColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: .08),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 10),
                        dense: true,
                        minLeadingWidth: 18,
                        horizontalTitleGap: 10,
                        minVerticalPadding: 5,
                        visualDensity: const VisualDensity(vertical: -3),
                        focusColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: .16),
                        leading: choice.icon == null
                            ? null
                            : Icon(choice.icon, size: 17),
                        title: Text.rich(
                            _liveLabel(context, choice.title, choice.liveLabel),
                            style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.25,
                                fontWeight: FontWeight.w600)),
                        subtitle: choice.description.isEmpty
                            ? null
                            : Text(choice.description,
                                style: TextStyle(
                                    fontSize: 11,
                                    height: 1.3,
                                    color: interfaceColor(
                                        context, const Color(0xFF99A7B7)))),
                        trailing: showSelection && choice.value != selected
                            ? const SizedBox(width: 17)
                            : Icon(
                                showSelection
                                    ? Icons.check_rounded
                                    : Icons.chevron_right_rounded,
                                size: 17,
                                color: showSelection
                                    ? Theme.of(context).colorScheme.primary
                                    : interfaceColor(context, Colors.white38)),
                        onTap: () => popRouteIfCurrent(context, choice.value),
                      ))
              ],
            ));

/// Matches the Sports toolbar density while retaining larger phone tap targets.
double sportsOptionHeight(BuildContext context) =>
    (context.read<AppPreferences?>()?.isTelevision == true
            ? 34.0
            : sportsTouchControlHeight(context))
        .clamp(MediaQuery.textScalerOf(context).scale(12) * 1.25 + 12,
            double.infinity);

class SportsOptionButton extends StatelessWidget {
  const SportsOptionButton(
      {super.key,
      required this.label,
      required this.selected,
      required this.onPressed,
      this.autofocus = false,
      this.compact = false,
      this.focusNode,
      this.icon,
      this.tooltip});
  final String label;
  final bool selected, autofocus, compact;
  final FocusNode? focusNode;
  final VoidCallback onPressed;
  final IconData? icon;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final button = TextButton(
        focusNode: focusNode,
        autofocus: autofocus,
        onPressed: onPressed,
        style: sportsPopupButtonStyle(context).copyWith(
            minimumSize: compact
                ? WidgetStatePropertyAll(
                    Size(0, sportsTouchControlHeight(context)))
                : null,
            foregroundColor: WidgetStatePropertyAll(
                selected ? colors.primary : colors.onSurfaceVariant),
            backgroundColor: WidgetStateProperty.resolveWith(
                (states) => colors.primary.withValues(
                    alpha: states.contains(WidgetState.focused)
                        ? .22
                        : selected
                            ? .12
                            : .025)),
            side: WidgetStateProperty.resolveWith((states) => BorderSide(
                color: states.contains(WidgetState.focused)
                    ? colors.primary
                    : selected
                        ? colors.primary.withValues(alpha: .25)
                        : Colors.transparent))),
        child: Semantics(
            selected: selected,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 15),
                const SizedBox(width: 6)
              ],
              Flexible(child: Text(label)),
            ])));
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

ButtonStyle sportsPopupButtonStyle(BuildContext context) =>
    TextButton.styleFrom(
        animationDuration: Duration.zero,
        minimumSize: Size(0, sportsOptionHeight(context)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)));

/// A bounded, content-sized popup with a stationary title and footer.
class SportsCompactDialog extends StatelessWidget {
  const SportsCompactDialog(
      {super.key,
      required this.title,
      required this.child,
      this.description,
      this.actions = const [],
      this.scrollController,
      this.closeTooltip = 'Close',
      this.maxWidth = 440,
      this.maxHeight = 440});
  final String title, closeTooltip;
  final String? description;
  final Widget child;
  final List<Widget> actions;
  final ScrollController? scrollController;
  final double maxWidth, maxHeight;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available = (media.size.height -
            media.viewInsets.bottom -
            media.padding.vertical -
            24)
        .clamp(0.0, maxHeight);
    final scroll =
        SingleChildScrollView(controller: scrollController, child: child);
    return Dialog(
        insetPadding: const EdgeInsets.all(12),
        backgroundColor: sportsPopupBackground(context),
        surfaceTintColor: Colors.transparent,
        shape: sportsPopupShape(context),
        child: ConstrainedBox(
            key: const ValueKey('sports-compact-dialog-surface'),
            constraints:
                BoxConstraints(maxWidth: maxWidth, maxHeight: available),
            child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SportsPopupHeader(
                          title: title,
                          description: description,
                          closeTooltip: closeTooltip),
                      Flexible(
                          child: scrollController == null
                              ? scroll
                              : Scrollbar(
                                  controller: scrollController,
                                  thumbVisibility: true,
                                  child: scroll)),
                      if (actions.isNotEmpty) ...[
                        Divider(
                            height: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withValues(alpha: .45)),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: actions),
                      ],
                    ]))));
  }
}
