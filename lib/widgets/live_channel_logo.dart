import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Shared disk cache, bounded decoding, original aspect ratio and no fades.
/// Animated section artwork remains supported while its row is visible.
class LiveChannelLogo extends StatelessWidget {
  const LiveChannelLogo({super.key, required this.url, this.icon = Icons.tv});
  final String url;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Image(
        image: ResizeImage(CachedNetworkImageProvider(url),
            width: 96, height: 96, policy: ResizeImagePolicy.fit),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.low,
        excludeFromSemantics: true,
        errorBuilder: (_, __, ___) => Icon(icon, size: 20),
      );
}
