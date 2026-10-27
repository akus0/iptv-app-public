import '../models/m3u_group.dart';

/// Presentation only: leaf identities always remain the provider's categories.
/// Building folders never combines catalogues or requests their title lists.
class LibraryCategoryNode {
  LibraryCategoryNode(
      {required this.id,
      required this.title,
      this.group,
      List<LibraryCategoryNode>? children})
      : children = children ?? [];
  final String id, title;
  final M3uGroup? group;
  final List<LibraryCategoryNode> children;
  bool get isFolder => group == null;
  late final int categoryCount =
      isFolder ? children.fold(0, (n, c) => n + c.categoryCount) : 1;
}

class LibraryCategoryTree {
  LibraryCategoryTree._(this.roots, this.labels, this.paths);
  final List<LibraryCategoryNode> roots;
  final Map<String, String> labels, paths;
  late final int sourceCount =
      labels.keys.map((key) => key.split('\u0000').first).toSet().length;
  static String key(M3uGroup group) =>
      '${group.playlistId}\u0000${group.title}';
  String label(M3uGroup group) => labels[key(group)] ?? group.title;
  String path(M3uGroup group) => paths[key(group)] ?? '';

  LibraryCategoryTree.filtered(
      Iterable<M3uGroup> groups, LibraryCategoryTree source)
      : roots = [
          for (final g in groups)
            LibraryCategoryNode(id: key(g), title: source.label(g), group: g)
        ],
        labels = source.labels,
        paths = source.paths;

  factory LibraryCategoryTree(List<M3uGroup> groups,
      {required bool Function(String) organise}) {
    final roots = <LibraryCategoryNode>[];
    final folders = <String, LibraryCategoryNode>{};
    final labels = <String, String>{}, paths = <String, String>{};
    final modes = <String, bool>{};
    final ranks = <String, int>{};
    int compare(LibraryCategoryNode a, LibraryCategoryNode b) {
      final priority = ranks
          .putIfAbsent(a.title, () => _rank(a.title))
          .compareTo(ranks.putIfAbsent(b.title, () => _rank(b.title)));
      return priority != 0
          ? priority
          : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }

    for (final group in groups) {
      final id = key(group);
      final enabled =
          modes.putIfAbsent(group.playlistId, () => organise(group.playlistId));
      final classified = enabled
          ? _classify(group.title)
          : (path: <String>[], title: group.title);
      var siblings = roots;
      var prefix = '';
      for (final folder in classified.path) {
        prefix += '/$folder';
        final node = folders.putIfAbsent(prefix, () {
          final n = LibraryCategoryNode(id: 'folder:$prefix', title: folder);
          siblings.add(n);
          return n;
        });
        siblings = node.children;
      }
      siblings.add(
          LibraryCategoryNode(id: id, title: classified.title, group: group));
      labels[id] = classified.title;
      paths[id] = classified.path.join(' › ');
    }
    // A genre folder is useful for a long list, but adds a needless step to a
    // small playlist. Only collect explicit genre shelves, never infer genres
    // from individual movie/series names or download title metadata.
    final english = folders['/English'];
    if (english != null) {
      final genres = english.children
          .where((n) => !n.isFolder && _genres.contains(n.title.toLowerCase()))
          .toList();
      if (genres.length >= 4) {
        final ids = genres.map((n) => n.id).toSet();
        english.children.removeWhere((n) => ids.contains(n.id));
        english.children.add(LibraryCategoryNode(
            id: 'folder:/English/Genres', title: 'Genres', children: genres));
        for (final n in genres) {
          paths[n.id] = 'English › Genres';
        }
      }
    }
    // Keep provider-order leaves unchanged. Sort only folders and their organised
    // contents; never change category IDs, caches, favourites or saved selection.
    void finish(List<LibraryCategoryNode> nodes, {bool root = false}) {
      for (final n in nodes) {
        if (n.isFolder) finish(n.children);
      }
      if (!root) {
        nodes.sort(compare);
      }
      // A one-category folder does not need another navigation step. Its label
      // includes the folder name so language/source context is not lost.
      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        if (n.isFolder &&
            n.children.length == 1 &&
            (!root || !n.children.single.isFolder)) {
          final leaf = n.children.single;
          final topicAlreadyClear = (n.title == 'Reality & shows' &&
                  _reality.hasMatch(leaf.title)) ||
              (n.title == 'Music & concerts' && _music.hasMatch(leaf.title));
          final title = topicAlreadyClear
              ? leaf.title
              : leaf.title.toLowerCase() == 'all titles'
                  ? n.title
                  : leaf.title.toLowerCase().startsWith(n.title.toLowerCase())
                      ? leaf.title
                      : '${n.title} · ${leaf.title}';
          nodes[i] = LibraryCategoryNode(
              id: leaf.id,
              title: title,
              group: leaf.group,
              children: leaf.children);
        }
      }
    }

    finish(roots, root: true);
    // Organised folders appear before untouched categories, whose relative order
    // must remain exactly the provider order, including mixed-playlist libraries.
    final ordered = roots.where((n) => n.isFolder).toList()..sort(compare);
    final leaves = roots.where((n) => !n.isFolder).toList();
    return LibraryCategoryTree._([...ordered, ...leaves], labels, paths);
  }
}

int _rank(String title) {
  final t = title.toLowerCase();
  if (t == 'english') return 0;
  // Keep the broad catalogue ahead of specialist shelves within each service.
  // A 4K kids/documentary shelf must not displace its general Movies/Series row.
  if (_generalShelf.hasMatch(t)) {
    return _quality.hasMatch(t) ? 3 : 2;
  }
  if (t == 'featured' ||
      t.contains('new release') ||
      t.contains('recently added')) {
    return 1;
  }
  if (t == 'streaming services') return 4;
  if (t == 'genres') return 5;
  if (t == 'kids & animation') return 6;
  if (t == 'documentaries') return 7;
  if (t == 'reality & shows') return 8;
  if (t == 'collections & studios') return 9;
  if (t == 'sports & events') return 10;
  if (t == 'music & concerts') return 11;
  if (t == 'international') return 80;
  if (_documentaries.hasMatch(t)) return 14;
  if (_kids.hasMatch(t)) return 16;
  if (_reality.hasMatch(t)) return 18;
  if (_quality.hasMatch(t)) return 20;
  if (t.contains('imdb') || t.startsWith('top ')) return 12;
  return 30;
}

const _genres = {
  'action',
  'adventure',
  'comedy',
  'crime',
  'drama',
  'fantasy',
  'horror',
  'romance',
  'science fiction',
  'sci-fi',
  'thriller',
  'western',
  'westerns',
  'war',
  'mystery',
  'musical',
  'musicals',
};
final _generalShelf = RegExp(
    r'^(?:all titles|movies|series|films?|serie|séries)(?:\s+(?:4k|uhd|fhd|hd|sd|hevc|dolby|audio|vision|hdr\S*|dv|blu-ray|\([^)]*\)))*$');
final _quality = RegExp(r'\b(?:4k|uhd|fhd|hevc|dolby|hdr\S*|dv|blu-ray)\b',
    caseSensitive: false);
final _documentaries = RegExp(
    r'\b(?:docu(?:mentaries|mentary)?|document\w*|doku\w*)\b',
    caseSensitive: false);
final _reality = RegExp(r'\b(?:reality|stand-up|podcasts?|tv shows?)\b',
    caseSensitive: false);
final _music = RegExp(r'\b(?:music|concerts?)\b', caseSensitive: false);
final _featured = RegExp(r'^(?:TOP\b|NEW RELEASE|LATEST\b|RECENT)|\bIMDB TOP\b',
    caseSensitive: false);
final _collections = RegExp(
    r'\b(?:JAMES BOND|MARVEL|UNIVERSAL|PARAMOUNT PICTURES|CHRISTIAN|BIBLICAL|COLLECTIONS?|CHRISTMAS)\b',
    caseSensitive: false);

final _regions = <(RegExp, String)>[
  (RegExp(r'^(?:EN\s*[-:|]\s*|ENGLISH\s+)', caseSensitive: false), 'English'),
  (
    RegExp(r'^(?:DE\s*[-:|]\s*|GERMANY\s+|GERMAN\s+)', caseSensitive: false),
    'German'
  ),
  (
    RegExp(r'^(?:FR\s*[-:|]\s*|FRANCE\s+|FRENCH\s+)', caseSensitive: false),
    'French'
  ),
  (
    RegExp(r'^(?:IT\s*[-:|]\s*|ITALY\s+|ITALIAN\s+)', caseSensitive: false),
    'Italian'
  ),
  (
    RegExp(r'^(?:ES\s*[-:|]\s*|ESPAÑA\s+|SPANISH\s+)', caseSensitive: false),
    'Spanish'
  ),
  (RegExp(r'^(?:NL\s*[-:|]\s*|NETHERLANDS\s+)', caseSensitive: false), 'Dutch'),
  (RegExp(r'^(?:BE\s*[-:|]\s*|BELGIUM\s+)', caseSensitive: false), 'Belgian'),
  (RegExp(r'^(?:QC\s*[-:|]\s*|QU[ÉE]BEC\s+)', caseSensitive: false), 'Québec'),
  (
    RegExp(r'^PT/BR\s*[-:|]?\s*', caseSensitive: false),
    'Portuguese & Brazilian'
  ),
  (RegExp(r'^BR\s*[-:|]\s*', caseSensitive: false), 'Brazilian'),
  (
    RegExp(r'^(?:LA\s*[-:|]\s*|LATINO\s+)', caseSensitive: false),
    'Latin American'
  ),
  (RegExp(r'^(?:PL\s*[-:|]\s*|POLSKA\s+)', caseSensitive: false), 'Polish'),
  (
    RegExp(r'^(?:GR\s*[-:|]\s*|GREECE\s+|GREEK\s+)', caseSensitive: false),
    'Greek'
  ),
  (RegExp(r'^(?:IL\s*[-:|]\s*|HEBREW\s+)', caseSensitive: false), 'Hebrew'),
  (
    RegExp(r'^(?:TR\s*[-:|]\s*|TURKISH\s+|TURKSIH\s+)', caseSensitive: false),
    'Turkish'
  ),
  (
    RegExp(r'^(?:IN\s*[-:|]\s*|INDIA[N]?\s+|HINDI\s+)', caseSensitive: false),
    'Indian'
  ),
  (
    RegExp(r'^(?:PK\s*[-:|]\s*|PAKISTAN\s+)', caseSensitive: false),
    'Pakistani'
  ),
  (RegExp(r'^BN\s*[-:|]\s*', caseSensitive: false), 'Bengali'),
  (
    RegExp(r'^(?:RU\s*[-:|]\s*|RUSSAIN\s+|RUSSIAN\s+)', caseSensitive: false),
    'Russian'
  ),
  (
    RegExp(r'^(?:BG\s*[-:|]\s*|BULGARIYA\s+)', caseSensitive: false),
    'Bulgarian'
  ),
  (RegExp(r'^(?:RO\s*[-:|]\s*|ROMANIAN\s+)', caseSensitive: false), 'Romanian'),
  (RegExp(r'^(?:AL\s*[-:|]\s*|ALBANIA\s+)', caseSensitive: false), 'Albanian'),
  (RegExp(r'^(?:MT\s*[-:|]\s*|MALTA\s+)', caseSensitive: false), 'Maltese'),
  (RegExp(r'^EX\s*[-:|]\s*', caseSensitive: false), 'Balkan'),
  (RegExp(r'^HUNGARY\s+', caseSensitive: false), 'Hungarian'),
  (RegExp(r'^(?:CN\s*[-:|]\s*|CHINA\s+)', caseSensitive: false), 'Chinese'),
  (RegExp(r'^JP\s*[-:|]\s*', caseSensitive: false), 'Japanese'),
  (
    RegExp(r'^(?:PH\s*[-:|]\s*|PHILIPPINES\s+)', caseSensitive: false),
    'Filipino'
  ),
  (RegExp(r'^(?:AF\s*[-:|]\s*|AFRICA\s+)', caseSensitive: false), 'African'),
  (RegExp(r'^SOUTH AFRICA\s+', caseSensitive: false), 'South African'),
  (RegExp(r'^(?:SO\s*[-:|]\s*|SOMALIA\s+)', caseSensitive: false), 'Somali'),
  (RegExp(r'^(?:IR\s*[-:|]\s*|PERSIAN\s+)', caseSensitive: false), 'Persian'),
  (RegExp(r'^(?:KU\s*[-:|]\s*|KURDISH\s+)', caseSensitive: false), 'Kurdish'),
  (RegExp(r'^NORDIC\s+', caseSensitive: false), 'Nordic'),
  (RegExp(r'^SVENSK[A]?\s+', caseSensitive: false), 'Swedish'),
  (RegExp(r'^DANSK[E]?\s+', caseSensitive: false), 'Danish'),
  (RegExp(r'^(?:NORGE|NORSK)\s+', caseSensitive: false), 'Norwegian'),
  (RegExp(r'^(?:SUOMEN|SUOMI)\s+', caseSensitive: false), 'Finnish'),
  (RegExp(r'^ÍSLANDS\s+', caseSensitive: false), 'Icelandic'),
];
// Require a service-name boundary so personal shelves such as "Appleton" or
// "Amazonia" are not silently treated as streaming services.
final _services = <(String, String)>[
  (r'NETFLIX', 'Netflix'),
  (
    r'AMAZON(?: PRIME)?|AMAZONE|PRIME VIDEO|PRIME(?=\s*(?:$|4K|UHD|⁴|²))',
    'Prime Video'
  ),
  (r'DISNEY\+?', 'Disney+'),
  (r'APPLE(?: TV)?\+?', 'Apple TV+'),
  (r'HBO MAX', 'HBO Max'),
  (r'PARAMOUNT\+', 'Paramount+'),
  (r'DISCOVERY\+', 'Discovery+'),
  (r'CRUNCHYROLL', 'Crunchyroll'),
  (r'VIAPLAY', 'Viaplay'),
  (r'JOYN', 'Joyn'),
  (r'SHOWTIME', 'Showtime'),
  (r'PEACOCK', 'Peacock'),
  (r'SKY\s*SHOWTIME', 'SkyShowtime'),
  (r'SKY(?=\s*$)', 'Sky'),
]
    .map((entry) => (
          RegExp('^(?:${entry.$1})' r'(?=\s|$|[-:|])\s*', caseSensitive: false),
          entry.$2,
        ))
    .toList(growable: false);
final _kids = RegExp(
    r'\b(kids?|children|family|animi|anime|animation|manga|dreamworks|nickelodeon)\b',
    caseSensitive: false);
final _sports = RegExp(
    r'\b(soccer|sports?|ufc|wwe|boxing|wrestling|workout|football|rugby|hockey|basketball|baseball|formula 1|afl|fifa)\b',
    caseSensitive: false);
final _arabic = RegExp(r'[\u0600-\u06ff]');
final _cataloguePrefix =
    RegExp(r'^(?:VOD|MOVIES|SERIES)\s*[|:]\s*', caseSensitive: false);
final _soccerPrefix = RegExp(r'^SOCCER\s+', caseSensitive: false);
final _serviceSeparator = RegExp(r'^[-:|]\s*');
final _resolution3840 = RegExp(r'\b3840P\b', caseSensitive: false);
final _whitespace = RegExp(r'\s+');
final _asia = RegExp(r'\bASIA\b', caseSensitive: false);
final _mena = RegExp(r'\bMENA\b', caseSensitive: false);

({List<String> path, String title}) _classify(String raw) {
  final title = raw.trim().replaceFirst(_cataloguePrefix, '');
  for (final region in _regions) {
    final match = region.$1.firstMatch(title);
    if (match == null) continue;
    final rest = title.substring(match.end).trim();
    return _regionalShelf(region.$2, rest.isEmpty ? title : rest);
  }
  // Arabic-script catalogues retain their exact readable titles. In particular,
  // do not infer that a subtitle/dubbed category is the original audio language.
  if (_arabic.hasMatch(title) ||
      title.startsWith('OSN+') ||
      title == 'UFC ARABIA') {
    final topic = RegExp(r'أطفال|اطفال|انمي|كرتون|كارتون|كيدز').hasMatch(title)
        ? 'Kids & animation'
        : RegExp(r'وثائق|وثائقي|ديسكفري|جيوغرافيك').hasMatch(title)
            ? 'Documentaries'
            : RegExp(r'رمضان').hasMatch(title)
                ? 'Ramadan'
                : RegExp(r'يعرض').hasMatch(title)
                    ? 'Currently airing'
                    : RegExp(r'أجنبي|اجنبي|أجنبه|أجنبيه|أجنبية|اجنبية')
                            .hasMatch(title)
                        ? 'International titles'
                        : RegExp(r'هند|اسيو|أسيو|آسيو|تركي|تركيه|ألماني|فرنسي')
                                .hasMatch(title)
                            ? 'World cinema & series'
                            : RegExp(r'برامج|بودكاست|مسرح|اغاني|أغاني|رياض|مباريات|مصارعة|UFC')
                                    .hasMatch(title)
                                ? 'Shows & events'
                                : 'Arabic titles';
    return (path: ['International', 'Arabic', topic], title: _clean(title));
  }
  // Provider-specific service shelves remain together instead of mixing their
  // languages/quality variants into an invented combined catalogue.
  final service = _serviceShelf(title);
  if (service != null) {
    return (
      path: [
        ..._serviceRegion(service.name, service.rest),
        'Streaming services',
        service.name
      ],
      title: _clean(service.rest.isEmpty ? 'All titles' : service.rest)
    );
  }
  if (title.startsWith('VIDEOLAND') && title.contains('(NL)')) {
    return (path: ['International', 'Dutch'], title: _clean(title));
  }
  if (title.startsWith('ASIA ')) {
    return (
      path: ['International', 'Asian · multi-subtitles'],
      title: _clean(title)
    );
  }
  final topic = _englishTopic(title);
  if (topic != null) {
    return (
      path: ['English', topic],
      title: _clean(_withoutSoccerPrefix(title))
    );
  }
  return (path: [], title: _clean(title));
}

String _withoutSoccerPrefix(String title) =>
    title.replaceFirst(_soccerPrefix, '');

String? _englishTopic(String title) {
  if (_kids.hasMatch(title)) return 'Kids & animation';
  if (_sports.hasMatch(title)) return 'Sports & events';
  if (_documentaries.hasMatch(title)) return 'Documentaries';
  if (_reality.hasMatch(title)) return 'Reality & shows';
  if (_music.hasMatch(title)) return 'Music & concerts';
  if (_collections.hasMatch(title)) return 'Collections & studios';
  if (_featured.hasMatch(title)) return 'Featured';
  return null;
}

({String name, String rest})? _serviceShelf(String title) {
  for (final service in _services) {
    final match = service.$1.firstMatch(title);
    if (match != null) {
      final rest =
          title.substring(match.end).trim().replaceFirst(_serviceSeparator, '');
      // Do not relabel a combined provider shelf as one exclusive service.
      if (rest.startsWith('&') || rest.startsWith('/')) return null;
      return (name: service.$2, rest: rest);
    }
  }
  return null;
}

({List<String> path, String title}) _regionalShelf(
    String region, String title) {
  final base = region == 'English' ? ['English'] : ['International', region];
  // The explicit outer language wins over service defaults (e.g. DE Netflix).
  final service = _serviceShelf(title);
  if (service != null) {
    return (
      path: [...base, 'Streaming services', service.name],
      title: _clean(service.rest.isEmpty ? 'All titles' : service.rest)
    );
  }
  final topic = region == 'English' ? _englishTopic(title) : null;
  return (
    path: [...base, if (topic != null) topic],
    title: _clean(region == 'English' ? _withoutSoccerPrefix(title) : title)
  );
}

// Explicit regional shelves stay outside English, even when the service name
// comes first. Unqualified mainstream service shelves follow the English browse.
List<String> _serviceRegion(String service, String rest) {
  if (_asia.hasMatch(rest)) {
    return ['International', 'Asian · multi-subtitles'];
  }
  if (_mena.hasMatch(rest)) {
    return ['International', 'Arabic'];
  }
  for (final region in _regions) {
    if (region.$1.hasMatch('$rest ')) {
      return region.$2 == 'English'
          ? ['English']
          : ['International', region.$2];
    }
  }
  if (service == 'Joyn') return ['International', 'German'];
  if (service == 'Crunchyroll' || rest.contains('(MULTI')) {
    return ['International', 'Multi-language'];
  }
  return ['English'];
}

String _clean(String title) {
  var result = title
      .replaceAll('⁴ᴷ', '4K')
      .replaceAll('³⁸⁴⁰ᴾ', '')
      .replaceAll(_resolution3840, '4K')
      .replaceAll('²¹⁶⁰ᵖ', '4K')
      .replaceAll('ᴰᴼᴸᴮʸ', 'Dolby')
      .replaceAll('ᴰᵒˡᵇʸ', 'Dolby')
      .replaceAll('ᴬᵁᴰᴵᴼ', 'Audio')
      .replaceAll('ⱽᶦˢᶦᵒⁿ', 'Vision')
      .replaceAll('ⱽᴵˢᴵÓᴺ', 'Vision')
      .replaceAll('ᴴᴰᴿ', 'HDR')
      .replaceAll('¹⁰', '10')
      .replaceAll(_whitespace, ' ')
      .trim();
  if (_arabic.hasMatch(result)) return result;
  const words = {
    '4k': '4K',
    '3d': '3D',
    'hdr': 'HDR',
    'hdr10/plus': 'HDR10+',
    'dv': 'DV',
    'hevc': 'HEVC',
    'imdb': 'IMDb',
    'ufc': 'UFC',
    'wwe': 'WWE',
    'afl': 'AFL',
    'f1': 'F1',
    'fifa+': 'FIFA+',
    'tv': 'TV',
    '(multi-subs)': '(multi-subs)',
    '(multi)': '(multi)',
    'animi': 'Anime',
    'docu-movies': 'Documentaries',
    'docu-series': 'Documentaries',
    'bluray': 'Blu-ray'
  };
  result = result
      .split(' ')
      .map((w) =>
          words[w.toLowerCase()] ??
          (w.length < 2
              ? w
              : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}'))
      .join(' ');
  return result.isEmpty ? title : result;
}
