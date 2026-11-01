import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/widgets/cached_channel_logo.dart';

class _Cache extends Fake implements BaseCacheManager {
  final files = <String, FileInfo>{};
  int reads = 0, otherCalls = 0;
  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    reads++;
    return files[key];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    otherCalls++;
    throw StateError('Only read-only cache lookups are allowed');
  }
}

void main() {
  test('reused logos and misses share a lookup without any download method',
      () async {
    final manager = _Cache();
    final file = MemoryFileSystem().file('/logo.png')..writeAsBytesSync([1, 2]);
    manager.files['logo'] = FileInfo(file, FileSource.Cache,
        DateTime.now().add(const Duration(days: 1)), 'logo');
    final cache = ChannelLogoCache(manager: manager);
    final first = cache.find('logo');
    expect(identical(first, cache.find('logo')), true);
    expect(await first, file);
    expect(await cache.find('missing'), isNull);
    expect(await cache.find('missing'), isNull);
    expect(manager.reads, 2);
    expect(manager.otherCalls, 0);
  });

  test('lookup storage stays bounded and oversized artwork is not decoded',
      () async {
    final manager = _Cache();
    final cache = ChannelLogoCache(manager: manager);
    for (var i = 0; i <= ChannelLogoCache.maxEntries; i++) {
      await cache.find('logo-$i');
    }
    final reads = manager.reads;
    await cache.find('logo-0');
    expect(manager.reads, reads + 1);
    final file = MemoryFileSystem().file('/huge.png')
      ..writeAsBytesSync(List.filled(ChannelLogoCache.maxFileBytes + 1, 0));
    manager.files['huge'] = FileInfo(file, FileSource.Cache,
        DateTime.now().add(const Duration(days: 1)), 'huge');
    expect(await cache.find('huge'), isNull);
    expect(manager.otherCalls, 0);
  });

  testWidgets('cached artwork uses bounded still images; misses keep geometry',
      (tester) async {
    final manager = _Cache();
    final file = const LocalFileSystem().file('assets/icon/icon_flat.png');
    manager.files['logo'] = FileInfo(file, FileSource.Cache,
        DateTime.now().add(const Duration(days: 1)), 'logo');
    final cache = ChannelLogoCache(manager: manager);
    expect(await tester.runAsync(() => cache.find('logo')), isNotNull);
    Widget view(String url) => MaterialApp(
        home:
            Center(child: CachedChannelLogo(url: url, size: 28, cache: cache)));
    await tester.pumpWidget(view('logo'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    expect(provider.width, 64);
    expect(provider.height, 64);
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(
        TickerMode.valuesOf(tester.element(find.byType(Image))).enabled, false);
    expect(tester.getSize(find.byType(CachedChannelLogo)), const Size(28, 28));
    await tester.pumpWidget(view('missing'));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(CachedChannelLogo)), const Size(28, 28));
    expect(manager.otherCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
