import 'package:flutter/material.dart';

/// Translucent grouping panel for related settings rows, retaining contrast over the shared
/// background.
class SettingsPanel extends StatelessWidget {
  const SettingsPanel(
      {super.key,
      required this.children,
      this.padding = const EdgeInsets.all(12)});

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
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: .35),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: .65)),
      ),
      child: Padding(
        padding: padding,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }
}
