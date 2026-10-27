import '../l10n/l10n.dart';
import '../services/playback_service.dart';

/// Ported upstream error explanations, using only the failure already returned
/// by the player. Never probe a stream or open another provider connection.
String playbackErrorMessage(String raw) {
  if (raw.contains('[UNSUPPORTED_VIDEO: video/dolby-vision')) {
    return tr(
        "This is a Dolby Vision video, and this device can't play this kind of Dolby Vision. Pick a version without DV (HDR10 or SDR) if your source has one.");
  }
  if (isDecoderPlaybackError(raw)) {
    return tr(
        'The video decoder could not play this stream. Try another version of this channel or check Stream info for the reported format.');
  }
  if (raw.contains('[STREAM_OPEN_TIMEOUT]')) {
    return tr(
        'No playable data arrived within 30 seconds. The server may be slow or unreachable.');
  }
  if (raw.contains('[STREAM_STALLED]')) {
    return tr(
        'Playback stopped progressing and automatic recovery did not succeed. Try again or choose another channel.');
  }
  if (raw.contains('[LIVE_STREAM_ENDED]')) {
    return tr(
        'The provider closed the live stream and it could not be resumed.');
  }
  final status =
      int.tryParse(RegExp(r'\[HTTP (\d{3})\b').firstMatch(raw)?.group(1) ?? '');
  if (status != null) {
    final hint = status == 429
        ? tr('The provider is limiting requests. Wait before retrying.')
        : status >= 500
            ? tr('The provider\'s server had a problem. Try again in a moment.')
            : status == 401 || status == 403
                ? tr(
                    'The provider refused the stream: check that your account is active and not already in use on another device.')
                : status == 404 || status == 410
                    ? tr(
                        'The provider has no stream at this address: the channel or title may have been removed.')
                    : tr('The provider rejected the request.');
    return '${tr('Server error {code}', {'code': '$status'})}\n$hint';
  }
  final lower = raw.toLowerCase();
  if (const [
    'unknownhostexception',
    'failed host lookup',
    'unable to resolve host',
    'no address associated with hostname',
    'getaddrinfo failed',
    'eai_noname',
    'name or service not known',
    'nodename nor servname',
  ].any(lower.contains)) {
    return tr(
        'Couldn\'t find the provider\'s server address. Check your internet connection or DNS settings, or try again later.');
  }
  if (raw.contains('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED') ||
      raw.contains('ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT')) {
    return tr(
        'Couldn\'t reach the provider\'s server. Check your internet connection, or the server may be down.');
  }
  return tr('Playback error:\n{raw}', {'raw': safePlaybackError(raw)});
}

final _diagnosticStreamAddress =
    RegExp(r'\b(?:https?|rtsps?|rtmps?)://[^\s<>]+', caseSensitive: false);
final _diagnosticClosingQuotes = RegExp(r'''["']+$''');

/// Hide credential-bearing addresses while retaining the surrounding error.
/// This is display-only; recovery and error classification use the raw failure.
String safePlaybackError(String raw) =>
    raw.replaceAllMapped(_diagnosticStreamAddress, (match) {
      // Apostrophes can occur inside valid userinfo/query values. Consume the
      // complete address, retaining only closing quotation marks for readability.
      final quotes =
          _diagnosticClosingQuotes.firstMatch(match[0]!)?.group(0) ?? '';
      return '[stream address]$quotes';
    });

String playbackIssueTitle(String raw) {
  final code = RegExp(r'\[HTTP (\d{3})\b').firstMatch(raw)?.group(1);
  if (code != null) {
    return switch (code) {
      '401' || '403' => 'HTTP $code · Refused',
      '404' || '410' => 'HTTP $code · Not found',
      '429' => 'HTTP 429 · Rate limited',
      _ => 'HTTP $code · Server error',
    };
  }
  if (raw.contains('[STREAM_OPEN_TIMEOUT]')) return 'Connection timed out';
  if (isDecoderPlaybackError(raw)) return 'Video decoder error';
  final lower = raw.toLowerCase();
  if (lower.contains('unknownhost') || lower.contains('failed host lookup')) {
    return 'Server address unavailable';
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return 'Connection timed out';
  }
  if (raw.contains('[STREAM_STALLED]') || raw.contains('[LIVE_STREAM_ENDED]')) {
    return 'Stream could not recover';
  }
  return 'Playback stopped';
}

/// Short, evidence-based interruption reason for the in-video retry status.
String playbackRecoveryReason(String? raw) {
  if (raw == null) return 'Stream interrupted';
  final code = RegExp(r'\[HTTP (\d{3})\b').firstMatch(raw)?.group(1);
  if (code != null) return 'Server error $code';
  if (raw.contains('[LIVE_STREAM_ENDED]')) return 'Live connection ended';
  if (raw.contains('[STREAM_STALLED]')) return 'Playback stalled';
  if (raw.contains('BEHIND_LIVE_WINDOW')) return 'Behind live coverage';
  if (raw.toLowerCase().contains('unknownhost')) {
    return 'Server address unavailable';
  }
  if (raw.contains('DECODING_FAILED')) return 'Video decoding interrupted';
  if (raw.contains('NETWORK_CONNECTION')) return 'Connection interrupted';
  return 'Stream interrupted';
}
