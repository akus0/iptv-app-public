import 'dart:convert';

import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../utils/display_title.dart';
import 'storage_service.dart';

/// A Stremio-protocol add-on the user turned on. Only its `subtitles`
/// resource is used (subtitles only — stream add-ons are
/// almost all torrent/debrid scrapers, which this app stays away from).
class Addon {
  const Addon({
    required this.manifestUrl,
    required this.name,
    this.description = '',
    this.enabled = false,
  });

  final String manifestUrl;
  final String name;
  final String description;
  final bool enabled;

  /// Where its resources live: the manifest URL minus `/manifest.json`.
  String get baseUrl {
    final u = manifestUrl.trim();
    return u.endsWith('/manifest.json')
        ? u.substring(0, u.length - '/manifest.json'.length)
        : u.replaceAll(RegExp(r'/+$'), '');
  }

  Addon copyWith({bool? enabled}) => Addon(
        manifestUrl: manifestUrl,
        name: name,
        description: description,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'url': manifestUrl,
        'name': name,
        'description': description,
        'enabled': enabled,
      };

  factory Addon.fromJson(Map<String, dynamic> j) => Addon(
        manifestUrl: j['url'] as String,
        name: (j['name'] as String?) ?? j['url'] as String,
        description: (j['description'] as String?) ?? '',
        enabled: j['enabled'] == true,
      );
}

/// One subtitle an add-on offers for the playing movie/episode.
class OnlineSubtitle {
  const OnlineSubtitle({
    required this.url,
    required this.lang,
    required this.addonName,
    this.fileName,
  });

  final String url;

  /// ISO 639-2 as add-ons send it ("fre", "eng", "spa").
  final String lang;
  final String addonName;
  final String? fileName;
}

/// Subtitle add-ons (Settings > Add-ons) and the lookups behind the
/// player's "Online" subtitles. Nothing runs until the user switches an
/// add-on on; the official OpenSubtitles add-on is listed, off, so it's one
/// switch away. Titles are matched to an IMDb id through
/// Cinemeta (Stremio's free metadata add-on, no key), which is what
/// subtitle add-ons are keyed by. Xtream movies/episodes only: those are
/// the ones whose title, year and episode the app knows.
class AddonService {
  AddonService(this._storage);

  final StorageService _storage;

  static const openSubtitlesManifest =
      'https://opensubtitles-v3.strem.io/manifest.json';
  static const _cinemeta = 'https://v3-cinemeta.strem.io';
  static const _timeout = Duration(seconds: 15);

  static const _defaults = [
    Addon(
      manifestUrl: openSubtitlesManifest,
      name: 'OpenSubtitles v3',
      description: 'OpenSubtitles v3 Addon for Stremio',
    ),
  ];

  /// IMDb ids already resolved, by channel id.
  static final Map<String, String?> _imdbCache = {};

  List<Addon> get addons {
    final raw = _storage.getAddonsJson();
    if (raw == null) return _defaults;
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          Addon.fromJson(Map<String, dynamic>.from(j as Map)),
      ];
    } catch (_) {
      return _defaults;
    }
  }

  bool get anyEnabled => addons.any((a) => a.enabled);

  Future<void> save(List<Addon> list) =>
      _storage.setAddonsJson(jsonEncode([for (final a in list) a.toJson()]));

  /// Reads an add-on's manifest. Null when the link isn't an add-on or it
  /// offers no subtitles (the only resource used here).
  static Future<Addon?> fetchManifest(String url) async {
    var u = url.trim();
    if (u.startsWith('stremio://')) u = 'https://${u.substring(10)}';
    if (!u.endsWith('/manifest.json')) {
      u = '${u.replaceAll(RegExp(r'/+$'), '')}/manifest.json';
    }
    final r = await http.get(Uri.parse(u)).timeout(_timeout);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final resources = (j['resources'] as List? ?? const [])
        .map((e) => e is Map ? e['name']?.toString() : e?.toString());
    if (!resources.contains('subtitles')) return null;
    return Addon(
      manifestUrl: u,
      name: (j['name'] as String?) ?? u,
      description: (j['description'] as String?) ?? '',
      enabled: true,
    );
  }

  /// Whether [channel] is something an add-on can find subtitles for.
  static bool supports(Channel channel) =>
      channel.rawId.startsWith('xt_vod_') || channel.rawId.startsWith('xt_ep_');

  static final _yearRe = RegExp(r'\((\d{4})\)');
  static final _episodeRe = RegExp(r'^S(\d+)E(\d+)');

  /// The Stremio id for [channel]: "tt123" (movie) or "tt123:1:2" (episode).
  Future<({String type, String id})?> _stremioId(Channel channel) async {
    final isEpisode = channel.rawId.startsWith('xt_ep_');
    final source = isEpisode ? channel.group : channel.name;
    final year = _yearRe.firstMatch(source)?.group(1);
    var title = cleanDisplayTitle(source)
        .replaceFirst(RegExp(r'^(4K|UHD|HD|FHD)\s+', caseSensitive: false), '')
        .trim();
    if (title.isEmpty) return null;
    final type = isEpisode ? 'series' : 'movie';
    final imdb = _imdbCache.containsKey(channel.id)
        ? _imdbCache[channel.id]
        : _imdbCache[channel.id] = await _searchImdb(type, title, year);
    if (imdb == null) return null;
    if (!isEpisode) return (type: type, id: imdb);
    final m = _episodeRe.firstMatch(channel.name);
    if (m == null) return null;
    return (
      type: type,
      id: '$imdb:${int.parse(m.group(1)!)}:${int.parse(m.group(2)!)}'
    );
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  Future<String?> _searchImdb(String type, String title, String? year) async {
    try {
      final uri = Uri.parse('$_cinemeta/catalog/$type/top/search='
          '${Uri.encodeComponent(title)}.json');
      final r = await http.get(uri).timeout(_timeout);
      if (r.statusCode != 200) return null;
      final metas =
          ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['metas'] as List? ??
              const []);
      final want = _norm(title);
      Map? pick;
      for (final m in metas.whereType<Map>()) {
        final sameName = _norm('${m['name']}') == want;
        final release = '${m['releaseInfo'] ?? m['year'] ?? ''}';
        final sameYear = year == null || release.startsWith(year);
        if (sameName && sameYear) {
          pick = m;
          break;
        }
        if (sameName) pick ??= m;
      }
      pick ??= metas.whereType<Map>().firstOrNull;
      final id = pick?['id']?.toString();
      return (id != null && id.startsWith('tt')) ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Every enabled add-on's subtitles for [channel], the app language
  /// first, then English, then the rest by language.
  Future<List<OnlineSubtitle>> search(Channel channel) async {
    if (!supports(channel)) return const [];
    final enabled = addons.where((a) => a.enabled).toList();
    if (enabled.isEmpty) return const [];
    final target = await _stremioId(channel);
    if (target == null) return const [];
    final results = <OnlineSubtitle>[];
    await Future.wait(enabled.map((a) async {
      try {
        final r = await http
            .get(Uri.parse(
                '${a.baseUrl}/subtitles/${target.type}/${target.id}.json'))
            .timeout(_timeout);
        if (r.statusCode != 200) return;
        final list = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['subtitles']
                as List? ??
            const []);
        for (final s in list.whereType<Map>()) {
          final url = s['url']?.toString();
          if (url == null || url.isEmpty) continue;
          results.add(OnlineSubtitle(
            url: url,
            lang: s['lang']?.toString() ?? 'und',
            addonName: a.name,
            fileName: s['subtitleFileName']?.toString(),
          ));
        }
      } catch (_) {
        // One add-on down shouldn't hide the others' results.
      }
    }));
    int rank(OnlineSubtitle s) {
      final l = _twoLetter(s.lang);
      if (l == L10n.code) return 0;
      if (l == 'en') return 1;
      return 2;
    }

    results.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.lang.compareTo(b.lang);
    });
    return results;
  }

  /// "fre"/"fra" → "fr" for ranking; other codes pass through.
  static String _twoLetter(String code) =>
      const {
        'eng': 'en',
        'fre': 'fr',
        'fra': 'fr',
        'spa': 'es',
        'ita': 'it',
      }[code] ??
      code;

  /// The subtitle file's text (SRT or WebVTT).
  static Future<String> download(OnlineSubtitle s) async {
    final r = await http.get(Uri.parse(s.url)).timeout(_timeout);
    if (r.statusCode != 200) {
      throw http.ClientException('HTTP ${r.statusCode}', Uri.parse(s.url));
    }
    var text = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    return text;
  }
}
