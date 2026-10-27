import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/playlist_session.dart';
import 'package:nox_iptv/services/storage_service.dart';

class CountedCatalogue extends ListBase<Channel> {
  CountedCatalogue(this.items);
  final List<Channel> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  Channel operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, Channel value) =>
      throw UnsupportedError('read only');
}

void main() {
  test(
      '80k M3U grouping preserves first-seen order, identity and fresh hidden state in one pass',
      () {
    final channels = CountedCatalogue([
      for (var i = 0; i < 80000; i++)
        Channel(
            id: 'p::$i',
            rawId: '$i',
            playlistId: 'p',
            name: 'Channel $i',
            group: 'Group ${i % 200}',
            url: 'https://example.test/$i')
    ]);
    final session = PlaylistSession(
        profile: PlaylistProfile(
            id: 'p',
            name: 'Test',
            mode: 'm3u',
            sortOrder: 0,
            createdAt: DateTime(2026)),
        storage: StorageService(),
        catalogDb: CatalogDatabase(),
        favoriteIds: () => {},
        favoriteSeriesIds: () => {},
        isRestrictedViewer: () => false,
        onNotify: () {});
    session.channels = channels;
    final groups = session.allGroups;
    expect(channels.reads, 80000);
    expect(groups.length, 200);
    expect(
        groups.map((g) => g.title), [for (var i = 0; i < 200; i++) 'Group $i']);
    expect(groups.first.channels.length, 400);
    expect(identical(groups.first.channels[1], channels.items[200]), isTrue);
    session.hiddenGroups = {'Group 0'};
    expect(session.allGroups.first.isHidden, isTrue);
    expect(channels.reads, 80000,
        reason: 'Reading groups again must reuse the index');
    for (var i = 0; i < 20; i++) {
      final rows =
          session.visibleChannels(groupTitle: 'Group 5', category: 'tv');
      expect(rows, hasLength(400));
    }
    expect(channels.reads, 80000,
        reason: 'Opening a category must not scan 80k channels again');
    session.hiddenChannels = {'5'};
    expect(session.visibleChannels(groupTitle: 'Group 5', category: 'tv'),
        hasLength(399));
    session.channels = [channels.items[201], channels.items[0]];
    expect(session.allGroups.map((g) => g.title), ['Group 1', 'Group 0']);
  });
}
