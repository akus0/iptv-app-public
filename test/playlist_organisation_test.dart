import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/utils/live_category_folders.dart';

Iterable<M3uGroup> leaves(List<LiveCategoryNode> nodes) sync* {
  for (final node in nodes) {
    if (node.group != null) yield node.group!;
    yield* leaves(node.children);
  }
}

Iterable<M3uGroup> originalGroups(List<LiveCategoryNode> nodes) =>
    leaves(nodes).expand((g) => g is LiveCategoryCollection ? g.sources : [g]);

void main() {
  test('legacy choices resolve without changing curated or raw layouts', () {
    final curated = [
      for (final title in [
        'TV Guide (UK)',
        'TV Guide (US)',
        'UK FORMULA 1 PPV'
      ])
        M3uGroup(title: title, playlistId: 'p', channels: []),
    ];
    final raw = [M3uGroup(title: 'UK GENERAL', playlistId: 'p', channels: [])];
    expect(resolveLiveCategoryLayout('auto', curated), 'organised');
    expect(resolveLiveCategoryLayout('auto', raw), 'provider');
    expect(resolveLiveCategoryLayout('provider', curated), 'provider');
    expect(resolveLiveCategoryLayout('organised', raw), 'organised');
    List<String> describe(List<LiveCategoryNode> nodes) => [
          for (final node in nodes) ...[
            '${node.key}:${node.label}',
            ...describe(node.children),
          ],
        ];
    for (final groups in [curated, raw]) {
      final layout = resolveLiveCategoryLayout('auto', groups);
      final before = describe(buildLiveCategoryTree(groups));
      buildLiveCategoryTree(groups, layouts: {'p': 'provider'});
      expect(describe(buildLiveCategoryTree(groups, layouts: {'p': layout})),
          before);
    }
  });

  test('raw organisation is lossless, reversible and scoped per playlist', () {
    final groups = [
      for (final name in [
        'UK| GENERAL ᴴᴰ/ᴿᴬᵂ',
        'UK| GENERAL ʰᵉᵛᶜ',
        'UK| FORMULA 1 PPV',
        'UK| APPLE TV F1 PPV',
        'US| GENERAL HD',
        'AU| GENERAL',
        'NZ| GENERAL',
        'Unknown category'
      ])
        M3uGroup(title: name, playlistId: 'raw', channels: []),
      M3uGroup(title: 'UK| FORMULA 1 PPV', playlistId: 'other', channels: []),
    ];
    final organised =
        buildLiveCategoryTree(groups, layouts: {'raw': 'organised'});
    expect(originalGroups(organised).toSet(), groups.toSet());
    final collections = leaves(organised).whereType<LiveCategoryCollection>();
    expect(collections.any((c) => c.displayName == 'UK guide'), isTrue);
    final f1 = collections.singleWhere((c) => c.displayName == 'Formula 1');
    expect(f1.sources, hasLength(2));
    final channel = Channel(
        id: 'stable',
        rawId: 'stable',
        name: 'F1 Main',
        group: groups[2].title,
        playlistId: 'raw',
        url: 'https://example.invalid/never-open');
    final selected = f1.select([channel]);
    expect(selected.last, same(channel));
    expect(selected.first.name, startsWith('###'));
    expect(selected.first.url, isEmpty);
    expect(
        leaves(buildLiveCategoryTree(groups, layouts: {'raw': 'provider'}))
            .toList(),
        groups);
    expect(leaves(buildLiveCategoryTree(groups)).toList(), groups);
  });

  test('playlist choice survives storage and unrelated edits', () {
    final original = PlaylistProfile(
        id: 'p',
        name: 'Playlist',
        mode: 'xtream',
        categoryLayout: 'provider',
        sortOrder: 2,
        createdAt: DateTime(2026),
        backupServers: ['https://example.invalid']);
    final restored =
        PlaylistProfile.fromJson(original.copyWith(name: 'Renamed').toJson());
    expect(restored.categoryLayout, 'provider');
    expect(restored.backupServers, original.backupServers);
    final legacy = original.toJson()..remove('categoryLayout');
    expect(PlaylistProfile.fromJson(legacy).categoryLayout, 'auto');
  });

  const auditPath = String.fromEnvironment('RAW_CATALOGUE_AUDIT');
  test('cached raw catalogue retains every category without reading streams',
      () {
    final data = jsonDecode(File(auditPath).readAsStringSync()) as Map;
    final groups = [
      for (final c in data['categories'] as List)
        M3uGroup(title: c['name'] as String, playlistId: 'audit', channels: [])
    ];
    final timer = Stopwatch()..start();
    final tree = buildLiveCategoryTree(groups, layouts: {'audit': 'organised'});
    final micros = timer.elapsedMicroseconds;
    expect(originalGroups(tree).toSet(),
        groups.where((g) => !isLivePlaylistInformation(g.title)).toSet());
    expect(leaves(tree).length, lessThan(groups.length));
    expect(tree.length, lessThan(20),
        reason:
            'Tagged provider categories should not spill into a long root list');
    final report = {
      'categories': groups.length,
      'channels': (data['channels'] as List).length,
      'organisedEntries': leaves(tree).length,
      'rootEntries': tree.length,
      'rootLabels': tree.map((n) => n.label).toList(),
      'buildMicrosecondsDesktop': micros,
      'providerRequests': 0
    };
    const out = String.fromEnvironment('RAW_CATALOGUE_REPORT');
    if (out.isNotEmpty) File(out).writeAsStringSync(jsonEncode(report));
  }, skip: auditPath.isEmpty);
}
