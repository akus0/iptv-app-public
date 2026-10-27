import '../models/m3u_group.dart';
import '../models/channel.dart';
import 'provider_category.dart';

/// A virtual category. Source channel objects and persisted category names stay
/// untouched; channel selection is resolved only when this category is opened.
class LiveCategoryCollection extends M3uGroup {
  LiveCategoryCollection(
      this.displayName, String playlistId, List<M3uGroup> sources, this.path,
      {Set<String> additionalSourceTitles = const {},
      this.providerOrganised = false})
      : sources = List.unmodifiable(sources),
        additionalSourceTitles = Set.unmodifiable(additionalSourceTitles),
        sourceTitles = Set.unmodifiable(sources.map((g) => g.title)),
        super(
            title: '__live_collection__:$displayName',
            playlistId: playlistId,
            channels: const []);
  final String displayName;
  final bool providerOrganised;
  final List<M3uGroup> sources;
  final Set<String> sourceTitles;
  final List<String> path;
  final Set<String> additionalSourceTitles;

  bool contains(Channel channel) =>
      channel.playlistId == playlistId &&
      (sourceTitles.contains(channel.group) ||
          (_dedicatedChannels.containsKey(displayName) &&
              sources.isNotEmpty &&
              additionalSourceTitles.contains(channel.group) &&
              !channel.name.trimLeft().startsWith('###') &&
              _isDedicated(channel.name)));

  bool _isDedicated(String name) =>
      !(displayName == 'Tennis' && _tableTennis.hasMatch(name)) &&
      (_dedicatedChannels[displayName]?.hasMatch(name) ?? false);

  // Feed alternatives can share an EPG ID: never deduplicate by that ID or name.
  List<Channel> select(Iterable<Channel> visibleChannels) {
    final seen = <(String, String, String)>{};
    final main = <Channel>[];
    final feeds = <Channel>[];
    for (final channel in visibleChannels) {
      if (!contains(channel) ||
          !seen.add((channel.playlistId, channel.id, channel.url))) {
        continue;
      }
      // Stable partitions, not a sort of the catalogue. Event feeds keep their
      // provider order and section headers; dedicated networks come first.
      final dedicated =
          displayName != 'Formula 1' && _isDedicated(channel.name);
      (dedicated ? main : feeds).add(channel);
    }
    final selected = [...main, ...feeds];
    if (!providerOrganised) return selected;
    final sectioned = <Channel>[];
    String? previous;
    for (final channel in selected) {
      if (channel.group != previous &&
          !channel.name.trimLeft().startsWith('###')) {
        sectioned.add(Channel(
          id: '__iptv_section__:$playlistId:${sectioned.length}:${channel.group}',
          rawId: '__iptv_section__:${sectioned.length}:${channel.group}',
          name: '### ${liveCategoryLabel(channel.group, inFolder: true)}',
          group: channel.group,
          playlistId: playlistId,
          url: '',
        ));
      }
      sectioned.add(channel);
      previous = channel.group;
    }
    return sectioned;
  }
}

LiveCategoryCollection? liveCollectionForSource(
    List<M3uGroup> groups, String playlistId, String title,
    {String layout = 'auto'}) {
  final raw = layout == 'organised' &&
      groups
              .where(
                  (g) => g.playlistId == playlistId && _guide.hasMatch(g.title))
              .length <
          2;
  final spec = raw ? _providerCollection(title) : _collection(title);
  if (layout == 'provider' ||
      spec == null ||
      (layout != 'organised' &&
          groups
                  .where((g) =>
                      g.playlistId == playlistId && _guide.hasMatch(g.title))
                  .length <
              2)) {
    return null;
  }
  return refreshLiveCategoryCollection(
      LiveCategoryCollection(spec.$1, playlistId, const [], spec.$2,
          providerOrganised: raw),
      groups);
}

LiveCategoryCollection refreshLiveCategoryCollection(
    LiveCategoryCollection selected, Iterable<M3uGroup> groups) {
  return LiveCategoryCollection(
      selected.displayName,
      selected.playlistId,
      [
        for (final group in groups)
          if (!group.isHidden &&
              group.playlistId == selected.playlistId &&
              (selected.providerOrganised
                          ? _providerCollection(group.title)
                          : _collection(group.title))
                      ?.$1 ==
                  selected.displayName)
            group
      ],
      selected.path,
      providerOrganised: selected.providerOrganised,
      additionalSourceTitles: _additionalSources(
          selected.displayName, selected.playlistId, groups));
}

// Category metadata only. The name filter runs once on category selection, never
// while rendering the tree; hidden groups and other playlists stay excluded.
Set<String> _additionalSources(
        String name, String playlistId, Iterable<M3uGroup> groups) =>
    !_dedicatedChannels.containsKey(name)
        ? const {}
        : {
            for (final g in groups)
              if (!g.isHidden &&
                  g.playlistId == playlistId &&
                  _collection(g.title)?.$1 != name &&
                  !isLivePlaylistInformation(g.title))
                g.title
          };

/// A presentation-only tree: original category objects and channel lists stay intact.
class LiveCategoryNode {
  LiveCategoryNode.folder(this.key, this.label, this.playlistId) : group = null;
  LiveCategoryNode.leaf(M3uGroup value)
      : key = '${value.playlistId}::${value.title}',
        label =
            value is LiveCategoryCollection ? value.displayName : value.title,
        playlistId = value.playlistId,
        group = value;
  final String key;
  final String label;
  final String playlistId;
  final M3uGroup? group;
  final List<LiveCategoryNode> children = [];
  int count = 0;
}

final _prefix = RegExp(r'^(uk|ca|au|nz|ie)\s*\|\s*');
final _displayPrefix =
    RegExp(r'^(UK|CA|AU|NZ|IE)\s*\|\s*', caseSensitive: false);
final _symbols = RegExp(r'^[^a-zA-Z0-9]+');
final _motorsport = RegExp(r'formula|dirtvision|rally|mxgp|tt races');
final _football = RegExp(
    r'football|premier|championship|league one|league two|national league|scottish|spfl|uefa|cymru|fa player|la liga|ligue 1|serie a|soccer|vidio epl|\bmls\b|fifa');
final _sportsNetworks = RegExp(
    r'sky sports?|tnt sports?|^sports\b|sport networks|rogers super|tsn|sportsnet');
final _basketball = RegExp(r'\b(w?nba)\b');
final _baseball = RegExp(r'\b(milb|mlb)\b');
final _americanFootball = RegExp(r'\b(nfl|cfl)\b');
final _hockey = RegExp(r'\b(nhl|whl)\b');
final _leagues = RegExp(
    r'\bnfl\b|\bnba\b|\bwnba\b|\bmlb\b|\bmilb\b|\bnhl\b|college|high school|btn\+');
final _entertainment =
    RegExp(r'entertainment|kids|movie networks|music|news|westerns');
final _streaming = RegExp(
    r'directv|prime channels|roku channels|sling tv|tubi channels|peacock channels');
final _services = RegExp(r'espn\+|flo sports|^flo\b|dazn|b/r max');
final _guide = RegExp(r'tv guide \(([^)]+)\)', caseSensitive: false);

/// Resolve old installations to the equivalent explicit presentation choice.
/// This only inspects category metadata, never channel lists or streams.
String resolveLiveCategoryLayout(String layout, Iterable<M3uGroup> groups) {
  if (layout == 'organised' || layout == 'provider') return layout;
  return groups.where((g) => _guide.hasMatch(g.title)).take(2).length == 2
      ? 'organised'
      : 'provider';
}

final _formulaOne =
    RegExp(r'\b(?:f\s*1|formula\s*(?:1|one))\b', caseSensitive: false);
final _tableTennis = RegExp(r'\btable\s+tennis\b', caseSensitive: false);
final _dedicatedChannels = <String, RegExp>{
  'Formula 1': _formulaOne,
  for (final entry in const {
    'Tennis':
        r'\b(?:sky sports? tennis|tennis channel|t2 tennis|super\s?sport tennis|tennis\s?tv|supertennis)\b|^tennis$',
    'Football channels':
        r'\b(?:sky sports? (?:football|premier league)|premier sports football|super\s?sport (?:football|premier league)|soccer tv)\b',
    'Golf':
        r'\b(?:sky sports? golf|golf channel|golfpass|liv golf|super\s?sport golf|canal\+? golf|nbc golf|v sports golf|sport klub golf|movistar golf)\b|^golf(?:\+|[ ᴿᴬᵂᴴᴰ]*)$',
    'Cricket':
        r'\b(?:sky sports? cricket|fox cricket|willow|astro cricket|atn cricket|sportsmax cricket|super\s?sport cricket)\b',
    'Rugby':
        r'\b(?:premier sports rugby|rugby\s?pass|rugby network|rugby tv|super\s?sport rugby|sky sports? rugby)\b',
    'Darts · PDC':
        r'\b(?:sky sports? darts|darts\s?tv|pdc\s?tv|dazn pdc darts|modus super series)\b',
    'Volleyball World': r'\b(?:volleyball world|volleyball\s?tv|volley\s?tv)\b',
    'Pool · Ultimate Pool':
        r'\b(?:ultimate pool|matchroom pool|billiard\s?tv)\b',
    'Horse racing':
        r'\b(?:sky sports? racing|racing tv|racing\.com|at the races|fan\s?duel racing|tvg)\b',
    'NBA League Pass': r'\bnba\s?tv\b',
    'NFL Sunday Ticket': r'\bnfl (?:network|red\s?zone)\b',
    'MLB.tv': r'\bmlb network\b',
    'NHL Center Ice': r'\bnhl network\b',
  }.entries)
    entry.key: RegExp(entry.value, caseSensitive: false),
};

String _normalized(String title) =>
    title.toLowerCase().trim().replaceFirst(_symbols, '');
bool isLivePlaylistInformation(String title) {
  final s = _normalized(title);
  return s == 'epgenius' || s.contains('release update') || s.contains('⬇');
}

// Merge only explicitly equivalent content, never all PPV or all sports feeds.
// Keeping this at category level avoids touching large channel lists on rebuild.
(String, List<String>)? _collection(String title) {
  final s = _normalized(title);
  if (_guide.hasMatch(s)) return null;
  final name = s.replaceFirst(_prefix, '');
  if (_formulaOne.hasMatch(name)) return ('Formula 1', const ['Sports']);
  if (name == 'football ᴳᴬᴺᴶᴬ'.toLowerCase() || name == 'football') {
    return ('Football channels', const ['Sports', 'Football']);
  }
  if (name == 'tennis') return ('Tennis', const ['Sports']);
  if (name == 'golf') return ('Golf', const ['Sports']);
  if (name == 'world cricket') return ('Cricket', const ['Sports']);
  if (name == 'world horse racing') return ('Horse racing', const ['Sports']);
  if (name == 'pdc board ppv') return ('Darts · PDC', const ['Sports']);
  if (name == 'volley ball world ppv') {
    return ('Volleyball World', const ['Sports']);
  }
  if (name == 'ultimate pool ppv') {
    return ('Pool · Ultimate Pool', const ['Sports']);
  }
  if (name == 'florugby ppv' || name == 'super league plus ppv') {
    return ('Rugby', const ['Sports']);
  }
  for (final (category, label, sport) in const [
    ('nba league pass', 'NBA League Pass', 'Basketball'),
    ('nfl sunday ticket', 'NFL Sunday Ticket', 'American football'),
    ('mlb.tv', 'MLB.tv', 'Baseball'),
    ('nhl center ice', 'NHL Center Ice', 'Ice hockey'),
  ]) {
    if (name == category) return (label, ['Sports', sport]);
  }
  if (name.startsWith('dazn')) {
    return ('DAZN', const ['Sports', 'Sports channels']);
  }
  if (name.startsWith('espn+')) {
    return ('ESPN+', const ['Sports', 'Sports channels']);
  }
  if (name.startsWith('flo sports') || name.startsWith('flo ⱽ'.toLowerCase())) {
    return ('Flo Sports', const ['Sports', 'Sports channels']);
  }
  if (name.startsWith('sky sport')) {
    return ('Sky Sports', const ['Sports', 'Sports channels']);
  }
  if (name.startsWith('tnt sport')) {
    return ('TNT Sports', const ['Sports', 'Sports channels']);
  }
  if (name.startsWith('ufc')) return ('UFC', const ['Sports']);
  if (name.startsWith('uefa')) return ('UEFA', const ['Sports', 'Football']);
  if (name.startsWith('epl ') ||
      name.startsWith('premier league+') ||
      name == 'vidio epl ppv' ||
      name == 'hub premier') {
    return ('Premier League', const ['Sports', 'Football']);
  }
  if (name.startsWith('ppv event')) {
    return ('PPV events', const ['Live events & PPV']);
  }
  if (name == 'hbo max ppv' || name == 'max ppv') {
    return ('HBO Max', const ['Live events & PPV']);
  }
  if (name == 'netflix ppv') {
    return ('Netflix events', const ['Live events & PPV']);
  }
  if (name == 'amazon prime ppv') {
    return ('Amazon Prime events', const ['Live events & PPV']);
  }
  if (s.startsWith('uk|') || !_prefix.hasMatch(s)) {
    if (name == 'kids' || name == 'kids channels') {
      return ('Kids', const ['Entertainment']);
    }
    if (name.startsWith('news')) return ('News', const ['Entertainment']);
    if (name.startsWith('music')) return ('Music', const ['Entertainment']);
    if (name.startsWith('entertainment')) {
      return ('Entertainment channels', const ['Entertainment']);
    }
    if (name == 'prime channels') {
      return ('Prime channels', const ['Entertainment']);
    }
  }
  return null;
}

// Raw provider categories become virtual guides. No channel IDs, URLs or
// original category strings are rewritten, so switching back is lossless.
final _ultraHdCategory = RegExp(r'^(?:4k|8k)(?:\b|\|)');
// Unrecognised provider tags remain separate, under World TV as before.
final _providerTag = RegExp(r'^[a-z]{2,5}\s*\|', caseSensitive: false);
(String, List<String>)? _providerCollection(String title) {
  if (_guide.hasMatch(title)) return null;
  final parsed = parseProviderCategory(title);
  final sport = providerSportCollection(parsed.name);
  if (sport != null) return sport;
  // Preserve the established branded collections on raw provider catalogues.
  final specific = _collection(title);
  if (specific != null) return specific;
  final region = providerRegionNames[parsed.region];
  if (region != null) {
    return (
      '$region guide',
      const {'us', 'uk', 'au', 'nz', 'ca', 'ie'}.contains(parsed.region)
          ? const []
          : const ['World TV']
    );
  }
  if (_ultraHdCategory.hasMatch(parsed.name)) {
    return ('4K & 8K channels', const ['Entertainment']);
  }
  return _collection(parsed.name);
}

List<String> liveCategoryPath(String title) {
  final s = _normalized(title);
  if (_guide.hasMatch(s) || isLivePlaylistInformation(title)) return const [];
  final collection = _collection(title);
  if (collection != null) return collection.$2;
  final region = _prefix.firstMatch(s)?.group(1);
  final name = s.replaceFirst(_prefix, '');
  if (name.contains('basketball') || _basketball.hasMatch(name)) {
    return const ['Sports', 'Basketball'];
  }
  if (_baseball.hasMatch(name)) return const ['Sports', 'Baseball'];
  if (_americanFootball.hasMatch(name) || name.contains('college football')) {
    return const ['Sports', 'American football'];
  }
  if (_hockey.hasMatch(name)) return const ['Sports', 'Ice hockey'];
  if (region == 'au') return const ['Australia'];
  if (region == 'nz') return const ['New Zealand'];
  if (region == 'ie') return const ['Ireland'];
  if (region == 'ca' || s.startsWith('canada')) {
    return [
      'Canada',
      name.contains('ppv') || _sportsNetworks.hasMatch(name)
          ? 'Sports & events'
          : 'TV & entertainment'
    ];
  }
  if (s.startsWith('world sports')) return const ['Sports', 'Sports channels'];
  if (s == 'world cricket' || s == 'world horse racing') {
    return const ['Sports'];
  }
  if (s == '4k channels') return const ['Entertainment'];
  if (s == '24/7 channels') return const [];
  if (s.contains('local affiliates') || s.contains('telemundo')) {
    return const ['US television', 'Local networks'];
  }
  if (_motorsport.hasMatch(name)) return const ['Sports', 'Motorsport'];
  if (_leagues.hasMatch(name)) return const ['Sports', 'College & school'];
  if (_football.hasMatch(name)) return const ['Sports', 'Football'];
  if (name.contains('rugby') || name.contains('super league')) {
    return const ['Sports', 'Rugby'];
  }
  if (name.contains('pdc board') ||
      name.contains('ultimate pool') ||
      name.contains('volley') ||
      name.contains('tennis') ||
      name.contains('golf') ||
      name.contains('triller')) {
    return const ['Sports'];
  }
  if (_services.hasMatch(name)) return const ['Sports', 'Sports channels'];
  if (_sportsNetworks.hasMatch(name)) {
    return const ['Sports', 'Sports channels'];
  }
  if (name.contains('ppv') || name == 'vidio' || name == 'vision+') {
    return const ['Live events & PPV'];
  }
  if (name.contains('series') || name.contains('netflix original')) {
    return const ['Entertainment', 'Series'];
  }
  if (name.contains('movie networks') ||
      name.contains('cine pro') ||
      name.contains('sky store')) {
    return const ['Entertainment', 'Movies'];
  }
  if (name.contains('docs') || name.contains('reality show')) {
    return const ['Entertainment', 'Documentaries & reality'];
  }
  if (_streaming.hasMatch(name) ||
      name.contains('sky channels') ||
      name.contains('bbc iplayer')) {
    return const ['Entertainment'];
  }
  if (_entertainment.hasMatch(name) || region == 'uk') {
    return const ['Entertainment'];
  }
  return const [];
}

String liveCategoryLabel(String title, {bool inFolder = false}) {
  final guide = _guide.firstMatch(title);
  if (guide != null) return '${guide.group(1)} guide';
  var label = title.replaceFirst(_symbols, '').replaceAll('ᴳᴬᴺᴶᴬ', '').trim();
  if (inFolder) {
    label = label.replaceFirst(_displayPrefix, '');
    final clean = label.replaceAll('ᴿᴬᵂ', '').replaceAll('ⱽᴵᴾ', '').trim();
    const names = {
      'SKY CHANNELS': 'Sky entertainment',
      'BBC IPLAYER': 'BBC live channels',
      'DIRECTV': 'DirecTV channels',
      'PEACOCK CHANNELS': 'Peacock channels',
      'ROKU CHANNELS': 'Roku channels',
      'SLING TV': 'Sling channels',
      'TUBI CHANNELS': 'Tubi channels',
      'WORLD CRICKET': 'Cricket',
      'WORLD HORSE RACING': 'Horse racing',
      'WORLD SPORTS ᴼᴺ ᴬᴵᴿ': 'World sports',
      'PDC BOARD PPV': 'Darts · PDC',
      'ULTIMATE POOL PPV': 'Pool · Ultimate Pool',
      'VOLLEY BALL WORLD PPV': 'Volleyball World',
      'MXGP PPV': 'Motocross · MXGP',
      'RALLY PPV': 'Rally',
      'TT RACES PPV': 'TT races',
      'FLORUGBY PPV': 'FloRugby',
      'SUPER LEAGUE PLUS PPV': 'Super League Rugby',
      'CHAMPIONSHIP PPV': 'Championship',
      'LEAGUE ONE PPV': 'League One',
      'LEAGUE TWO PPV': 'League Two',
      'NATIONAL LEAGUE PPV': 'National League',
      'SPFL/SCOTTISH PPV': 'Scottish Premiership',
      'SCOTTISH CUP PPV': 'Scottish Cup',
      'CYMRU FOOTBALL PPV': 'Cymru football',
      'FA PLAYER PPV': 'FA Player',
      'LA LIGA TEAM PPV': 'La Liga',
      'LIGUE 1 PPV': 'Ligue 1',
      'LIVE FOOTBALL PPV': 'Live football',
      'SERIE A TEAM PPV': 'Serie A',
      'SOCCER REPLAY': 'Football replays',
      'TRILLER TV PPV': 'Triller TV',
      'APPLE TV+ SERIES': 'Apple TV+ series',
      'BBC IPLAYER SERIES': 'BBC iPlayer series',
      'BBC STREAM PPV': 'BBC live events',
      'CINE PRO 4K': 'Cine Pro 4K',
      'NETFLIX ORIGINAL': 'Netflix originals',
      'PRIME VIDEO SERIES': 'Prime Video series',
      'REALITY SHOW TV': 'Reality TV',
      'SKY MIX DOCS': 'Sky documentaries',
      'SKY MIX SERIES': 'Sky series',
      'SKY STORE': 'Sky Store',
      'EU GAME PASS PPV': 'EU Game Pass',
      'MONO MAX PPV': 'Mono Max',
      'VIDIO': 'Vidio',
      'VISION+': 'Vision+',
    };
    label = names[clean.toUpperCase()] ?? clean;
  }
  return label.isEmpty ? title : label;
}

LiveCategoryNode _compactNode(LiveCategoryNode node) {
  if (node.group != null) return node;
  final children = node.children.map(_compactNode).toList();
  node.children
    ..clear()
    ..addAll(children);
  // Keep the meaningful outer label when only one subfolder remains.
  while (node.children.length == 1 && node.children.single.group == null) {
    final grandchildren = node.children.single.children.toList();
    node.children
      ..clear()
      ..addAll(grandchildren);
  }
  return node.children.length == 1 ? node.children.single : node;
}

const _categoryOrder = <String, List<String>>{
  'root': [
    'Sports',
    'Live events & PPV',
    'Entertainment',
    'US television',
    'Australia',
    'New Zealand',
    'Canada',
    'Ireland',
    '24/7 Channels'
  ],
  'Sports': [
    'Football',
    'Formula 1',
    'Sports channels',
    'Motorsport',
    'Rugby',
    'Tennis',
    'Golf',
    'Basketball',
    'American football',
    'Baseball',
    'Ice hockey',
    'College & school',
    'UFC',
    'Darts · PDC',
    'Volleyball World',
    'Pool · Ultimate Pool'
  ],
  'Football': [
    'Football channels',
    'Premier League',
    'UEFA',
    'La Liga',
    'Serie A',
    'Ligue 1',
    'Championship',
    'League One',
    'League Two',
    'National League',
    'Scottish Premiership',
    'Scottish Cup'
  ],
  'Sports channels': [
    'Sky Sports',
    'TNT Sports',
    'ESPN+',
    'DAZN',
    'Flo Sports'
  ],
  'Entertainment': [
    'Entertainment channels',
    'Movies',
    'Series',
    'Documentaries & reality',
    'Kids',
    'News',
    'Music',
    'Sky entertainment',
    'BBC live channels',
    'Prime channels',
    'Peacock channels',
    'DirecTV channels',
    'Roku channels',
    'Sling channels',
    'Tubi channels'
  ],
};

void _orderCategories(List<LiveCategoryNode> nodes, String parent) {
  final order = _categoryOrder[parent];
  if (order == null) return;
  // Stable partitions leave unrecognised/provider-specific entries in their order.
  final buckets = {for (final label in order) label: <LiveCategoryNode>[]};
  final remaining = <LiveCategoryNode>[];
  for (final node in nodes) {
    final label = node.group == null || node.group is LiveCategoryCollection
        ? node.label
        : liveCategoryLabel(node.label, inFolder: true);
    (buckets[label] ?? remaining).add(node);
  }
  nodes
    ..clear()
    ..addAll(buckets.values.expand((bucket) => bucket))
    ..addAll(remaining);
}

List<LiveCategoryNode> buildLiveCategoryTree(List<M3uGroup> groups,
    {Map<String, String> layouts = const {}}) {
  final byPlaylist = <String, List<M3uGroup>>{};
  for (final g in groups) {
    (byPlaylist[g.playlistId] ??= []).add(g);
  }
  final result = <LiveCategoryNode>[];
  for (final entry in byPlaylist.entries) {
    final curated =
        entry.value.where((g) => _guide.hasMatch(g.title)).length >= 2;
    final layout = layouts[entry.key] ?? 'auto';
    if (layout == 'provider' || (!curated && layout != 'organised')) {
      result.addAll(entry.value.map(LiveCategoryNode.leaf));
      continue;
    }
    final raw = !curated && layout == 'organised';
    final classifications = <String, (String, List<String>)?>{};
    (String, List<String>)? classify(String title) =>
        classifications.putIfAbsent(
            title, () => raw ? _providerCollection(title) : _collection(title));
    final folders = <String, LiveCategoryNode>{};
    final roots = <LiveCategoryNode>[];
    final buckets = <String, List<M3uGroup>>{};
    for (final g in entry.value) {
      final spec = classify(g.title);
      if (spec != null) (buckets[spec.$1] ??= []).add(g);
    }
    final emitted = <String>{};
    for (final source in entry.value) {
      if (isLivePlaylistInformation(source.title)) continue;
      final spec = classify(source.title);
      if (spec != null && !emitted.add(spec.$1)) continue;
      final M3uGroup g = spec == null
          ? source
          : LiveCategoryCollection(
              spec.$1, entry.key, buckets[spec.$1]!, spec.$2,
              providerOrganised: raw,
              additionalSourceTitles:
                  _additionalSources(spec.$1, entry.key, entry.value));
      var children = roots;
      var key = entry.key;
      for (final part in g is LiveCategoryCollection
          ? g.path
          : (raw
              ? (_providerTag.hasMatch(_normalized(g.title))
                  ? const ['World TV']
                  : const <String>[])
              : liveCategoryPath(g.title))) {
        key = '$key/$part';
        var folder = folders[key];
        if (folder == null) {
          folder = LiveCategoryNode.folder(key, part, entry.key);
          folders[key] = folder;
          children.add(folder);
        }
        folder.count++;
        children = folder.children;
      }
      children.add(LiveCategoryNode.leaf(g));
    }
    void order(LiveCategoryNode node) {
      _orderCategories(node.children, node.label);
      for (final child in node.children) {
        order(child);
      }
    }

    for (final root in roots) {
      order(root);
    }
    final compact = roots.map(_compactNode).toList();
    _orderCategories(compact, 'root');
    bool guide(LiveCategoryNode n) =>
        n.group != null &&
        (_guide.hasMatch(n.label) ||
            (raw &&
                n.group is LiveCategoryCollection &&
                n.label.endsWith(' guide')));
    result.addAll(compact.where(guide));
    result.addAll(compact.where((n) => !guide(n)));
  }
  return result;
}
