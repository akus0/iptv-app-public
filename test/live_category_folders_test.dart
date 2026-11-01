import 'dart:convert';
import 'dart:io';
import 'dart:collection';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/widgets/live_category_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/live_category_folders.dart';
import 'package:nox_iptv/widgets/live_category_folders.dart';

M3uGroup group(String title, [String id = 'epg']) =>
    M3uGroup(title: title, playlistId: id, channels: []);
List<M3uGroup> fixture() => [
      group('EPGenius'),
      group('🇺🇸 TV Guide (USA)'),
      group('🇬🇧 TV Guide (UK)'),
      group('🏀 NBA League Pass'),
      group('UK| Sky Sports ᴳᴬᴺᴶᴬ'),
      group('UK| LEAGUE ONE PPV'),
      group('UK| FORMULA 1 PPV'),
      group('UK| Entertainment'),
      group('TH| THAILAND', 'xtream'),
    ];
Iterable<M3uGroup> leaves(List<LiveCategoryNode> nodes) sync* {
  for (final n in nodes) {
    if (n.group case final g?) {
      yield g;
    } else {
      yield* leaves(n.children);
    }
  }
}

Iterable<M3uGroup> sources(List<LiveCategoryNode> tree) =>
    leaves(tree).expand((g) => g is LiveCategoryCollection ? g.sources : [g]);

class UnscannableChannels extends ListBase<Channel> {
  @override
  int get length => 80000;
  @override
  set length(int value) => throw StateError('Do not change channels');
  @override
  Channel operator [](int index) => throw StateError('Do not scan channels');
  @override
  void operator []=(int index, Channel value) =>
      throw StateError('Do not change channels');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (category, label, network) in [
    ('🎾 Tennis', 'Tennis', 'Sky Sports Tennis 1080p50'),
    ('⛳️ Golf', 'Golf', 'Sky Sports Golf'),
    ('World Cricket', 'Cricket', 'Willow Cricket'),
    ('UK| FLORUGBY PPV', 'Rugby', 'Premier Sports Rugby'),
    ('UK| PDC BOARD PPV', 'Darts · PDC', 'DAZN PDC DARTS'),
    ('UK| VOLLEY BALL WORLD PPV', 'Volleyball World', 'Volleyball TV'),
    ('UK| ULTIMATE POOL PPV', 'Pool · Ultimate Pool', 'Matchroom Pool'),
    ('World Horse Racing', 'Horse racing', 'Racing TV'),
    ('🏀 NBA League Pass', 'NBA League Pass', 'NBA TV'),
    ('🏈 NFL Sunday Ticket', 'NFL Sunday Ticket', 'NFL Network'),
    ('⚾️ MLB.tv', 'MLB.tv', 'MLB Network'),
    ('🏒 NHL Center Ice', 'NHL Center Ice', 'NHL Network'),
    ('UK| Football ᴳᴬᴺᴶᴬ', 'Football channels', 'Sky Sports Football'),
  ]) {
    test(
        '$label puts dedicated networks before event feeds and respects visibility',
        () {
      final groups = [
        group('TV Guide (USA)'),
        group('TV Guide (UK)'),
        group(category),
        group('Sports networks')
      ];
      final collection = leaves(buildLiveCategoryTree(groups))
          .whereType<LiveCategoryCollection>()
          .single;
      Channel channel(String name, String category,
              {String pid = 'epg', String extra = ''}) =>
          Channel(
              id: name,
              rawId: name,
              playlistId: pid,
              name: name,
              group: category,
              url: 'https://example.test/$name/$extra');
      final feed = channel('Event feed 1', category);
      final main = channel(network, 'Sports networks');
      final backup = channel(network, 'Sports networks', extra: 'backup');
      final foreign = channel(network, 'Sports networks', pid: 'other');
      final visible = [
        feed,
        main,
        backup,
        foreign,
        main,
        channel('Table Tennis Channel', 'Sports networks'),
        channel('Pig Goat Banana Cricket', 'Sports networks'),
        channel('Sky Sports Main Event', 'Sports networks'),
        channel('### $network ###', 'Sports networks')
      ];
      expect(collection.displayName, label);
      expect(collection.select(visible), [main, backup, feed]);
      expect(collection.select([feed]), [feed]);
      final refreshed = refreshLiveCategoryCollection(
          collection, groups.where((g) => g.title != 'Sports networks'));
      expect(refreshed.select(visible), [feed]);
    });
  }
  test(
      'folders preserve every category, playlist identity and provider order inside branches',
      () {
    final groups = fixture();
    final tree = buildLiveCategoryTree(groups);
    expect(tree.take(2).map((n) => n.label),
        ['🇺🇸 TV Guide (USA)', '🇬🇧 TV Guide (UK)']);
    expect(sources(tree).toSet(),
        groups.where((g) => !isLivePlaylistInformation(g.title)).toSet());
    expect(sources(tree).length, groups.length - 1);
    expect(tree.last.group, groups.last);
    expect(tree[2].label, 'Sports');
    expect(tree[2].children.any((n) => n.label == 'Formula 1'), isTrue);
    expect(tree.any((n) => n.label == 'United Kingdom'), isFalse);
    expect(tree.any((n) => n.label == 'Sports'), isTrue);
    expect(sources(tree).map((g) => g.title), isNot(contains('EPGenius')));
    final plain = [group('Sports', 'other'), group('News', 'other')];
    expect(buildLiveCategoryTree(plain).map((n) => n.group), plain);
  });

  test(
      'saved catalogue has separate countries, no redundant folders and every original category',
      () {
    final titles = (jsonDecode(
            File('test/fixtures/curated_category_titles.json')
                .readAsStringSync()) as List)
        .cast<String>();
    final channels = UnscannableChannels();
    final groups = [
      for (final title in titles)
        M3uGroup(title: title, playlistId: 'saved', channels: channels)
    ];
    final tree = buildLiveCategoryTree(groups);
    expect(sources(tree).toSet(),
        groups.where((g) => !isLivePlaylistInformation(g.title)).toSet());
    expect(sources(tree).length, 164);
    expect(tree.take(4).map((n) => n.group!.title), titles.sublist(1, 5));
    for (final (country, count) in [('Australia', 5), ('New Zealand', 2)]) {
      final node = tree.singleWhere((n) => n.label == country);
      expect(node.children, hasLength(count));
      expect(node.children.every((n) => n.group != null), isTrue);
    }
    expect(tree.where((n) => n.label == 'Australia & New Zealand'), isEmpty);
    expect(
        tree.singleWhere((n) => n.label == '24/7 Channels').group, isNotNull);
    void check(LiveCategoryNode node, int depth) {
      if (node.group != null) {
        for (final source in node.group is LiveCategoryCollection
            ? (node.group as LiveCategoryCollection).sources
            : [node.group!]) {
          expect(identical(source.channels, channels), isTrue);
        }
        return;
      }
      expect(node.children.length, greaterThan(1), reason: node.label);
      expect(depth, lessThan(2));
      expect(leaves(node.children).length, node.count);
      for (final child in node.children) {
        check(child, depth + 1);
      }
    }

    for (final node in tree) {
      check(node, 0);
    }
    final unknown = group('Custom documentary selection');
    expect(
        buildLiveCategoryTree([...fixture(), unknown])
            .any((n) => identical(n.group, unknown)),
        isTrue);
    expect(liveCategoryPath('🏟️ College Football'),
        ['Sports', 'American football']);
    expect(liveCategoryPath('UK| FLORUGBY PPV'), ['Sports']);
    expect(liveCategoryLabel('UK| Sky Sports ᴳᴬᴺᴶᴬ', inFolder: true),
        'Sky Sports');
    expect(liveCategoryLabel('UK| Sky Sports ᴳᴬᴺᴶᴬ'), 'UK| Sky Sports');
  });
  test(
      'sports and entertainment have predictable, recognisable browsing groups',
      () {
    final titles = (jsonDecode(
            File('test/fixtures/curated_category_titles.json')
                .readAsStringSync()) as List)
        .cast<String>();
    final tree = buildLiveCategoryTree(titles.map(group).toList());
    expect(tree.take(6).map((n) => n.label), [
      '🇺🇸 TV Guide (USA)',
      '🇬🇧 TV Guide (UK)',
      '🇨🇦 TV Guide (Canada)',
      '🇦🇺 TV Guide (Australia)',
      'Sports',
      'Live events & PPV'
    ]);
    final sports = tree.singleWhere((n) => n.label == 'Sports');
    expect(sports.children.take(5).map((n) => n.label),
        ['Football', 'Formula 1', 'Sports channels', 'Motorsport', 'Rugby']);
    final football = sports.children.first;
    expect(football.children.take(3).map((n) => n.label),
        ['Football channels', 'Premier League', 'UEFA']);
    expect(sports.children.any((n) => n.label == 'Leagues & college'), isFalse);
    expect(liveCategoryPath('🏀 NBA League Pass'), ['Sports', 'Basketball']);
    expect(liveCategoryPath('⚾️ MLB.tv'), ['Sports', 'Baseball']);
    expect(liveCategoryPath('🏒 NHL Center Ice'), ['Sports', 'Ice hockey']);
    final entertainment = tree.singleWhere((n) => n.label == 'Entertainment');
    expect(entertainment.children.take(4).map((n) => n.label), [
      'Entertainment channels',
      'Movies',
      'Series',
      'Documentaries & reality'
    ]);
    expect(tree.any((n) => n.label == 'World sports & 4K'), isFalse);
  });

  test('single surviving subfolders flatten without losing country context',
      () {
    final tree = buildLiveCategoryTree([
      group('TV Guide (USA)'),
      group('TV Guide (UK)'),
      group('UK| LEAGUE ONE PPV'),
      group('UK| LEAGUE TWO PPV')
    ]);
    final uk = tree.singleWhere((n) => n.label == 'Sports');
    expect(uk.children.every((n) => n.group != null), isTrue);
    final single = buildLiveCategoryTree(
        [group('TV Guide (USA)'), group('TV Guide (UK)'), group('AU| Sports')]);
    expect(single.last.group!.title, 'AU| Sports');
  });

  test('combined feeds preserve alternatives, scope and current visibility',
      () {
    final original = [group('🏎️ Formula 1'), group('UK| FORMULA 1 PPV')];
    final selected = LiveCategoryCollection('Formula 1', 'epg', original, []);
    Channel channel(String title, String url, {String playlist = 'epg'}) =>
        Channel(
            id: '$playlist::same-guide-id',
            rawId: 'same-guide-id',
            playlistId: playlist,
            name: 'Formula 1',
            group: title,
            url: url);
    final main = channel(original.first.title, 'https://example.test/main');
    final alternate =
        channel(original.last.title, 'https://example.test/driver');
    final foreign = channel(original.first.title, main.url, playlist: 'other');
    final unrelated = channel('UK| Football', 'https://example.test/football');
    expect(selected.select([main, alternate, main, foreign, unrelated]),
        [main, alternate]);
    expect(selected.select([alternate]), [alternate]);
    expect(
        liveCollectionForSource(original, 'epg', original.first.title), isNull);
    final curated = [
      group('TV Guide (USA)'),
      group('TV Guide (UK)'),
      ...original
    ];
    expect(
        liveCollectionForSource(curated, 'epg', original.first.title)!
            .sourceTitles,
        original.map((g) => g.title).toSet());
    expect(liveCollectionForSource(curated, 'other', original.first.title),
        isNull);
    final added = group('UK| FORMULA 1 APPLE TV PPV');
    final refreshed = refreshLiveCategoryCollection(selected, [
      original.first,
      M3uGroup(
          title: original.last.title,
          playlistId: 'epg',
          channels: [],
          isHidden: true),
      added,
      group('UK| FORMULA 1 PPV', 'other')
    ]);
    expect(refreshed.sourceTitles, {original.first.title, added.title});
    expect(refreshed.select([main, alternate]), [main]);
    expect(refreshLiveCategoryCollection(selected, []).select([main]), isEmpty);
  });

  test(
      'F1 includes named feeds across visible groups without leaking hidden sources',
      () {
    final groups = [
      group('TV Guide (USA)'),
      group('TV Guide (UK)'),
      group('UK| FORMULA 1 PPV'),
      group('UK| Sky Sports'),
      group('4K Channels'),
      M3uGroup(
          title: 'Hidden sports',
          playlistId: 'epg',
          channels: [],
          isHidden: true),
    ];
    final f1 = leaves(buildLiveCategoryTree(groups))
        .whereType<LiveCategoryCollection>()
        .singleWhere((g) => g.displayName == 'Formula 1');
    Channel channel(String name, String category,
            {String playlist = 'epg', String suffix = ''}) =>
        Channel(
            id: name,
            rawId: name,
            name: name,
            group: category,
            playlistId: playlist,
            url: 'https://example.test/${Uri.encodeComponent(name)}/$suffix');
    final sky = channel('Sky Sports F1 UHD 50fps', 'UK| Sky Sports');
    final backup =
        channel('Sky Sports F1 UHD 50fps', 'UK| Sky Sports', suffix: 'backup');
    final ultra = channel('CANAL+ FORMULA ONE', '4K Channels');
    final camera = channel('Driver camera 14', 'UK| FORMULA 1 PPV');
    final visible = [
      sky,
      backup,
      ultra,
      camera,
      sky,
      channel('Sky Sports Main Event', 'UK| Sky Sports'),
      channel('F10', 'UK| Sky Sports'),
      channel('Formula 100', '4K Channels'),
      channel('### Formula 1 ###', 'TV Guide (UK)'),
      channel('Sky Sports F1', 'Hidden sports'),
      channel('F1 TV', 'Unknown group'),
      channel('Sky Sports F1', 'UK| Sky Sports', playlist: 'another'),
    ];
    expect(f1.path, ['Sports']);
    expect(f1.select(visible), [sky, backup, ultra, camera]);
    expect(
        f1.select([camera]), [camera]); // Hidden channels never reintroduced.
    final refreshed = refreshLiveCategoryCollection(
        f1, groups.where((g) => g.title != 'UK| Sky Sports'));
    expect(refreshed.select(visible), [ultra, camera]);
    expect(refreshLiveCategoryCollection(f1, []).select(visible), isEmpty);
  });

  test(
      'entertainment removes the generic layer and combines equivalent Prime feeds',
      () {
    final groups = [
      ...fixture(),
      group('📺 Prime Channels'),
      group('UK| Prime Channels'),
      group('CA| Prime Channels'),
      group('UK| Sky Channels ᴳᴬᴺᴶᴬ'),
      group('UK| BBC IPLAYER ᴿᴬᵂ')
    ];
    final tree = buildLiveCategoryTree(groups);
    final entertainment = tree.singleWhere((n) => n.label == 'Entertainment');
    expect(
        entertainment.children.any((n) => n.label == 'TV channels'), isFalse);
    final prime = entertainment.children
        .singleWhere((n) => n.label == 'Prime channels')
        .group as LiveCategoryCollection;
    expect(prime.sourceTitles, {'📺 Prime Channels', 'UK| Prime Channels'});
    expect(liveCategoryLabel('UK| Sky Channels ᴳᴬᴺᴶᴬ', inFolder: true),
        'Sky entertainment');
    expect(liveCategoryLabel('UK| BBC IPLAYER ᴿᴬᵂ', inFolder: true),
        'BBC live channels');
    expect(sources(tree).toSet(),
        groups.where((g) => !isLivePlaylistInformation(g.title)).toSet());
  });

  testWidgets(
      'root-only collections remain combined and original sources remain accessible',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LiveCategoryFolders(
                groups: [
          group('EPGenius'),
          group('TV Guide (USA)'),
          group('TV Guide (UK)'),
          group('🏎️ Formula 1'),
          group('UK| FORMULA 1 APPLE TV PPV'),
          group('UK| FORMULA 1 PPV')
        ],
                storage: storage,
                selectedKey: null,
                playlistName: (s) => s,
                rowBuilder: (g, label) => Text(label ?? g.title)))));
    await tester.pumpAndSettle();
    expect(find.text('Formula 1'), findsOneWidget);
    expect(find.text('EPGenius'), findsNothing);
    await tester.tap(find.byTooltip('Show original category list'));
    await tester.pumpAndSettle();
    expect(find.text('UK| FORMULA 1 APPLE TV PPV'), findsOneWidget);
    expect(find.text('UK| FORMULA 1 PPV'), findsOneWidget);
    expect(find.text('EPGenius'), findsNothing);
  });

  testWidgets('folder preferences follow the active viewer', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final first = storage.getActiveViewerId();
    Widget page() => MaterialApp(
        home: Scaffold(
            body: LiveCategoryFolders(
                groups: fixture(),
                storage: storage,
                rowBuilder: (g, label) => Text(g.title),
                selectedKey: null,
                playlistName: (id) => id)));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Sports'), findsOneWidget);
    await storage.setActiveViewerId('other');
    await storage.setLiveCategoryFolders(false);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Sports'), findsNothing);
    expect(find.text('UK| FORMULA 1 PPV'), findsOneWidget);
    await storage.setActiveViewerId(first);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Sports'), findsOneWidget);
    expect(find.text('UK| LEAGUE ONE PPV'), findsNothing);
  });
  testWidgets(
      'renamed browsing folders retain their open state without reopening after restart',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await storage.setOpenLiveCategoryFolders(
        {'epg/Sports', 'epg/Sports/Sports networks'});
    final groups = [...fixture(), group('UK| TNT Sports')];
    Widget page() => MaterialApp(
        home: Scaffold(
            body: LiveCategoryFolders(
                groups: groups,
                storage: storage,
                selectedKey: null,
                playlistName: (s) => s,
                rowBuilder: (g, label) => Text(label ?? g.title))));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Sky Sports'), findsOneWidget);
    await tester.tap(find.text('Sports channels'));
    await tester.pumpAndSettle();
    expect(find.text('Sky Sports'), findsNothing);
    expect(
        storage
            .getOpenLiveCategoryFolders()
            .contains('epg/Sports/Sports networks'),
        isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Sky Sports'), findsNothing);
  });

  testWidgets('previous country expansion survives the split', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await storage.setOpenLiveCategoryFolders({
      'epg/Australia & New Zealand',
      'epg/Australia & New Zealand/Australia',
      'epg/Australia & New Zealand/New Zealand'
    });
    Widget page() => MaterialApp(
            home: Scaffold(
                body: LiveCategoryFolders(
                    groups: [
              ...fixture(),
              group('AU| Sports'),
              group('AU| Entertainment'),
              group('NZ| Sports'),
              group('NZ| Entertainment')
            ],
                    storage: storage,
                    rowBuilder: (g, label) => Text(g.title),
                    selectedKey: null,
                    playlistName: (id) => id)));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('AU| Sports'), findsOneWidget);
    expect(find.text('NZ| Sports'), findsOneWidget);
    await tester.tap(find.text('Australia'));
    await tester.pumpAndSettle();
    expect(find.text('AU| Sports'), findsNothing);
    expect(
        storage
            .getOpenLiveCategoryFolders()
            .any((key) => key.contains('Australia & New Zealand')),
        isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('AU| Sports'), findsNothing);
    expect(find.text('NZ| Sports'), findsOneWidget);
  });
  for (final width in [30.0, 32.0]) {
    testWidgets(
        'collapsed categories fit $width with labelled expansion controls',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: width,
                  child: ListView(children: [
                    LiveCategoryFolders(
                        groups: fixture(),
                        storage: storage,
                        rowBuilder: (g, label) => SizedBox(
                            height: 40,
                            child: LiveCategoryIcon(label: g.title)),
                        selectedKey: 'epg::UK| LEAGUE ONE PPV',
                        collapsed: true,
                        playlistName: (id) => id)
                  ])))));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Sports'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [180.0, 320.0]) {
    testWidgets(
        'remote navigation, collapse persistence and original list at width $width',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      String? picked;
      Widget page(List<M3uGroup> groups) => MaterialApp(
          home: Scaffold(
              body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                      width: width,
                      child: ListView(children: [
                        LiveCategoryFolders(
                          groups: groups,
                          storage: storage,
                          selectedKey: 'epg::UK| LEAGUE ONE PPV',
                          playlistName: (s) => s,
                          rowBuilder: (g, label) => TextButton(
                              onPressed: () => picked = g.title,
                              child: Text(g.title)),
                        ),
                      ])))));
      await tester.pumpWidget(page(fixture()));
      await tester.pumpAndSettle();
      expect(find.text('UK| LEAGUE ONE PPV'), findsOneWidget);
      await tester.tap(find.text('Sports'));
      await tester.pumpAndSettle();
      expect(find.text('UK| LEAGUE ONE PPV'), findsNothing);
      // A catalogue/EPG rebuild must not reopen a deliberately collapsed path.
      await tester.pumpWidget(page(fixture()));
      await tester.pumpAndSettle();
      expect(find.text('UK| LEAGUE ONE PPV'), findsNothing);
      final folder = find
          .ancestor(of: find.text('Sports'), matching: find.byType(InkWell))
          .first;
      Focus.of(tester.element(find
              .descendant(of: folder, matching: find.byType(Padding))
              .first))
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      // Touch and remote activate the same folder; the selected inner branch remains open.
      expect(find.text('UK| LEAGUE ONE PPV'), findsOneWidget);
      await tester.tap(find.text('UK| LEAGUE ONE PPV'));
      await tester.pumpAndSettle();
      expect(picked, 'UK| LEAGUE ONE PPV');
      await tester.ensureVisible(find.byTooltip('Show original category list'));
      await tester.tap(find.byTooltip('Show original category list'));
      await tester.pumpAndSettle();
      expect(find.text('UK| LEAGUE ONE PPV'), findsOneWidget);
      expect(storage.getLiveCategoryFolders(), false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
