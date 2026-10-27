import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/database_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tekartik.sqflite');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('requests a bounded worker pool before returning to startup', () async {
    var completed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'options');
      expect(call.arguments, {'androidThreadCount': 2});
      await Future<void>.delayed(Duration.zero);
      completed = true;
      return null;
    });
    await configureAndroidDatabaseWorkers();
    expect(completed, isTrue);
  });

  test('unsupported worker option cannot prevent application startup',
      () async {
    for (final error in [
      PlatformException(code: 'unsupported'),
      MissingPluginException()
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => throw error);
      await configureAndroidDatabaseWorkers();
    }
  });
}
