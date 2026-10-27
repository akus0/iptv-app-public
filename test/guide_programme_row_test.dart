import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/epg_service.dart';
import 'package:nox_iptv/services/storage_service.dart';
import 'package:nox_iptv/widgets/guide_programme_row.dart';

class _Guide extends EpgService {
  _Guide() : super(StorageService());
  final rows = <String, List<EpgProgram>>{};
  final reads = <String, int>{};
  @override
  List<EpgProgram> getPrograms(String id) {
    reads.update(id, (n) => n + 1, ifAbsent: () => 1);
    return rows[id] ?? const [];
  }

  void publish(String id, String title) {
    rows[id] = [
      EpgProgram(
          channelId: id,
          title: title,
          start: DateTime(2026),
          stop: DateTime(2027))
    ];
    lastLoadedGuideChannelIds = {id};
    guideRowsLoaded.value++;
  }
}

void main() {
  testWidgets('fast browsing uses cached rows and loads only on landing',
      (tester) async {
    final epg = _Guide();
    final fast = ValueNotifier(true);
    Widget app(String id) => MaterialApp(
        home: GuideProgrammeRow(
            epg: epg,
            channelId: id,
            isActive: () => true,
            fastBrowsing: fast,
            builder: (rows) =>
                Text(rows.firstOrNull?.title ?? 'No cached programme')));
    await tester.pumpWidget(app('a'));
    expect(epg.reads, isEmpty);
    epg.publish('a', 'Arrived while scrolling');
    await tester.pump();
    expect(epg.reads, isEmpty);
    await tester.pumpWidget(app('b'));
    expect(epg.reads, isEmpty);
    epg.publish('b', 'Landing programme');
    fast.value = false;
    await tester.pump();
    expect(epg.reads, {'b': 1});
    expect(find.text('Landing programme'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fast.dispose();
    epg.dispose();
  });

  testWidgets('unchanged guide rows reuse children without hiding real updates',
      (tester) async {
    final epg = _Guide();
    var renderKey = 0;
    var active = true;
    var builds = 0;
    Widget app() => MaterialApp(
            home: GuideProgrammeRow(
          epg: epg,
          channelId: 'a',
          isActive: () => active,
          renderKey: renderKey,
          builder: (rows) {
            builds++;
            return Text('${rows.firstOrNull?.title ?? 'empty'}:$renderKey');
          },
        ));
    await tester.pumpWidget(app());
    for (var i = 0; i < 10; i++) {
      await tester.pumpWidget(app());
    }
    expect(builds, 1);
    epg.publish('a', 'Current');
    await tester.pump();
    expect(builds, 2);
    expect(find.text('Current:0'), findsOneWidget);
    renderKey++;
    await tester.pumpWidget(app());
    expect(builds, 3);
    expect(find.text('Current:1'), findsOneWidget);
    active = false;
    epg.publish('a', 'Updated while away');
    await tester.pump();
    expect(builds, 3);
    active = true;
    await tester.pumpWidget(app());
    expect(builds, 4);
    expect(find.text('Updated while away:1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    epg.dispose();
  });

  testWidgets('guide batch rebuilds only its channel and defers hidden rows',
      (tester) async {
    final epg = _Guide();
    var active = true;
    final builds = <String, int>{};
    Widget app() => MaterialApp(
            home: Column(children: [
          for (final id in ['a', 'b', 'section'])
            GuideProgrammeRow(
                key: ValueKey(id),
                epg: epg,
                channelId: ' ${id.toUpperCase()} ',
                enabled: id != 'section',
                isActive: () => active,
                builder: (rows) {
                  builds.update(id, (n) => n + 1, ifAbsent: () => 1);
                  return Text(rows.firstOrNull?.title ?? id);
                }),
        ]));
    await tester.pumpWidget(app());
    epg.publish('a', 'New programme');
    await tester.pump();
    expect(builds, {'a': 2, 'b': 1, 'section': 1});
    expect(epg.reads, {'a': 2, 'b': 1});
    active = false;
    epg.publish('a', 'Hidden update');
    await tester.pump();
    expect(find.text('New programme'), findsOneWidget);
    expect(epg.reads['a'], 2);
    active = true;
    await tester.pumpWidget(app());
    expect(find.text('Hidden update'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    epg.dispose();
  });
}
