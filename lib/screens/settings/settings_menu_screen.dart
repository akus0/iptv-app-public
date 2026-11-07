import '../../widgets/tv_app_bar_button.dart';
export '../../widgets/settings_navigation.dart' show SettingsAction;
import '../../widgets/settings_navigation.dart';
import '../../widgets/iptv_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../../services/app_preferences.dart';
import '../../services/additional_licenses.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../l10n/l10n.dart';

import 'general_settings_screen.dart';
import 'playlist_manager_screen.dart';
import 'theme_screen.dart';

import 'library_settings_screen.dart';

class SettingsMenuScreen extends StatelessWidget {
  const SettingsMenuScreen({super.key, this.includeTools = false});
  final bool includeTools;

  void _returnAction(BuildContext context, SettingsAction action) {
    if (ModalRoute.of(context)?.isCurrent == true) {
      final workspace = SettingsNavigation.maybeOf(context);
      if (workspace != null) {
        workspace.onExit(action);
      } else {
        Navigator.pop(context, action);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPreferences>();
    Widget link(IconData icon, String title, String subtitle, Widget page) =>
        TvMenuTile(
            autofocus: prefs.isTelevision && page is PlaylistManagerScreen,
            icon: icon,
            title: tr(title),
            subtitle: tr(subtitle),
            onTap: () => Navigator.of(context)
                .push(SettingsRoute(builder: (_) => page)));
    Widget action(IconData icon, String title, String subtitle,
            SettingsAction value) =>
        TvMenuTile(
            icon: icon,
            title: tr(title),
            subtitle: tr(subtitle),
            onTap: () => _returnAction(context, value));
    return withSettingsTheme(
        context,
        (context) => SettingsScaffold(
              title: tr('Settings'),
              actions: includeTools && prefs.isTelevision
                  ? [
                      TvAppBarButton.icon(
                          key: const ValueKey('settings-live'),
                          icon: Icons.live_tv_outlined,
                          tooltip: tr('Live TV'),
                          onTap: () =>
                              _returnAction(context, SettingsAction.live)),
                      TvAppBarButton.icon(
                          key: const ValueKey('settings-sports'),
                          icon: Icons.sports,
                          tooltip: tr('Sports'),
                          onTap: () =>
                              _returnAction(context, SettingsAction.sports)),
                    ]
                  : null,
              bottomNavigationBar: includeTools &&
                      !prefs.isTelevision &&
                      MediaQuery.sizeOf(context).width < 600
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: IptvBottomBar(
                          selected: 'settings',
                          onSelect: (value) {
                            if (value == 'movies' || value == 'series') {
                              _returnAction(
                                  context,
                                  value == 'movies'
                                      ? SettingsAction.movies
                                      : SettingsAction.shows);
                            }
                            if (value == 'live') {
                              _returnAction(context, SettingsAction.live);
                            }
                            if (value == 'sports') {
                              _returnAction(context, SettingsAction.sports);
                            }
                          }))
                  : null,
              body: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  children: [
                    SettingsSection(title: tr('Content'), children: [
                      link(
                          Icons.playlist_play,
                          'Playlists & guide',
                          'Channels, categories and programme listings',
                          const PlaylistManagerScreen()),
                      link(
                          Icons.video_library_outlined,
                          'Movies & series',
                          'Tabs, categories and on-demand browsing',
                          const LibrarySettingsScreen()),
                    ]),
                    SettingsSection(
                        title: tr('Playback & appearance'),
                        children: [
                          link(
                              Icons.tune,
                              'Playback & preferences',
                              'Startup, multiview, language and history',
                              const GeneralSettingsScreen()),
                          link(
                              Icons.display_settings_outlined,
                              'Appearance',
                              'OLED black, dark grey or light',
                              const ThemeScreen()),
                        ]),
                    if (includeTools && !prefs.hideMultiview)
                      SettingsSection(title: tr('Viewing tools'), children: [
                        action(
                            Icons.grid_view,
                            'Multiview',
                            'Watch live channels side by side',
                            SettingsAction.multiview),
                      ]),
                    SettingsSection(title: tr('App'), children: [
                      link(
                          Icons.info_outline,
                          'About iptv-app',
                          'Version, credits and open-source licences',
                          const AppInfoScreen()),
                      if (includeTools)
                        action(
                            Icons.power_settings_new,
                            'Disable and exit',
                            'Disable playlists and release this login',
                            SettingsAction.disableAndExit),
                    ]),
                  ]),
            ));
  }
}

class AppInfoScreen extends StatefulWidget {
  const AppInfoScreen({super.key});
  @override
  State<AppInfoScreen> createState() => _AppInfoScreenState();
}

class _AppInfoScreenState extends State<AppInfoScreen> {
  late final _version = PackageInfo.fromPlatform();

  @override
  void initState() {
    super.initState();
    registerAdditionalLicenses();
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
      title: tr('About iptv-app'),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        SettingsSection(title: 'iptv-app', children: [
          Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        tr('Live TV, sports, movies and series from your own playlists.'),
                        style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    FutureBuilder<PackageInfo>(
                        future: _version,
                        builder: (context, snapshot) => Text(
                            snapshot.hasData
                                ? 'Version ${snapshot.data!.version} · ${snapshot.data!.buildNumber}'
                                : tr('Version —'),
                            style: Theme.of(context).textTheme.bodySmall)),
                  ])),
          TvMenuTile(
              icon: Icons.code,
              title: tr('Open-source licences'),
              onTap: () => Navigator.of(context).push(SettingsRoute(
                  builder: (_) => const LicensePage(
                      applicationName: 'iptv-app',
                      applicationLegalese:
                          'Based on VesperTV by NoXqc and contributors. GPL-3.0.')))),
        ]),
        SettingsSection(title: tr('Credits'), children: [
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  tr('Based on VesperTV by NoXqc and contributors. Modified and distributed under GPL-3.0, without warranty. Channel content comes from your playlists. Programme listings and sports coverage depend on the available sources.'),
                  style: Theme.of(context).textTheme.bodySmall)),
        ]),
      ]));
}
