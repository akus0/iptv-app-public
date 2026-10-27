import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../utils/channel_content.dart';

import '../models/channel.dart';
import '../l10n/l10n.dart';

/// Parses M3U / M3U8 playlists into [Channel] objects.
///
/// Supports the common extended attributes (`tvg-id`, `tvg-logo`,
/// `group-title`), the `#EXTGRP:` fallback tag, and an optional external
/// subtitle track via `#EXTVLCOPT:sub-file=`.
class M3uParser {
  static final RegExp _attrPattern = RegExp(r'([a-zA-Z0-9_-]+)="([^"]*)"');

  /// Streams the response line-by-line rather than buffering the whole body
  /// into one String — Xtream `get.php` playlists with tens of thousands of
  /// entries can be well over 100MB of text, and materializing that as a
  /// single contiguous allocation is what triggers an OutOfMemoryError on
  /// phones with a capped per-app heap (Android's default ~256MB ceiling).
  static Future<List<Channel>> fetchAndParse(String url,
          {required String playlistId, bool liveOnly = false}) =>
      compute(_fetchPlaylist, (url, playlistId, liveOnly));

  static Future<List<Channel>> _fetchPlaylist(
      (String, String, bool) requestData) async {
    final (url, playlistId, liveOnly) = requestData;
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final streamedResponse =
          await client.send(request).timeout(const Duration(seconds: 30));

      if (streamedResponse.statusCode != 200) {
        throw Exception(tr(
            'Failed to load playlist from {host} (HTTP {code})', {
          'host': Uri.parse(url).host,
          'code': streamedResponse.statusCode
        }));
      }

      final state = _ParseState(playlistId: playlistId, liveOnly: liveOnly);
      await streamedResponse.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(state.consumeLine)
          .timeout(const Duration(minutes: 5));

      return Channel.withUniqueIds(state.channels);
    } finally {
      client.close();
    }
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
      _attrs = {};
      for (final match in M3uParser._attrPattern.allMatches(line)) {
        _attrs[match.group(1)!.toLowerCase()] = match.group(2)!;
      }
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
