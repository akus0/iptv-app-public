import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'storage_service.dart';

/// Hashes/verifies the single PIN that gates leaving a restricted viewer
/// profile (and opening Settings from one) — see `ViewerProfile.isRestricted`'s
/// doc comment for the feature this protects.
///
/// A 4-digit PIN has only 10,000 possible values — hashing it doesn't change
/// that; what it buys is keeping the PIN out of plain sight in prefs or an
/// adb backup. The actual protection against guessing is the rate limiting
/// here (escalating lockouts), not the hash's own strength.
class ParentalPin {
  ParentalPin(this._storage);

  final StorageService _storage;

  static const _currentVersion = 1;
  static const _hashIterations = 8000;
  static const _maxFailuresBeforeLockout = 5;
  static const _lockoutStages = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  bool get isSet => _storage.getParentalPin() != null;

  Future<void> setPin(String pin) async {
    final salt = _randomSalt();
    final hash = _hash(pin, salt);
    await _storage.setParentalPin({
      'v': _currentVersion,
      'salt': salt,
      'hash': hash,
    });
    // A newly-set PIN clears any lockout from a previous one — the old
    // PIN's failures shouldn't lock someone out of a PIN they just changed.
    await _storage.setPinFailCount(0);
    await _storage.setPinLockedUntil(null);
  }

  Future<void> clearPin() => _storage.clearParentalPin();

  /// Null when nothing's locked; otherwise how much longer to wait.
  Duration? get lockedForRemaining {
    final until = _storage.getPinLockedUntil();
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  /// Verifies [pin] against the stored record, tracking failures/lockouts.
  /// Returns true only on a correct PIN while not currently locked out.
  Future<bool> verify(String pin) async {
    if (lockedForRemaining != null) return false;
    final record = _storage.getParentalPin();
    // No PIN ever set — nothing to gate against, so treat as unlocked
    // rather than permanently refusing (shouldn't actually be reachable:
    // a restricted profile can't exist without a PIN having been set first).
    if (record == null) return true;
    final salt = record['salt'] as String;
    final expected = record['hash'] as String;
    final matches = _hash(pin, salt) == expected;
    if (matches) {
      await _storage.setPinFailCount(0);
      await _storage.setPinLockedUntil(null);
      return true;
    }
    final fails = _storage.getPinFailCount() + 1;
    await _storage.setPinFailCount(fails);
    if (fails >= _maxFailuresBeforeLockout) {
      final stage = ((fails - _maxFailuresBeforeLockout) % _lockoutStages.length);
      await _storage.setPinLockedUntil(
          DateTime.now().add(_lockoutStages[stage]));
    }
    return false;
  }

  String _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Encode(bytes);
  }

  String _hash(String pin, String salt) {
    List<int> digest = utf8.encode('$salt:$pin');
    for (var i = 0; i < _hashIterations; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return base64Encode(digest);
  }
}
