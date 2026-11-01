import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/cloud_transfer.dart';
import 'package:nox_iptv/services/device_transfer.dart';

/// Runs `tools/pair_relay/relay.py` locally (skipped without python3/python)
/// and goes through upload → download (twice) → delete.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Process? relay;
  Directory? vault;

  setUpAll(() async {
    HttpOverrides.global = null; // the test binding fakes HTTP otherwise
    vault = await Directory.systemTemp.createTemp('vault');
    const port = 18931;
    for (final exe in ['python3', 'python']) {
      try {
        relay = await Process.start(exe, [
          'tools/pair_relay/relay.py'
        ], environment: {
          'PAIR_PORT': '$port',
          'PAIR_PAGE': 'assets/pair/pair.html',
          'PAIR_VAULT_DIR': vault!.path,
        });
        break;
      } on ProcessException {
        continue;
      }
    }
    cloudTransferBase = 'http://127.0.0.1:$port';
    // Wait for it to listen.
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        s.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    relay?.kill();
    relay = null;
  });

  tearDownAll(() async {
    relay?.kill();
    await vault?.delete(recursive: true);
  });

  test('code keys are stable and distinct', () async {
    final a = await VaultKeys.fromCode('1234567890123456');
    final b = await VaultKeys.fromCode('1234567890123456');
    final c = await VaultKeys.fromCode('1234567890123457');
    expect(a.id, b.id);
    expect(a.id, isNot(c.id));
    expect(a.id.length, 22);
    expect(formatCloudCode('1234567890123456'), '1234 5678 9012 3456');
  });

  test('upload, download twice, delete', () async {
    if (relay == null) {
      markTestSkipped('no python to run the relay');
      return;
    }
    final payload = <String, Object>{
      'k': {'t': 's', 'v': 'hello'},
      'big': {'t': 's', 'v': 'x' * 900000},
    };
    final watch = Stopwatch()..start();
    final upload = await uploadCloudTransfer(payload, const Duration(hours: 1));
    // ignore: avoid_print
    print('upload took ${watch.elapsedMilliseconds} ms');
    expect(upload.code.length, kCloudCodeLength);
    expect(upload.isActive, isTrue);

    for (var i = 0; i < 2; i++) {
      final got = await downloadCloudTransfer(upload.code);
      expect(got['k'], {'t': 's', 'v': 'hello'});
      expect((got['big'] as Map)['v'], hasLength(900000));
    }
    // Nothing on disk is readable as the setup.
    for (final f in vault!.listSync().whereType<File>()) {
      expect(
          String.fromCharCodes(f.readAsBytesSync()), isNot(contains('hello')));
    }

    await deleteCloudTransfer(upload.code);
    await expectLater(
        downloadCloudTransfer(upload.code),
        throwsA(isA<TransferException>()
            .having((e) => e.kind, 'kind', TransferError.notFound)));
    expect(vault!.listSync(), isEmpty);
  });

  test('unknown code is notFound', () async {
    if (relay == null) {
      markTestSkipped('no python to run the relay');
      return;
    }
    await expectLater(
        downloadCloudTransfer('0000000000000000'),
        throwsA(isA<TransferException>()
            .having((e) => e.kind, 'kind', TransferError.notFound)));
  });
}
