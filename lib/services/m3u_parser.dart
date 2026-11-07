import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../utils/channel_content.dart';

import '../models/channel.dart';
import '../models/playlist_failure.dart';
import 'playlist_http_client.dart';

/// Parses M3U / M3U8 playlists into [Channel] objects.
///
/// Supports the common extended attributes (`tvg-id`, `tvg-logo`,
/// `group-title`), the `#EXTGRP:` fallback tag, and an optional external
/// subtitle track via `#EXTVLCOPT:sub-file=`.
class M3uParser {
  /// Same quoted attribute grammar as the legacy regex, without creating
  /// a Match object for every field of every channel.
  static Map<String, String> attributesOf(String line) {
    final attributes = <String, String>{};
    var from = 0;
    while (true) {
      final equals = line.indexOf('="', from);
      if (equals < 0) break;
      var start = equals;
      while (start > from && _isKeyChar(line.codeUnitAt(start - 1))) {
        start--;
      }
      if (start == equals) {
        from = equals + 1;
        continue;
      }
      final end = line.indexOf('"', equals + 2);
      if (end < 0) break;
      attributes[line.substring(start, equals).toLowerCase()] =
          line.substring(equals + 2, end);
      from = end + 1;
    }
    return attributes;
  }

  static bool _isKeyChar(int c) =>
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c == 95 ||
      c == 45;

  /// Streams the response line-by-line rather than buffering the whole body
  /// into one String — Xtream `get.php` playlists with tens of thousands of
  /// entries can be well over 100MB of text, and materializing that as a
  /// single contiguous allocation is what triggers an OutOfMemoryError on
  /// phones with a capped per-app heap (Android's default ~256MB ceiling).
  static Future<List<Channel>> fetchAndParse(String url,
      {required String playlistId,
      bool liveOnly = false,
      Map<String, String> headers = const {},
      void Function(int bytes)? onProgress}) async {
    final port = onProgress == null ? null : ReceivePort();
    final subscription = port?.listen((bytes) => onProgress!(bytes as int));
    try {
      return await compute(
          _fetchPlaylist, (url, playlistId, liveOnly, headers, port?.sendPort));
    } finally {
      await subscription?.cancel();
      port?.close();
    }
  }

  static Future<List<Channel>> _fetchPlaylist(
      (
        String,
        String,
        bool,
        Map<String, String>,
        SendPort?
      ) requestData) async {
    final (url, playlistId, liveOnly, headers, progress) = requestData;
    final client = playlistHttpClient(headers['User-Agent']);
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(headers);
      final streamedResponse =
          await client.send(request).timeout(const Duration(seconds: 30));

      if (streamedResponse.statusCode != 200) {
        throw PlaylistRequestException(
            'Playlist server returned HTTP ${streamedResponse.statusCode}.',
            reason: PlaylistFailureReason.http,
            httpStatus: streamedResponse.statusCode);
      }

      return await parseStream(streamedResponse.stream,
          playlistId: playlistId,
          liveOnly: liveOnly,
          onProgress:
              progress == null ? null : (bytes) => progress.send(bytes));
    } finally {
      client.close();
    }
  }

  /// Timeout measures silence on the byte stream, not total download time or
  /// gaps between complete lines. Parsing remains on the download isolate.
  @visibleForTesting
  static Future<List<Channel>> parseStream(Stream<List<int>> stream,
      {required String playlistId,
      bool liveOnly = false,
      Duration stallTimeout = const Duration(seconds: 60),
      void Function(int bytes)? onProgress}) async {
    final state = _ParseState(playlistId: playlistId, liveOnly: liveOnly);
    var bytes = 0;
    final watch = Stopwatch()..start();
    var nextReport = 0;
    await stream
        .timeout(stallTimeout, onTimeout: (sink) {
          sink.addError(const PlaylistRequestException(
              'Playlist download stopped responding. Please try again.',
              reason: PlaylistFailureReason.timeout));
          sink.close();
        })
        .map((chunk) {
          bytes += chunk.length;
          if (onProgress != null && watch.elapsedMilliseconds >= nextReport) {
            nextReport = watch.elapsedMilliseconds + 1000;
            onProgress(bytes);
          }
          return chunk;
        })
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(state.consumeLine);
    onProgress?.call(bytes);
    return Channel.withUniqueIds(state.channels);
  }

  /// Parses an already-in-memory M3U string. Kept for convenience (tests,
  /// small local files) — [fetchAndParse] is what avoids buffering large
  /// remote playlists whole.
  static List<Channel> parse(String content,
      {required String playlistId, bool liveOnly = false}) {
    final state = _ParseState(playlistId: playlistId, liveOnly: liveOnly);
    for (final line in content.split(RegExp(r'\r?\n'))) {
      state.consumeLine(line);
    }
    return state.channels;
  }
}

/// Holds the mutable state needed to parse M3U one line at a time, so the
/// same logic can drive either a fully-buffered string ([M3uParser.parse])
/// or a live stream ([M3uParser.fetchAndParse]).
class _ParseState {
  _ParseState({required this.playlistId, this.liveOnly = false});

  final bool liveOnly;

  final String playlistId;
  final List<Channel> channels = [];
  Map<String, String> _attrs = {};
  String? _pendingName;
  String? _pendingSubtitleUrl;
  int _autoId = 0;

  void consumeLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) return;

    if (line.startsWith('#EXTINF')) {
      _attrs = M3uParser.attributesOf(line);
      // EXTINF's first comma outside quoted attributes starts the display
      // name. Later commas belong to that name, including location names
      // and dated PPV labels whose END/NEXT prefix must be preserved.
      var quoted = false;
      var commaIndex = -1;
      for (var i = 0; i < line.length; i++) {
        if (line.codeUnitAt(i) == 34) quoted = !quoted;
        if (line.codeUnitAt(i) == 44 && !quoted) {
          commaIndex = i;
          break;
        }
      }
      _pendingName = commaIndex != -1
          ? line.substring(commaIndex + 1).trim()
          : 'Unnamed Channel';
      _pendingSubtitleUrl = null;
    } else if (line.startsWith('#EXTVLCOPT:sub-file=')) {
      _pendingSubtitleUrl = line.split('=').skip(1).join('=').trim();
    } else if (line.startsWith('#EXTGRP:')) {
      _attrs['group-title'] = line.substring('#EXTGRP:'.length).trim();
    } else if (line.startsWith('#')) {
      // Unsupported directive (#EXTM3U, #EXT-X-*, ...) — ignore.
      return;
    } else {
      // A bare, non-comment line is the stream URL that finishes the
      // pending #EXTINF entry.
      if (_pendingName != null) {
        _autoId++;
        final tvgId = _attrs['tvg-id'];
        final rawId =
            (tvgId != null && tvgId.isNotEmpty) ? tvgId : 'ch_$_autoId';
        final groupTitle = _attrs['group-title'];
        final channel = Channel(
          id: '$playlistId::$rawId',
          rawId: rawId,
          playlistId: playlistId,
          name: _pendingName!,
          group: (groupTitle != null && groupTitle.isNotEmpty)
              ? groupTitle
              : 'Uncategorized',
          url: line,
          logoUrl: _attrs['tvg-logo'],
          subtitleUrl: _pendingSubtitleUrl,
        );
        if (!liveOnly || !isOnDemandChannel(channel)) channels.add(channel);
      }
      _pendingName = null;
      _attrs = {};
      _pendingSubtitleUrl = null;
    }
  }
}
