import 'package:nox_iptv/widgets/guide_fast_browse_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/m3u_group.dart';
import 'package:nox_iptv/screens/tv_home_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/services/viewer_profile_service.dart';
import 'package:nox_iptv/utils/constants.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GuidePlaylist extends PlaylistManager {
  GuidePlaylist(StorageService storage) : super(storage, CatalogDatabase());

  int categoryReads = 0;
  bool hideTestGroup = false;
  final live = Channel(
      id: 'p::one',
      rawId: 'one',
      playlistId: 'p',
      name: 'Test channel',
      group: 'Test group',
      url: 'https://example.com/live');

  @override
  bool get hasLiveChannels => channels.isNotEmpty;

  @override
  List<Channel> get channels => [live];

  @override
  List<M3uGroup> get tvGroups {
    categoryReads++;
    return [
      M3uGroup(
          title: 'Test group',
          playlistId: 'p',
          channels: [live],
          isHidden: hideTestGroup)
    ];
  }

  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      [live];
}

class CombinedGuidePlaylist extends GuidePlaylist {
  CombinedGuidePlaylist(super.storage);
  bool hideApple = false;
  int channelReads = 0;
  final feeds = [
    for (final (group, name) in [
      ('🏎️ Formula 1', 'Main feed'),
      ('UK| FORMULA 1 PPV', 'Driver camera'),
      ('UK| FORMULA 1 APPLE TV PPV', 'Apple feed')
    ])
      Channel(
          id: 'p::$name',
          rawId: name,
          playlistId: 'p',
          name: name,
          group: group,
          url: 'https://example.test/$name')
  ];
  @override
  List<M3uGroup> get tvGroups => [
        for (final title in ['EPGenius', 'TV Guide (USA)', 'TV Guide (UK)'])
          M3uGroup(title: title, playlistId: 'p', channels: []),
        for (final channel in feeds)
          M3uGroup(title: channel.group, playlistId: 'p', channels: [channel])
      ];
  @override
  List<Channel> get channels => feeds;
  @override
  List<Channel> visibleChannels(
      {String? playlistId, String? groupTitle, required String category}) {
    channelReads++;
    return feeds
        .where((c) =>
            (playlistId == null || playlistId == c.playlistId) &&
            (groupTitle == null || groupTitle == c.group) &&
            (!hideApple || c.name != 'Apple feed'))
        .toList();
  }
}

class SectionGuidePlaylist extends GuidePlaylist {
  SectionGuidePlaylist(super.storage, {int count = 60})
      : rows = [
          for (var i = 0; i < count; i++)
            Channel(
                id: 'p::row$i',
                rawId: 'row$i',
                playlistId: 'p',
                group: 'Test group',
                name: i == 0
                    ? '### News ###'
                    : i == 8
                        ? '### Sports ###'
                        : i == 20
                            ? '### Movies ###'
                            : 'Channel $i',
                url: 'https://example.test/$i')
        ];
  final List<Channel> rows;
  @override
  List<Channel> get channels => rows;
  @override
  List<Channel> visibleChannels(
          {String? playlistId, String? groupTitle, required String category}) =>
      rows;
}

class SearchGuidePlaylist extends GuidePlaylist {
  SearchGuidePlaylist(super.storage);
  int allReads = 0;
  final rows = [
    for (final country in ['USA', 'UK'])
      Channel(
          id: 'p::$country',
          rawId: country,
          playlistId: 'p',
          name: '$country 1',
          group: 'TV Guide ($country)',
          url: 'https://example.test/$country'),
  ];
  @override
  List<Channel> get channels => rows;
  @override
  List<M3uGroup> get tvGroups => [
        for (final c in rows)
          M3uGroup(title: c.group, playlistId: 'p', channels: [c])
      ];
  @override
  List<Channel> visibleChannels(
      {String? playlistId, String? groupTitle, required String category}) {
    if (groupTitle == null) allReads++;
    return rows
        .where((c) => groupTitle == null || c.group == groupTitle)
        .toList();
  }
}

class GuidePlayback extends PlaybackService {
  GuidePlayback(super.storage, super.playlistManager);
  @override
  Future<void> play(Channel channel) async {
    currentChannel = channel;
    notifyListeners();
  }
}

class GuideEpg extends EpgService {
  GuideEpg(super.storage);

  int reads = 0;
  List<EpgProgram> programs = [];
  @override
  List<EpgProgram> getPrograms(String channelId) {
    reads++;
    return programs;
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
  });
  Future<void> pumpHome(WidgetTester tester, Size size,
      {bool television = false,
      bool fullVideo = true,
      bool combined = false,
      bool searchGroups = false,
      bool sections = false,
      bool fakePlayback = false,
      int channelCount = 60}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      AppConstants.keyShowClock: false,
    });
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = television;
    prefs.guideViewMode = 'timeline';
    prefs.guideFullVideo = fullVideo;
    final playlist = searchGroups
        ? SearchGuidePlaylist(storage)
        : sections
            ? SectionGuidePlaylist(storage, count: channelCount)
            : combined
                ? CombinedGuidePlaylist(storage)
                : GuidePlaylist(storage);
    final playback = fakePlayback
        ? GuidePlayback(storage, playlist)
        : PlaybackService(storage, playlist);
    final epg = GuideEpg(storage);
    final viewers = ViewerProfileService(storage, playlist, playback);
    await tester.pumpWidget(MultiProvider(providers: [
      Provider.value(value: storage),
      ChangeNotifierProvider.value(value: prefs),
      ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
      ChangeNotifierProvider.value(value: playback),
      ChangeNotifierProvider<EpgService>.value(value: epg),
      ChangeNotifierProvider.value(value: viewers),
    ], child: const MaterialApp(home: TvHomeScreen())));
    await tester.pumpAndSettle();
    // Drain the one-off launch-update delay/timeout in virtual test time.
    // Widget tests block HTTP; no real update request is made.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 16));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      playback.dispose();
      viewers.dispose();
      playlist.dispose();
      prefs.dispose();
      epg.dispose();
      await tester.pump();
    });
  }

  testWidgets(
      'choosing a search result keeps focus on that channel after filtering closes',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true,
        fullVideo: false,
        sections: true,
        channelCount: 1000,
        fakePlayback: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guide-search')));
    await tester.pumpAndSettle();
    final timeline = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_TimelineGuide');
    for (final (index, digit) in ['9', '0', '0'].indexed) {
      final dynamic before = tester.widget(timeline);
      await tester.tap(find.text(digit).hitTestable());
      await tester.pump();
      if (index > 0) {
        final dynamic updating = tester.widget(timeline);
        expect(updating.channels, same(before.channels),
            reason: 'Refining search must not dispose the visible guide');
        expect(find.text('Updating results…'), findsOneWidget);
      }
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    }
    expect(find.text('Updating results…'), findsNothing);
    expect(find.text('Channel 900').hitTestable(), findsOneWidget);
    await tester.tap(find
        .descendant(
            of: find.byWidgetPredicate(
                (w) => w.runtimeType.toString() == '_ProgramBlock'),
            matching: find.byType(InkWell))
        .hitTestable()
        .first);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(TvHomeScreen));
    expect(context.read<PlaybackService>().currentChannel?.id, 'p::row900');
    final panel = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_GuideNowPanel');
    final dynamic summary = tester.widget(panel);
    expect(summary.focusedChannel.id, 'p::row900');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final dynamic next = tester.widget(panel);
    expect(next.focusedChannel.id, 'p::row901');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('TV Search submits pending query and focuses its first result',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true, fullVideo: false, sections: true, channelCount: 1000);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guide-search')));
    await tester.pumpAndSettle();
    for (final digit in ['9', '0', '0']) {
      await tester.tap(find.text(digit).hitTestable());
      await tester.pump();
    }
    await tester.tap(find.text('Search').hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Search').hitTestable(), findsNothing);
    expect(find.text('Channel 900').hitTestable(), findsNWidgets(2));
    final panel = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_GuideNowPanel');
    final dynamic summary = tester.widget(panel);
    expect(summary.focusedChannel.id, 'p::row900');
    final timeline = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_TimelineGuide');
    final dynamic guide = tester.widget(timeline);
    expect(guide.channels.length, 1);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('TV search scope, Clear and category changes cancel old filters',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true,
        fullVideo: false,
        searchGroups: true,
        fakePlayback: true);
    final groups = tester.widgetList(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == '_GroupRow'));
    final dynamic usa =
        groups.firstWhere((w) => (w as dynamic).label == 'TV Guide (USA)');
    final dynamic uk =
        groups.firstWhere((w) => (w as dynamic).label == 'TV Guide (UK)');
    usa.onTap();
    await tester.pumpAndSettle();
    final playlist = tester
        .element(find.byType(TvHomeScreen))
        .read<PlaylistManager>() as SearchGuidePlaylist;
    final timeline = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_TimelineGuide');
    List<String> names() =>
        ((tester.widget(timeline) as dynamic).channels as List<Channel>)
            .map((c) => c.name)
            .toList();
    await tester.tap(find.byKey(const ValueKey('guide-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1').hitTestable());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(names(), ['USA 1']);
    // Up from the letter row reaches the options; all three are remote accessible.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'guide-search-group');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(names(), ['USA 1', 'UK 1']);
    final reads = playlist.allReads;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'guide-search-clear');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Search').hitTestable(), findsOneWidget);
    expect(names(), ['USA 1', 'UK 1']);
    await tester.tap(find.text('9').hitTestable());
    await tester.pump();
    expect(playlist.allReads, reads,
        reason: 'Typing and clearing reuse the all-channel catalogue');
    uk.onTap();
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('Search').hitTestable(), findsNothing);
    expect(names(), ['UK 1'],
        reason: 'A pending query cannot filter a newly selected group');
    await tester.tap(find.byKey(const ValueKey('guide-search')));
    await tester.pumpAndSettle();
    expect(
        (tester.widget(find.byKey(const ValueKey('guide-search-scope-group')))
                as dynamic)
            .selected,
        isTrue);
    await tester.tap(find.text('1').hitTestable());
    await tester.pump();
    await tester.tap(find.text('Search').hitTestable());
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    usa.onTap();
    await tester.pumpAndSettle();
    expect(names(), ['USA 1'],
        reason: 'Submitted searches also clear on group selection');
    await tester.tap(find.byKey(const ValueKey('guide-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('U').hitTestable());
    await tester.pump();
    await tester.tap(find.text('K').hitTestable());
    await tester.tap(find.byKey(const ValueKey('guide-search-scope-all')));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(names(), ['UK 1']);
    await tester.tap(find.text('Search').hitTestable());
    await tester.pumpAndSettle();
    final dynamic globalResult = tester.widget(timeline);
    globalResult.onOpen(globalResult.channels.first);
    await tester.pumpAndSettle();
    expect(
        tester
            .element(find.byType(TvHomeScreen))
            .read<PlaybackService>()
            .currentChannel
            ?.id,
        'p::UK');
    await tester.tap(find.byKey(const ValueKey('guide-search')));
    await tester.pumpAndSettle();
    expect(
        (tester.widget(find.byKey(const ValueKey('guide-search-scope-group')))
                as dynamic)
            .selected,
        isTrue);
    expect(names(), ['UK 1'],
        reason:
            'Opening a global result enters its actual group without retaining the search');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('mobile search scope and Clear fit at $size', (tester) async {
      await pumpHome(tester, size, fullVideo: false, searchGroups: true);
      await tester.tap(find.byKey(const ValueKey('guide-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'UK');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('guide-search-scope-all')));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('UK 1').hitTestable(), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('guide-search-clear')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(find.byKey(const ValueKey('guide-search-scope-all')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('explicit channel restore wins a simultaneous list refresh',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true, fullVideo: false, sections: true, channelCount: 1000);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(TvHomeScreen));
    final playlist = Provider.of<PlaylistManager>(context, listen: false);
    final guideFinder = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_TimelineGuide');
    final dynamic guide = tester.state(guideFinder);
    playlist.notifyListeners();
    await tester.pump();
    guide.restoreFocusToChannel('p::row900');
    await tester.pumpAndSettle();
    final panel = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_GuideNowPanel');
    final dynamic summary = tester.widget(panel);
    expect(summary.focusedChannel.id, 'p::row900');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final dynamic next = tester.widget(panel);
    expect(next.focusedChannel.id, 'p::row901');
    guide.restoreFocusToChannel('p::row100');
    guide.restoreFocusToChannel('p::row700');
    await tester.pumpAndSettle();
    final dynamic latest = tester.widget(panel);
    expect(latest.focusedChannel.id, 'p::row700');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'combined guide keeps feeds, cached reads and fullscreen return stable',
      (tester) async {
    await pumpHome(tester, const Size(390, 844),
        fullVideo: false, combined: true);
    final initialContext = tester.element(find.byType(TvHomeScreen));
    final initialPlaylist =
        Provider.of<PlaylistManager>(initialContext, listen: false)
            as CombinedGuidePlaylist;
    final initialPlayback =
        Provider.of<PlaybackService>(initialContext, listen: false);
    initialPlayback.currentChannel = initialPlaylist.feeds[1];
    initialPlayback.notifyListeners();
    await tester.pumpAndSettle();
    // A resumed source feed resolves to its combined category in grouped mode.
    expect(find.text('Main feed').hitTestable(), findsWidgets);
    expect(find.text('Apple feed').hitTestable(), findsWidgets);
    initialPlayback.currentChannel = null;
    await tester.tap(find.byIcon(Icons.arrow_back).hitTestable());
    await tester.pumpAndSettle();
    final toolbar = find.byKey(const ValueKey('live-category-toolbar'));
    final allChannels = find.byKey(const ValueKey('all-live-channels'));
    expect(tester.getSize(toolbar).height, 26);
    expect(tester.getTopLeft(toolbar).dy - tester.getBottomLeft(allChannels).dy,
        lessThanOrEqualTo(1));
    await tester.longPress(find.text('Formula 1').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Browse an individual feed group'), findsOneWidget);
    expect(find.text('UK| FORMULA 1 APPLE TV PPV'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Formula 1').hitTestable());
    await tester.pumpAndSettle();
    for (final name in ['Main feed', 'Driver camera', 'Apple feed']) {
      expect(find.text(name).hitTestable(), findsWidgets);
    }
    expect(find.textContaining('__live_collection__'), findsNothing);
    final context = tester.element(find.byType(TvHomeScreen));
    final playlist = Provider.of<PlaylistManager>(context, listen: false)
        as CombinedGuidePlaylist;
    final playback = Provider.of<PlaybackService>(context, listen: false);
    final reads = playlist.channelReads;
    // Exercise the fullscreen-return lifecycle without opening a stream.
    playback.currentChannel = playlist.feeds[1];
    playback.isFullscreenActive = true;
    final dynamic state = tester.state(find.byType(TvHomeScreen));
    state.didPopNext();
    await tester.pumpAndSettle();
    expect(find.text('Main feed').hitTestable(), findsWidgets);
    expect(find.text('Apple feed').hitTestable(), findsWidgets);
    expect(playlist.channelReads, reads);
    playback.isFullscreenActive = false;
    playback.currentChannel = null;
    playlist.hideApple = true;
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Apple feed').hitTestable(), findsNothing);
    expect(find.text('Driver camera').hitTestable(), findsWidgets);
    expect(playlist.channelReads, reads + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'changing guide density retains the top channel and column alignment',
      (tester) async {
    await pumpHome(tester, const Size(900, 650),
        fullVideo: false, sections: true);
    ListView grid() => tester
        .widget<ListView>(find.byKey(const ValueKey('guide-programme-scroll')));
    grid().controller!.jumpTo(10.25 * 44);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(grid().itemExtent, 36);
    expect(grid().controller!.offset, closeTo(10.25 * 36, .1));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(grid().itemExtent, 44);
    expect(grid().controller!.offset, closeTo(10.25 * 44, .1));
    final labels = tester
        .widget<ListView>(find.byKey(const ValueKey('guide-channel-scroll')));
    expect(labels.controller!.offset, grid().controller!.offset);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'guide virtualizes time slots and keeps remote focus across windows',
      (tester) async {
    await pumpHome(tester, const Size(960, 540),
        television: true, fullVideo: false, sections: true);
    final epg = Provider.of<EpgService>(
        tester.element(find.byType(TvHomeScreen)),
        listen: false) as GuideEpg;
    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day, now.hour,
            now.minute - now.minute % 30)
        .subtract(const Duration(hours: 2));
    epg.programs = [
      for (var i = 0; i < 100; i++)
        EpgProgram(
            channelId: 'test',
            title: 'Programme $i',
            start: base.add(Duration(minutes: i * 5)),
            stop: base.add(Duration(minutes: (i + 1) * 5)))
    ];
    epg.notifyListeners();
    await tester.pumpAndSettle();
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
    final rows = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_TimelineRow');
    final blocks = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_ProgramBlock');
    expect(blocks.evaluate().length, lessThan(rows.evaluate().length * 50));
    EpgProgram? focused() {
      EpgProgram? result;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
        if (e.widget.runtimeType.toString() == '_ProgramBlock') {
          result = (e.widget as dynamic).program as EpgProgram?;
          return false;
        }
        return true;
      });
      return result;
    }

    expect(focused(), isNotNull);
    for (var i = 1; i <= 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      final expected = base.add(Duration(minutes: 120 + 30 * i));
      expect(focused(), isNotNull);
      expect(focused()!.start.isAfter(expected), isFalse);
      expect(focused()!.stop.isAfter(expected), isTrue);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote reaches and navigates the complete guide toolbar',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        fullVideo: false, sections: true, television: true);
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'timeline-filter-button');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'guide-now');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'guide-next-section');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        isNot('guide-next-section'));
    for (var i = 0; i < 18; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'timeline-filter-button',
        reason: 'Menu reaches tools without scrolling to row zero');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final before = FocusManager.instance.primaryFocus;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'timeline-filter-button');
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'timeline-filter-button',
        reason: 'Remaining hold repeats stay in tools');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(before),
        reason: 'Tools return to the same channel and time');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'remote guide navigation reuses categories until the playlist changes',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        fullVideo: false, sections: true, television: true);
    final context = tester.element(find.byType(TvHomeScreen));
    final playlist = Provider.of<PlaylistManager>(context, listen: false)
        as SectionGuidePlaylist;
    final reads = playlist.categoryReads;
    expect(reads, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    for (var i = 0; i < 16; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(playlist.categoryReads, reads);
    playlist.hideTestGroup = true;
    playlist.notifyListeners();
    await tester.pumpAndSettle();
    expect(playlist.categoryReads, reads + 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Test group').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'remote focus updates summary without rebuilding mounted guide rows',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        fullVideo: false, sections: true, television: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(TvHomeScreen));
    final epg = context.read<EpgService>() as GuideEpg;
    // First move settles automatic focus/rail transitions; both rows are visible.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final reads = epg.reads;
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(
          i.isEven ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowUp);
      await tester.pump();
    }
    expect(epg.reads, reads,
        reason: 'Focus must not re-query/rebuild the entire guide');
    expect(find.text('Channel 1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('column transitions reuse mounted programme widgets',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        fullVideo: false, sections: true, television: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final before = tester
        .widgetList(find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_TimelineRow'))
        .toList();
    expect(before, isNotEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final after = tester
        .widgetList(find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_TimelineRow'))
        .toList();
    expect(after.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(identical(before[i], after[i]), isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '80k guide accelerates a real hold, bounds work, and stops on release',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true,
        fullVideo: false,
        sections: true,
        channelCount: 80000);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final dynamic guide = tester.state(find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_TimelineGuide'));
    final epg = tester.element(find.byType(TvHomeScreen)).read<EpgService>()
        as GuideEpg;
    final gridWidget = tester
        .widget<ListView>(find.byKey(const ValueKey('guide-programme-scroll')));
    final grid = gridWidget.controller!;
    // The Android compatibility path can stamp every repeat at zero. Use
    // that path's hardware/focus dispatch while advancing the binding clock.
    void key(KeyEvent e) {
      HardwareKeyboard.instance.handleKeyEvent(e);
      // Exercise the legacy Android repeat path still used by this TV.
      // ignore: deprecated_member_use
      tester.binding.keyEventManager.keyMessageHandler!(KeyMessage([e], null));
    }

    key(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: LogicalKeyboardKey.arrowDown,
        timeStamp: Duration.zero));
    await tester.pump();
    int? fastReads;
    for (var ms = 100; ms <= 22000; ms += 100) {
      key(const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      if (ms == 4000) {
        expect(find.byType(GuideFastBrowseRow), findsNothing,
            reason: 'Normal guide stays intact for the first five seconds');
      }
      if (ms == 6000) fastReads = epg.reads;
    }
    expect(grid.offset, greaterThan(2000 * gridWidget.itemExtent!));
    expect(epg.reads, fastReads,
        reason: 'Skipped rows must not request database loads');
    final visibleRows =
        (grid.position.viewportDimension / gridWidget.itemExtent!).ceil();
    expect(
        find
            .byWidgetPredicate(
                (w) => w.runtimeType.toString() == 'GuideFastBrowseRow')
            .evaluate()
            .length,
        lessThanOrEqualTo((visibleRows + 1) * 2),
        reason:
            'Fast jumps should lay out only visible labels and timeline rows');
    expect(guide.mountedProgrammeRowCount, lessThan(45));
    expect(find.byKey(const ValueKey('guide-browse-position')), findsOneWidget);
    final fastLabels = tester
        .widgetList<GuideFastBrowseRow>(find.byType(GuideFastBrowseRow))
        .where((w) => w.label && w.textInset == 46);
    expect(fastLabels, isNotEmpty,
        reason: 'Reserve the normal 30px logo, 8px gap and 8px padding');
    expect(fastLabels.every((w) => w.fontSize == 13), isTrue);
    final beforeRelease = grid.offset;
    // Repeats delivered together while the UI is busy must not accumulate.
    for (var ms = 22100; ms <= 23000; ms += 100) {
      key(const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration.zero));
    }
    key(const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: LogicalKeyboardKey.arrowDown,
        timeStamp: Duration(seconds: 23)));
    await tester.pump();
    await tester.pump();
    expect(epg.reads, greaterThan(fastReads!));
    expect(grid.offset, beforeRelease,
        reason: 'Release discards repeats not yet rendered');
    final landed = grid.offset;
    await tester.pump(const Duration(seconds: 2));
    expect(grid.offset, landed,
        reason: 'Release must not leave a repeat backlog');
    expect(find.byKey(const ValueKey('guide-browse-position')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(grid.offset - landed, closeTo(gridWidget.itemExtent!, .1),
        reason: 'A fresh tap is one row');
    guide.moveVertical(1000000);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(grid.offset, grid.position.maxScrollExtent);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(grid.offset, grid.position.maxScrollExtent,
        reason: 'End of list never wraps');
    guide.moveVertical(-1000000);
    // Back before the destination mounts must cancel its pending focus restore.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
        tester
            .getSize(find.byKey(const ValueKey('live-categories-rail')))
            .width,
        208);
    expect(guide.mountedProgrammeRowCount, lessThan(45));
    expect(tester.takeException(), isNull);
  });

  testWidgets('refreshing a focused guide keeps its first row navigable',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true, fullVideo: false, sections: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    tester
        .element(find.byType(TvHomeScreen))
        .read<PlaylistManager>()
        .notifyListeners();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final dynamic panel = tester.widget(find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_GuideNowPanel'));
    expect(panel.focusedChannel?.id, 'p::row1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('guide clock ticks do not rebuild unchanged programme rows',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true, fullVideo: false, sections: true);
    final epg = tester.element(find.byType(TvHomeScreen)).read<EpgService>()
        as GuideEpg;
    final reads = epg.reads;
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(epg.reads, reads);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '80k-channel TV guide mounts only viewport rows, including distant jumps',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true,
        fullVideo: false,
        sections: true,
        channelCount: 80000);
    final rows = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_TimelineRow');
    final labels = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_ChannelLabel');
    expect(rows.evaluate().length, inInclusiveRange(5, 40));
    expect(labels.evaluate().length, inInclusiveRange(5, 40));
    final grid = tester
        .widget<ListView>(find.byKey(const ValueKey('guide-programme-scroll')));
    grid.controller!.jumpTo(50000 * grid.itemExtent!);
    await tester.pumpAndSettle();
    expect(find.text('Channel 50000'), findsOneWidget);
    expect(rows.evaluate().length, lessThan(40));
    expect(labels.evaluate().length, lessThan(40));
    grid.controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Channel 1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden guide defers row and clock rebuilds until resume',
      (tester) async {
    await pumpHome(tester, const Size(1280, 720),
        television: true, fullVideo: false, sections: true);
    final context = tester.element(find.byType(TvHomeScreen));
    final epg = context.read<EpgService>() as GuideEpg;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final reads = epg.reads;
    epg.guideRowsLoaded.value++;
    await tester.pump(const Duration(seconds: 31));
    expect(epg.reads, reads);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(epg.reads, greaterThan(reads));
    expect(tester.takeException(), isNull);
  });

  for (final (size, television) in [
    (const Size(390, 844), false),
    (const Size(844, 390), false),
    (const Size(1280, 720), true)
  ]) {
    testWidgets(
        'section headings pin, push away, scroll and protect focus at $size',
        (tester) async {
      await pumpHome(tester, size,
          fullVideo: false, sections: true, television: television);
      final labelFinder = find.byKey(const ValueKey('guide-channel-scroll'));
      final gridFinder = find.byKey(const ValueKey('guide-programme-scroll'));
      final grid = tester.widget<ListView>(gridFinder).controller!;
      final labels = tester.widget<ListView>(labelFinder).controller!;
      final height = !television && size.width > size.height ? 36.0 : 44.0;
      final header = find.byKey(const ValueKey('guide-sticky-section'));
      expect(header, findsNothing);
      grid.jumpTo(3 * height);
      await tester.pumpAndSettle();
      expect(find.descendant(of: header, matching: find.text('News')),
          findsOneWidget);
      expect(labels.offset, grid.offset);
      final headerTop = tester.getTopLeft(header).dy;
      expect(headerTop, closeTo(tester.getTopLeft(gridFinder).dy, .1));
      grid.jumpTo(7.5 * height);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(header).dy, closeTo(headerTop - height / 2, .1));
      labels.jumpTo(10 * height);
      await tester.pumpAndSettle();
      expect(find.descendant(of: header, matching: find.text('Sports')),
          findsOneWidget);
      expect(grid.offset, labels.offset);
      // A header tap must never play the channel hidden underneath it.
      final context = tester.element(find.byType(TvHomeScreen));
      final playback = Provider.of<PlaybackService>(context, listen: false);
      await tester.tap(header);
      await tester.pump();
      expect(playback.currentChannel, isNull);
      final before = grid.offset;
      await tester.drag(header, const Offset(0, -65));
      await tester.pumpAndSettle();
      expect(grid.offset, greaterThan(before));
      expect(labels.offset, grid.offset);
      // Native scrolling still works directly over the channel-name column.
      await tester.dragFrom(
          tester.getTopLeft(labelFinder) + Offset(70, height * 2),
          const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(labels.offset, grid.offset);
      grid.jumpTo(10 * height);
      await tester.pumpAndSettle();
      final guideFinder = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_TimelineGuide');
      final dynamic guide = tester.state(guideFinder);
      guide.focusEntry();
      await tester.pumpAndSettle();
      expect(grid.offset, lessThanOrEqualTo(9 * height));
      expect(labels.offset, grid.offset);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(grid.offset, lessThanOrEqualTo(8 * height));
      grid.jumpTo(0);
      await tester.pumpAndSettle();
      expect(header, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, tv, width) in [
    (const Size(844, 390), false, 30.0),
    (const Size(1280, 720), true, 0.0)
  ]) {
    testWidgets(
        'guide rails collapse to $width and reopen without changing categories',
        (tester) async {
      await pumpHome(tester, size, television: tv, fullVideo: false);
      if (tv) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      } else {
        await tester.tap(find.text('Test group'));
      }
      await tester.pumpAndSettle();
      final navigation = find.byKey(const ValueKey('live-navigation-rail'));
      final categories = find.byKey(const ValueKey('live-categories-rail'));
      expect(tester.getSize(navigation).width, width);
      expect(tester.getSize(categories).width, width);
      if (tv) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(tester.getCenter(categories));
      }
      await tester.pumpAndSettle();
      expect(tester.getSize(categories).width, tv ? 208 : 180);
      expect(find.text('Test group').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final size in [
    const Size(720, 720),
    const Size(840, 960),
    const Size(1024, 600)
  ]) {
    testWidgets('wide non-TV guide has working Back at $size', (tester) async {
      await pumpHome(tester, size);
      expect(find.byTooltip('Back'), findsNothing);
      await tester.tap(find.text('Test group'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      // First Back opens groups; second opens tabs, without exiting.
      expect(find.byTooltip('Back'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back'), findsNothing);
      expect(find.byType(TvHomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));
  }

  for (final systemBack in [false, true]) {
    testWidgets(
        '${systemBack ? 'System' : 'Touch'} Back reopens columns when focus cannot move during resize',
        (tester) async {
      await pumpHome(tester, const Size(840, 960));
      await tester.tap(find.text('Test group'));
      await tester.pumpAndSettle();
      final columns = tester
          .widgetList<FocusScope>(find.byType(FocusScope))
          .map((w) => w.focusNode)
          .whereType<FocusScopeNode>()
          .where((n) => n.debugLabel == 'tv-col1' || n.debugLabel == 'tv-tabs')
          .toList();
      expect(columns, hasLength(2));
      // Touch navigation must work even while the newly laid-out column
      // cannot accept focus (for example during fold/unfold reparenting).
      for (final node in columns) {
        node.canRequestFocus = false;
      }
      await tester.pump();
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.text('Test group').hitTestable(), findsNothing);
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byTooltip('Back'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Test group').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byTooltip('Back'));
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back'), findsNothing);
      expect(find.byType(TvHomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('compact portrait retains its existing single back arrow',
      (tester) async {
    await pumpHome(tester, const Size(400, 850));
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.byType(TvHomeScreen), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('folding and unfolding keeps a way back from the guide',
      (tester) async {
    await pumpHome(tester, const Size(840, 960));
    await tester.tap(find.text('Test group'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsOneWidget);
    tester.view.physicalSize = const Size(400, 850);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    tester.view.physicalSize = const Size(840, 960);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Test group').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('real TV keeps remote navigation without a header back button',
      (tester) async {
    await pumpHome(tester, const Size(1920, 1080), television: true);
    await tester.tap(find.text('Test group'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
