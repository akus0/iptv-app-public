import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Call once on Android, before opening any database. Two workers let the
/// artwork/catalogue database progress during guide reads while bounding CPU
/// contention on TVs. Sqflite still serializes operations within each database.
Future<void> configureAndroidDatabaseWorkers() async {
  try {
    await const MethodChannel('com.tekartik.sqflite')
        .invokeMethod<void>('options', {'androidThreadCount': 2});
  } on PlatformException {
    debugPrint('Database workers: using platform default');
  } on MissingPluginException {
    debugPrint('Database workers: option unavailable');
  }
}
