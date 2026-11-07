import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:nox_iptv/models/playlist_failure.dart';
import 'package:nox_iptv/services/stalker_portal_service.dart';
import 'package:nox_iptv/services/xtream_api_service.dart';
import 'package:nox_iptv/widgets/playlist_failure_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const privateText =
      'https://private.invalid/get.php?username=private-user&password=private-password';
  for (final (error, reason) in <(Object, PlaylistFailureReason)>[
    (TimeoutException(privateText), PlaylistFailureReason.timeout),
    (const SocketException(privateText), PlaylistFailureReason.network),
    (http.ClientException(privateText), PlaylistFailureReason.network),
    (
      const FileSystemException(privateText, privateText),
      PlaylistFailureReason.storage
    ),
    (
      const FormatException(privateText, privateText),
      PlaylistFailureReason.response
    ),
    (StateError(privateText), PlaylistFailureReason.unknown),
    (
      const XtreamException(privateText, accountRejected: true),
      PlaylistFailureReason.access
    ),
    (
      const XtreamException(privateText,
          reason: PlaylistFailureReason.http, httpStatus: 403),
      PlaylistFailureReason.http
    ),
    (
      const PortalException(privateText, authentication: true, httpStatus: 401),
      PlaylistFailureReason.access
    ),
    (
      const PortalException(privateText, unsupported: true),
      PlaylistFailureReason.unsupported
    ),
  ]) {
    test('${error.runtimeType} reports $reason without private exception data',
        () {
      final failure =
          PlaylistFailure.fromError(error, PlaylistFailureStage.connect);
      expect(failure.reason, reason);
      final report =
          failure.report(source: 'xtream', version: '0.1.6', build: '2471');
      expect(report, contains('Version: 0.1.6 (build 2471)'));
      expect(report, contains(failure.code));
      expect(report, isNot(contains('private')));
      expect(failure.message, isNot(contains('private')));
    });
  }

  test('unknown source, version and invalid HTTP fields are not copied', () {
    const failure = PlaylistFailure(
        PlaylistFailureStage.download, PlaylistFailureReason.http,
        httpStatus: 123456789);
    final report = failure.report(
        source: privateText, version: privateText, build: privateText);
    expect(report, contains('Source: Unknown'));
    expect(report, contains('Version: unavailable'));
    expect(report, isNot(contains('private')));
    expect(report, isNot(contains('123456789')));
  });

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(960, 540)
  ]) {
    testWidgets(
        'error dialog fits $size, copies safely and navigates by remote',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      PackageInfo.setMockInitialValues(
          appName: 'private name',
          packageName: 'private.package',
          version: '0.1.6',
          buildNumber: '2471',
          buildSignature: 'private-signature');
      String? copied;
      var rejectClipboard = false;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (rejectClipboard) throw PlatformException(code: 'unavailable');
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      PlaylistFailureAction? result;
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async => result =
                          await showPlaylistFailureDialog(context,
                              failure: const PlaylistFailure(
                                  PlaylistFailureStage.channels,
                                  PlaylistFailureReason.http,
                                  httpStatus: 503),
                              source: 'xtream'),
                      child: const Text('Open'))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP 503'), findsOneWidget);
      final edit = find.byKey(const ValueKey('playlist-error-edit'));
      final retry = find.byKey(const ValueKey('playlist-error-retry'));
      expect(
          Focus.of(tester.element(find.text('Edit details'))).hasFocus, isTrue);
      expect(Theme.of(tester.element(edit)).brightness, Brightness.dark);
      if (size.width >= 900) {
        final stacked =
            (tester.getCenter(edit).dy - tester.getCenter(retry).dy).abs() > 10;
        await tester.sendKeyEvent(stacked
            ? LogicalKeyboardKey.arrowDown
            : LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(find.text('Retry'))).hasFocus, isTrue);
        await tester.sendKeyEvent(stacked
            ? LogicalKeyboardKey.arrowUp
            : LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(Focus.of(tester.element(find.text('Edit details'))).hasFocus,
            isTrue);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(Focus.of(tester.element(find.text('Retry'))).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(Focus.of(tester.element(find.text('Copy error details'))).hasFocus,
          isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(copied, contains('PL-CHANNELS-HTTP'));
      expect(copied, contains('HTTP status: 503'));
      expect(copied, contains('0.1.6 (build 2471)'));
      expect(copied, isNot(contains('private')));
      expect(find.text('Copied'), findsOneWidget);
      expect(result, isNull);
      rejectClipboard = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('Copy failed · try again'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Traverse the dialog's actions without touching the screen.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
          Focus.of(tester.element(find.text('Edit details'))).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(Focus.of(tester.element(find.text('Retry'))).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(result, PlaylistFailureAction.retry);
      expect(retry, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(
          find.byKey(const ValueKey('playlist-failure-dialog')), findsNothing);
    });
  }
}
