import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/utils/live_category_folders.dart';
import 'package:nox_iptv/utils/provider_category.dart';

Iterable<M3uGroup> leaves(List<LiveCategoryNode> nodes) sync* {
  for (final node in nodes) {
    if (node.group != null) yield node.group!;
    yield* leaves(node.children);
  }
}

class _UnreadableChannels extends ListBase<Channel> {
  @override
  int get length =>
      throw StateError('Category building must not read channels');
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  Channel operator [](int index) => throw StateError('No channel reads');
  @override
  void operator []=(int index, Channel value) =>
      throw UnsupportedError('read only');
}

void main() {
  test('country tags support common delimiters, names and quality decorations',
      () {
    for (final title in [
      'UK| GENERAL ᴴᴰ/ᴿᴬᵂ',
      'UK: General HD',
      '[UK] General FHD',
      '🇬🇧 UK - General',
      'United Kingdom / General',
      'GB_General',
      'General [UK]',
      'General - UK',
      'HD | UK | General',
      'LIVE TV | UK | General',
      'UK General',
    ]) {
      final category = parseProviderCategory(title);
      expect(category.region, 'uk', reason: title);
      expect(category.name, 'general', reason: title);
    }
    for (final (title, code) in [
      ('USA: Local Channels', 'us'),
      ('[AUS] Entertainment', 'au'),
      ('New Zealand - TV', 'nz'),
      ('CANADA | News', 'ca'),
      ('Deutschland: Allgemein', 'de'),
      ('France / General', 'fr'),
      ('ESPAÑA | General', 'es'),
      ('BRASIL - Esportes', 'br'),
      ('[JP] TV', 'jp'),
      ('KOREA | TV', 'kr'),
      ('[IN] TV', 'in'),
      ('NO | TV', 'no'),
      ('IT: Cinema', 'it'),
    ]) {
      expect(parseProviderCategory(title).region, code, reason: title);
    }
  });

  test('unknown names and country-like words are not guessed', () {
    for (final name in [
      'IN THE MIX',
      'NO LIMITS',
      'IT TAKES TWO',
      'BE INSPIRED',
      'Custom [ABC]'
    ]) {
      expect(parseProviderCategory(name).region, isNull, reason: name);
    }
    expect(parseProviderCategory('UK | US | Sports').region, isNull);
    expect(parseProviderCategory('[UK] [US] Sports').region, isNull);
    expect(parseProviderCategory('La Liga').region, isNull);
    expect(providerSportCollection('la liga')?.$1, 'La Liga');
    expect(
        providerSportCollection(parseProviderCategory('UK | La Liga PPV').name)
            ?.$1,
        'La Liga');
    expect(
        providerSportCollection(parseProviderCategory('TS| TENNIS TV PPV').name)
            ?.$1,
        'Tennis');
    expect(parseProviderCategory('UKRAINE | General').region, 'ua');
  });

  test('different provider formats form consistent virtual sports collections',
      () {
    final groups = [
      for (final name in [
        'UK: F1 PPV',
        '[US] Formula 1 Live',
        'Sports | Formula One',
        'UK - Tennis HD',
        '[FR] ATP PPV',
        'WTA - CA',
        'AU: Rugby',
        'USA | NBA',
        'CA - NHL',
        'SPORTS | MMA',
        'UK | SKY SPORTS FHD',
        'USA: SPORTS HD',
        'PPV - UK',
        'United Kingdom | General',
        '[UK] General UHD',
        'France | News',
        'FR: Kids',
        'Unknown curated favourites',
      ])
        M3uGroup(title: name, playlistId: 'p', channels: _UnreadableChannels()),
    ];
    final tree = buildLiveCategoryTree(groups, layouts: {'p': 'organised'});
    final entries = leaves(tree).toList();
    LiveCategoryCollection collection(String name) => entries
        .whereType<LiveCategoryCollection>()
        .singleWhere((c) => c.displayName == name);
    expect(collection('Formula 1').sources, hasLength(3));
    expect(collection('Tennis').sources, hasLength(3));
    expect(collection('UK guide').sources, hasLength(2));
    expect(collection('France guide').sources, hasLength(2));
    expect(collection('France guide').path, ['World TV']);
    expect(collection('Sky Sports').path, ['Sports', 'Sports channels']);
    expect(collection('Combat sports').path, ['Sports']);
    expect(
        entries
            .expand((g) => g is LiveCategoryCollection ? g.sources : [g])
            .toSet(),
        groups.toSet());
    expect(
        leaves(buildLiveCategoryTree(groups, layouts: {'p': 'provider'}))
            .toList(),
        groups);
  });

  test(
      'collection restore, dedicated channels and section headers remain consistent',
      () {
    final groups = [
      for (final (name, hidden, playlist) in [
        ('[US] Tennis PPV', false, 'p'),
        ('UK: ATP LIVE', false, 'p'),
        ('UK: General', false, 'p'),
        ('WTA - CA', true, 'p'),
        ('AU: Tennis', false, 'other'),
      ])
        M3uGroup(
            title: name, playlistId: playlist, channels: [], isHidden: hidden),
    ];
    final collection = liveCollectionForSource(groups, 'p', '[US] Tennis PPV',
        layout: 'organised')!;
    final channels = [
      for (final (id, name, group, playlist) in [
        ('one', 'Court 1', '[US] Tennis PPV', 'p'),
        ('two', 'Court 2', 'UK: ATP LIVE', 'p'),
        ('three', 'Sky Sports Tennis', 'UK: General', 'p'),
        ('four', 'Hidden tennis', 'WTA - CA', 'p'),
        ('five', 'Other playlist tennis', 'AU: Tennis', 'other'),
        ('six', 'Sky Sports Main Event', 'UK: General', 'p'),
      ])
        Channel(
            id: id,
            rawId: id,
            name: name,
            group: group,
            playlistId: playlist,
            url: 'https://example.invalid/$id'),
    ];
    final selected = collection.select(channels);
    expect(selected.where((c) => c.url.isNotEmpty).map((c) => c.id),
        ['three', 'one', 'two']);
    expect(
        selected
            .where((c) => c.url.isEmpty)
            .every((c) => c.name.startsWith('### ')),
        isTrue);
    expect(selected.where((c) => c.url.isNotEmpty).every(channels.contains),
        isTrue);
    expect(refreshLiveCategoryCollection(collection, groups).sourceTitles,
        collection.sourceTitles);
  });
}
