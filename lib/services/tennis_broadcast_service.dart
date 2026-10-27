import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/sports.dart';
import '../models/channel.dart';
import 'sports_channel_matcher.dart';
import 'sky_tennis_schedule_service.dart';

/// Optional first-party live listings. One shared page request serves every
/// live tennis match. Never opens playback links or sends playlist information.
class TennisBroadcastService {
  TennisBroadcastService(this.client, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now,
        _schedule = SkyTennisScheduleService(client, clock: clock);
  final SkyTennisScheduleService _schedule;
  bool _configured = false;
  void configureChannels(Iterable<Channel> channels) {
    _configured = true;
    _schedule.configureChannels(channels);
  }

  static final instance = TennisBroadcastService(http.Client())
    ..configureChannels(const []);
  static const source = 'Sky Sports live schedule';
  final http.Client client;
  final DateTime Function() clock;
  DateTime? _checked, _retryAt;
  List<TennisLiveListing> _rows = const [];
  Future<void>? _loading;

  bool _eligible(SportsGame g) =>
      g.league.kind == SportsKind.tennis &&
      g.state == GameState.live &&
      g.start.isBefore(clock().add(const Duration(minutes: 30))) &&
      g.start.isAfter(clock().subtract(const Duration(hours: 8)));

  List<SportsBroadcast> cachedFor(SportsGame game) {
    if (_configured) return _schedule.cachedFor(game);
    if (!_eligible(game) ||
        _checked == null ||
        clock().difference(_checked!) >= const Duration(minutes: 5)) {
      return [];
    }
    final names = <String>{};
    return [
      for (final row in _rows)
        if (SportsChannelMatcher.tennisListingFits(
                game, row.title, row.tournament) &&
            names.add(row.channel))
          SportsBroadcast(row.channel,
              source: source, country: 'United Kingdom', tournamentOnly: true),
    ];
  }

  Future<void> warm(List<SportsGame> games,
      {required bool Function() cancelled}) async {
    if (_configured) return _schedule.warm(games, cancelled: cancelled);
    if (cancelled() || !games.any(_eligible)) return;
    if (_loading != null) return _loading;
    if (_retryAt != null && clock().isBefore(_retryAt!)) return;
    _loading = () async {
      // Positive and empty results both share a five-minute minimum interval.
      _retryAt = clock().add(const Duration(minutes: 5));
      try {
        final response = await client
            .get(Uri.https('www.skysports.com', '/tennis/watch'))
            .timeout(const Duration(seconds: 4));
        if (cancelled()) return;
        final age = int.tryParse(response.headers['age'] ?? '0') ?? 0;
        if (response.statusCode != 200 ||
            age > 300 ||
            response.bodyBytes.length > 1024 * 1024) {
          throw const FormatException('Live listings unavailable');
        }
        _rows = await compute(parseTennisLiveListings, response.body);
        _checked = clock();
      } catch (_) {
        _rows = const [];
        _checked = null;
        _retryAt = clock().add(const Duration(minutes: 15));
      }
    }()
        .whenComplete(() {
      _loading = null;
    });
    await _loading;
  }
}

class TennisLiveListing {
  const TennisLiveListing(this.title, this.tournament, this.channel);
  final String title, tournament, channel;
}

/// Parse only the bounded live-event tiles, not news, video or rights articles.
/// Unknown markup fails closed. Sky Sports+ is a collection of streams: its
/// label cannot identify a numbered IPTV channel, so it is deliberately omitted.
List<TennisLiveListing> parseTennisLiveListings(String html) {
  final out = <TennisLiveListing>[];
  for (final match
      in RegExp(r'<article\b[^>]*>[\s\S]*?</article>', caseSensitive: false)
          .allMatches(html)
          .take(100)) {
    final tile = match[0]!;
    if (!tile.contains('data-sport="tennis"') ||
        !tile.contains('data-type="live"')) {
      continue;
    }
    final channel =
        RegExp(r'Showing on (Sky Sports [^<]+)<').firstMatch(tile)?[1]?.trim();
    if (!const {
      'Sky Sports Tennis',
      'Sky Sports Main Event',
      'Sky Sports Action',
      'Sky Sports Arena',
      'Sky Sports Mix'
    }.contains(channel)) {
      continue;
    }
    final title = RegExp(r'data-title="([^"]+)"').firstMatch(tile)?[1];
    if (title == null) continue;
    final slug =
        RegExp(r'href="/tennis/watch/\d+/([^"/]+)"').firstMatch(tile)?[1] ?? '';
    // These entities occur in the site's public data-title attributes.
    String decode(String s) => s
        .replaceAll('&amp;', '&')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ');
    out.add(
        TennisLiveListing(decode(title), slug.replaceAll('-', ' '), channel!));
  }
  return out;
}
