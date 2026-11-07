import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/services/multiview_session.dart';
import 'playback_recovery_test.dart'
    show TestStorage, TestPlaylist, TestPlayback, FakePlayer;
import 'multiview_session_test.dart' show FakeController;

Channel portalChannel() => Channel(
    id: 'p::portal',
    rawId: 'portal',
    playlistId: 'p',
    name: 'Portal',
    group: 'TV',
    url: 'stalker://play?type=itv&cmd=fixture');

class _Playlist extends TestPlaylist {
  _Playlist(super.storage);
  final pending = Completer<Channel>();
  int calls = 0;
  @override
  Future<Channel> resolvePlaybackChannel(Channel c) {
    calls++;
    return pending.future;
  }
}

class _Playback extends TestPlayback {
  _Playback(super.storage, super.playlistManager, super.log);
  final opened = <Channel>[];
  @override
  FakePlayer createController(Channel c, {String? url}) {
    opened.add(c);
    return super.createController(c, url: url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
  });
  testWidgets('stopping during portal resolution cannot start a late stream',
      (tester) async {
    final storage = TestStorage();
    await storage.init();
    final playlist = _Playlist(storage);
    final playback = _Playback(storage, playlist, []);
    final opening = playback.play(portalChannel());
    await tester.pump();
    expect(playlist.calls, 1);
    expect(playback.created, isEmpty);
    await playback.stop();
    playlist.pending.complete(
        portalChannel().copyWith(url: 'https://example.invalid/never-open'));
    await tester.pump();
    await opening;
    expect(playback.created, isEmpty);
    expect(playback.currentChannel, isNull);
    playback.dispose();
    playlist.dispose();
  });
  testWidgets(
      'resolved URL and headers reach player while selection retains stable command',
      (tester) async {
    final storage = TestStorage();
    await storage.init();
    final playlist = _Playlist(storage);
    final playback = _Playback(storage, playlist, []);
    final original = portalChannel();
    final opening = playback.play(original);
    await tester.pump();
    playlist.pending.complete(original.copyWith(
        url: 'https://example.invalid/resolved',
        httpHeaders: {'Cookie': 'fixture=1'}));
    await tester.pump();
    await opening;
    expect(playback.opened.single.url, 'https://example.invalid/resolved');
    expect(playback.opened.single.httpHeaders['Cookie'], 'fixture=1');
    expect(playback.currentChannel, same(original));
    await playback.stop();
    playback.created.single.ready.complete();
    await tester.pump();
    playback.dispose();
    playlist.dispose();
  });
  test('clearing a multiview tile invalidates its pending portal resolution',
      () async {
    final pending = Completer<Channel>();
    var creates = 0, calls = 0;
    final session = MultiviewSession(
        resolveChannel: (c) {
          calls++;
          return pending.future;
        },
        createController: (c) {
          creates++;
          return FakeController(c.id, []);
        },
        configure: (_) async {},
        configureGrid: (_, __) async {});
    final opening = session.assign(0, portalChannel());
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    final clearing = session.clear(0);
    pending.complete(
        portalChannel().copyWith(url: 'https://example.invalid/never-open'));
    await Future.wait([opening, clearing]);
    expect(creates, 0);
    expect(session.cells[0].controller, isNull);
    await session.close();
    session.dispose();
  });
}
