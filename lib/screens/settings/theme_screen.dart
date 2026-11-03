import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_preferences.dart';
import '../../utils/constants.dart';
import '../../utils/tv_theme.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/tv_menu_tile.dart';

class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPreferences>();
    return SettingsScaffold(
        title: 'Themes',
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                    'Choose your appearance. The layout adapts automatically to your phone or TV.')),
            SettingsSection(title: 'Appearance', children: [
              for (final palette in AppConstants.cyberpunkPalettes)
                Builder(builder: (context) {
                  final scheme =
                      buildPaletteColorScheme(palette, Brightness.dark);
                  final selected = prefs.palette.id == palette.id;
                  return TvMenuTile(
                    title: palette.label,
                    subtitle: switch (palette.id) {
                      'oled' => 'True black surfaces · soft blue accents',
                      'light' => 'Soft white surfaces · deep blue accents',
                      _ =>
                        'Our original look · slate surfaces and cool blue accents',
                    },
                    leading: Container(
                        width: 46,
                        height: 34,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: scheme.outline)),
                        child: Row(children: [
                          Container(width: 7, color: scheme.primary),
                          const SizedBox(width: 4),
                          Expanded(
                              child: Column(children: [
                            Expanded(
                                child: Container(
                                    color: scheme.surfaceContainerHighest)),
                            const SizedBox(height: 3),
                            Container(
                                height: 3, color: scheme.onSurfaceVariant),
                          ])),
                        ])),
                    trailing: Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                        size: 21,
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline),
                    onTap: () => prefs.setPalette(palette),
                  );
                }),
            ]),
          ],
        ));
  }
}
