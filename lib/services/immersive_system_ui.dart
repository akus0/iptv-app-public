import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Route-owned Android fullscreen bars. Android 16 requires the native inset
/// controller; Flutter's legacy immersive SystemUiMode is ignored there.
class ImmersiveSystemUi {
  static const _channel = MethodChannel('com.nox.nox_iptv/system_ui');
  static final _owners = <Object>{};

  /// Release is idempotent. An outgoing route cannot restore the bars while a
  /// newer immersive route still owns them. Channel calls retain FIFO ordering.
  static VoidCallback acquire() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return () {};
    final owner = Object();
    _owners.add(owner);
    if (_owners.length == 1) unawaited(_set(true));
    return () {
      if (_owners.remove(owner) && _owners.isEmpty) unawaited(_set(false));
    };
  }

  static Future<void> _set(bool immersive) async {
    try {
      await _channel.invokeMethod<void>('setImmersive', immersive);
    } on MissingPluginException {
      // Non-Android hosts and tests can render the route without the activity.
    } on PlatformException catch (error) {
      debugPrint('System bar update failed: ${error.code}');
    }
  }
}
