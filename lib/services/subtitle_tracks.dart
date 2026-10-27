import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

import '../models/channel.dart';
import 'addon_service.dart';
import 'storage_service.dart';

/// Display name for a subtitle/audio language code ("fr-CA" → "Français
/// (CA)"), in that language — how pickers usually list them.
String languageName(String? code) {
  if (code == null || code.isEmpty || code == 'und') return '';
  final parts = code.split(RegExp('[-_]'));
  const names = {
    'en': 'English',
    'eng': 'English',
    'fr': 'Français',
    'fre': 'Français',
    'fra': 'Français',
    'es': 'Español',
    'spa': 'Español',
    'it': 'Italiano',
    'ita': 'Italiano',
    'de': 'Deutsch',
    'ger': 'Deutsch',
    'deu': 'Deutsch',
    'pt': 'Português',
    'por': 'Português',
    'nl': 'Nederlands',
    'dut': 'Nederlands',
    'nld': 'Nederlands',
    'ar': 'العربية',
    'ara': 'العربية',
    'ru': 'Русский',
    'rus': 'Русский',
    'ja': '日本語',
    'jpn': '日本語',
    'ko': '한국어',
    'kor': '한국어',
    'zh': '中文',
    'chi': '中文',
    'zho': '中文',
    'hi': 'हिन्दी',
    'hin': 'हिन्दी',
    'tr': 'Türkçe',
    'tur': 'Türkçe',
    'pl': 'Polski',
    'pol': 'Polski',
    'sv': 'Svenska',
    'swe': 'Svenska',
    'da': 'Dansk',
    'dan': 'Dansk',
    'no': 'Norsk',
    'nb': 'Norsk',
    'nor': 'Norsk',
    'fi': 'Suomi',
    'fin': 'Suomi',
    'el': 'Ελληνικά',
    'gre': 'Ελληνικά',
    'he': 'עברית',
    'heb': 'עברית',
    'cs': 'Čeština',
    'cze': 'Čeština',
    'hu': 'Magyar',
    'hun': 'Magyar',
    'ro': 'Română',
    'rum': 'Română',
    'uk': 'Українська',
    'vi': 'Tiếng Việt',
    'vie': 'Tiếng Việt',
    'th': 'ไทย',
    'tha': 'ไทย',
    'id': 'Bahasa Indonesia',
    'ind': 'Bahasa Indonesia',
    'ms': 'Bahasa Melayu',
    'hr': 'Hrvatski',
    'bg': 'Български',
    'ta': 'தமிழ்',
    'tam': 'தமிழ்',
    'ell': 'Ελληνικά',
    'srp': 'Српски',
    'ron': 'Română',
    'bul': 'Български',
    'ukr': 'Українська',
    'slv': 'Slovenščina',
    'slk': 'Slovenčina',
    'est': 'Eesti',
    'lav': 'Latviešu',
    'lit': 'Lietuvių',
    'per': 'فارسی',
    'fas': 'فارسی',
    'hrv': 'Hrvatski',
    'pob': 'Português (BR)',
    'zht': '中文 (繁體)',
    'zhe': '中文',
    'may': 'Bahasa Melayu',
    'msa': 'Bahasa Melayu',
  };
  final base = names[parts.first.toLowerCase()] ?? parts.first.toUpperCase();
  return parts.length > 1 ? '$base (${parts.sublist(1).join('-')})' : base;
}

/// One subtitle track inside the playing file (MKV/MP4 text tracks).
class SubtitleTrack {
  const SubtitleTrack({
    required this.group,
    required this.track,
    this.language,
    this.label,
    this.forced = false,
    this.selected = false,
    this.closedCaptions = false,
  });

  final int group;
  final int track;
  final String? language;
  final String? label;
  final bool forced;
  final bool selected;

  /// Broadcast closed captions (CEA-608/708) on a live channel. Every .ts
  /// stream lists one; it stays empty on channels that don't carry them.
  final bool closedCaptions;
}

/// Android embedded subtitle tracks through the vendored SubtitleBridge. Tracks start
/// disabled; [select] enables one and [cues] supplies text. [playerId] is the controller
/// texture id.
class SubtitleTracks {
  static const _methods = MethodChannel('vespertv/subtitles');
  static const _events = EventChannel('vespertv/subtitles/cues');

  static final Stream<({int playerId, String text})> cues =
      _events.receiveBroadcastStream().map((e) {
    final m = e as Map;
    return (
      playerId: (m['playerId'] as num).toInt(),
      text: (m['text'] as String?) ?? '',
    );
  });

  /// The plugin's player id for [controller]. video_player_hdr marks
  /// `textureId` test-only, but it is exactly the id the native bridge keys
  /// players by (the platform-view player's id).
  static int playerIdOf(VideoPlayerHdrController controller) =>
      // ignore: invalid_use_of_visible_for_testing_member
      controller.textureId;

  static Future<List<SubtitleTrack>> list(int playerId) async {
    final raw = await _methods
            .invokeListMethod<Map>('getTextTracks', {'playerId': playerId}) ??
        const [];
    return [
      for (final m in raw)
        SubtitleTrack(
          group: (m['group'] as num).toInt(),
          track: (m['track'] as num).toInt(),
          language: m['language'] as String?,
          label: m['label'] as String?,
          forced: m['forced'] == true,
          selected: m['selected'] == true,
          closedCaptions: m['cc'] == true,
        ),
    ];
  }

  /// The player showing a downloaded subtitle file (an add-on's, see
  /// AddonService) instead of an embedded track; SubtitleOverlay then draws
  /// the controller's caption.
  static final ValueNotifier<int?> externalFor = ValueNotifier(null);

  /// Shows [text] (SRT or WebVTT) on [controller], embedded tracks off.
  static Future<void> useExternal(
      VideoPlayerHdrController controller, String text) async {
    final id = playerIdOf(controller);
    await select(id, null);
    final file = text.trimLeft().startsWith('WEBVTT')
        ? WebVTTCaptionFile(text)
        : SubRipCaptionFile(text);
    await controller.setClosedCaptionFile(Future.value(file));
    externalFor.value = id;
  }

  /// Drops a downloaded file from [controller] (picking Off or an embedded
  /// track).
  static Future<void> clearExternal(VideoPlayerHdrController controller) async {
    final id = playerIdOf(controller);
    if (externalFor.value != id) return;
    externalFor.value = null;
    await controller.setClosedCaptionFile(null);
  }

  /// null = subtitles off.
  static Future<void> select(int playerId, SubtitleTrack? track) =>
      _methods.invokeMethod('selectTextTrack', {
        'playerId': playerId,
        'group': track?.group ?? -1,
        'track': track?.track ?? 0,
      });

  /// What a downloaded subtitle shows as in the picker, by player id.
  static final Map<int, String> externalLabel = {};

  // ------------------------------------------------- per-series memory

  /// Subtitles turned on during an episode stay on for the rest of that
  /// series; movies are picked each time. Off forgets.
  static String? seriesKeyOf(Channel channel) =>
      channel.rawId.startsWith('xt_ep_')
          ? '${channel.playlistId}::${channel.group}'
          : null;

  static Map<String, dynamic> _seriesChoices(StorageService storage) {
    try {
      final raw = storage.getSeriesSubtitlesJson();
      return raw == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  /// The remembered choice for [channel]'s series (`kind`/`lang`/`label`),
  /// or null — Windows' player reapplies it itself (desktop_subtitles.dart).
  static Map<String, dynamic>? seriesChoiceFor(
      StorageService storage, Channel channel) {
    final key = seriesKeyOf(channel);
    final choice = key == null ? null : _seriesChoices(storage)[key];
    return choice is Map ? Map<String, dynamic>.from(choice) : null;
  }

  /// [kind] 'embedded' (a track of the file, matched by [lang] + [label])
  /// or 'online' (the first add-on match in [lang]); null = forget.
  static Future<void> rememberForSeries(
      StorageService storage, Channel? channel,
      {String? kind, String? lang, String? label}) async {
    final key = channel == null ? null : seriesKeyOf(channel);
    if (key == null) return;
    final all = _seriesChoices(storage);
    if (kind == null) {
      if (all.remove(key) == null) return;
    } else {
      all[key] = {'kind': kind, 'lang': lang, 'label': label};
    }
    await storage.setSeriesSubtitlesJson(jsonEncode(all));
  }

  /// Reapplies the series' remembered subtitles on a new episode's player.
  /// Gives up quietly when the episode has no matching track/subtitle.
  static Future<void> applyForSeries(StorageService storage, Channel channel,
      VideoPlayerHdrController controller) async {
    final key = seriesKeyOf(channel);
    if (key == null) return;
    final choice = _seriesChoices(storage)[key];
    if (choice is! Map) return;
    final lang = choice['lang'] as String?;
    final id = playerIdOf(controller);
    if (choice['kind'] == 'online') {
      final addons = AddonService(storage);
      if (lang == null || !addons.anyEnabled) return;
      final match = (await addons.search(channel))
          .where((s) => s.lang == lang)
          .firstOrNull;
      if (match == null) return;
      final text = await AddonService.download(match);
      await useExternal(controller, text);
      externalLabel[id] =
          languageName(lang).isEmpty ? lang : languageName(lang);
      return;
    }
    // Embedded: the track list exists once the file's header is read.
    for (var i = 0; i < 6; i++) {
      List<SubtitleTrack> tracks;
      try {
        tracks = await list(id);
      } catch (_) {
        return; // player gone
      }
      if (tracks.isNotEmpty) {
        final label = choice['label'] as String?;
        final sameLang = tracks.where((t) => t.language == lang);
        final pick = sameLang.where((t) => t.label == label).firstOrNull ??
            sameLang.firstOrNull;
        if (pick != null) await select(id, pick);
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}
