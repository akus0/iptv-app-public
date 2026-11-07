import '../models/playlist_failure.dart';

/// A temporary, per-session pause for provider-wide catalogue failures.
/// Cached reads and playback never pass through this gate. There is no timer
/// or automatic retry; the next request checks expiry, or explicit refresh
/// resets the gate. An old connection's completion cannot affect its replacement.
class CatalogRequestBackoff {
  CatalogRequestBackoff({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  static const _duration = Duration(minutes: 2);
  Object? _owner;
  int _generation = 0;
  int _failures = 0;
  DateTime? _until;

  bool isPausedFor(Object owner) =>
      identical(owner, _owner) && _until != null && _now().isBefore(_until!);

  void reset() {
    _generation++;
    _failures = 0;
    _until = null;
  }

  static bool isProviderFailure(Object error) {
    final failure =
        PlaylistFailure.fromError(error, PlaylistFailureStage.library);
    return switch (failure.reason) {
      PlaylistFailureReason.timeout ||
      PlaylistFailureReason.network ||
      PlaylistFailureReason.access =>
        true,
      PlaylistFailureReason.http =>
        const {401, 403, 429, 500, 502, 503, 504}.contains(failure.httpStatus),
      _ => false,
    };
  }

  Future<T> run<T>(Object owner, Future<T> Function() request) async {
    if (!identical(owner, _owner)) {
      reset();
      _owner = owner;
    }
    if (isPausedFor(owner)) throw const CatalogRequestsPaused();
    if (_until != null) reset(); // expired: allow a fresh attempt
    final generation = _generation;
    try {
      final result = await request();
      // A successful request already in flight must not reopen a gate that
      // other workers just closed. Explicit retry/expiry starts a new generation.
      if (generation == _generation && _until == null) _failures = 0;
      return result;
    } catch (error) {
      if (generation == _generation && _until == null) {
        if (isProviderFailure(error)) {
          if (++_failures >= 2) _until = _now().add(_duration);
        } else {
          _failures = 0;
        }
      }
      rethrow;
    }
  }
}

class CatalogRequestsPaused implements Exception {
  const CatalogRequestsPaused();

  @override
  String toString() =>
      'The provider is not responding reliably. Cached titles are still available. '
      'Wait a moment or refresh to try again.';
}
