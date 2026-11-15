import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/painting.dart" show Size;

import "../../../link/link.dart";
import "../../../platform/link_platform.dart";
import "../../sources.dart";

/// Where a [DesktopSession] is, for the page's message.
enum DesktopPhase {
  /// Opening the desktop, or waiting for the window's size.
  starting,

  /// The desktop is open and its picture is on.
  live,

  /// The connection is gone; the page opens the desktop again when it is back.
  reconnecting,

  /// The desktop closed it (`ionix-link desktop close`, the plugin switched off, the output gone, a shutdown).
  closedByDesktop,

  /// Another phone has the desktop.
  busy,

  /// The desktop could not make the monitor, or no longer offers the plugin.
  unavailable,

  /// The picture stopped or the open failed for another reason.
  failed,
}

/// Everything the Phone desktop page does that is not a widget: the `desktop.open` / `screen.start` pair and its
/// repeat after every size change, the video decoder, and what happens when the connection or the desktop goes.
///
/// It lives in the [ShellController] (not in the page's state), so a fold or unfold, which rebuilds the page in
/// another place of the tree, keeps the desktop, the stream and the decoder as they were. The page [attach]es and
/// [detach]es; [leave] ends it.
///
/// The window is reported with [setWindow]. The first call opens at once; a later one that changes the pixel size is
/// held back [resizeDebounce], then runs `desktop.open` again and `screen.start` again, while the last picture stays
/// on screen. One open runs at a time, a size that changes meanwhile starts another right after.
class DesktopSession extends ChangeNotifier {
  DesktopSession({DesktopSource? desktop, ScreenSource? screen, HomeSource? home})
      : _desktop = desktop ?? UiSources.desktop,
        _screen = screen ?? UiSources.screen,
        _home = home ?? UiSources.home {
    uiSize = _desktop.uiSize;
    ScreenAwake.hold();
    _videoUnits = _screen.video.listen(_onVideoUnit);
    _frames = _screen.frames.listen(_onFrame);
    _stopped = _screen.stopped.listen(_onStopped);
    _closed = _desktop.closed.listen(_onClosed);
    _home.status.addListener(_onStatus);
    _wasReady = _home.status.value.isReady;
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      fps.value = _framesThisSecond;
      _framesThisSecond = 0;
    });
  }

  /// How long a size change must hold still before the desktop is resized.
  static const Duration resizeDebounce = Duration(milliseconds: 300);

  static const double _streamScale = 4.0;
  static const int _streamFps = 60;
  static const int _maxBitrate = 12000000;
  static const int _minBitrate = 2000000;
  static const Duration _firstPictureTimeout = Duration(seconds: 4);

  final DesktopSource _desktop;
  final ScreenSource _screen;
  final HomeSource _home;

  /// Room given to windows, 1.0..2.0 (the page's slider; persisted).
  late double uiSize;

  /// Frames drawn in the last second.
  final ValueNotifier<int> fps = ValueNotifier(0);

  /// The newest picture while the stream is JPEG (a phone with no decoder); null for video.
  final ValueNotifier<ScreenFrame?> frame = ValueNotifier(null);

  /// Counted so tests and the preview can see that one size change is one open.
  int openCount = 0;

  DesktopPhase _phase = DesktopPhase.starting;
  String? _message;
  DesktopInfo? _info;
  Size? _pictureSize;
  String _format = ScreenClient.formatJpeg;
  bool _left = false;
  bool _suspended = false;
  bool _wasReady = false;
  int _attached = 0;

  // The window.
  double _dpr = 1;
  ({int width, int height})? _target;
  ({int width, int height})? _opened;
  Timer? _debounce;
  bool _running = false;
  bool _again = false;

  // Video. A failure lasts for the app's run: it is not worth trying a decoder that has just failed.
  static bool _videoBroken = false;
  bool _forceJpeg = false;
  bool? _phoneDecodes;
  VideoDecoder? _decoder;
  H264ParameterSets? _decoderSets;
  Size? _videoSize;
  bool _videoShown = false;
  Timer? _firstPicture;
  Future<void> _videoChain = Future.value();
  StreamSubscription<ScreenVideoUnit>? _videoUnits;
  StreamSubscription<ScreenFrame>? _frames;
  StreamSubscription<String>? _stopped;
  StreamSubscription<String>? _closed;
  StreamSubscription<int>? _videoDecoded;
  StreamSubscription<String>? _videoErrors;
  Timer? _fpsTimer;
  int _framesThisSecond = 0;

  DesktopPhase get phase => _phase;

  /// A plain sentence for the current [phase], null while live or starting.
  String? get message => _message;

  /// The open desktop as the desktop described it, null before the first open and after it closed.
  DesktopInfo? get info => _info;

  /// The picture's size in px, once there is one to show: what touches are normalised to.
  Size? get pictureSize => _pictureSize;

  /// The running stream's format, [ScreenClient.formatH264] or [ScreenClient.formatJpeg].
  String get format => _format;

  bool get isVideo => _format == ScreenClient.formatH264 && _decoder != null;

  /// The decoder whose texture holds the picture, while the stream is video.
  VideoDecoder? get decoder => _decoder;

  /// Whether a video picture has been drawn.
  bool get videoShown => _videoShown;

  /// The pixel size the window asked for, null before [setWindow].
  ({int width, int height})? get target => _target;

  /// Whether the desktop offered touch input. Without it the picture streams but every tap is dropped, which is
  /// the case on a desktop that has no uinput access yet (until the user logs in again after installing).
  bool get hasTouch => _desktop.hasTouch;

  /// Whether the phone can type on the desktop at all: through its input method, or `input.text` as the fallback.
  bool get hasKeyboard => _desktop.hasIme || UiSources.input.hasKeyboard;

  /// Whether the desktop tells the phone when to show its keyboard.
  bool get hasIme => _desktop.hasIme;

  /// Whether the desktop's shell answers Home and Overview (Back always works: it falls back to Escape).
  bool get hasNav => _desktop.hasNav;

  /// The focused text field on the phone's desktop, null while none.
  ValueListenable<DesktopTextInput?> get textInput => _desktop.textInput;

  /// Persisted place of the page's handle.
  ({bool right, double pos}) get handle => _desktop.handle;

  Future<void> setHandle({required bool right, required double pos}) => _desktop.setHandle(right: right, pos: pos);

  /// Set the fingers that are down; the link layer sends it at once or coalesced, as the change deserves.
  void touch(List<DesktopTouch> touches) => _desktop.touch(touches);

  /// Ask the desktop's shell for `back`, `home` or `overview`.
  void nav(String action) => _desktop.nav(action);

  /// Type [text] after deleting [deleteBefore] code points: through the desktop's input method, or, on a desktop
  /// without one, as `input.text` and `BackSpace` keys.
  void commit(String? text, int deleteBefore) {
    if (_desktop.hasIme) {
      try {
        _desktop.commit(text: text, deleteBefore: deleteBefore);
      } on LinkException catch (e) {
        debugPrint("ionix-link: commit: ${e.message}");
      }
      return;
    }
    _typeThroughInput(text, deleteBefore);
  }

  /// Press Enter on the desktop (`input.key Return`).
  void enter() => _quietly(UiSources.input.key("Return"));

  Future<void> _typeThroughInput(String? text, int deleteBefore) async {
    final input = UiSources.input;
    try {
      for (var i = 0; i < deleteBefore; i++) {
        await input.key("BackSpace");
      }
      if (text != null && text.isNotEmpty) await input.text(text);
    } on LinkException catch (e) {
      debugPrint("ionix-link: typing: ${e.message}");
    }
  }

  void _quietly(Future<void> future) {
    future.catchError((Object e) => debugPrint("ionix-link: key: ${e is LinkException ? e.message : e}"));
  }

  /// Whether [leave] has run.
  bool get left => _left;

  /// Whether the app is in the background and the stream is off.
  bool get suspended => _suspended;

  /// A page shows this session. Pair with [detach].
  void attach() => _attached++;

  /// Returns whether no page shows the session any more.
  bool detach() => --_attached <= 0;

  /// Whether a page shows the session right now.
  bool get hasPages => _attached > 0;

  /// The window the page fills, in logical px with its pixel ratio. Opens the desktop the first time; later, a
  /// changed pixel size resizes it after [resizeDebounce].
  void setWindow(Size logical, double dpr) {
    if (_left || logical.isEmpty || dpr <= 0) return;
    final target = (width: _pixels(logical.width * dpr), height: _pixels(logical.height * dpr));
    final dprChanged = (dpr - _dpr).abs() > 0.001;
    _dpr = dpr;
    if (_target == target && !dprChanged) return;
    _target = target;
    if (_opened == null) {
      if (!_running) _kick();
      return;
    }
    if (_opened == target && !dprChanged) {
      _debounce?.cancel();
      _debounce = null;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(resizeDebounce, _kick);
  }

  /// Pixels the compositor accepts: 320..4096, rounded down to even.
  static int _pixels(double value) => (value.floor() ~/ 2 * 2).clamp(320, 4096);

  /// `scale` for `desktop.open`: the phone's pixel ratio over [uiSize], within the protocol's 1.0..4.0.
  double get openScale => (_dpr / uiSize).clamp(1.0, 4.0);

  /// Change [uiSize] and open the desktop again with it.
  Future<void> setUiSize(double size) async {
    final next = size.clamp(1.0, 2.0);
    if ((next - uiSize).abs() < 0.001) return;
    uiSize = next;
    notifyListeners();
    await _desktop.setUiSize(next);
    reopen();
  }

  /// Open the desktop again now (after a failure, a resume, or a change of [uiSize]).
  void reopen() {
    if (_left) return;
    _debounce?.cancel();
    _debounce = null;
    _opened = null;
    if (_target != null) _kick();
  }

  void _kick() {
    _debounce = null;
    if (_left || _suspended) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _openAndStream().whenComplete(() {
      _running = false;
      if (_again && !_left) {
        _again = false;
        _kick();
      }
    });
  }

  Future<void> _openAndStream() async {
    final target = _target;
    if (target == null || _left) return;
    if (!_home.status.value.isReady) {
      _setPhase(DesktopPhase.reconnecting, "The connection to the desktop is down. Trying again…");
      return;
    }
    if (_phase != DesktopPhase.live) _setPhase(DesktopPhase.starting, null);
    try {
      openCount++;
      final info = await _desktop.open(width: target.width, height: target.height, scale: openScale);
      if (_left) return;
      _info = info;
      _opened = target;
      await _startStream(info);
      if (_left) return;
      _setPhase(DesktopPhase.live, null);
    } on LinkRemoteException catch (e) {
      _opened = null;
      if (e.code == LinkErrorCode.busy) {
        _setPhase(DesktopPhase.busy, "Another phone is using this desktop's phone screen.");
      }
      else if (e.code == LinkErrorCode.pluginUnavailable || e.code == LinkErrorCode.unavailable) {
        _setPhase(DesktopPhase.unavailable, "This desktop does not offer the phone desktop right now.");
      }
      else {
        _setPhase(DesktopPhase.failed, e.message);
      }
    } on LinkPluginUnavailableException {
      _opened = null;
      _setPhase(DesktopPhase.unavailable, "This desktop does not offer the phone desktop right now.");
    } on LinkException catch (e) {
      _opened = null;
      if (!_home.status.value.isReady) {
        _setPhase(DesktopPhase.reconnecting, "The connection to the desktop is down. Trying again…");
      }
      else {
        _setPhase(DesktopPhase.failed, e.message);
      }
    }
  }

  Future<void> _startStream(DesktopInfo info) async {
    _phoneDecodes ??= await LinkPlatform.instance.canDecodeH264();
    var video = _screen.canVideo && _phoneDecodes! && !_videoBroken && !_forceJpeg;
    _decoderSets = null; // the new stream's first keyframe starts the decoder afresh
    if (video) {
      video = await _ensureDecoder();
    }
    else {
      await _releaseDecoder();
    }
    final hires = _screen.canHires;
    final stream = await _screen.start(
      info.output,
      scale: hires ? _streamScale : 1.0,
      quality: 75,
      maxFps: hires ? _streamFps : 30,
      format: video ? ScreenClient.formatH264 : ScreenClient.formatJpeg,
      bitrate: video ? bitrateFor(info.width, info.height) : null,
    );
    if (_left) return;
    _format = stream.format;
    _pictureSize ??= Size(stream.width.toDouble(), stream.height.toDouble());
    if (!video) _videoShown = false;
    notifyListeners();
  }

  /// About 12 Mbit/s on a full phone screen, less on a smaller picture.
  static int bitrateFor(int width, int height) => (width * height * _streamFps * 0.075).round().clamp(_minBitrate, _maxBitrate);

  //#region Video

  Future<bool> _ensureDecoder() async {
    if (_decoder != null) return true;
    try {
      final decoder = await LinkPlatform.instance.createH264Decoder();
      if (_left) {
        await decoder.dispose();
        return false;
      }
      _decoder = decoder;
      _videoDecoded = decoder.decoded.listen(_onVideoDecoded);
      _videoErrors = decoder.errors.listen(_onVideoError);
      decoder.picture.addListener(_onVideoPicture);
      return true;
    } on UnsupportedError catch (e) {
      debugPrint("ionix-link: no video decoder: ${e.message}");
      _videoBroken = true;
      return false;
    }
  }

  Future<void> _releaseDecoder() async {
    _firstPicture?.cancel();
    _firstPicture = null;
    final decoder = _decoder;
    if (decoder == null) return;
    _decoder = null;
    _decoderSets = null;
    decoder.picture.removeListener(_onVideoPicture);
    await _videoDecoded?.cancel();
    await _videoErrors?.cancel();
    await decoder.dispose();
  }

  void _onVideoUnit(ScreenVideoUnit unit) {
    // In order, one at a time: a keyframe may (re)configure the decoder, and nothing may overtake that.
    _videoChain = _videoChain.then((_) => _feed(unit)).catchError((Object error) => debugPrint("ionix-link: video: $error"));
  }

  Future<void> _feed(ScreenVideoUnit unit) async {
    final decoder = _decoder;
    if (decoder == null || _left || _format != ScreenClient.formatH264) return;
    if (unit.keyframe) {
      final sets = H264.parameterSets(unit.bytes);
      final size = Size(unit.width.toDouble(), unit.height.toDouble());
      if (sets != null && (!sets.sameAs(_decoderSets) || size != _videoSize)) {
        _decoderSets = sets;
        _videoSize = size;
        await decoder.configure(width: unit.width, height: unit.height, sps: sets.sps, pps: sets.pps);
      }
    }
    if (_decoderSets == null || !identical(decoder, _decoder)) return;
    if (!_videoShown) _firstPicture ??= Timer(_firstPictureTimeout, () => _onVideoError("The phone's video decoder showed nothing."));
    decoder.decode(unit.seq, unit.bytes, keyframe: unit.keyframe);
  }

  void _onVideoDecoded(int seq) {
    _framesThisSecond++;
    _firstPicture?.cancel();
    _firstPicture = null;
    _screen.ack(seq);
    if (!_videoShown) {
      _videoShown = true;
      notifyListeners();
    }
  }

  void _onVideoPicture() {
    final picture = _decoder?.picture.value;
    if (picture == null) return;
    _pictureSize = Size(picture.width.toDouble(), picture.height.toDouble());
    notifyListeners();
  }

  void _onVideoError(String message) {
    if (_decoder == null || _left) return;
    debugPrint("ionix-link: $message");
    _videoBroken = true;
    _releaseDecoder().whenComplete(reopen);
  }

  void _onFrame(ScreenFrame frame) {
    if (_left || _format != ScreenClient.formatJpeg) return;
    _framesThisSecond++;
    final size = Size(frame.width.toDouble(), frame.height.toDouble());
    if (size != _pictureSize) {
      _pictureSize = size;
      notifyListeners();
    }
    this.frame.value = frame;
    // Acked once painted would be better, but a page that is not shown has no paint to wait for.
    scheduleMicrotask(() => _screen.ack(frame.seq));
  }

  //#endregion

  //#region Events

  void _onStopped(String reason) {
    if (_left || _suspended || reason == "disconnected" || reason == "stopped") return;
    if (reason == "capture_failed" && _format == ScreenClient.formatH264 && !_forceJpeg) {
      // The encoder can fail for a while (the screen off, a mode change) while grim still works.
      _forceJpeg = true;
      reopen();
      return;
    }
    _setPhase(
      DesktopPhase.failed,
      switch (reason) {
        "output_gone" => "The phone's screen disappeared on the desktop.",
        "stalled" => "The picture stopped coming through.",
        _ => "The desktop couldn't capture the phone's screen.",
      },
    );
  }

  void _onClosed(String reason) {
    if (_left) return;
    _info = null;
    _opened = null;
    _debounce?.cancel();
    _debounce = null;
    _setPhase(
      DesktopPhase.closedByDesktop,
      switch (reason) {
        DesktopClient.closedFailed => "The phone's screen disappeared on the desktop.",
        DesktopClient.closedShutdown => "The desktop is shutting down.",
        _ => "The phone desktop was closed on the desktop.",
      },
    );
  }

  void _onStatus() {
    if (_left) return;
    final status = _home.status.value;
    if (status.isReady) {
      if (_wasReady) return;
      _wasReady = true;
      // The desktop keeps the monitor for 30 s: opening again finds it as it was and continues.
      if (_phase != DesktopPhase.closedByDesktop) reopen();
      return;
    }
    _wasReady = false;
    if (_phase == DesktopPhase.closedByDesktop) return;
    _setPhase(
      DesktopPhase.reconnecting,
      status.state == LinkState.forgotten ? "The desktop no longer knows this phone." : "The connection to the desktop is down. Trying again…",
    );
  }

  //#endregion

  /// The app went to the background: no stream for nobody, fingers lifted. [resume] undoes it.
  void suspend() {
    if (_suspended || _left) return;
    _suspended = true;
    _desktop.touch(const []);
    _debounce?.cancel();
    _debounce = null;
    _screen.stop().catchError((_) {});
    _releaseDecoder();
    _videoShown = false;
    notifyListeners();
  }

  void resume() {
    if (!_suspended || _left) return;
    _suspended = false;
    reopen();
  }

  /// End the phone desktop: fingers lifted, stream stopped, `desktop.close` sent, the decoder freed.
  Future<void> leave() async {
    if (_left) return;
    _left = true;
    _debounce?.cancel();
    _fpsTimer?.cancel();
    _firstPicture?.cancel();
    _home.status.removeListener(_onStatus);
    _desktop.touch(const []);
    await _videoUnits?.cancel();
    await _frames?.cancel();
    await _stopped?.cancel();
    await _closed?.cancel();
    ScreenAwake.release();
    try {
      await _screen.stop();
    } on LinkException {
      // The desktop stops the stream itself when the monitor goes.
    }
    try {
      await _desktop.close();
    } on LinkException catch (e) {
      debugPrint("ionix-link: desktop.close: ${e.message}");
    }
    await _releaseDecoder();
    // Not disposed: the page's last frame may still hold listeners, and none of this owns anything native.
  }

  void _setPhase(DesktopPhase phase, String? message) {
    if (_phase == phase && _message == message) return;
    _phase = phase;
    _message = message;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_left) return;
    super.notifyListeners();
  }

  /// The picture's size as "1080×2400", "…" before there is one.
  String get sizeLabel {
    final size = _pictureSize;
    if (size == null) return "…";
    return "${size.width.round()}×${size.height.round()}";
  }
}
