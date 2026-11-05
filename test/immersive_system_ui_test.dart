import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/immersive_system_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <bool>[];
  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.nox.nox_iptv/system_ui'), (call) async {
      expect(call.method, 'setImmersive');
      calls.add(call.arguments as bool);
      return null;
    });
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('outgoing immersive route cannot show bars over its replacement',
      () async {
    final old = ImmersiveSystemUi.acquire();
    final next = ImmersiveSystemUi.acquire();
    addTearDown(old);
    addTearDown(next);
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true]);
    old();
    old();
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true]);
    next();
    next();
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true, false]);
  });

  test('rapid reopen sends final immersive request after restoration',
      () async {
    final old = ImmersiveSystemUi.acquire();
    old();
    final next = ImmersiveSystemUi.acquire();
    addTearDown(next);
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true, false, true]);
    next();
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true, false, true, false]);
  });
}
