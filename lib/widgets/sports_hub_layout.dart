import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';

bool sportsLandscape(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= 600 && size.width > size.height;
}

// Shared by the header and body so their column edges cannot drift apart.
double sportsPreviewWidth(double width) => (width * .38).clamp(276.0, 480.0);

/// Centre overlays in the same content column as the Sports hub. Portrait
/// keeps the full viewport; keyboard height never changes the column choice.
class SportsPopupRegion extends StatelessWidget {
  const SportsPopupRegion({
    super.key,
    required this.child,
    this.enabled = true,
    this.outerInset = 0,
  });
  final Widget child;
  final bool enabled;
  final double outerInset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final inset = (20 - outerInset).clamp(0.0, 20.0);
      final hubWidth = constraints.maxWidth - inset * 2;
      final beside = enabled &&
          sportsLandscape(context) &&
          hubWidth - sportsPreviewWidth(hubWidth) - 12 >= 300;
      return Padding(
          padding: beside
              ? EdgeInsets.only(
                  left: inset + sportsPreviewWidth(hubWidth) + 12, right: inset)
              : EdgeInsets.zero,
          child: child);
    });
  }
}

/// One layout for every Sports tab. Only the browsing pane
/// scrolls; the preview and its status remain in a stable left-hand column.
class SportsHubLayout extends StatelessWidget {
  const SportsHubLayout(
      {super.key,
      required this.header,
      required this.preview,
      required this.content,
      this.showPreview = true});
  final Widget header, preview, content;
  final bool showPreview;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 4),
          Expanded(child: LayoutBuilder(builder: (context, constraints) {
            if (!showPreview || !sportsLandscape(context)) {
              return Column(children: [preview, Expanded(child: content)]);
            }
            final width = sportsPreviewWidth(constraints.maxWidth);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  key: const ValueKey('sports-preview-column'),
                  width: width,
                  height: constraints.maxHeight,
                  child: preview),
              const SizedBox(width: 12),
              Expanded(child: ClipRect(child: content)),
            ]);
          })),
        ],
      );
}

/// Native pinned sliver, scoped by a SliverMainAxisGroup so the next sport
/// pushes it away when the last card in this section leaves the viewport.
class SportsPinnedHeading extends SliverPersistentHeaderDelegate {
  const SportsPinnedHeading({required this.child, required this.height});
  final Widget child;
  final double height;
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      ColoredBox(
          color: interfaceColor(context, const Color(0xFF171D25)),
          child: child);
  @override
  bool shouldRebuild(SportsPinnedHeading oldDelegate) =>
      height != oldDelegate.height || child != oldDelegate.child;
}
