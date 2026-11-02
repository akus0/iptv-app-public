import '../models/sports_channel_filters.dart';
import '../services/sports_channel_matcher.dart';
import 'provider_category.dart';

String channelSortLabel(SportsChannelSort sort) => switch (sort) {
      SportsChannelSort.suggested => 'Suggested order',
      SportsChannelSort.name => 'Channel A–Z',
      SportsChannelSort.region => 'Country / region',
      SportsChannelSort.playlist => 'Playlist',
    };

String channelEvidenceLabel(SportsChannelEvidence evidence) =>
    switch (evidence) {
      SportsChannelEvidence.all => 'All suggestions',
      SportsChannelEvidence.specific => 'Event-specific',
      SportsChannelEvidence.likely => 'Likely or better',
    };

bool channelPassesQuickFilters(
    ChannelSearchResult row, SportsChannelFilters filter, Set<String> tried) {
  if (filter.untriedOnly && tried.contains(row.channel.id)) return false;
  if (filter.playlist != null && row.channel.playlistId != filter.playlist) {
    return false;
  }
  final reason = row.match?.reason;
  final specific = reason == MatchReason.guide || reason == MatchReason.name;
  return switch (filter.evidence) {
    SportsChannelEvidence.all => true,
    SportsChannelEvidence.specific => specific,
    SportsChannelEvidence.likely => specific ||
        reason == MatchReason.network ||
        reason == MatchReason.listing,
  };
}

/// Metadata is parsed only when sorting/filtering is requested, never on focus
/// changes. Slices and cancellation keep large related-channel lists responsive.
class SportsChannelBrowser {
  final _facts = <(String, String), ({String name, String? region})>{};
  final _categories = <String, String?>{};
  ({String name, String? region}) facts(ChannelSearchResult row) {
    final channel = row.channel;
    final key = (channel.name, channel.group);
    final cached = _facts[key];
    if (cached != null) return cached;
    final name = parseProviderCategory(channel.name, removeFormatLabels: false);
    final category = _categories.putIfAbsent(
        channel.group, () => parseProviderCategory(channel.group).region);
    final region =
        name.region != null && category != null && name.region != category
            ? null
            : name.region ?? category;
    final result = (name: channel.name.toLowerCase(), region: region);
    if (_facts.length >= 8192) _facts.clear();
    if (_categories.length >= 4096) _categories.clear();
    _facts[key] = result;
    return result;
  }

  Future<({List<String> regions, List<String> playlists})> choices(
      List<ChannelSearchResult> rows,
      {required bool Function() cancelled}) async {
    final regions = <String>{}, playlists = <String>{};
    final slice = Stopwatch()..start();
    for (var i = 0; i < rows.length; i++) {
      if (cancelled()) return (regions: <String>[], playlists: <String>[]);
      regions.add(facts(rows[i]).region ?? '?');
      playlists.add(rows[i].channel.playlistId);
      if (i % 32 == 0 && slice.elapsedMilliseconds >= 2) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    return (
      regions: regions.toList()
        ..sort((a, b) => regionLabel(a).compareTo(regionLabel(b))),
      playlists: playlists.toList()
    );
  }

  static String regionLabel(String code) =>
      providerRegionNames[code] ?? 'Unspecified';

  Future<List<ChannelSearchResult>> apply(
      List<ChannelSearchResult> rows,
      SportsChannelFilters filter,
      Set<String> tried,
      Map<String, String> playlists,
      {required bool Function() cancelled}) async {
    if (filter.isDefault) return rows;
    final result = <ChannelSearchResult>[];
    final keys = <String, (String, String)>{};
    final slice = Stopwatch()..start();
    for (var i = 0; i < rows.length; i++) {
      if (cancelled()) return const [];
      final row = rows[i];
      if (channelPassesQuickFilters(row, filter, tried)) {
        final needsFacts = filter.region != null ||
            filter.sort == SportsChannelSort.region ||
            filter.sort == SportsChannelSort.name;
        final fact = needsFacts ? facts(row) : null;
        if (filter.region == null || (fact?.region ?? '?') == filter.region) {
          result.add(row);
          if (filter.sort != SportsChannelSort.suggested) {
            final primary = switch (filter.sort) {
              SportsChannelSort.name => fact!.name,
              SportsChannelSort.region => fact!.region == null
                  ? '\uffff'
                  : regionLabel(fact.region!).toLowerCase(),
              SportsChannelSort.playlist =>
                (playlists[row.channel.playlistId] ?? row.channel.playlistId)
                    .toLowerCase(),
              SportsChannelSort.suggested => '',
            };
            keys[row.channel.id] = (primary, row.channel.name.toLowerCase());
          }
        }
      }
      if (i % 32 == 0 && slice.elapsedMilliseconds >= 2) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
    }
    if (filter.sort == SportsChannelSort.suggested) return result;
    // Bottom-up merge sort yields even when all names share long prefixes.
    var input = result, output = List<ChannelSearchResult>.of(result);
    int compare(ChannelSearchResult a, ChannelSearchResult b) {
      final ka = keys[a.channel.id]!, kb = keys[b.channel.id]!;
      final group = ka.$1.compareTo(kb.$1);
      return group != 0 ? group : ka.$2.compareTo(kb.$2);
    }

    for (var width = 1; width < input.length; width *= 2) {
      for (var start = 0; start < input.length; start += width * 2) {
        final middle = (start + width).clamp(0, input.length),
            end = (start + width * 2).clamp(0, input.length);
        var a = start, b = middle;
        for (var at = start; at < end; at++) {
          output[at] =
              a < middle && (b >= end || compare(input[a], input[b]) <= 0)
                  ? input[a++]
                  : input[b++];
          if (at % 64 == 0 && slice.elapsedMilliseconds >= 2) {
            await Future<void>.delayed(Duration.zero);
            slice.reset();
            if (cancelled()) return const [];
          }
        }
      }
      final swap = input;
      input = output;
      output = swap;
    }
    return input;
  }
}
