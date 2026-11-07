import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

enum PlaylistFailureStage {
  save,
  connect,
  download,
  categories,
  channels,
  library,
  cache
}

enum PlaylistFailureReason {
  unknown,
  timeout,
  network,
  access,
  response,
  storage,
  http,
  unsupported
}

/// Transport metadata stays separate from exception text and account data.
class PlaylistRequestException implements Exception {
  const PlaylistRequestException(this.message,
      {this.reason = PlaylistFailureReason.unknown, this.httpStatus});
  final String message;
  final PlaylistFailureReason reason;
  final int? httpStatus;
  @override
  String toString() => message;
}

/// An allowlisted report: never retain exception text, URLs or response bodies.
class PlaylistFailure {
  const PlaylistFailure(this.stage, this.reason, {this.httpStatus});
  final PlaylistFailureStage stage;
  final PlaylistFailureReason reason;
  final int? httpStatus;

  factory PlaylistFailure.fromError(Object error, PlaylistFailureStage stage) {
    if (error is PlaylistRequestException) {
      return PlaylistFailure(stage, error.reason, httpStatus: error.httpStatus);
    }
    return PlaylistFailure(
        stage,
        switch (error) {
          TimeoutException() => PlaylistFailureReason.timeout,
          SocketException() ||
          http.ClientException() ||
          HandshakeException() =>
            PlaylistFailureReason.network,
          FileSystemException() => PlaylistFailureReason.storage,
          FormatException() => PlaylistFailureReason.response,
          _ => PlaylistFailureReason.unknown,
        });
  }

  String get code =>
      'PL-${stage.name.toUpperCase()}-${reason.name.toUpperCase()}';
  String get stageLabel => switch (stage) {
        PlaylistFailureStage.save => 'Saving playlist settings',
        PlaylistFailureStage.connect => 'Connecting to the provider',
        PlaylistFailureStage.download => 'Downloading the playlist',
        PlaylistFailureStage.categories => 'Loading channel categories',
        PlaylistFailureStage.channels => 'Loading live channels',
        PlaylistFailureStage.library => 'Loading library categories',
        PlaylistFailureStage.cache => 'Saving playlist data',
      };
  int? get safeHttpStatus =>
      httpStatus != null && httpStatus! >= 100 && httpStatus! <= 599
          ? httpStatus
          : null;
  String get message => switch (reason) {
        PlaylistFailureReason.timeout =>
          'The server took too long to respond. Check your connection and try again.',
        PlaylistFailureReason.network =>
          'Could not reach the server. Check the address, internet connection and any VPN settings.',
        PlaylistFailureReason.access =>
          'The provider rejected access. Check your login details and whether the account is active.',
        PlaylistFailureReason.response =>
          'The server returned data the app could not read. Check the playlist address or try again later.',
        PlaylistFailureReason.storage =>
          'Could not save playlist data on this device. Check available storage and try again.',
        PlaylistFailureReason.unsupported =>
          'The provider endpoint or requested action is unavailable. Check the portal address.',
        PlaylistFailureReason.http
            when safeHttpStatus == 401 || safeHttpStatus == 403 =>
          'The server denied access. Check your account details and any provider requirements.',
        PlaylistFailureReason.http when safeHttpStatus == 404 =>
          'The server could not find this playlist endpoint. Check the server address and port.',
        PlaylistFailureReason.http when safeHttpStatus == 429 =>
          'The server is receiving too many requests. Wait a moment before trying again.',
        PlaylistFailureReason.http =>
          'The server could not complete the request. Try again later or check with your provider.',
        PlaylistFailureReason.unknown =>
          'Could not complete this step. Try again or copy the error details to report the problem.',
      };

  static String sourceLabel(String source) => switch (source) {
        'xtream' => 'Xtream Codes',
        'stalker' => 'Stalker / MAC',
        'm3u' => 'M3U URL',
        _ => 'Unknown',
      };

  String report({required String source, String? version, String? build}) {
    String safeVersion(String? value) => value != null &&
            RegExp(r'^[0-9]+(?:[.][0-9]+)*(?:[-+][a-zA-Z0-9.]+)?$')
                .hasMatch(value) &&
            value.length <= 40
        ? value
        : 'unavailable';
    return [
      'iptv-app playlist setup error',
      'Version: ${safeVersion(version)} (build ${safeVersion(build)})',
      'Source: ${sourceLabel(source)}',
      'Reference: $code',
      'Step: $stageLabel',
      if (safeHttpStatus != null) 'HTTP status: $safeHttpStatus',
      'Reason: $message',
    ].join('\n');
  }
}
