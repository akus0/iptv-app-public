import '../utils/interface_colors.dart';
import 'package:flutter/material.dart';

/// Translucent grouping panel for related settings rows, retaining contrast over the shared
/// background.
class SettingsPanel extends StatelessWidget {
  const SettingsPanel(
      {super.key,
      required this.children,
      this.padding = const EdgeInsets.all(16)});

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // A row with its own solid focus fill (TvSwitchListTile, used with
      // zero padding here so it can sit flush against the panel edges)
      // would otherwise square off past these rounded corners.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: interfaceColor(context, Colors.white).withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: interfaceColor(context, Colors.white).withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: padding,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }
}
