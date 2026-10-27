import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/services/sports_channel_matcher.dart';
import 'package:nox_iptv/utils/sports_channel_filter.dart';

void main() {
  final channel = Channel(
      id: 'test',
      rawId: 'test',
      playlistId: 'test',
      name: 'Sports channel',
      group: 'Sports',
      url: 'https://example.invalid');
  final strong = ChannelMatch(channel, MatchReason.name, 420);
  final weak = ChannelMatch(channel, MatchReason.sport, 80);
  test('pending events appear only in possible/all, never With channel', () {
    expect(SportsChannelFilter.matched.accepts([], pending: true), false);
    expect(SportsChannelFilter.matched.accepts([weak], pending: true), false);
    expect(SportsChannelFilter.possible.accepts([], pending: true), true);
    expect(SportsChannelFilter.possible.accepts([], pending: false), false);
    expect(SportsChannelFilter.possible.accepts([weak], pending: true), true);
    expect(SportsChannelFilter.all.accepts([], pending: true), true);
  });
  test('possible mode adds weaker suggestions without weakening With channel',
      () {
    expect(SportsChannelFilter.matched.accepts([weak], pending: false), false);
    expect(SportsChannelFilter.possible.accepts([weak], pending: false), true);
    for (final mode in SportsChannelFilter.values) {
      expect(mode.accepts([strong, weak], pending: false), true);
    }
  });
  test('pending weak suggestions cannot auto-play under With channel', () {
    expect(SportsChannelFilter.matched.preferred([weak]), isNull);
    expect(SportsChannelFilter.matched.preferred([weak, strong]), same(strong));
    expect(SportsChannelFilter.possible.preferred([weak]), same(weak));
    expect(SportsChannelFilter.all.preferred([]), isNull);
  });
}
