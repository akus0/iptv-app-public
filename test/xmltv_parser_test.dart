import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/services/epg_database.dart';
import 'package:nox_iptv/services/xmltv_parser.dart';
import 'package:nox_iptv/utils/thai_epg.dart';

final _now = DateTime.utc(2026, 10, 31, 12);
String _programme(String body,
        {String id = 'ABC', String? start, String? stop}) =>
    '<programme channel="$id" start="${start ?? '20261031110000 +0000'}" '
    'stop="${stop ?? '20261031130000 +0000'}">$body</programme>';

void main() {
  test(
      'full display names survive CDATA and comments without matching a prefix',
      () async {
    final rows = <EpgRow>[];
    final xml =
        '<tv><channel id="bbc"><display-name>BBC <![CDATA[World]]><!-- split --> HD</display-name><display-name>BBC</display-name></channel>'
        '<channel id="cnn"><display-name><![CDATA[CNN HD]]></display-name></channel>'
        '${_programme('<title>BBC programme</title>', id: 'bbc')}'
        '${_programme('<title>CNN programme</title>', id: 'cnn')}</tv>';
    final result = await parseXmltvInBackground(
        Stream.fromIterable(utf8.encode(xml).map((byte) => [byte])),
        knownChannelIds: {},
        knownChannelNames: {'bbc', 'cnn hd'},
        noTitle: 'Untitled',
        now: _now,
        onRows: (batch) async => rows.addAll(batch));
    expect(result.channelNames, {'bbc': 'BBC World HD', 'cnn': 'CNN HD'});
    expect(result.nameMatches, {'cnn hd': 'cnn'});
    expect(rows.single.channelId, 'cnn');
  });

  test(
      'custom names retain only exact qualified identities and reject ambiguity',
      () async {
    final rows = <EpgRow>[];
    final result = await parseXmltvInBackground(
        Stream.value(utf8.encode('<tv>'
            '<channel id="different"><display-name> AU  Sports HD </display-name></channel>'
            '<channel id="region"><display-name>UK Sports HD</display-name></channel>'
            '<channel id="quality"><display-name>AU Sports SD</display-name></channel>'
            '<channel id="a"><display-name>Sports Mix</display-name></channel>'
            '<channel id="b"><display-name>Sports Mix</display-name></channel>'
            '<channel id="same"><display-name>Repeat</display-name></channel>'
            '<channel id="same"><display-name>Repeat</display-name></channel>'
            '${_programme('<title>Named</title>', id: 'different')}'
            '${_programme('<title>Region</title>', id: 'region')}'
            '${_programme('<title>Quality</title>', id: 'quality')}'
            '${_programme('<title>Ambiguous A</title>', id: 'a')}'
            '${_programme('<title>Ambiguous B</title>', id: 'b')}'
            '${_programme('<title>Repeated directory</title>', id: 'same')}'
            '${_programme('<title>Explicit ID</title>', id: 'explicit')}'
            '</tv>')),
        namespace: 'custom:',
        knownChannelIds: {'custom:explicit'},
        knownChannelNames: {'au sports hd', 'sports mix', 'repeat'},
        noTitle: 'Untitled',
        now: _now,
        onRows: (batch) async => rows.addAll(batch));
    expect(rows.map((r) => r.channelId),
        ['custom:different', 'custom:same', 'custom:explicit']);
    expect(result.nameMatches,
        {'au sports hd': 'custom:different', 'repeat': 'custom:same'});
  });

  test('late duplicate names cannot publish an automatic name assignment',
      () async {
    final result = await parseXmltvInBackground(
        Stream.value(utf8.encode('<tv>'
            '<channel id="a"><display-name>Sports Mix</display-name></channel>'
            '${_programme('<title>First feed</title>', id: 'a')}'
            '<channel id="b"><display-name>Sports Mix</display-name></channel>'
            '${_programme('<title>Second feed</title>', id: 'b')}'
            '</tv>')),
        knownChannelIds: {},
        knownChannelNames: {'sports mix'},
        noTitle: 'Untitled',
        now: _now,
        onRows: (_) async {});
    expect(result.nameMatches, isEmpty);
  });

  test('ordinary imports remain ID-only even with matching directory names',
      () async {
    final rows = <EpgRow>[];
    final result = await parseXmltvInBackground(
        Stream.value(utf8.encode('<tv>'
            '<channel id="other"><display-name>ABC</display-name></channel>'
            '${_programme('<title>Different ID</title>', id: 'other')}'
            '</tv>')),
        knownChannelIds: {'abc'},
        noTitle: 'Untitled',
        now: _now,
        onRows: (batch) async => rows.addAll(batch));
    expect(rows, isEmpty);
    expect(result.nameMatches, isEmpty);
  });

  for (final compressed in [false, true]) {
    test(
        'streamed ${compressed ? 'gzip' : 'plain'} XML preserves guide evidence',
        () async {
      final xml = '<tv><channel id=" ABC "><display-name>日本 스포츠</display-name>'
          '<display-name>Other name</display-name></channel>'
          '${_programme('<title>J1 日本 &amp; K리그</title><sub-title>Team A vs Team B</sub-title><desc>Live football</desc><live/>')}'
          '${_programme('<title>Other channel</title>', id: 'OTHER')}'
          '${_programme('<title>Invalid time</title>', start: 'bad')}'
          '${_programme('<title>Expired</title>', stop: '20261031100000 +0000')}'
          '${_programme('<title>Too far away</title>', start: '20261102000000 +0000', stop: '20261102020000 +0000')}'
          '<programme channel="abc" start="20261031140000 +0000" stop="20261031150000 +0000"/>'
          '</tv>';
      final bytes =
          compressed ? gzip.encode(utf8.encode(xml)) : utf8.encode(xml);
      final rows = <EpgRow>[];
      // Split both gzip magic bytes and multibyte UTF-8 characters.
      final result = await parseXmltvInBackground(
        Stream.fromIterable(bytes.map((b) => [b])),
        now: _now,
        noTitle: 'Untitled',
        knownChannelIds: {'abc'},
        onRows: (batch) async => rows.addAll(batch),
      );
      expect(result.stored, 2);
      expect(result.channelNames, {'abc': '日本 스포츠'});
      expect(result.nowPlaying.keys, containsAll(['abc', 'other']));
      expect(rows.first, (
        channelId: 'abc',
        startMs: _now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        stopMs: _now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        title: 'J1 日本 & K리그',
        description: 'Team A vs Team B\nLive football',
        isLive: true,
      ));
      expect(rows.last.title, 'Untitled');
    });
  }

  test(
      'namespace, English preference, subtitle deduplication and timezone survive worker boundary',
      () async {
    final rows = <EpgRow>[];
    await parseXmltvInBackground(
      Stream.value(utf8.encode('<tv>${_programme(
        '<title lang="th">ไทย</title><title lang="en">Match A vs B</title>'
        '<desc lang="th">ไทย</desc><desc lang="en">Details</desc><sub-title lang="en">A vs B</sub-title>',
        start: '20261031220000 +1100',
        stop: '20261031233000 +1030',
      )}</tv>')),
      namespace: thaiEpgPrefix,
      knownChannelIds: {'${thaiEpgPrefix}abc'},
      noTitle: 'Untitled',
      now: _now,
      onRows: (batch) async => rows.addAll(batch),
    );
    expect(rows.single.channelId, '${thaiEpgPrefix}abc');
    expect(rows.single.title, 'Match A vs B');
    expect(rows.single.description, 'Details');
    expect(rows.single.startMs,
        DateTime.utc(2026, 10, 31, 11).millisecondsSinceEpoch);
    expect(rows.single.stopMs,
        DateTime.utc(2026, 10, 31, 13).millisecondsSinceEpoch);
  });

  test('slow database applies backpressure to bounded batches and input',
      () async {
    final gate = Completer<void>();
    final firstBatch = Completer<void>();
    var consumed = 0, batches = 0;
    final row = _programme('<title>Live sport</title>');
    Stream<List<int>> input() async* {
      yield utf8.encode('<tv>');
      for (var i = 0; i < 6000; i++) {
        consumed++;
        yield utf8.encode(row);
      }
      yield utf8.encode('</tv>');
    }

    final parsing = parseXmltvInBackground(
      input(),
      noTitle: 'Untitled',
      now: _now,
      onRows: (rows) async {
        expect(rows.length, lessThanOrEqualTo(1000));
        if (++batches == 1) {
          firstBatch.complete();
          await gate.future;
        }
      },
    );
    await firstBatch.future;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(batches, 1);
    expect(consumed, lessThan(1500),
        reason:
            'Worker must not read the whole guide while a write is blocked');
    gate.complete();
    expect((await parsing).stored, 6000);
    expect(batches, 6);
  });

  test('network and database errors propagate and cancel the input', () async {
    final network = StateError('network failed');
    await expectLater(
        parseXmltvInBackground(Stream.error(network),
            noTitle: 'Untitled', onRows: (_) async {}),
        throwsA(same(network)));
    final cancelled = Completer<void>();
    final input = StreamController<List<int>>(onCancel: cancelled.complete);
    input.add(utf8.encode(
        '<tv>${List.filled(1001, _programme('<title>Sport</title>')).join()}</tv>'));
    final database = StateError('database failed');
    await expectLater(
        parseXmltvInBackground(input.stream,
            now: _now,
            noTitle: 'Untitled',
            onRows: (_) async => throw database),
        throwsA(same(database)));
    await cancelled.future;
    await input.close();
  });

  test('timeout stops the worker and cancels stalled network input', () async {
    final cancelled = Completer<void>();
    final input = StreamController<List<int>>(onCancel: cancelled.complete);
    await expectLater(
        parseXmltvInBackground(
          input.stream,
          noTitle: 'Untitled',
          timeout: const Duration(milliseconds: 100),
          onRows: (_) async {},
        ),
        throwsA(isA<TimeoutException>()));
    await cancelled.future;
    await input.close();
  });

  test(
      'invalid XML tokens and corrupt gzip fail without reporting a complete guide',
      () async {
    for (final bytes in [
      utf8.encode('<tv><&invalid'),
      [0x1f, 0x8b, 0, 1, 2]
    ]) {
      await expectLater(
          parseXmltvInBackground(Stream.value(bytes),
              noTitle: 'Untitled', onRows: (_) async {}),
          throwsA(isA<FormatException>()));
    }
  });

  test('empty input completes with empty catalogues', () async {
    final result = await parseXmltvInBackground(const Stream.empty(),
        noTitle: 'Untitled', onRows: (_) async {});
    expect(result.stored, 0);
    expect(result.channelNames, isEmpty);
    expect(result.nowPlaying, isEmpty);
  });
}
