import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/archive_models.dart';
import 'package:nox_iptv/screens/archive_playback.dart';
import 'package:nox_iptv/services/archive_service.dart';

const _a =
    ArchiveSource(manifestUrl: 'https://a.example/manifest.json', name: 'A');
const _b =
    ArchiveSource(manifestUrl: 'https://b.example/manifest.json', name: 'B');

ArchiveStreamOption _o(ArchiveSource s, String url, [String? name]) =>
    ArchiveStreamOption(source: s, stream: ArchiveStream(url: url, name: name));

void main() {
  group('next episode keeps to the picked stream', () {
    final picked = _o(_a, 'https://a/e1_1080.mp4', 'A 1080p');

    test('same source and same name wins', () {
      final next = [
        _o(_b, 'https://b/e2.mp4', 'A 1080p'),
        _o(_a, 'https://a/e2_4k.mkv', 'A 4K'),
        _o(_a, 'https://a/e2_1080.mp4', 'A 1080p'),
      ];
      expect(preferredArchiveStream(next, picked).stream.url,
          'https://a/e2_1080.mp4');
    });

    test('else the same source first, else the first of all', () {
      expect(
          preferredArchiveStream([
            _o(_b, 'https://b/e2.mp4'),
            _o(_a, 'https://a/e2_720.mp4', 'A 720p'),
          ], picked)
              .stream
              .url,
          'https://a/e2_720.mp4');
      expect(
          preferredArchiveStream([_o(_b, 'https://b/e2.mp4')], picked)
              .stream
              .url,
          'https://b/e2.mp4');
      expect(
          preferredArchiveStream([_o(_b, 'https://b/e2.mp4')], null).stream.url,
          'https://b/e2.mp4');
    });
  });

  test('full meta carries rating, cast and episode air dates', () {
    final m = ArchiveMeta.fromJson({
      'id': 'tt11126994',
      'type': 'series',
      'name': 'Arcane',
      'imdbRating': '9.0',
      'cast': ['Hailee Steinfeld', 'Ella Purnell'],
      'director': [],
      'runtime': '39 min',
      'videos': [
        {
          'id': 'tt11126994:1:1',
          'name': 'Welcome to the Playground',
          'season': 1,
          'episode': 1,
          'released': '2021-11-06T00:00:00.000Z',
          'thumbnail': 'https://img/e1.jpg',
        },
      ],
    })!;
    expect(m.rating, '9.0');
    expect(m.cast, ['Hailee Steinfeld', 'Ella Purnell']);
    expect(m.director, isEmpty);
    expect(m.videos.single.title, 'Welcome to the Playground');
    expect(m.videos.single.released, '2021-11-06T00:00:00.000Z');
    expect(m.videos.single.thumbnailUrl, 'https://img/e1.jpg');
  });

  test('episode placeholders share the id of the channel that plays', () {
    const v = ArchiveVideo(id: 'tt1:1:2', title: '', season: 1, episode: 2);
    expect(ArchiveService.channelId(_a, v.id, episode: true),
        ArchiveService.channelId(_a, 'tt1:1:2', episode: true));
    expect(ArchiveService.channelId(_a, v.id, episode: true),
        isNot(ArchiveService.channelId(_b, v.id, episode: true)));
  });
}
