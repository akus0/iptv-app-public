import '../utils/interface_colors.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Fast scanning needs text and a selection stripe, not programme controls.
/// Layout each visible label once; selection changes repaint the cached text.
/// The normal accessible, focusable guide returns as soon as the hold ends.
class GuideFastBrowseRow extends StatefulWidget {
  const GuideFastBrowseRow(
      {super.key,
      required this.text,
      required this.index,
      required this.selected,
      required this.height,
      this.label = false,
      this.left = 0,
      this.textInset = 10,
      this.fontSize = 12,
      this.topInset = 0,
      this.textWidth});
  final String text;
  final int index;
  final ValueListenable<int> selected;
  final double height, left;
  final double textInset, fontSize, topInset;
  final double? textWidth;
  final bool label;

  @override
  State<GuideFastBrowseRow> createState() => _GuideFastBrowseRowState();
}

class _GuideFastBrowseRowState extends State<GuideFastBrowseRow> {
  final _text = TextPainter(textDirection: TextDirection.ltr);
  int _textRevision = 0;

  void _updateText() {
    _textRevision++;
    _text
      ..text = TextSpan(
          text: widget.text,
          style: TextStyle(
              fontSize: widget.fontSize,
              height: 1.15,
              color: widget.label ? interfaceColor(context, Colors.white) : interfaceColor(context, Colors.white70),
              fontWeight: FontWeight.w400))
      ..maxLines = widget.label ? 2 : 1
      ..ellipsis = '…'
      ..textScaler = MediaQuery.textScalerOf(context)
      ..textDirection = Directionality.of(context);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateText();
  }

  @override
  void didUpdateWidget(GuideFastBrowseRow old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text ||
        old.label != widget.label ||
        old.fontSize != widget.fontSize) {
      _updateText();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
        label: widget.text,
        child: SizedBox(
            height: widget.height,
            child: CustomPaint(
                painter: _FastRowPainter(
                    text: _text,
                    textRevision: _textRevision,
                    index: widget.index,
                    selected: widget.selected,
                    left: widget.left,
                    textInset: widget.textInset,
                    topInset: widget.topInset,
                    textWidth: widget.textWidth,
                    accent: scheme.primary,
                    fill: scheme.primaryContainer))));
  }
}

class _FastRowPainter extends CustomPainter {
  _FastRowPainter(
      {required this.text,
      required this.textRevision,
      required this.index,
      required this.selected,
      required this.left,
      required this.textInset,
      required this.topInset,
      required this.textWidth,
      required this.accent,
      required this.fill})
      : super(repaint: selected);
  final TextPainter text;
  final int textRevision;
  final int index;
  final ValueListenable<int> selected;
  final double left;
  final double textInset, topInset;
  final double? textWidth;
  final Color accent, fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
        0, 2, size.width, (size.height - 4).clamp(0, double.infinity));
    final active = selected.value == index;
    canvas.drawRect(
        rect, Paint()..color = active ? fill : const Color(0x06FFFFFF));
    if (active) {
      canvas.drawRect(
          rect.deflate(.75),
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
    text.layout(
        maxWidth: (textWidth ?? size.width - textInset - 8)
            .clamp(0, double.infinity));
    text.paint(canvas,
        Offset(left + textInset, (size.height + topInset - text.height) / 2));
  }

  @override
  bool shouldRepaint(_FastRowPainter old) =>
      old.text != text ||
      old.textRevision != textRevision ||
      old.index != index ||
      old.selected != selected ||
      old.left != left ||
      old.textInset != textInset ||
      old.topInset != topInset ||
      old.textWidth != textWidth ||
      old.accent != accent ||
      old.fill != fill;
}
