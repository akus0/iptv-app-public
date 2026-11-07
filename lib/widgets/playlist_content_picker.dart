import 'settings_theme.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist_profile.dart';
import '../services/playlist_manager.dart';
import 'tv_switch_list_tile.dart';

Future<void> choosePlaylistContent(
    BuildContext context, PlaylistProfile profile) async {
  final result = await pickPlaylistContent(context,
      live: profile.includeLive,
      movies: profile.includeMovies,
      series: profile.includeSeries);
  if (result == null || !context.mounted) return;
  await context.read<PlaylistManager>().setPlaylistContent(profile.id,
      live: result.$1, movies: result.$2, series: result.$3);
}

/// Shared choice dialog; new-playlist forms keep its result local until Save.
Future<(bool, bool, bool)?> pickPlaylistContent(BuildContext context,
        {required bool live, required bool movies, required bool series}) =>
    showSettingsDialog<(bool, bool, bool)>(
        context: context,
        useRootNavigator: false,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Text('Content from this playlist'),
                    scrollable: true,
                    titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    content: SizedBox(
                        width: 430,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TvSwitchListTile(
                              title: const Text('Live TV'),
                              subtitle:
                                  const Text('Channels and programme guide'),
                              value: live,
                              onChanged: (v) => update(() => live = v)),
                          TvSwitchListTile(
                              title: const Text('Movies'),
                              subtitle: const Text('On-demand films'),
                              value: movies,
                              onChanged: (v) => update(() => movies = v)),
                          TvSwitchListTile(
                              title: const Text('Series'),
                              subtitle: const Text('Seasons and episodes'),
                              value: series,
                              onChanged: (v) => update(() => series = v)),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: live || movies || series
                              ? () =>
                                  Navigator.pop(context, (live, movies, series))
                              : null,
                          child: const Text('Save')),
                    ])));
