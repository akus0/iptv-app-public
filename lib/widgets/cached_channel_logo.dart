import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Read existing artwork only. Never call getSingleFile/getFileStream: a cache
/// miss must not turn browsing replays into more provider/network traffic.
class ChannelLogoCache {
  ChannelLogoCache({BaseCacheManager? manager})
      : _manager = manager ?? CachedNetworkImageProvider.defaultCacheManager;
  static final shared = ChannelLogoCache();
  final BaseCacheManager _manager;
  final _entries = <String, (DateTime, Future<File?>)>{};
  static const maxEntries = 128;
  static const maxFileBytes = 256 * 1024;

  Future<File?> find(String url) {
    final now = DateTime.now();
    final previous = _entries.remove(url);
    if (previous != null && now.difference(previous.$1).inMinutes < 5) {
      _entries[url] = previous;
      return previous.$2;
    }
    final result = _read(url);
    _entries[url] = (now, result);
    if (_entries.length > maxEntries) _entries.remove(_entries.keys.first);
    return result;
  }

  Future<File?> _read(String url) async {
    try {
      final hit = await _manager.getFileFromCache(url);
      if (hit == null) return null;
      final bytes = await hit.file.length();
      return bytes > 0 && bytes <= maxFileBytes ? hit.file : null;
    } catch (_) {
      return null;
    }
  }
}

/// Fixed geometry, bounded decode and no animated images/fades. Flutter's
/// Image defers decode during fast scrolling; missing artwork keeps its icon.
class CachedChannelLogo extends StatelessWidget {
  const CachedChannelLogo(
      {super.key,
      this.url,
      this.size = 24,
      this.icon = Icons.live_tv_outlined,
      this.color = Colors.white54,
      this.cache});
  final String? url;
  final double size;
  final IconData icon;
  final Color color;
  final ChannelLogoCache? cache;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(icon, size: size * .7, color: color);
    final source = url?.trim();
    return SizedBox(
        width: size,
        height: size,
        child: source == null || source.isEmpty
            ? fallback
            : FutureBuilder<File?>(
                key: ValueKey(source),
                future: (cache ?? ChannelLogoCache.shared).find(source),
                builder: (context, snapshot) {
                  final file = snapshot.data;
                  if (file == null) return fallback;
                  return TickerMode(
                      enabled: false,
                      child: Image(
                          image: ResizeImage(FileImage(file),
                              width: 64,
                              height: 64,
                              policy: ResizeImagePolicy.fit),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.low,
                          excludeFromSemantics: true,
                          errorBuilder: (_, __, ___) => fallback));
                }));
  }
}
