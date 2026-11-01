import '../utils/guarded_dialog.dart';
import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';
import 'sports_hub_layout.dart';

bool compactSportsPortrait(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width < 600 && size.height > size.width;
}

double sportsFilterHeight(BuildContext context) =>
    (compactSportsPortrait(context) || sportsLandscape(context)) &&
            MediaQuery.textScalerOf(context).scale(12) <= 14
        ? (sportsLandscape(context) ? 34 : 32)
        : 42;

Color sportsPopupBackground(BuildContext context) =>
    Theme.of(context).colorScheme.surface;
ShapeBorder sportsPopupShape(BuildContext context) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(6),
    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant));

class SportsPopupHeader extends StatelessWidget {
  const SportsPopupHeader({super.key, required this.title, this.description});
  final String title;
  final String? description;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.15))),
          SizedBox(
              width: 36,
              height: 36,
              child: IconButton(
                  tooltip: 'Close',
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.close_rounded,
                      size: 18,
                      color: interfaceColor(context, const Color(0xFF9AA7B6))),
                  onPressed: () => popRouteIfCurrent(context))),
        ]),
        if (description != null)
          Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 8),
              child: Text(description!,
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color:
                          interfaceColor(context, const Color(0xFF98A6B6))))),
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
      this.accent});
  final String caption, value;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final bool selected;
  final bool liveLabel;
  final Color? accent;
  @override
  Widget build(BuildContext context) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
    return Tooltip(
        message: '$caption: $value',
        child: SizedBox(
            height: sportsFilterHeight(context),
            child: TextButton(
              focusNode: focusNode,
              onFocusChange: (focused) {
                if (focused) onFocus?.call();
              },
              onPressed: onTap,
              style: ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size.zero),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                overlayColor:
                    WidgetStatePropertyAll(color.withValues(alpha: .08)),
                padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 6)),
                backgroundColor: WidgetStateProperty.resolveWith((s) => s
                        .contains(WidgetState.focused)
                    ? color.withValues(alpha: .22)
                    : selected
                        ? Color.alphaBlend(color.withValues(alpha: .045),
                            interfaceColor(context, const Color(0xFF1D252F)))
                        : interfaceColor(context, const Color(0xFF1D252F))),
                shape: WidgetStateProperty.resolveWith((s) =>
                    RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(3),
                        side: BorderSide(
                            width: 1,
                            color: s.contains(WidgetState.focused)
                                ? color
                                : selected
                                    ? color.withValues(alpha: .24)
                                    : interfaceColor(
                                        context, const Color(0xFF303A46))))),
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
                    size: 13, color: interfaceColor(context, Colors.white38)),
              ]),
            )));
  }
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

Future<T?> showSportsChoices<T>(
  BuildContext context, {
  required String title,
  required T selected,
  required List<SportsChoice<T>> choices,
  String? description,
  bool showSelection = true,
}) =>
    showGuardedDialog<T>(
        context: context,
        builder: (context) => SimpleDialog(
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
