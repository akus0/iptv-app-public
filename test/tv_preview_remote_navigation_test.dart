import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/tv_preview_remote_navigation.dart';

void main() {
  const channel = MethodChannel('com.nox.nox_iptv/tv_remote');
  testWidgets(
      'Back hold follows the visible preview and restores home after Sports',
      (tester) async {
    final updates = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'setEnabled') updates.add(call.arguments as bool);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final nav = GlobalKey<NavigatorState>();
    var home = 0, sports = 0;
    Widget preview(String label, VoidCallback open) =>
        TvPreviewRemoteNavigation(
            enabled: true,
            onFullscreen: open,
            child: Scaffold(body: Text(label)));
    Future<bool> hold() async {
      final reply = Completer<bool>();
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('fullscreen')),
          (data) => reply.complete(
              const StandardMethodCodec().decodeEnvelope(data!) == true));
      return reply.future;
    }

    await tester.pumpWidget(
        MaterialApp(navigatorKey: nav, home: preview('Home', () => home++)));
    await tester.pumpAndSettle();
    expect(await hold(), isTrue);
    expect(home, 1);
    nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => preview('Sports', () => sports++)));
    await tester.pumpAndSettle();
    expect(await hold(), isTrue);
    expect(sports, 1);
    expect(home, 1);
    showDialog<void>(
        context: tester.element(find.text('Sports')),
        builder: (_) => const AlertDialog(title: Text('Options')));
    await tester.pumpAndSettle();
    expect(updates.last, isFalse);
    expect(await hold(), isFalse);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(updates.last, isTrue);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(await hold(), isTrue);
    expect(home, 2);
    expect(sports, 1);
    await tester.pumpWidget(const SizedBox());
    expect(updates.last, isFalse);
  });
}
