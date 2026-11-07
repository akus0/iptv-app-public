import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nox_iptv/services/app_preferences.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/utils/tv_theme.dart';
import 'package:nox_iptv/widgets/playlist_user_agent_picker.dart';

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets('user agent presets, custom editing and clearing fit $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService();
      await storage.init();
      final prefs = AppPreferences(storage);
      await prefs.init();
      prefs.isTelevision = size.width >= 900;
      addTearDown(prefs.dispose);
      var value = '';
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
              theme: buildAppTheme(prefs.palette),
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () async {
                            value =
                                await choosePlaylistUserAgent(context, value) ??
                                    value;
                          },
                          child: const Text('Choose')))))));
      Future<void> open() async {
        await tester.tap(find.text('Choose'));
        await tester.pumpAndSettle();
      }

      await open();
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(find.text('TiviMate'));
      }
      await tester.pumpAndSettle();
      expect(value, 'TiviMate');
      await open();
      // Traverse the scrollable choices to Custom using the same remote path
      // on every viewport; the final choice must not require touch scrolling.
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('Custom user agent'), findsOneWidget);
      final field = find.byKey(const ValueKey('playlist-user-agent-input'));
      if (prefs.isTelevision) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
      }
      await tester.enterText(field, 'ProviderPlayer/2.0');
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Save').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(value, 'ProviderPlayer/2.0');
      await open();
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(value, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'invalid custom values stay editable and Cancel preserves the old agent',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    final prefs = AppPreferences(storage);
    await prefs.init();
    addTearDown(prefs.dispose);
    String? value = 'Original/1';
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: prefs,
        child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          final result =
                              await choosePlaylistUserAgent(context, value!);
                          if (result != null) value = result;
                        },
                        child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('playlist-user-agent-input'));
    await tester.enterText(field, 'x' * 513);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Use 512 characters or fewer.'), findsOneWidget);
    await tester.enterText(field, 'bad\r\nheader');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('single line'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(value, 'Original/1');
  });
}
