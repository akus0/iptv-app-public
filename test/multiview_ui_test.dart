import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:video_player_hdr/video_player_hdr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/channel.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/screens/multiview_screen.dart';
import 'package:nox_iptv/screens/tv_home_screen.dart'
    show LiveGuideSelectionViewport;
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/multiview_session.dart';
import 'package:nox_iptv/services/playback_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/multiview_channel_picker.dart';
import 'multiview_session_test.dart' show FakeController, channel, profile;

class Playlist extends PlaylistManager {
  Playlist(StorageService storage, this.rows)
      : super(storage, CatalogDatabase());
  final List<Channel> rows;
  @override
  List<Channel> get visibleLiveChannels => rows;
  @override
  List<PlaylistProfile> get profiles => [profile(max: 1)];
  @override
  Future<void> ensureLiveChannelsLoaded() async {}
}

class PickerEpg extends EpgService {
  PickerEpg(super.storage);
  @override
  EpgProgram? getCurrentProgram(String id) => id == '79998'
      ? EpgProgram(
          channelId: id,
          title: 'Tournament coverage',
          description: 'Almaty quarterfinal tennis',
          start: DateTime.now().subtract(const Duration(minutes: 10)),
          stop: DateTime.now().add(const Duration(hours: 1)),
        )
      : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
  });
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(732, 360),
    const Size(844, 390),
    const Size(960, 540),
    const Size(1280, 720)
  ]) {
    testWidgets('multiview layout, sound, options and fullscreen fit $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (size.width < 960) {
        tester.view.padding = FakeViewPadding(
          top: size.height > size.width ? 24 : 0,
          left: size.width > size.height ? 24 : 0,
          bottom: 24,
        );
        addTearDown(tester.view.resetPadding);
      }
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width >= 960;
      final playlist =
          Playlist(storage, [channel(1), channel(2), channel(3), channel(4)]);
      final playback = PlaybackService(storage, playlist);
      final session = MultiviewSession(
          configure: (_) async {},
          configureGrid: (_, __) async {},
          createController: (c) => FakeController(c.rawId, []));
      final boundary = GlobalKey();
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: EpgService(storage))
          ],
          child: MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              home: RepaintBoundary(
                  key: boundary, child: MultiviewScreen(session: session)))));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('multiview-cell-0')));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
      expect(find.text('Live TV guide'), findsOneWidget);
      expect(find.text('Sports events'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await settle(tester);
      if (find.byType(MultiviewChannelPicker).evaluate().isNotEmpty) {
        await tester.binding.handlePopRoute();
        await settle(tester);
      }
      await session.assign(0, channel(1));
      await session.assign(1, channel(2));
      await settle(tester);
      expect(find.byKey(const ValueKey('multiview-cell-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('multiview-cell-1')), findsOneWidget);
      final first = session.cells[0].controller!;
      first.value = first.value.copyWith(isPlaying: false);
      await settle(tester);
      expect(find.text('Waiting for stream…'), findsOneWidget);
      first.value = first.value.copyWith(isPlaying: true);
      await settle(tester);
      expect(find.text('Waiting for stream…'), findsNothing);
      if (size.width >= 960) {
        final surfaces = tester
            .widgetList<VideoPlayerHdr>(find.byType(VideoPlayerHdr))
            .toList();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle(tester);
        expect(
            tester
                .widgetList<VideoPlayerHdr>(find.byType(VideoPlayerHdr))
                .toList(),
            orderedEquals(surfaces));
        expect(find.textContaining('Listen to this channel'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
            FocusManager.instance.primaryFocus?.debugLabel, 'multiview-change');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)));
        await settle(tester);
        expect(find.byType(MultiviewChannelPicker), findsOneWidget);
        await tester.tap(find.byType(BackButton).first);
        await settle(tester);
        if (find.byType(MultiviewChannelPicker).evaluate().isNotEmpty) {
          await tester.tap(find.byType(BackButton).first);
          await settle(tester);
        }
        expect(session.cells[0].controller, same(first));
        expect((first as FakeController).disposed, false);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'multiview-options');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester);
        expect(find.text('Change channel'), findsOneWidget);
        await tester.tap(find.byTooltip('Close'));
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(
            FocusManager.instance.primaryFocus?.debugLabel, 'multiview-back');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
            FocusManager.instance.primaryFocus?.debugLabel, 'multiview-layout');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
            FocusManager.instance.primaryFocus?.debugLabel, 'multiview-mute');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
            FocusManager.instance.primaryFocus?.debugLabel, 'multiview-cell-0');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        expect(
            FocusManager.instance.primaryFocus?.debugLabel, 'multiview-cell-1');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester);
      } else {
        await tester.tap(find.byKey(const ValueKey('multiview-cell-1')));
        await settle(tester);
      }
      expect(session.active, 1);
      expect(session.cells[0].controller!.value.volume, 0);
      if (size.width >= 960) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('multiview-mute')));
      await settle(tester);
      expect(session.muted, true);
      if (size.width >= 960) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('multiview-mute')));
      await settle(tester);
      final videoState = tester.state(find.byType(VideoPlayerHdr).at(1));
      await tester.tap(find.byKey(const ValueKey('multiview-cell-1')));
      await settle(tester);
      expect(tester.state(find.byType(VideoPlayerHdr)), same(videoState));
      expect(
          tester.getRect(find.byKey(const ValueKey('multiview-video-area-1'))),
          Offset.zero & size);
      if (size.width < 960) {
        final label = tester
            .getRect(find.byKey(const ValueKey('multiview-channel-label-1')));
        expect(label.bottom, size.height - 24);
        expect(label.left, size.width > size.height ? 24 : 0);
      }
      expect(find.byKey(const ValueKey('multiview-cell-0')), findsNothing);
      expect(find.byTooltip('Back to multiview'), findsWidgets);
      if (size.width >= 960) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Back to multiview').first);
      await settle(tester);
      expect(tester.state(find.byType(VideoPlayerHdr).at(1)), same(videoState));
      final controller = session.cells[1].controller;
      for (final layout in ['Side by side', 'Stacked']) {
        tester
            .widget<TextButton>(find.byKey(const ValueKey('multiview-layout')))
            .focusNode!
            .requestFocus();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('multiview-layout')));
        await settle(tester);
        await tester.ensureVisible(find.text(layout));
        await tester.pumpAndSettle();
        await tester.tap(find.text(layout));
        await settle(tester);
        final firstRect =
            tester.getRect(find.byKey(const ValueKey('multiview-cell-0')));
        final secondRect =
            tester.getRect(find.byKey(const ValueKey('multiview-cell-1')));
        expect(firstRect.top, 0);
        expect(secondRect.bottom, size.height);
        expect(
            tester
                .getRect(find.byKey(const ValueKey('multiview-video-area-0'))),
            firstRect);
        expect(
            tester
                .getRect(find.byKey(const ValueKey('multiview-video-area-1'))),
            secondRect);
        if (layout == 'Stacked') {
          if (size.width >= 960) {
            expect(firstRect.top, 0);
            expect(secondRect.bottom, size.height);
            // Header and footer reveal on remote focus without resizing video.
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pump();
            expect(FocusManager.instance.primaryFocus?.debugLabel,
                'multiview-back');
            final header = find
                .ancestor(
                    of: find.byKey(const ValueKey('multiview-layout')),
                    matching: find.byType(Opacity))
                .first;
            expect(tester.widget<Opacity>(header).opacity, 1);
            expect(
                tester.getRect(find.byKey(const ValueKey('multiview-cell-0'))),
                firstRect);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(tester.widget<Opacity>(header).opacity, 0);
          }
          expect(secondRect.top, greaterThanOrEqualTo(firstRect.bottom));
          expect(secondRect.left, firstRect.left);
          expect(firstRect.width, greaterThan(size.width - 10));
          final video = tester
              .getRect(find.byKey(const ValueKey('multiview-video-area-0')));
          expect(video.height, greaterThanOrEqualTo(firstRect.height - 2));
          if (size.width >= 960) {
            expect(find.byKey(const ValueKey('multiview-channel-label-0')),
                findsNothing);
            expect(find.byKey(const ValueKey('multiview-channel-label-1')),
                findsNothing);
          } else {
            final label = tester.getRect(
                find.byKey(const ValueKey('multiview-channel-label-0')));
            expect(video.overlaps(label), true,
                reason:
                    'Touch controls do not reserve a strip in stacked view');
          }
          expect(secondRect.top - firstRect.bottom, lessThanOrEqualTo(2));
        } else {
          expect(secondRect.left, greaterThanOrEqualTo(firstRect.right));
          expect(secondRect.top, firstRect.top);
          expect(
              firstRect.width + secondRect.width, greaterThan(size.width - 10));
        }
        expect(
            tester.state(find.byType(VideoPlayerHdr).at(1)), same(videoState));
        expect(session.cells[1].controller, same(controller));
        expect((controller as FakeController).disposed, false);
        expect(session.active, 1);
        expect(storage.getMultiviewLayout(),
            layout == 'Stacked' ? 'stacked' : 'sideBySide');
        expect(tester.takeException(), isNull);
      }
      tester
          .widget<TextButton>(find.byKey(const ValueKey('multiview-layout')))
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('multiview-layout')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('multiview-fill')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('multiview-fill')));
      await settle(tester);
      await tester.tap(find.byTooltip('Close'));
      await settle(tester);
      expect(storage.getMultiviewFill(), true);
      final fit = tester.widget<FittedBox>(find
          .ancestor(
              of: find.byType(VideoPlayerHdr).at(1),
              matching: find.byType(FittedBox))
          .first);
      expect(fit.fit, BoxFit.cover);
      expect(tester.state(find.byType(VideoPlayerHdr).at(1)), same(videoState));
      // Fullscreen keeps the entire picture even when the split view uses Fill.
      await tester.tap(find.byKey(const ValueKey('multiview-cell-1')));
      await settle(tester);
      expect(
          tester
              .widget<FittedBox>(find
                  .ancestor(
                      of: find.byType(VideoPlayerHdr),
                      matching: find.byType(FittedBox))
                  .first)
              .fit,
          BoxFit.contain);
      if (size.width >= 960) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Back to multiview').first);
      await settle(tester);
      tester
          .widget<TextButton>(find.byKey(const ValueKey('multiview-layout')))
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('multiview-layout')));
      await settle(tester);
      await tester.ensureVisible(find.text('4 screens'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('4 screens'));
      await settle(tester);
      await session.assign(2, channel(3));
      await session.assign(3, channel(4));
      await settle(tester);
      expect(find.byKey(const ValueKey('multiview-cell-3')), findsOneWidget);
      {
        final first =
            tester.getRect(find.byKey(const ValueKey('multiview-cell-0')));
        final second =
            tester.getRect(find.byKey(const ValueKey('multiview-cell-1')));
        final third =
            tester.getRect(find.byKey(const ValueKey('multiview-cell-2')));
        final fourth =
            tester.getRect(find.byKey(const ValueKey('multiview-cell-3')));
        expect(first.topLeft, Offset.zero);
        expect(fourth.bottomRight, Offset(size.width, size.height));
        expect(first.right, second.left);
        expect(first.bottom, third.top);
        for (var i = 0; i < 4; i++) {
          if (size.width >= 960) {
            expect(find.byKey(ValueKey('multiview-channel-label-$i')),
                findsNothing);
          }
          expect(
              tester.getSize(find.byKey(ValueKey('multiview-video-area-$i'))),
              Size(size.width / 2, size.height / 2));
        }
      }
      if (size.width < 960) {
        final surface = tester.state(find.byType(VideoPlayerHdr).first);
        final before = tester
            .getRect(find.byKey(const ValueKey('multiview-video-area-0')));
        final chrome = find
            .ancestor(
                of: find.byKey(const ValueKey('multiview-layout')),
                matching: find.byType(Opacity))
            .first;
        await tester.pump(const Duration(seconds: 5));
        expect(tester.widget<Opacity>(chrome).opacity, 0);
        for (var i = 0; i < 4; i++) {
          final label = find
              .ancestor(
                  of: find.byKey(ValueKey('multiview-channel-label-$i')),
                  matching: find.byType(Opacity))
              .first;
          expect(tester.widget<Opacity>(label).opacity, 0);
        }
        final active = session.active;
        await tester.tap(find.byKey(const ValueKey('multiview-cell-0')));
        await tester.pump();
        expect(tester.widget<Opacity>(chrome).opacity, 1);
        expect(session.active, active,
            reason:
                'First tap reveals controls without switching audio or expanding');
        expect(find.byType(VideoPlayerHdr), findsNWidgets(4));
        expect(tester.state(find.byType(VideoPlayerHdr).first), same(surface));
        expect(
            tester
                .getRect(find.byKey(const ValueKey('multiview-video-area-0'))),
            before);
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/iptv105-layout-${size.width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      if (size.width >= 960) {
        tester
            .widget<InkWell>(find.byKey(const ValueKey('multiview-cell-3')))
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      } else {
        await tester.longPress(find.byKey(const ValueKey('multiview-cell-3')));
      }
      await settle(tester);
      expect(find.text('Change channel'), findsOneWidget);
      await tester.ensureVisible(find.text('Remove channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove channel'));
      await settle(tester);
      expect(session.cells[3].controller, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      prefs.dispose();
      playback.dispose();
      playlist.dispose();
    });
  }
  for (final guideView in [false, true]) {
    testWidgets(
        'channel picker guide=$guideView filters 80k rows with bounded focus',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = true;
      final playlist =
          Playlist(storage, [for (var i = 0; i < 80000; i++) channel(i)]);
      final playback = PlaybackService(storage, playlist);
      // A stale history row from a hidden/removed playlist must not bypass the catalogue.
      playback.recentlyPlayed.add(channel(90000));
      await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider<EpgService>.value(value: PickerEpg(storage))
          ],
          child: MaterialApp(
              theme: ThemeData.dark(),
              home: MultiviewChannelPicker(
                  initialGuideView: guideView,
                  screenNumber: 2,
                  selectedIds: const {'p::0'},
                  unavailableReason: (c) => c.rawId == '79999'
                      ? 'This channel is already open in another screen.'
                      : null))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await settle(tester);
      expect(find.text('80000 channels'), findsOneWidget);
      expect(
          find.byType(Focus).evaluate().length, lessThan(guideView ? 100 : 40));
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byKey(const ValueKey('multiview-category-rail')),
          findsOneWidget);
      expect(find.text('All channels'), findsOneWidget);
      expect(find.text('Channel group'), findsNothing);
      await tester.tap(find.text('All channels'));
      await settle(tester);
      final search = find.byKey(const ValueKey('multiview-channel-search'));
      await tester.tap(search);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.enterText(search, 'Channel 79999');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await settle(tester);
      expect(find.text('1 channel'), findsOneWidget);
      expect(find.text('Channel 79999'), findsWidgets);
      expect(find.text('In use'), findsOneWidget);
      await tester.tap(find.text('Channel 79999').last);
      await settle(tester);
      expect(find.text('This channel is already open in another screen.'),
          findsOneWidget);
      await tester.tap(find.text('Back to channels'));
      await settle(tester);
      expect(find.byType(MultiviewChannelPicker), findsOneWidget);
      await tester.tap(search);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.enterText(search, 'no such channel');
      // Submission applies the latest query immediately, without selecting stale results.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await settle(tester);
      expect(find.text('No matching channels'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'multiview-empty-action');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await settle(tester);
      expect(find.text('80000 channels'), findsOneWidget);
      if (guideView) {
        expect(
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<LiveGuideSelectionViewport>(),
            isNotNull);
      } else {
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'multiview-results');
      }
      await tester.tap(search);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.enterText(search, 'Almaty');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
      await settle(tester);
      expect(find.text('1 channel'), findsOneWidget);
      expect(find.text('Channel 79998'), findsWidgets);
      await tester.binding.handlePopRoute();
      await settle(tester);
      await tester.tap(find.text('All channels').last);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await settle(tester);
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(find.text('80000 channels'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      prefs.dispose();
      playback.dispose();
      playlist.dispose();
    });
  }
}
