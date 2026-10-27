import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../utils/image_urls.dart';

/// A [CachedNetworkImage] for posters, backdrops and episode stills that
/// asks TMDB for a rendition sized to [decodeWidth] (see [hdImageUrl]) and
/// falls back to the provider's own [url] if that rendition fails to load.
/// Never use it for channel logos — those aren't TMDB art.
///
/// [decodeWidth] is also the decode cap (`memCacheWidth`, width only, so
/// the aspect ratio is kept — passing a height too stretches the image to
/// the box's shape). Always pass one: an uncapped HD backdrop decodes at
/// full size, which a memory-starved Fire Stick can't afford. Use
/// [cardDecodeWidth] / [screenDecodeWidth] to compute it.
class HdNetworkImage extends StatelessWidget {
  const HdNetworkImage({
    super.key,
    required this.url,
    required this.kind,
    required this.decodeWidth,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fadeInDuration = const Duration(milliseconds: 500),
    this.errorWidget,
    this.onLoaded,
    this.onFailed,
  });

  final String url;
  final ImageKind kind;
  final int decodeWidth;
  final BoxFit fit;
  final Alignment alignment;
  final Duration fadeInDuration;
  final Widget Function(BuildContext context)? errorWidget;

  /// Called (during build) once the image is available — see [HdSwapImage].
  final VoidCallback? onLoaded;

  /// Called (during build) when neither the HD nor the original URL loads.
  final VoidCallback? onFailed;

  /// Decode width for a fixed-size card: its physical width times
  /// [oversample] (1.2 covers the ~1.1x focus zoom, so the focused card
  /// isn't an upscale of its resting size).
  static int cardDecodeWidth(BuildContext context, double logicalWidth,
          {double oversample = 1.2}) =>
      math.max(
          1,
          (logicalWidth * MediaQuery.of(context).devicePixelRatio * oversample)
              .round());

  /// Decode width for a large surface (hero, backdrop, full-screen
  /// background): its physical width, capped at 1920 on Android (a Fire
  /// Stick's whole 1080p screen) and 3840 elsewhere (a 4K Windows monitor).
  static int screenDecodeWidth(BuildContext context, double logicalWidth) {
    final px = (logicalWidth * MediaQuery.of(context).devicePixelRatio).round();
    return px.clamp(1, Platform.isAndroid ? 1920 : 3840);
  }

  @override
  Widget build(BuildContext context) {
    final hd = hdImageUrl(url, kind, decodeWidth);
    Widget fallback(BuildContext c) {
      onFailed?.call();
      return errorWidget?.call(c) ?? const SizedBox.shrink();
    }

    final loaded = onLoaded;
    ImageWidgetBuilder? builder;
    if (loaded != null) {
      builder = (c, provider) {
        loaded();
        return Image(image: provider, fit: fit, alignment: alignment);
      };
    }
    return CachedNetworkImage(
      imageUrl: hd,
      fit: fit,
      alignment: alignment,
      memCacheWidth: decodeWidth,
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeInDuration == Duration.zero
          ? Duration.zero
          : const Duration(milliseconds: 1000),
      imageBuilder: builder,
      errorWidget: (c, _, __) => hd == url
          ? fallback(c)
          // The upgraded rendition failed (a dead path, a CDN hiccup) —
          // the provider's own link may still work.
          : CachedNetworkImage(
              imageUrl: url,
              fit: fit,
              alignment: alignment,
              memCacheWidth: decodeWidth,
              fadeInDuration: fadeInDuration,
              fadeOutDuration: fadeInDuration == Duration.zero
                  ? Duration.zero
                  : const Duration(milliseconds: 1000),
              imageBuilder: builder,
              errorWidget: (c2, _, __) => fallback(c2),
            ),
    );
  }
}

/// [HdNetworkImage] for big surfaces whose image changes in place (the
/// browse hero, a carousel slide whose backdrop arrives late, a detail
/// backdrop): the previous image stays painted underneath until the new
/// one has loaded and faded in, so a swap never flashes an empty frame.
/// Only for opaque `cover` images — a transparent one would show the old
/// picture through it.
class HdSwapImage extends StatefulWidget {
  const HdSwapImage({
    super.key,
    required this.url,
    required this.kind,
    required this.decodeWidth,
    this.alignment = Alignment.center,
    this.fadeInDuration = const Duration(milliseconds: 300),
  });

  final String url;
  final ImageKind kind;
  final int decodeWidth;
  final Alignment alignment;
  final Duration fadeInDuration;

  @override
  State<HdSwapImage> createState() => _HdSwapImageState();
}

class _HdSwapImageState extends State<HdSwapImage> {
  /// What was showing before [widget.url] — painted under it until that
  /// one is in. At most one previous image is ever kept (memory).
  String? _previous;
  ImageKind? _previousKind;
  Timer? _dropTimer;

  @override
  void didUpdateWidget(HdSwapImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _dropTimer?.cancel();
      _dropTimer = null;
      _previous = old.url;
      _previousKind = old.kind;
    }
  }

  @override
  void dispose() {
    _dropTimer?.cancel();
    super.dispose();
  }

  /// Called from the new image's builder (i.e. during build) — the drop
  /// itself waits until the fade-in is over.
  void _scheduleDrop() {
    if (_previous == null || _dropTimer != null) return;
    _dropTimer =
        Timer(widget.fadeInDuration + const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _previous = null);
      _dropTimer = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final previous = _previous;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (previous != null)
          HdNetworkImage(
            key: ValueKey('prev:$previous'),
            url: previous,
            kind: _previousKind ?? widget.kind,
            decodeWidth: widget.decodeWidth,
            alignment: widget.alignment,
            fadeInDuration: Duration.zero,
          ),
        HdNetworkImage(
          key: ValueKey(widget.url),
          url: widget.url,
          kind: widget.kind,
          decodeWidth: widget.decodeWidth,
          alignment: widget.alignment,
          fadeInDuration: widget.fadeInDuration,
          onLoaded: _scheduleDrop,
          onFailed: _scheduleDrop,
        ),
      ],
    );
  }
}
