import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_preferences.dart';
import '../../services/playlist_manager.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/tv_menu_tile.dart';
import '../../widgets/tv_switch_list_tile.dart';
import 'playlist_manager_screen.dart';

class LibrarySettingsScreen extends StatefulWidget {
  const LibrarySettingsScreen({super.key});
  @override
  State<LibrarySettingsScreen> createState() => _LibrarySettingsScreenState();
}

class _LibrarySettingsScreenState extends State<LibrarySettingsScreen> {
  bool _refreshing = false;
  String? _status;
  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _status = null;
    });
    try {
      await context
          .read<PlaylistManager>()
          .ensureLibraryCategories(refresh: true);
      if (mounted) setState(() => _status = 'Category lists updated.');
    } catch (_) {
      if (mounted) {
        setState(() => _status =
            'Could not reach every playlist. Your saved categories are kept.');
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPreferences>();
    return SettingsScaffold(
        title: 'Movies & series',
        body: ListView(padding: const EdgeInsets.all(12), children: [
          SettingsSection(title: 'Tabs in the app', children: [
            TvSwitchListTile(
                title: const Text('Show Movies tab'),
                value: !prefs.hideMovies,
                onChanged: (v) => prefs.setHideMovies(!v)),
            TvSwitchListTile(
                title: const Text('Show Series tab'),
                value: !prefs.hideShows,
                onChanged: (v) => prefs.setHideShows(!v)),
          ]),
          SettingsSection(title: 'Content & updates', children: [
            TvMenuTile(
                icon: Icons.playlist_play,
                title: 'Choose content in your playlists',
                subtitle:
                    'Choose Movies, Series and visible categories per playlist.',
                onTap: () => Navigator.of(context).push(SettingsRoute(
                    builder: (_) => const PlaylistManagerScreen()))),
            TvMenuTile(
                icon: Icons.refresh,
                title:
                    _refreshing ? 'Updating categories…' : 'Refresh categories',
                subtitle: _status ??
                    'Find new movie and series categories from your Xtream playlists.',
                enabled: !_refreshing,
                onTap: _refresh),
          ]),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                  'Titles load as you browse. Refresh a category in Movies or Series to find new titles.',
                  style: Theme.of(context).textTheme.bodySmall)),
        ]));
  }
}
