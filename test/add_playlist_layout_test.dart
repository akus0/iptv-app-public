import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/models/playlist_profile.dart';
import 'package:nox_iptv/widgets/tv_switch_list_tile.dart';
import 'package:nox_iptv/screens/settings/add_playlist_screen.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/catalog_database.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/playlist_manager.dart';
import 'package:nox_iptv/services/storage_service.dart';

class _Playlists extends PlaylistManager {
  _Playlists(StorageService storage) : super(storage, CatalogDatabase());
  final saved = <PlaylistProfile>[];
  final existing = <PlaylistProfile>[];
  final pending = Completer<void>();
  @override
  List<PlaylistProfile> get profiles => existing;
  @override
  Future<void> addPlaylist(PlaylistProfile profile) async {
    saved.add(profile);
    await pending.future;
  }

  @override
  Future<void> updatePlaylist(PlaylistProfile profile) => addPlaylist(profile);
  @override
  Future<void> loadPlaylist(String id) async {}
}

void main() {
  for (final width in [540.0, 760.0]) {
    for (final mode in [
      'M3U URL',
      'Xtream Codes',
      'Stalker / MAC',
      'Smart Add'
    ]) {
      testWidgets('stacked TV form follows visible controls $width $mode',
          (tester) async {
        tester.view.physicalSize = Size(width, 540);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService();
        await storage.init();
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = true;
        final playlists = _Playlists(storage);
        final guide = EpgService(storage);
        await tester.pumpWidget(MultiProvider(providers: [
          Provider.value(value: storage),
          ChangeNotifierProvider.value(value: prefs),
          ChangeNotifierProvider<PlaylistManager>.value(value: playlists),
          ChangeNotifierProvider<EpgService>.value(value: guide),
        ], child: const MaterialApp(home: AddPlaylistScreen())));
        await tester.pumpAndSettle();
        final source = find.text(mode);
        Focus.of(tester.element(source)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        Future<void> arrow(LogicalKeyboardKey key) async {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
        }

        Finder field(String label) => find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label);
        // Source choices are horizontal; Down enters the form, not a trapped scope.
        await arrow(LogicalKeyboardKey.arrowDown);
        expect(
            tester.widget<TextField>(field('Name')).focusNode!.hasFocus, true);
        await arrow(LogicalKeyboardKey.arrowUp);
        expect(Focus.of(tester.element(source)).hasFocus, true);
        await arrow(LogicalKeyboardKey.arrowDown);
        // A held direction follows the same path without skipping controls.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        final afterPress = FocusManager.instance.primaryFocus;
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus, isNot(same(afterPress)));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        tester.widget<TextField>(field('Name')).focusNode!.requestFocus();
        await tester.pumpAndSettle();
        final visited = <String>[];
        for (var i = 0; i < 22; i++) {
          final node = FocusManager.instance.primaryFocus!;
          final fieldWidgets = find
              .byType(TextField)
              .evaluate()
              .map((e) => e.widget as TextField);
          for (final input in fieldWidgets) {
            if (input.focusNode!.hasFocus) {
              visited.add(input.decoration!.labelText!);
            }
          }
          final save = find.byKey(const ValueKey('playlist-save'));
          if (tester.widget<FilledButton>(save).focusNode!.hasFocus) {
            break;
          }
          await arrow(LogicalKeyboardKey.arrowDown);
          expect(FocusManager.instance.primaryFocus, isNot(same(node)),
              reason: 'Down must advance through $mode (step $i)');
        }
        expect(visited.first, 'Name');
        expect(
            visited.length, greaterThanOrEqualTo(mode == 'Smart Add' ? 2 : 3));
        await arrow(LogicalKeyboardKey.arrowUp);
        expect(
            find.byWidgetPredicate((w) =>
                w is DropdownButton<String> && w.focusNode?.hasFocus == true),
            findsOneWidget);
        await arrow(LogicalKeyboardKey.arrowUp);
        expect(
            Focus.of(tester.element(find.text('User agent'))).hasFocus, true);
        if (mode == 'Stalker / MAC') {
          final advanced = find.byKey(const ValueKey('portal-advanced'));
          tester.widget<TextButton>(advanced).focusNode!.requestFocus();
          await tester.ensureVisible(advanced);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pumpAndSettle();
          expect(
              tester
                  .widget<TextField>(field('Portal username — optional'))
                  .focusNode!
                  .hasFocus,
              true);
          final details = <String>{};
          for (var i = 0; i < 18; i++) {
            for (final input in find
                .byType(TextField)
                .evaluate()
                .map((e) => e.widget as TextField)) {
              if (input.focusNode!.hasFocus) {
                details.add(input.decoration!.labelText!);
              }
            }
            if (tester
                .widget<FilledButton>(
                    find.byKey(const ValueKey('playlist-save')))
                .focusNode!
                .hasFocus) {
              break;
            }
            await arrow(LogicalKeyboardKey.arrowDown);
          }
          expect(
              details,
              containsAll([
                'Portal username — optional',
                'Portal password — optional',
                'Serial number — optional',
                'Device ID — optional',
                'Device ID 2 — optional',
                'Signature — optional'
              ]));
        }
        expect(playlists.saved, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        playlists.dispose();
        guide.dispose();
        prefs.dispose();
      });
    }
  }

  testWidgets(
      'content choices stay local, cancel safely and reach Save by remote',
      (tester) async {
    tester.view.physicalSize = const Size(540, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlists = _Playlists(storage);
    final guide = EpgService(storage);
    await tester.pumpWidget(MultiProvider(providers: [
      Provider.value(value: storage),
      ChangeNotifierProvider.value(value: prefs),
      ChangeNotifierProvider<PlaylistManager>.value(value: playlists),
      ChangeNotifierProvider<EpgService>.value(value: guide),
    ], child: const MaterialApp(home: AddPlaylistScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xtream Codes'));
    await tester.pumpAndSettle();
    Future<void> openContent() async {
      final row = find.text('Content from this playlist');
      await tester.ensureVisible(row);
      Focus.of(tester.element(row)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
    }

    Future<void> toggle(String label) async {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await openContent();
    await toggle('Live TV');
    await toggle('Movies');
    await toggle('Series');
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await openContent();
    expect(
        tester
            .widgetList<TvSwitchListTile>(find.byType(TvSwitchListTile))
            .every((w) => w.value),
        true);
    await toggle('Movies');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(find.text('Live TV · Series'), findsOneWidget);
    expect(playlists.saved, isEmpty);
    expect(
        Focus.of(tester.element(find.text('Content from this playlist')))
            .hasFocus,
        true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('User agent'))).hasFocus, true);
    await openContent();
    expect(
        tester
            .widgetList<TvSwitchListTile>(find.byType(TvSwitchListTile))
            .map((w) => w.value),
        [true, false, true]);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    playlists.dispose();
    guide.dispose();
    prefs.dispose();
  });

  testWidgets(
      'TV playlist fields retain editing arrows until Back restores navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    prefs.isTelevision = true;
    final playlists = _Playlists(storage);
    final guide = EpgService(storage);
    await tester.pumpWidget(MultiProvider(providers: [
      Provider.value(value: storage),
      ChangeNotifierProvider.value(value: prefs),
      ChangeNotifierProvider<PlaylistManager>.value(value: playlists),
      ChangeNotifierProvider<EpgService>.value(value: guide),
    ], child: const MaterialApp(home: AddPlaylistScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xtream Codes'));
    await tester.pumpAndSettle();
    Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label);
    final server = field('Server URL (e.g. http://host:port)');
    final input = tester.widget<TextField>(server);
    input.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(server, 'https://example.invalid');
    final end = input.controller!.text.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(input.focusNode!.hasFocus, true);
    expect(input.controller!.selection.baseOffset, end - 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(input.focusNode!.hasFocus, true);
    expect(input.controller!.selection.baseOffset, end);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(input.focusNode!.hasFocus, true);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AddPlaylistScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(field('Username')).focusNode!.hasFocus, true);
    expect(playlists.saved, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    playlists.dispose();
    guide.dispose();
    prefs.dispose();
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540),
    const Size(1280, 720)
  ]) {
    for (final edit in [false, true]) {
      testWidgets('playlist action stays reachable $size edit=$edit',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = size.width > size.height
            ? const FakeViewPadding(left: 24, right: 48)
            : const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService();
        await storage.init();
        final prefs = AppPreferences(storage);
        await prefs.init();
        prefs.isTelevision = size.width >= 900;
        final playlists = _Playlists(storage);
        if (edit) {
          playlists.existing.add(PlaylistProfile(
              id: 'existing',
              name: 'Existing',
              userAgent: 'ProviderPlayer/1',
              mode: 'm3u',
              m3uUrl: 'https://example.test/list.m3u',
              createdAt: DateTime(2026),
              sortOrder: 2));
        }
        final epg = EpgService(storage);
        await tester.pumpWidget(MultiProvider(
          providers: [
            Provider.value(value: storage),
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider<PlaylistManager>.value(value: playlists),
            ChangeNotifierProvider.value(value: epg),
          ],
          child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                      body: Center(
                          child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => AddPlaylistScreen(
                                    editPlaylistId: edit ? 'existing' : null))),
                        child: const Text('Open form'),
                      )),
                    )),
          ),
        ));
        await tester.tap(find.text('Open form'));
        await tester.pumpAndSettle();
        final save = find.ancestor(
            of: find.text(edit ? 'Save changes' : 'Add playlist'),
            matching: find.byWidgetPredicate((w) => w is FilledButton));
        expect(save.hitTestable(), findsOneWidget,
            reason: 'Save must not be below the form scroll');
        if (!edit) {
          for (final mode in ['Xtream Codes', 'Smart Add', 'M3U URL']) {
            await tester.ensureVisible(find.text(mode));
            await tester.pumpAndSettle();
            await tester.tap(find.text(mode));
            await tester.pumpAndSettle();
            expect(save.hitTestable(), findsOneWidget,
                reason: '$mode must keep the mobile action visible');
            expect(tester.takeException(), isNull);
          }
        }
        final xtream = prefs.isTelevision && !edit;
        if (xtream) {
          await tester.tap(find.text('Xtream Codes'));
          await tester.pumpAndSettle();
        }
        Finder field(String label) => find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label);
        Future<void> enter(String label, String text) async {
          await tester.ensureVisible(field(label));
          await tester.pumpAndSettle();
          if (prefs.isTelevision) {
            tester.widget<TextField>(field(label)).focusNode!.requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pump();
          }
          await tester.enterText(field(label), text);
          await tester.pump();
        }

        await enter('Name', 'Mobile playlist');
        if (xtream) {
          await enter(
              'Server URL (e.g. http://host:port)', 'https://example.test');
          await enter('Username', 'test-user');
          await enter('Password', 'test-password');
        } else {
          await enter('M3U Playlist URL', 'https://example.test/new.m3u');
        }
        if (!edit) {
          final agentTile = find.byKey(const ValueKey('playlist-user-agent'));
          await tester.ensureVisible(agentTile);
          await tester.pumpAndSettle();
          await tester.tap(agentTile);
          await tester.pumpAndSettle();
          for (var i = 0; i < 3; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pumpAndSettle();
        }
        final inset = size.height > size.width ? 280.0 : 180.0;
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pumpAndSettle();
        expect(save.hitTestable(), findsOneWidget);
        final bounds = tester.getRect(save);
        expect(bounds.bottom, lessThanOrEqualTo(size.height - inset));
        expect(
            bounds.right,
            lessThanOrEqualTo(
                size.width - (size.width > size.height ? 48 : 0)));
        await tester.tap(save);
        await tester.pump();
        expect(playlists.saved, hasLength(1));
        expect(playlists.saved.single.name, 'Mobile playlist');
        expect(playlists.saved.single.userAgent,
            edit ? 'ProviderPlayer/1' : 'VLC');
        if (xtream) {
          expect(playlists.saved.single.mode, 'xtream');
          expect(playlists.saved.single.xtreamUsername, 'test-user');
          expect(playlists.saved.single.xtreamPassword, 'test-password');
        } else {
          expect(playlists.saved.single.m3uUrl, 'https://example.test/new.m3u');
        }
        if (edit) expect(playlists.saved.single.id, 'existing');
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        playlists.pending.complete();
        await tester.pumpAndSettle();
        expect(find.byType(AddPlaylistScreen), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        playlists.dispose();
        epg.dispose();
        prefs.dispose();
      });
    }
  }
}
