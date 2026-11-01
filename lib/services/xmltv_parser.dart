import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:xml/xml_events.dart';

import '../models/epg_program.dart';
import '../utils/constants.dart';
import '../utils/thai_epg.dart';
import 'epg_database.dart';

typedef XmltvResult = ({
  int stored,
  Map<String, String> channelNames,
  Map<String, EpgProgram> nowPlaying,
});

/// Decode and parse in a worker while retaining database ownership in the caller.
/// Pull-based input and acknowledged row batches bound memory even when the
/// download is fast or SQLite is busy. No complete XML document is buffered.
Future<XmltvResult> parseXmltvInBackground(
  Stream<List<int>> input, {
  Set<String>? knownChannelIds,
  String namespace = '',
  required String noTitle,
  DateTime? now,
  Duration timeout = const Duration(minutes: 10),
  required Future<void> Function(List<EpgRow>) onRows,
}) async {
  final messages = ReceivePort();
  final bytes = _XmltvInput(input);
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
        _xmltvWorker,
        (
          port: messages.sendPort,
          knownChannelIds: knownChannelIds,
          namespace: namespace,
          noTitle: noTitle,
          now: now ?? DateTime.now(),
        ),
        onError: messages.sendPort,
        onExit: messages.sendPort,
        debugName: 'xmltv-parser');
    Future<XmltvResult> receive() async {
      await for (final message in messages) {
        switch (message) {
          case ('read', SendPort reply):
            reply.send(await bytes.read());
          case ('rows', List<EpgRow> rows, SendPort reply):
            await onRows(rows);
            reply.send(true);
          case ('done', XmltvResult result):
            return result;
          case ('error', String error, String stack):
            Error.throwWithStackTrace(
                FormatException(error), StackTrace.fromString(stack));
          case [String error, String stack]:
            Error.throwWithStackTrace(
                StateError(error), StackTrace.fromString(stack));
          default:
            throw StateError('XMLTV parser stopped before completing');
        }
      }
      throw StateError('XMLTV parser closed before completing');
    }

    return await receive().timeout(timeout);
  } finally {
    worker?.kill(priority: Isolate.immediate);
    messages.close();
    await bytes.cancel();
  }
}

// Bound each cross-isolate copy without an async-generator wrapper: cancelling
// a stalled download must cancel its subscription immediately, not wait for the
// generator's pending read. A slice owns its bytes (no full-file backing buffer).
class _XmltvInput {
  _XmltvInput(Stream<List<int>> input) : _iterator = StreamIterator(input);
  final StreamIterator<List<int>> _iterator;
  List<int> _chunk = const [];
  int _offset = 0;

  Future<List<int>?> read() async {
    while (_offset == _chunk.length) {
      if (!await _iterator.moveNext()) return null;
      _chunk = _iterator.current;
      _offset = 0;
    }
    final end = (_offset + 64 * 1024).clamp(0, _chunk.length);
    final result = _chunk.sublist(_offset, end);
    _offset = end;
    return result;
  }

  Future<void> cancel() => _iterator.cancel();
}

typedef _XmltvRequest = ({
  SendPort port,
  Set<String>? knownChannelIds,
  String namespace,
  String noTitle,
  DateTime now,
});

Future<Object?> _request(
    SendPort port, Object Function(SendPort) message) async {
  final reply = ReceivePort();
  try {
    port.send(message(reply.sendPort));
    return await reply.first;
  } finally {
    reply.close();
  }
}

void _xmltvWorker(_XmltvRequest request) async {
  Stream<List<int>> input() async* {
    while (true) {
      final bytes = await _request(request.port, (reply) => ('read', reply));
      if (bytes == null) return;
      yield bytes as List<int>;
    }
  }

  try {
    final result = await _parseXmltvStream(
      _autoGunzip(input()),
      knownChannelIds: request.knownChannelIds,
      namespace: request.namespace,
      noTitle: request.noTitle,
      now: request.now,
      onRows: (rows) async {
        await _request(request.port, (reply) => ('rows', rows, reply));
      },
    );
    // Transfer ownership of the final channel catalogues instead of copying
    // potentially thousands of currently-airing programmes back to the UI.
    Isolate.exit(request.port, ('done', result));
  } catch (error, stack) {
    Isolate.exit(request.port, ('error', error.toString(), stack.toString()));
  }
}

/// Sniff across chunk boundaries, including a one-byte first network packet.
Stream<List<int>> _autoGunzip(Stream<List<int>> input) async* {
  final it = StreamIterator(input);
  try {
    final prefix = <int>[];
    while (prefix.length < 2 && await it.moveNext()) {
      prefix.addAll(it.current);
    }
    if (prefix.isEmpty) return;
    Stream<List<int>> rebuilt() async* {
      yield prefix;
      while (await it.moveNext()) {
        yield it.current;
      }
    }

    final compressed =
        prefix.length >= 2 && prefix[0] == 0x1f && prefix[1] == 0x8b;
    yield* compressed ? rebuilt().transform(gzip.decoder) : rebuilt();
  } finally {
    await it.cancel();
  }
}

/// Parses XMLTV as a stream of events rather than building a full DOM —
/// full program guides (many channels x many days) are routinely well
/// over 100MB of XML, and loading that into one String plus a full
/// [XmlDocument] tree is exactly the kind of allocation that triggers an
/// OutOfMemoryError on a phone's capped per-app heap.
///
/// Programmes are handed to [onRows] in batches as they're parsed, never
/// accumulated — only those inside the stored window
/// ([AppConstants.epgPastRetention]/[AppConstants.epgFutureWindow]) and,
/// when [knownChannelIds] is non-null, only for channels in it (a shared
/// multi-provider source routinely covers far more channels than any
/// one playlist actually has).
Future<
    ({
      int stored,
      Map<String, String> channelNames,
      Map<String, EpgProgram> nowPlaying
    })> _parseXmltvStream(
  Stream<List<int>> byteStream, {
  Set<String>? knownChannelIds,
  String namespace = '',
  required DateTime now,
  required String noTitle,
  required Future<void> Function(List<EpgRow> rows) onRows,
}) async {
  const batchSize = 1000;
  var pending = <EpgRow>[];
  var stored = 0;
  // Every <channel id>'s first <display-name> — never filtered by
  // [knownChannelIds]: see [EpgService._channelCatalog]'s doc comment for
  // why the *whole* feed's directory matters here, not just whatever one
  // playlist already owns.
  final channelNames = <String, String>{};
  // Every <channel id>'s own currently-airing programme, same
  // unfiltered-by-design reasoning as [channelNames] — "Assign EPG
  // channel" needs to show what's actually on right now for each
  // *candidate* id, most of which aren't in [knownChannelIds] at all
  // (that's the whole point of searching for one). Bounded the same
  // way [channelNames] is (one entry per channel, not per programme),
  // so keeping it unfiltered costs nothing worth guarding against.
  final nowPlaying = <String, EpgProgram>{};
  final minStopMs =
      now.subtract(AppConstants.epgPastRetention).millisecondsSinceEpoch;
  final maxStartMs =
      now.add(AppConstants.epgFutureWindow).millisecondsSinceEpoch;

  String? channelId;
  String? startRaw;
  String? stopRaw;
  // 'title'/'desc' while inside a <programme>, or 'display-name' while
  // inside a <channel> — safe to share one flag either way since XMLTV
  // never nests one inside the other.
  String? currentTextTag;
  String? title;
  String? desc;
  String? subtitle;
  var isLive = false;
  String? catalogChannelId;
  String? catalogDisplayName;
  final preferEnglish = namespace == thaiEpgPrefix;
  String? localizedText;
  var languagePriority = 0,
      titlePriority = -1,
      descPriority = -1,
      subtitlePriority = -1;

  void finalizeProgramme() {
    if (channelId == null || startRaw == null || stopRaw == null) return;
    try {
      final start = _parseXmltvTime(startRaw);
      final stop = _parseXmltvTime(stopRaw);
      final cleanTitle =
          title?.trim().isNotEmpty == true ? title!.trim() : noTitle;
      // Preserve episode/match subtitles in the existing searchable synopsis.
      // This needs no database migration and keeps the guide's show title intact.
      final cleanSubtitle = subtitle?.trim() ?? '';
      final description = desc?.trim() ?? '';
      final combined = cleanSubtitle.isEmpty ||
              description.toLowerCase().contains(cleanSubtitle.toLowerCase()) ||
              cleanTitle.toLowerCase().contains(cleanSubtitle.toLowerCase())
          ? description
          : '$cleanSubtitle\n$description'.trim();
      final cleanDesc = combined.isEmpty ? null : combined;
      if (!now.isBefore(start) && now.isBefore(stop)) {
        nowPlaying[channelId] = EpgProgram(
          channelId: channelId,
          title: cleanTitle,
          description: cleanDesc,
          isLive: isLive,
          start: start,
          stop: stop,
        );
      }
      if (knownChannelIds != null && !knownChannelIds.contains(channelId)) {
        return;
      }
      final startMs = start.millisecondsSinceEpoch;
      final stopMs = stop.millisecondsSinceEpoch;
      if (stopMs <= minStopMs || startMs >= maxStartMs) return;
      pending.add((
        channelId: channelId,
        startMs: startMs,
        stopMs: stopMs,
        title: cleanTitle,
        description: cleanDesc,
        isLive: isLive,
      ));
    } catch (_) {
      // Unparseable timestamp — skip this one programme, keep going.
    }
  }

  Future<void> flush() async {
    if (pending.isEmpty) return;
    final rows = pending;
    pending = <EpgRow>[];
    stored += rows.length;
    await onRows(rows);
  }

  final events = byteStream
      .transform(const Utf8Decoder(allowMalformed: true))
      .toXmlEvents()
      .normalizeEvents()
      .flatten();

  await for (final event in events) {
    if (event is XmlStartElementEvent) {
      if (event.name == 'programme') {
        channelId = null;
        startRaw = null;
        stopRaw = null;
        title = null;
        desc = null;
        subtitle = null;
        subtitlePriority = -1;
        titlePriority = -1;
        descPriority = -1;
        localizedText = null;
        isLive = false;
        currentTextTag = null;
        for (final attr in event.attributes) {
          switch (attr.name) {
            case 'channel':
              channelId = '$namespace${attr.value.trim().toLowerCase()}';
            case 'start':
              startRaw = attr.value;
            case 'stop':
              stopRaw = attr.value;
          }
        }
        // A self-closing <programme/> has no title/desc children and no
        // matching end event, so it must be recorded right here.
        if (event.isSelfClosing) finalizeProgramme();
      } else if (event.name == 'live') {
        isLive = true;
      } else if (event.name == 'channel') {
        catalogChannelId = null;
        catalogDisplayName = null;
        currentTextTag = null;
        for (final attr in event.attributes) {
          if (attr.name == 'id') {
            catalogChannelId = '$namespace${attr.value.trim().toLowerCase()}';
          }
        }
      } else if ((event.name == 'title' ||
              event.name == 'desc' ||
              event.name == 'sub-title' ||
              event.name == 'display-name') &&
          !event.isSelfClosing) {
        // Self-closing versions of these carry no text — leave
        // currentTextTag unset so we don't wait on an end event that
        // will never arrive for them.
        currentTextTag = event.name;
        if (preferEnglish &&
            (event.name == 'title' ||
                event.name == 'desc' ||
                event.name == 'sub-title')) {
          localizedText = '';
          final lang = event.attributes
                  .where((a) => a.name == 'lang')
                  .firstOrNull
                  ?.value
                  .toLowerCase() ??
              '';
          languagePriority = lang == 'en' || lang.startsWith('en-') ? 2 : 0;
        }
      }
    } else if (event is XmlTextEvent) {
      if (preferEnglish &&
          (currentTextTag == 'title' ||
              currentTextTag == 'desc' ||
              currentTextTag == 'sub-title')) {
        localizedText = (localizedText ?? '') + event.value;
      } else if (currentTextTag == 'title') {
        title = (title ?? '') + event.value;
      } else if (currentTextTag == 'sub-title') {
        subtitle = (subtitle ?? '') + event.value;
      } else if (currentTextTag == 'desc') {
        desc = (desc ?? '') + event.value;
      } else if (currentTextTag == 'display-name' &&
          catalogDisplayName == null) {
        // First <display-name> only — a channel can list several
        // (language variants, abbreviations); the first is XMLTV's own
        // convention for "the" name.
        catalogDisplayName = event.value;
      }
    } else if (event is XmlEndElementEvent) {
      if (event.name == 'title' ||
          event.name == 'desc' ||
          event.name == 'sub-title') {
        if (preferEnglish && (localizedText?.trim().isNotEmpty ?? false)) {
          if (event.name == 'title' && languagePriority > titlePriority) {
            title = localizedText;
            titlePriority = languagePriority;
          } else if (event.name == 'desc' && languagePriority > descPriority) {
            desc = localizedText;
            descPriority = languagePriority;
          } else if (event.name == 'sub-title' &&
              languagePriority > subtitlePriority) {
            subtitle = localizedText;
            subtitlePriority = languagePriority;
          }
        }
        localizedText = null;
        currentTextTag = null;
      } else if (event.name == 'display-name') {
        currentTextTag = null;
      } else if (event.name == 'programme') {
        finalizeProgramme();
      } else if (event.name == 'channel') {
        final id = catalogChannelId;
        if (id != null && catalogDisplayName != null) {
          channelNames.putIfAbsent(id, () => catalogDisplayName!.trim());
        }
      }
    }
    if (pending.length >= batchSize) await flush();
  }
  await flush();

  return (stored: stored, channelNames: channelNames, nowPlaying: nowPlaying);
}

/// Parses XMLTV timestamps such as `20240101120000 +0000`.
DateTime _parseXmltvTime(String raw) {
  final cleaned = raw.trim();
  final datePart = cleaned.substring(0, 14);
  final year = int.parse(datePart.substring(0, 4));
  final month = int.parse(datePart.substring(4, 6));
  final day = int.parse(datePart.substring(6, 8));
  final hour = int.parse(datePart.substring(8, 10));
  final minute = int.parse(datePart.substring(10, 12));
  final second = int.parse(datePart.substring(12, 14));

  var offsetHours = 0;
  var offsetMinutes = 0;
  if (cleaned.length > 15) {
    final offsetPart = cleaned.substring(15).trim();
    final sign = offsetPart.startsWith('-') ? -1 : 1;
    final digits = offsetPart.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 4) {
      offsetHours = sign * int.parse(digits.substring(0, 2));
      offsetMinutes = sign * int.parse(digits.substring(2, 4));
    }
  }

  return DateTime.utc(year, month, day, hour, minute, second)
      .subtract(Duration(hours: offsetHours, minutes: offsetMinutes))
      .toLocal();
}
