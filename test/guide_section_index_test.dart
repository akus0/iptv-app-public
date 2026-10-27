import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/utils/guide_section_index.dart';

Channel channel(int i,
        {String? name, String group = 'Guide', String playlist = 'p'}) =>
    Channel(
        id: '$playlist::$i',
        rawId: '$i',
        playlistId: playlist,
        name: name ?? 'Channel $i',
        group: group,
        url: 'https://example.test/$i');

class CountedChannels extends ListBase<Channel> {
  CountedChannels(this.values);
  final List<Channel> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  Channel operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, Channel value) =>
      throw UnsupportedError('read only');
}

void main() {
  test(
      'headers pin and push out at the next section, in both scroll directions',
      () {
    final index = GuideSectionIndex([
      for (var i = 0; i < 30; i++)
        channel(i,
            name: i == 0
                ? '### News ###'
                : i == 10
                    ? '### Sports ###'
                    : null)
    ]);
    expect(index.pinned(0, 44), isNull);
    expect(index.pinned(44, 44), (section: 0, displacement: 0.0));
    expect(index.pinned(418, 44), (section: 0, displacement: -22.0));
    expect(index.pinned(440, 44), isNull);
    expect(index.pinned(441, 44), (section: 1, displacement: 0.0));
    expect(index.pinned(400, 44), (section: 0, displacement: -4.0));
    expect(index.pinned(-20, 44), isNull);
  });
  test(
      'headings stop at category and playlist boundaries, including an unheaded tail',
      () {
    final index = GuideSectionIndex([
      channel(0, name: '### News'),
      channel(1),
      channel(2),
      channel(3, group: 'Other'),
      channel(4, group: 'Other'),
      channel(5, group: 'Other', name: '### Films'),
      channel(6, group: 'Other'),
      channel(7, playlist: 'second', group: 'Other'),
      channel(8, playlist: 'second', group: 'Other')
    ]);
    expect(index.sections.map((s) => (s.start, s.end)), [(0, 3), (5, 7)]);
    expect(index.pinned(110, 44), (section: 0, displacement: -22.0));
    expect(index.pinned(132, 44), isNull);
    expect(index.pinned(308, 44), isNull);
    expect(index.focusTop(3, 44), 132);
  });
  test('empty/consecutive headings never cover unrelated rows', () {
    final index = GuideSectionIndex([
      channel(0, name: '### Empty'),
      channel(1, name: '### Sports'),
      channel(2),
      channel(3, name: '### End')
    ]);
    expect(index.pinned(10, 44), isNull);
    expect(index.pinned(45, 44)?.section, 1);
    expect(index.pinned(133, 44), isNull);
    expect(GuideSectionIndex([]).pinned(40, 44), isNull);
    expect(GuideSectionIndex([channel(0)]).pinned(40, 44), isNull);
  });
  test(
      'remote focus leaves one header row of space and can focus the original header',
      () {
    final index = GuideSectionIndex([
      for (var i = 0; i < 20; i++)
        channel(i, name: i == 5 ? '### Sports' : null)
    ]);
    expect(index.focusTop(2, 44), 88);
    expect(index.focusTop(5, 44), 220);
    expect(index.focusTop(6, 44), 220);
    expect(index.focusTop(12, 44), 484);
  });
  test(
      '80k catalogue is indexed once; scroll and focus do not revisit channels',
      () {
    final channels = CountedChannels([
      for (var i = 0; i < 80000; i++)
        channel(i, name: i % 1000 == 0 ? '### Section $i' : null)
    ]);
    final index = GuideSectionIndex(channels);
    final reads = channels.reads;
    expect(index.sections.length, 80);
    expect(reads, 80000);
    for (var i = 0; i < 80000; i += 7) {
      index.pinned(i * 44.0, 44);
      index.focusTop(i, 44);
    }
    expect(channels.reads, reads);
  });
}
