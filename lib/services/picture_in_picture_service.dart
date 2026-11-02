import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player_hdr/video_player_hdr.dart';

/// Android owns the window; the existing video controller owns the stream.
/// Android's onStop, rather than Flutter's inactive state, decides when the
/// player is hidden: entering PiP also makes Flutter inactive.
class PictureInPictureService extends ChangeNotifier {
  PictureInPictureService() {
    if (isAndroid) {
      _channel.setMethodCallHandler(_onMethod);
      unawaited(_initialize());
    }
  }

  static const _channel = MethodChannel('com.nox.nox_iptv/picture_in_picture');
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool supported = false;
  bool active = false;
  bool _fullscreen = false;
  bool _fullscreenSession = false;
  bool _allowBackgroundAudio = false;
  bool _dismissed = false;
  final Set<Object> _previews = {};
  bool _hidden = false;
  bool _screenOffPlayback = false;
  bool _mediaStopped = false;
  String _title = 'iptv-app';
  bool? _lastSession;
  bool? _lastPlaying;
  String? _lastTitle;
  bool _resumeWhenVisible = true;
  bool _disposed = false;
  bool? _lastEnabled;
  double? _lastRatio;
  VideoPlayerHdrController? _controller;
  VideoPlayerHdrController? _resumeController;

  Future<void> _initialize() async {
    try {
      final available =
          await _channel.invokeMethod<bool>('isSupported') ?? false;
      if (_disposed) return;
      supported = available;
      _sync();
      notifyListeners();
    } on MissingPluginException {
      // Desktop, tests, or an older native shell.
    } on PlatformException {
      // Devices without the system feature keep their normal player.
    }
  }

  void attach(VideoPlayerHdrController? controller,
      {String? title, bool allowBackgroundAudio = false}) {
    if (_disposed) return;
    _controller?.removeListener(_sync);
    _controller = controller;
    _title = title ?? 'iptv-app';
    _allowBackgroundAudio = allowBackgroundAudio;
    _mediaStopped = false;
    controller?.addListener(_sync);
    _sync();
  }

  /// Only the active, visible phone preview may automatically enter PiP.
  void setPreviewVisible(Object owner, bool visible) {
    if (visible) {
      _previews.add(owner);
    } else {
      _previews.remove(owner);
    }
    _sync();
  }

  bool get fullscreenVisible => _fullscreen;

  bool get _backgroundAudio => _allowBackgroundAudio && !_dismissed;

  void setFullscreenVisible(bool visible, {bool playerOpen = false}) {
    _fullscreen = visible;
    // A player dialog disables automatic PiP, but must not tear down the
    // media session of the movie still playing behind it.
    _fullscreenSession = visible || playerOpen;
    _sync();
  }

  void _sync() {
    if (_disposed || !isAndroid) return;
    final controller = _controller;
    final value = controller?.value;
    // Also catches a stream/reconnection that finishes loading after Home.
    if (_hidden &&
        !_screenOffPlayback &&
        !_backgroundAudio &&
        value?.isPlaying == true) {
      if (_resumeWhenVisible) _resumeController = controller;
      unawaited(controller!.pause());
      return;
    }
    final enabled = supported &&
        (_fullscreen || _previews.isNotEmpty) &&
        !_hidden &&
        value?.isInitialized == true &&
        value?.isPlaying == true &&
        value?.hasError == false;
    final rawRatio = value?.aspectRatio ?? 16 / 9;
    final ratio = rawRatio.isFinite && rawRatio > 0 ? rawRatio : 16 / 9;
    if (value?.isPlaying == true) _mediaStopped = false;
    final session = !_mediaStopped &&
        (_fullscreenSession ||
            active ||
            _allowBackgroundAudio ||
            _screenOffPlayback) &&
        (!_hidden || _screenOffPlayback || _backgroundAudio) &&
        (value?.isInitialized == true ||
            (_allowBackgroundAudio && value != null)) &&
        value?.hasError == false;
    final playing = value?.isPlaying == true;
    if (enabled == _lastEnabled &&
        ratio == _lastRatio &&
        session == _lastSession &&
        playing == _lastPlaying &&
        _title == _lastTitle) {
      return;
    }
    _lastEnabled = enabled;
    _lastRatio = ratio;
    _lastSession = session;
    _lastPlaying = playing;
    _lastTitle = _title;
    unawaited(_update(enabled, ratio, session: session, playing: playing));
  }

  Future<void> _update(bool enabled, double ratio,
      {bool session = false, bool playing = false}) async {
    try {
      await _channel.invokeMethod<void>('update', {
        'enabled': enabled,
        'aspectRatio': ratio,
        'mediaSession': session,
        'playing': playing,
        'title': _title,
      });
    } on PlatformException {
      // OEMs can reject PiP parameters even when they advertise support.
    } on MissingPluginException {
      // No native implementation in widget tests.
    }
  }

  Future<bool> enter() async {
    if (!supported || _lastEnabled != true) return false;
    try {
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _onMethod(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'modeChanged':
        active = call.arguments == true;
        _sync();
        notifyListeners();
      case 'background':
        _hidden = true;
        final args = call.arguments;
        _dismissed = args is Map ? args['dismissed'] == true : args == false;
        _screenOffPlayback = args is Map &&
            args['screenOff'] == true &&
            (_fullscreen ||
                active ||
                _allowBackgroundAudio ||
                _screenOffPlayback);
        _resumeWhenVisible =
            args is Map ? args['resume'] == true : args == true;
        final controller = _controller;
        final playing = controller?.value.isPlaying == true;
        _resumeController = !_screenOffPlayback &&
                !_backgroundAudio &&
                _resumeWhenVisible &&
                playing
            ? controller
            : null;
        if (playing && !_screenOffPlayback && !_backgroundAudio) {
          await controller!.pause();
        }
        if (_dismissed && !_screenOffPlayback) _mediaStopped = true;
        _sync();
      case 'foreground':
        _hidden = false;
        _dismissed = false;
        _screenOffPlayback = false;
        final resume = _resumeController;
        _resumeController = null;
        if (resume != null && identical(resume, _controller)) {
          await resume.play();
        }
        _sync();
      case 'mediaAction':
        switch (call.arguments) {
          case 'play':
            await _controller?.play();
          case 'pause':
            _resumeController = null;
            await _controller?.pause();
          case 'stop':
            _resumeController = null;
            await _controller?.pause();
            _mediaStopped = true;
            _screenOffPlayback = false;
            _sync();
        }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_sync);
    if (isAndroid) {
      unawaited(_update(false, 16 / 9));
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
