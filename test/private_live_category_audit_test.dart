import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/services/m3u_parser.dart';
import 'package:nox_iptv/utils/live_category_folders.dart';

void main() {
  const path = String.fromEnvironment('PRIVATE_PLAYLIST_FILE');
  test(
      'cached playlist F1 enrichment is complete without any provider requests',
      () {
    final channels = M3uParser.parse(File(path).readAsStringSync(),
        playlistId: 'audit', liveOnly: true);
    final titles = channels.map((c) => c.group).toSet();
    final groups = [
      for (final t in titles)
        M3uGroup(title: t, playlistId: 'audit', channels: [])
    ];
    final timer = Stopwatch()..start();
    final tree = buildLiveCategoryTree(groups);
    Object snapshot(LiveCategoryNode node) => {
          'key': node.key,
          'label': node.label,
          'children': node.children.map(snapshot).toList(),
          if (node.group case final LiveCategoryCollection collection) ...{
            'sources': collection.sourceTitles.toList(),
            'channels': collection.select(channels).map((c) => c.id).toList(),
          },
        };
    final layoutHash = sha256
        .convert(utf8.encode(jsonEncode(tree.map(snapshot).toList())))
        .toString();
    const expectedHash = String.fromEnvironment('EXPECTED_LAYOUT_HASH');
    if (expectedHash.isNotEmpty) expect(layoutHash, expectedHash);
    final treeUs = timer.elapsedMicroseconds;
    final sports = tree.singleWhere((n) => n.label == 'Sports');
    final f1 = sports.children.singleWhere((n) => n.label == 'Formula 1').group
        as LiveCategoryCollection;
    timer.reset();
    final selected = f1.select(channels);
    final selectionUs = timer.elapsedMicroseconds;
    final expected =
        channels.where((c) => c.name.toLowerCase().contains('sky sports f1'));
    expect(expected, isNotEmpty);
    expect(selected.map((c) => (c.id, c.url)).toSet(),
        containsAll(expected.map((c) => (c.id, c.url)).toSet()));
    expect(selected.where((c) => c.name.contains('Main Event')), isEmpty);
    // Aggregate metadata only: no subscription URLs, identifiers or credentials.
    final report = <String, Object>{
      'layoutHash': layoutHash,
      'catalogueChannels': channels.length,
      'categories': groups.length,
      'f1Channels': selected.length,
      'skySportsF1': expected.length,
      'additionalFeeds':
          selected.where((c) => !f1.sourceTitles.contains(c.group)).length,
      'treeBuildMicrosecondsDesktopTest': treeUs,
      'selectionMicrosecondsDesktopTest': selectionUs
    };
    Iterable<LiveCategoryCollection> collections(
        List<LiveCategoryNode> nodes) sync* {
      for (final node in nodes) {
        if (node.group case final LiveCategoryCollection collection) {
          yield collection;
        }
        yield* collections(node.children);
      }
    }

    final sportsReport = <String, Object>{};
    for (final collection in collections(tree)) {
      if (collection.additionalSourceTitles.isEmpty) continue;
      final feeds = collection.select(channels);
      sportsReport[collection.displayName] = {
        'channels': feeds.length,
        'additional': feeds
            .where((c) => !collection.sourceTitles.contains(c.group))
            .length,
      };
      if (collection.displayName == 'Tennis') {
        expect(feeds.first.name.toLowerCase(), contains('sky sports tennis'));
        expect(
            feeds.where((c) => c.name.toLowerCase().contains('table tennis')),
            isEmpty);
      }
    }
    report['sports'] = sportsReport;
    const output = String.fromEnvironment('PRIVATE_AUDIT_REPORT');
    if (output.isNotEmpty) {
      File(output).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n');
    }
  }, skip: path.isEmpty);
}
