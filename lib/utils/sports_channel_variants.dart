import '../services/sports_channel_matcher.dart';
import 'provider_category.dart';
import 'sports_programme_identity.dart';

final _quality = RegExp(
    r'\b(?:sd|hd|fhd|uhd|4k|8k|hdr|hevc|h[ .]?26[45]|(?:480|576|720|1080|2160)[pi](?:(?:24|25|30|50|60)(?:fps)?)?|(?:25|30|50|60)\s*fps)\b',
    caseSensitive: false);
final _separators = RegExp(r'[\s|:\[\](){}._\-]+');
String _name(String value) => value
    .toLowerCase()
    .replaceAll(_quality, ' ')
    .replaceAll(_separators, ' ')
    .trim();

class SportsChannelVariants {
  SportsChannelVariants(ChannelSearchResult first) : rows = [first];
  final List<ChannelSearchResult> rows;
}

/// Exact channel identities across a playlist's categories. Preserve country,
/// channel number, language and feed identity; never merge conflicting regions.
/// Conflicting programme evidence stays separate. Ranking is never changed.
List<SportsChannelVariants> groupSportsChannelVariants(
    List<ChannelSearchResult> rows) {
  final groups = _VariantGroups();
  for (final row in rows) {
    groups.add(row);
  }
  return groups.buckets.values.toList();
}

/// Broad suggestions can contain thousands of feeds. Yield in bounded slices
/// and discard obsolete searches instead of blocking a frame to group them.
Future<List<SportsChannelVariants>> groupSportsChannelVariantsAsync(
    List<ChannelSearchResult> rows,
    {required bool Function() cancelled}) async {
  final groups = _VariantGroups();
  final slice = Stopwatch()..start();
  for (var i = 0; i < rows.length; i++) {
    if (cancelled()) return const [];
    groups.add(rows[i]);
    if (i % 32 == 0 && slice.elapsedMilliseconds >= 2) {
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
  }
  return groups.buckets.values.toList();
}

class _VariantGroups {
  final buckets = <Object, SportsChannelVariants>{};
  final _byProgramme = <Object, SportsChannelVariants>{};
  final _unknown = <Object, SportsChannelVariants>{};
  final _first = <Object, SportsChannelVariants>{};
  final _categories = <String, ProviderCategory>{};
  final _names = <String, ProviderCategory>{};
  final _programmeTitles = <String, String>{};
  void add(ChannelSearchResult row) {
    final channel = row.channel;
    final baseName = channel.name.replaceAll(_quality, ' ').trim();
    final identity = _names.putIfAbsent(baseName, () {
      final parsed = parseProviderCategory(baseName, removeFormatLabels: false);
      return ProviderCategory(_name(parsed.name), parsed.region);
    });
    final category = _categories.putIfAbsent(
        channel.group, () => parseProviderCategory(channel.group));
    final name = identity.name;
    final region = identity.region ?? category.region;
    final conflict = identity.region != null &&
        category.region != null &&
        identity.region != category.region;
    final programme = row.programme ?? row.match?.programme;
    final identityKey = (
      channel.playlistId,
      conflict ? (identity.region, category.region) : region,
      name.isEmpty ? channel.id : name,
    );
    // Without a region, identical programme evidence can establish a family
    // across categories. Without that evidence, keep unknown feeds separate.
    final fallbackKey =
        region == null ? (identityKey, _name(channel.group)) : identityKey;
    final programmeKey = (
      identityKey,
      programme == null
          ? null
          : _programmeTitles.putIfAbsent(
              programme.title, () => sportsProgrammeTitleKey(programme.title)),
      programme?.start,
      programme?.stop,
    );
    // A saved choice often has no programme attached. Join it to its channel
    // family rather than creating another top-level copy. Known conflicting
    // schedules still get separate groups, with every original row retained.
    final existing = programme == null
        ? _first[fallbackKey]
        : _byProgramme[programmeKey] ?? _unknown.remove(fallbackKey);
    if (existing != null) {
      existing.rows.add(row);
      _first.putIfAbsent(fallbackKey, () => existing);
      if (programme != null) _byProgramme[programmeKey] = existing;
    } else {
      final group = SportsChannelVariants(row);
      buckets[buckets.length] = group;
      _first.putIfAbsent(fallbackKey, () => group);
      if (programme == null) {
        _unknown[fallbackKey] = group;
      } else {
        _byProgramme[programmeKey] = group;
      }
    }
  }
}
