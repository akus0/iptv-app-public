import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/utils/playback_error_message.dart';

void main() {
  test('stream diagnostics hide addresses for each supported URL scheme', () {
    for (final scheme in ['http', 'HTTPS', 'RtSp', 'rtsps', 'rtmp', 'rtmps']) {
      final raw =
          'Cannot open "$scheme://demo:secret@example.invalid/live/demo/secret/1.ts" [HTTP 503]';
      final safe = safePlaybackError(raw);
      expect(safe, 'Cannot open "[stream address]" [HTTP 503]');
      expect(safe, isNot(contains('secret')));
    }
  });

  test('unknown errors redact multiple URLs without losing surrounding details',
      () {
    const raw = 'Primary HTTPS://example.invalid/live/demo/secret/1.ts\n'
        'Fallback rtsp://demo:secret@example.invalid/feed\nDecoder unavailable';
    final message = playbackErrorMessage(raw);
    expect(message, isNot(contains('secret')));
    expect(message, contains('Primary [stream address]'));
    expect(message, contains('Fallback [stream address]'));
    expect(message, contains('Decoder unavailable'));
    expect(playbackIssueTitle('[HTTP 503] $raw'), 'HTTP 503 · Server error');
    expect(playbackRecoveryReason('[HTTP 503] $raw'), 'Server error 503');
  });

  test('apostrophes inside URL credentials cannot end redaction early', () {
    const raw =
        'Cannot open "https://demo:sec\'ret@example.invalid/feed?token=pri\'vate" [HTTP 403]';
    expect(safePlaybackError(raw), 'Cannot open "[stream address]" [HTTP 403]');
  });

  test('known provider failures have distinct explanations', () {
    expect(playbackErrorMessage('Source error [HTTP 404 Not Found]'),
        contains('no stream at this address'));
    expect(playbackErrorMessage('Source error [HTTP 403 Forbidden]'),
        contains('account is active'));
    expect(playbackErrorMessage('Source error [HTTP 503 Unavailable]'),
        contains('server had a problem'));
    expect(playbackErrorMessage('Source error: java.net.UnknownHostException'),
        contains('server address'));
    expect(playbackErrorMessage('[ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT]'),
        contains('reach the provider'));
    expect(playbackErrorMessage('[UNSUPPORTED_VIDEO: video/dolby-vision]'),
        contains('Dolby Vision'));
    expect(playbackErrorMessage('Unknown native error'),
        contains('Unknown native error'));
  });
}
