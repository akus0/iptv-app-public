import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/epg_service.dart';

bool isGuideSection(Channel channel) =>
    channel.name.trimLeft().startsWith('###');

String guideSectionTitle(Channel channel) {
  final title =
      channel.name.trim().replaceAll(RegExp(r'^#+\s*|\s*#+$'), '').trim();
  return title.isEmpty ? channel.name : title;
}

/// Searches only cached listings, with one lookup per unique EPG id. Large
/// subscriptions yield regularly so typing, scrolling and video stay responsive.
Future<List<Channel>> searchLiveGuide(List<Channel> channels, String query,
    EpgProgram? Function(String) currentProgram,
    {bool Function()? cancelled, DateTime? now}) async {
  final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
  if (terms.singleOrNull == '') return channels;
  final clock = now ?? DateTime.now();
  final titles = <String, String>{};
  final result = <Channel>[];
  final budget = Stopwatch()..start();
  for (var i = 0; i < channels.length; i++) {
    if (i % 64 == 0) {
      if (cancelled?.call() == true) return const [];
      if (budget.elapsedMilliseconds >= 4) {
        await Future<void>.delayed(Duration.zero);
        budget.reset();
      }
    }
    final channel = channels[i];
    final name = channel.name.toLowerCase();
    if (terms.every(name.contains)) {
      result.add(channel);
      continue;
    }
    if (isGuideSection(channel)) continue;
    final id = normalizeEpgId(channel.epgId);
    final programme = titles.putIfAbsent(id, () {
      final p = currentProgram(id);
      return p != null && p.isNowPlaying(clock)
          ? '${p.title} ${p.description ?? ''}'.toLowerCase()
          : '';
    });
    final text = '$name $programme';
    if (terms.every(text.contains)) result.add(channel);
  }
  return result;
}

/// Reuse only the last completed result when a query becomes more specific.
/// Retains channel references, not a second copy of programme text. Guide
/// changes, programme boundaries, broader queries and clock rollback invalidate
/// narrowing, so a newly airing show cannot disappear from search results.
class LiveGuideSearchSession {
  List<Channel>? _source;
  List<Channel> _matches = const [];
  List<String> _terms = const [];
  Object? _revision;
  DateTime? _clock, _expires;
  int _generation = 0;

  void clear() {
    _generation++;
    _source = null;
    _matches = const [];
    _terms = const [];
    _revision = null;
    _clock = _expires = null;
  }

  Future<List<Channel>> search(List<Channel> channels, String query,
      EpgProgram? Function(String) currentProgram,
      {required EpgProgram? Function(String) nextProgram,
      required Object Function() revision,
      bool Function()? cancelled,
      DateTime? now}) async {
    final generation = ++_generation;
    final clock = now ?? DateTime.now();
    final stamp = revision();
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
    final narrow = identical(_source, channels) &&
        _revision == stamp &&
        _clock != null &&
        !clock.isBefore(_clock!) &&
        (_expires == null || clock.isBefore(_expires!)) &&
        _terms.every((old) => terms.any((term) => term.contains(old)));
    DateTime? expires = narrow ? _expires : null;
    EpgProgram? read(String id) {
      final current = currentProgram(id);
      final boundary = current != null && current.isNowPlaying(clock)
          ? current.stop
          : nextProgram(id)?.start;
      if (boundary != null &&
          boundary.isAfter(clock) &&
          (expires == null || boundary.isBefore(expires!))) {
        expires = boundary;
      }
      return current;
    }

    bool obsolete() => generation != _generation || cancelled?.call() == true;
    final result = await searchLiveGuide(
        narrow ? _matches : channels, query, read,
        cancelled: obsolete, now: clock);
    if (!obsolete() && stamp == revision()) {
      _source = channels;
      _matches = result;
      _terms = terms;
      _revision = stamp;
      _clock = clock;
      _expires = expires;
    }
    return result;
  }
}
