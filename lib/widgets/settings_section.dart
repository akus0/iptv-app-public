import 'package:flutter/material.dart';

class SettingsScope extends InheritedWidget {
  const SettingsScope({super.key, required super.child});
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>() != null;
  @override
  bool updateShouldNotify(SettingsScope oldWidget) => false;
}

class SettingsSection extends StatelessWidget {
  const SettingsSection(
      {super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 7),
            child: Text(title,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant))),
        DecoratedBox(
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .35),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: .65))),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                    height: 1,
                    indent: 12,
                    endIndent: 12,
                    color: scheme.outlineVariant.withValues(alpha: .45)),
              children[i],
            ]
          ]),
        ),
      ]),
    );
  }
}
