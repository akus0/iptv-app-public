import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/sports.dart';
import 'package:nox_iptv/widgets/sports_widgets.dart';

class _LogoCache extends Fake implements BaseCacheManager {
  final available = <String>{};
  final requests = <String>[];
  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    requests.add(url);
    if (!available.contains(url)) throw StateError('Missing fixture logo');
    yield FileInfo(const LocalFileSystem().file('assets/icon/icon_flat.png'),
        FileSource.Cache, DateTime.now().add(const Duration(days: 1)), url);
  }
}

void main() {
  for (final darkAvailable in [true, false]) {
    testWidgets(
        'static logo keeps cache, decode bounds and fallback: dark=$darkAvailable',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cache = _LogoCache();
      CachedNetworkImageProvider.defaultCacheManager = cache;
      addTearDown(() {
        CachedNetworkImageProvider.defaultCacheManager = _LogoCache();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      });
      const url = 'https://a.espncdn.com/i/teamlogos/nhl/500/bos.png';
      final source = sportsLogoUrl(url, size: 64)!;
      final dark = sportsLogoUrl(sportsDarkLogoUrl(url), size: 64)!;
      cache.available.add(darkAvailable ? dark : source);
      Widget view(String? url) => MaterialApp(
          home: Center(
              child: SportsLogo(
                  url: url, size: 24, fallback: 'BOS', animate: false)));
      Future<void> flush() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
      }

      await tester.pumpWidget(view(url));
      await flush();
      expect(cache.requests, darkAvailable ? [dark] : [dark, source]);
      expect(find.byType(CachedNetworkImage), findsNothing);
      final decoded = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null)
          .single;
      expect(decoded.image!.width, 24);
      expect(tester.getSize(find.byType(SportsLogo)), const Size(24, 24));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(view(url));
      await flush();
      expect(
          cache.requests
              .where((u) => u == (darkAvailable ? dark : source))
              .length,
          1,
          reason: 'Remounting uses the existing decoded-image cache');
      await tester.pumpWidget(view('https://example.invalid/missing.png'));
      await flush();
      expect(find.text('BOS'), findsOneWidget);
      expect(tester.getSize(find.byType(SportsLogo)), const Size(24, 24));
      await tester.pumpWidget(view(null));
      expect(find.text('BOS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
