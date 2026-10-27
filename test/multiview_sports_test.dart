import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/services/multiview_sports.dart';

Channel _ch(String name, String group) => Channel(
    id: 'p::$name',
    rawId: name,
    playlistId: 'p',
    name: name,
    group: group,
    url: 'http://x/$name');

void main() {
  test('sports channels by group or name, whole words only', () {
    bool s(String name, String group) =>
        MultiviewSports.isSports(_ch(name, group));
    expect(s('NHL | 02 - 7pm Avalanche at Flyers', 'NHL | Events'), isTrue);
    expect(s('Channel 1', 'USA | SPORTS'), isTrue);
    expect(s('ESPN2 HD', 'USA | Entertainment'), isTrue);
    expect(s('TSN 3', 'CA | General'), isTrue);
    expect(s('DAZN 1 ES', 'Spain'), isTrue);
    expect(s('Sky Sports Main Event', 'UK'), isTrue);
    expect(s('beIN Sports 1', 'FR'), isTrue);
    expect(s('CNN', 'USA | News'), isFalse);
    expect(s('HDF1 Kids', 'Kids'), isFalse); // "f1" inside a word
    expect(s('Transport TV', 'Docs'), isFalse); // "sport" inside a word
  });
}
