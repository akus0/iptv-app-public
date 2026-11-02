import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_preferences.dart';

/// Category-only hierarchy; primary navigation keeps its own density.
class LiveCategoryLevel extends InheritedWidget {
  const LiveCategoryLevel(
      {super.key,
      required this.depth,
      required this.folder,
      required super.child});
  final int depth;
  final bool folder;
  static LiveCategoryLevel? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveCategoryLevel>();
  @override
  bool updateShouldNotify(LiveCategoryLevel oldWidget) =>
      depth != oldWidget.depth || folder != oldWidget.folder;
}

/// Shared sizing for natural Live TV rows and the virtual library list.
class LiveNavigationMetrics {
  LiveNavigationMetrics(BuildContext context,
      {required bool nested, required bool collapsed}) {
    final tv = context.read<AppPreferences?>()?.isTelevision ?? false;
    final size = MediaQuery.sizeOf(context);
    final landscape = !tv && size.width > size.height;
    minHeight = collapsed
        ? (tv ? 36 : 32)
        : nested
            ? (tv
                ? 35
                : landscape
                    ? 32
                    : 40)
            : landscape
                ? 34
                : 40;
    fontSize = nested
        ? (tv
            ? 12
            : landscape
                ? 11
                : 11.5)
        : tv
            ? 13
            : landscape
                ? 11.5
                : 12;
    verticalPadding = nested ? 4 : 5;
  }
  late final double minHeight, fontSize, verticalPadding;

  TextStyle labelStyle({required bool emphasized}) => TextStyle(
      fontSize: fontSize,
      height: 1.15,
      fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500);

  double measureHeight(BuildContext context,
      {required String label,
      required double width,
      required bool emphasized,
      String? subtitle,
      double trailingWidth = 0,
      required double leadingHeight}) {
    final painter = TextPainter(
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: subtitle == null ? 2 : 1,
        ellipsis: '…',
        text: TextSpan(
            text: label,
            style: DefaultTextStyle.of(context)
                .style
                .merge(labelStyle(emphasized: emphasized))))
      ..layout(
          maxWidth: math.max(
              1,
              width -
                  3 -
                  14 -
                  22 -
                  7 -
                  (trailingWidth == 0 ? 0 : trailingWidth + 5)));
    var textHeight = painter.height;
    if (subtitle != null) {
      painter.text = TextSpan(
          text: subtitle,
          style: DefaultTextStyle.of(context)
              .style
              .merge(const TextStyle(fontSize: 10, height: 1.1)));
      painter.maxLines = 1;
      painter.layout(
          maxWidth: math.max(
              1,
              width -
                  3 -
                  14 -
                  22 -
                  7 -
                  (trailingWidth == 0 ? 0 : trailingWidth + 5)));
      textHeight += painter.height;
    }
    painter.dispose();
    return math.max(minHeight,
        math.max(leadingHeight, textHeight) + verticalPadding * 2 + 3);
  }
}

/// Shared flat styling for category, folder and primary navigation rows.
/// Focus changes only paint a fill/border; no animated size, blur or shadow.
class LiveNavigationBody extends StatelessWidget {
  const LiveNavigationBody(
      {super.key,
      required this.label,
      required this.leading,
      required this.collapsed,
      required this.focused,
      required this.selected,
      this.trailing,
      this.subtitle});
  final String label;
  final String? subtitle;
  final Widget leading;
  final Widget? trailing;
  final bool collapsed, focused, selected;
  @override
  Widget build(BuildContext context) {
    final level = LiveCategoryLevel.of(context);
    final nested = level != null && level.depth > 0;
    final folder = level?.folder ?? false;
    final metrics =
        LiveNavigationMetrics(context, nested: nested, collapsed: collapsed);
    final scheme = Theme.of(context).colorScheme;
    final ink = focused
        ? scheme.onPrimaryContainer
        : selected
            ? scheme.primary
            : scheme.onSurface;
    final content = Container(
        constraints: BoxConstraints(minHeight: metrics.minHeight),
        decoration: BoxDecoration(
            color: focused
                ? scheme.primaryContainer
                : selected
                    ? scheme.primary.withValues(alpha: .09)
                    : folder
                        ? scheme.onSurface
                            .withValues(alpha: nested ? .025 : .045)
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
                color: focused ? scheme.primary : Colors.transparent,
                width: 1.5)),
        child: Stack(alignment: Alignment.centerLeft, children: [
          if (selected && !focused)
            Positioned(
                left: 0,
                top: 8,
                bottom: 8,
                child: Container(width: 2, color: scheme.primary)),
          Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: collapsed ? 1 : 7,
                  vertical: metrics.verticalPadding),
              child: IconTheme(
                  data: IconThemeData(
                      size: 18,
                      color:
                          focused || selected ? ink : scheme.onSurfaceVariant),
                  child: collapsed
                      ? Center(child: leading)
                      : Row(children: [
                          SizedBox(width: 22, child: Center(child: leading)),
                          const SizedBox(width: 7),
                          Expanded(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(label,
                                    maxLines: subtitle == null ? 2 : 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: metrics
                                        .labelStyle(
                                            emphasized:
                                                selected || focused || folder)
                                        .copyWith(
                                            color: nested &&
                                                    !focused &&
                                                    !selected &&
                                                    !folder
                                                ? ink.withValues(alpha: .85)
                                                : ink)),
                                if (subtitle != null)
                                  Text(subtitle!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 10,
                                          height: 1.1,
                                          color: ink.withValues(alpha: .65))),
                              ])),
                          if (trailing != null) ...[
                            const SizedBox(width: 5),
                            trailing!
                          ],
                        ]))),
        ]));
    return Tooltip(message: collapsed ? label : '', child: content);
  }
}
