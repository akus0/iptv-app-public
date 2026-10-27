import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/utils/library_categories.dart';

M3uGroup group(String name, [String playlist = 'one']) =>
    M3uGroup(title: name, playlistId: playlist, channels: []);
Iterable<LibraryCategoryNode> leaves(
    Iterable<LibraryCategoryNode> nodes) sync* {
  for (final n in nodes) {
    if (n.isFolder) {
      yield* leaves(n.children);
    } else {
      yield n;
    }
  }
}

void main() {
  test('general service catalogues precede quality and specialist shelves', () {
    final groups = [
      for (final s in [
        'NETFLIX KIDS ⁴ᴷ',
        'NETFLIX DOCU-SERIES',
        'NETFLIX SERIES ⁴ᴷ',
        'NETFLIX SERIES',
        'NETFLIX REALITY',
        'NETFLIX ADULT-SWIM',
        'NETFLIX KIDS',
        'NETFLIX SERIES ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ',
      ])
        group(s)
    ];
    final tree = LibraryCategoryTree(groups, organise: (_) => true);
    final ordered = leaves(tree.roots).map((n) => n.group!.title).toList();
    expect(ordered.first, 'NETFLIX SERIES');
    expect(ordered.indexOf('NETFLIX SERIES ⁴ᴷ'),
        lessThan(ordered.indexOf('NETFLIX KIDS ⁴ᴷ')));
    expect(ordered.indexOf('NETFLIX SERIES ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ'),
        lessThan(ordered.indexOf('NETFLIX DOCU-SERIES')));
    expect(tree.path(groups[5]), 'English › Streaming services › Netflix');
    expect(tree.path(groups[5]), isNot(contains('Kids')));
  });
  test('long genre lists collapse together while small playlists stay shallow',
      () {
    final groups = [
      for (final name in ['ACTION', 'DRAMA', 'COMEDY', 'HORROR'])
        group('EN - $name')
    ];
    final tree = LibraryCategoryTree(groups, organise: (_) => true);
    expect(leaves(tree.roots).map((n) => n.group), unorderedEquals(groups));
    expect(tree.path(groups.first), 'English › Genres');
    final small =
        LibraryCategoryTree(groups.take(2).toList(), organise: (_) => true);
    expect(small.roots.single.children.every((n) => !n.isFolder), isTrue);
    expect(small.path(groups.first), 'English');
  });
  test(
      'English topic shelves and general series have distinct browse positions',
      () {
    final groups = [
      for (final name in [
        'ENGLISH REALITY SERIES',
        'ENGLISH SERIES ⁴ᴷ',
        'ENGLISH SERIES',
        'EN - DOCUMENTARIES',
        'EN - CONCERTS',
        'EN - COLLECTIONS',
        'EN - NEW RELEASE'
      ])
        group(name)
    ];
    final tree = LibraryCategoryTree(groups, organise: (_) => true);
    expect(tree.path(groups[0]), 'English › Reality & shows');
    expect(tree.path(groups[3]), 'English › Documentaries');
    expect(tree.path(groups[4]), 'English › Music & concerts');
    expect(tree.path(groups[5]), 'English › Collections & studios');
    expect(tree.path(groups[6]), 'English › Featured');
    expect(leaves(tree.roots).firstWhere((n) => n.group == groups[0]).title,
        'Reality Series');
    expect(leaves(tree.roots).firstWhere((n) => n.group == groups[4]).title,
        'Concerts');
    final ordered = leaves(tree.roots).map((n) => n.group).toList();
    expect(ordered.indexOf(groups[2]), lessThan(ordered.indexOf(groups[1])));
    expect(ordered.indexOf(groups[2]), lessThan(ordered.indexOf(groups[0])));
  });
  test('regional service shelves retain language and never merge providers',
      () {
    final groups = [
      group('GERMANY NETFLIX'),
      group('GERMANY NETFLIX DV ⁴ᴷ ᴴᴰᴿ'),
      group('GERMANY PRIME'),
      group('FRANCE NETFLIX'),
      group('EN - NETFLIX SERIES'),
      group('TR - HBO MAX & BLUTV FILMLERI'),
      group('NETFLIX ASIA'),
      group('Appleton collection'),
      group('Amazonia'),
      group('EN - PRIME SUSPECT')
    ];
    final tree = LibraryCategoryTree(groups, organise: (_) => true);
    expect(tree.path(groups[0]),
        'International › German › Streaming services › Netflix');
    expect(tree.path(groups[2]),
        'International › German › Streaming services › Prime Video');
    expect(tree.path(groups[3]),
        'International › French › Streaming services › Netflix');
    expect(tree.path(groups[4]), 'English › Streaming services › Netflix');
    expect(tree.path(groups[5]), 'International › Turkish');
    expect(tree.path(groups[6]), contains('Asian'));
    for (final g in groups.skip(7)) {
      expect(tree.path(g), isNot(contains('Streaming services')));
    }
    expect(leaves(tree.roots).map((n) => n.group), unorderedEquals(groups));
  });
  test('single service shelf does not repeat All titles in visible label', () {
    final groups = [group('SKY'), group('SHOWTIME'), group('PEACOCK')];
    final tree = LibraryCategoryTree(groups, organise: (_) => true);
    expect(
        leaves(tree.roots).map((n) => n.title), ['Peacock', 'Showtime', 'Sky']);
  });
  test('provider mode preserves exact names, order and group identity', () {
    final groups = [
      group('EN - NEW RELEASE'),
      group('NETFLIX MOVIES ⁴ᴷ ³⁸⁴⁰ᴾ'),
      group('DE - KINDER FILME')
    ];
    final tree = LibraryCategoryTree(groups, organise: (_) => false);
    expect(tree.roots.map((n) => n.title), groups.map((g) => g.title));
    expect(tree.roots.map((n) => n.group), orderedEquals(groups));
    expect(tree.roots.every((n) => !n.isFolder), isTrue);
  });
  test(
      'folders separate languages and services without merging or dropping leaves',
      () {
    final groups = [
      group('EN - ACTION'),
      group('EN - NEW RELEASE'),
      group('DE - KINDER FILME'),
      group('DE - FILME 2025/2026'),
      group('NETFLIX MOVIES'),
      group('NETFLIX KIDS'),
      group('SOCCER RUGBY'),
      group('SOCCER FORMULA 1')
    ];
    final tree = LibraryCategoryTree(groups, organise: (_) => true);
    expect(tree.path(groups[0]), 'English');
    expect(tree.label(groups[0]), 'Action');
    expect(tree.path(groups[2]), 'International › German');
    expect(tree.path(groups[4]), 'English › Streaming services › Netflix');
    expect(tree.label(groups.last), 'Formula 1');
    expect(tree.path(groups.last), 'English › Sports & events');
    expect(tree.roots.first.title, 'English');
    expect(tree.roots.first.children.any((n) => n.group == groups[1]), isTrue);
    expect(leaves(tree.roots).map((n) => n.group), unorderedEquals(groups));
  });
  test(
      'mixed playlists apply organisation independently, unknown titles stay accessible',
      () {
    final groups = [
      group('EN - ACTION'),
      group('EN - HORROR'),
      group('EN - ACTION', 'raw'),
      group('MY PERSONAL SHELF', 'raw'),
      group('Unusual category')
    ];
    final tree = LibraryCategoryTree(groups, organise: (id) => id != 'raw');
    final raw =
        leaves(tree.roots).where((n) => n.group!.playlistId == 'raw').toList();
    expect(raw.map((n) => n.title), ['EN - ACTION', 'MY PERSONAL SHELF']);
    expect(raw.map((n) => n.group), orderedEquals(groups.sublist(2, 4)));
    expect(leaves(tree.roots).map((n) => n.group), unorderedEquals(groups));
  });
  test(
      'English shelves stay together and explicit service regions stay international',
      () {
    final groups = [
      group('EN - ACTION'),
      group('ENGLISH KIDS'),
      group('NETFLIX MOVIES'),
      group('TOP MOVIES'),
      group('MARVEL MOVIES'),
      group('NETFLIX ASIA'),
      group('DISCOVERY+ SERIES MENA'),
      group('VIAPLAY POLSKA SERIA'),
      group('VIAPLAY ÍSLANDS KVIKMYNDIR'),
      group('JOYN SERIES'),
    ];
    final tree = LibraryCategoryTree(groups, organise: (_) => true);
    for (final g in groups.take(5)) {
      expect(tree.path(g), startsWith('English'));
    }
    for (final g in groups.skip(5)) {
      expect(tree.path(g), startsWith('International'));
    }
    expect(tree.path(groups[7]), contains('Polish'));
    expect(tree.path(groups[8]), contains('Icelandic'));
    expect(leaves(tree.roots).map((n) => n.group), unorderedEquals(groups));
  });
  test('both audited catalogues retain every category exactly once', () {
    final fixture = jsonDecode(File('test/fixtures/library_category_names.json')
        .readAsStringSync()) as List;
    for (final type in ['vod', 'series']) {
      final groups = fixture
          .where((r) => r['type'] == type)
          .map((r) => group(r['title'] as String))
          .toList();
      final tree = LibraryCategoryTree(groups, organise: (_) => true);
      expect(groups.length, type == 'vod' ? 445 : 385);
      expect(leaves(tree.roots).map((n) => n.group), unorderedEquals(groups));
      expect(leaves(tree.roots).map((n) => n.id).toSet().length, groups.length);
      expect(tree.roots.fold<int>(0, (total, n) => total + n.categoryCount),
          groups.length);
      expect(tree.roots.length, lessThan(25));
      final raw = LibraryCategoryTree(groups, organise: (_) => false);
      expect(raw.roots.map((n) => n.group), orderedEquals(groups));
      expect(raw.roots.map((n) => n.title), groups.map((g) => g.title));
      // Switching the setting changes presentation, not selected IDs or caches.
      final restored = LibraryCategoryTree(groups, organise: (_) => true);
      expect(leaves(restored.roots).map((n) => n.id),
          orderedEquals(leaves(tree.roots).map((n) => n.id)));
      void check(List<LibraryCategoryNode> nodes) {
        for (final n in nodes) {
          if (n.isFolder) {
            expect(n.children.length, greaterThan(1), reason: n.title);
            check(n.children);
          }
        }
      }

      check(tree.roots);
      // Emit counts only; no playlist URLs, credentials or content metadata.
      // ignore: avoid_print
      print(
          '$type: ${groups.length} categories → ${tree.roots.length} top-level entries; ${tree.roots.map((n) => '${n.title}: ${n.categoryCount}').join(', ')}');
    }
  });
}
