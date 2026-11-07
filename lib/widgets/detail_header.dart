import 'package:flutter/material.dart';

import '../utils/image_urls.dart';
import 'hd_network_image.dart';

/// Shared pieces of the series and movie detail pages
/// (`SeriesDetailScreen`, `MovieDetailScreen`): the pill buttons, metadata
/// chips, the fanart backdrop and the side poster — one look for both.

/// The app's standard focus look (see `_SelectableRow` in tv_home_screen):
/// black -> accent -> black diagonal sheen, `scheme.primary` border and a
/// soft glow. [selected] is the quieter persistent marker (active season,
/// favorited), [emphasized] the primary action's resting tint.
BoxDecoration detailFocusDecoration(
  ColorScheme scheme, {
  required bool focused,
  bool selected = false,
  bool emphasized = false,
  required double radius,
}) {
  return BoxDecoration(
    borderRadius: BorderRadius.circular(radius.clamp(3, 6)),
    color: focused
        ? scheme.primaryContainer
        : emphasized
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: .18), Colors.black)
            : Colors.black.withValues(alpha: .6),
    border: Border.all(
      color: focused
          ? scheme.primary
          : (selected || emphasized)
              ? scheme.primary.withValues(alpha: 0.75)
              : Colors.white24,
      width: focused ? 2.5 : 1.2,
    ),
    boxShadow: const [],
  );
}

class DetailPillButton extends StatefulWidget {
  const DetailPillButton({
    super.key,
    required this.focusNode,
    required this.onPressed,
    required this.scale,
    this.icon,
    this.label,
    this.emphasized = false,
    this.selected = false,
    this.compact = false,
    this.onFocused,
  });

  final FocusNode focusNode;
  final VoidCallback onPressed;
  final double scale;
  final IconData? icon;
  final String? label;
  final bool emphasized;
  final bool selected;
  final bool compact;
  final VoidCallback? onFocused;

  @override
  State<DetailPillButton> createState() => _DetailPillButtonState();
}

class _DetailPillButtonState extends State<DetailPillButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.scale;
    final radius = 22 * s;
    final fg = _focused
        ? scheme.onPrimaryContainer
        : widget.selected
            ? scheme.primary
            : Colors.white;
    final iconColor = _focused
        ? scheme.onPrimaryContainer
        : (widget.emphasized || widget.selected)
            ? scheme.primary
            : Colors.white;
    final label = widget.label;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        focusNode: widget.focusNode,
        borderRadius: BorderRadius.circular(radius.clamp(3, 6)),
        focusColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.white10,
        onTap: widget.onPressed,
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) widget.onFocused?.call();
        },
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: (label == null ? 9 : (widget.compact ? 14 : 18)) * s,
            vertical: (widget.compact ? 7 : 9) * s,
          ),
          decoration: detailFocusDecoration(scheme,
              focused: _focused,
              selected: widget.selected,
              emphasized: widget.emphasized,
              radius: radius),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null)
                Icon(widget.icon, size: 20 * s, color: iconColor),
              if (widget.icon != null && label != null) SizedBox(width: 6 * s),
              if (label != null)
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: (widget.compact ? 13 : 14.5) * s,
                    fontWeight:
                        (_focused || widget.selected || widget.emphasized)
                            ? FontWeight.bold
                            : FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class DetailMetaChip extends StatelessWidget {
  const DetailMetaChip({
    super.key,
    required this.scale,
    required this.label,
    this.leading,
    this.strong = false,
  });

  final double scale;
  final String label;
  final Widget? leading;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 3 * s),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6 * s),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, SizedBox(width: 3 * s)],
          Text(
            label,
            style: TextStyle(
              color: strong ? Colors.white : Colors.white70,
              fontSize: 12 * s,
              fontWeight: strong ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fanart, darkened toward the text side and faded into the black page.
/// Plain gradients only — no blur (weak Fire Sticks). Without a landscape
/// image it's just a faint accent wash (the poster shows beside the title).
/// HD via [HdNetworkImage]: decode capped at the box's physical width
/// (max 1920 on Android).
class DetailBackdrop extends StatelessWidget {
  const DetailBackdrop({super.key, required this.url, required this.fadeLeft});

  final String? url;
  final bool fadeLeft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = this.url;
    if (url == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.16), Colors.black),
              Colors.black,
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      return RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            HdSwapImage(
              url: url,
              kind: ImageKind.backdrop,
              decodeWidth:
                  HdNetworkImage.screenDecodeWidth(context, c.maxWidth),
              alignment: Alignment.topCenter,
              fadeInDuration: const Duration(milliseconds: 300),
            ),
            if (fadeLeft)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black,
                      Color(0xB3000000),
                      Color(0x00000000)
                    ],
                    stops: [0.0, 0.35, 0.75],
                  ),
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x33000000), Color(0x00000000), Colors.black],
                  stops: [0.0, 0.35, 1.0],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// The side poster shown when there is no landscape backdrop.
class DetailPoster extends StatelessWidget {
  const DetailPoster({super.key, required this.url, required this.width});

  final String url;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: width * 1.5,
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      clipBehavior: Clip.antiAlias,
      child: HdNetworkImage(
        url: url,
        kind: ImageKind.poster,
        decodeWidth:
            HdNetworkImage.cardDecodeWidth(context, width, oversample: 1),
        errorWidget: (_) =>
            const Icon(Icons.tv_rounded, color: Colors.white24, size: 40),
      ),
    );
  }
}
