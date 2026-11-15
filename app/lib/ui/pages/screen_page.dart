import "dart:async";

import "package:flutter/services.dart";
import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../../platform/link_platform.dart";
import "../sources.dart";
import "../theme.dart";
import "../widgets/adaptive_scaffold.dart";
import "../widgets/empty_state.dart";
import "../widgets/floating_bar.dart";
import "../widgets/fold_split.dart";
import "../widgets/ion_page.dart";
import "../widgets/keys_panel.dart";
import "../widgets/touchpad.dart";
import "../widgets/window_layout.dart";

/// Screen viewer: output picker, then the desktop's picture; a tap is a click at that spot, a drag moves the pointer
/// there, a pinch zooms, and two fingers scroll (or pan when zoomed in). The stream stops when the page goes away. In
/// tabletop posture the picture is on the upright half and a touchpad with keys on the flat one.
///
/// The picture is H.264 video when the desktop offers it and the phone has a decoder ([LinkPlatform.createH264Decoder]
/// draws it into a texture), unless the options sheet asks for still frames; otherwise JPEG frames painted with
/// `Image.memory(gaplessPlayback: true)`, acknowledged once shown. A decoder that fails switches the page to JPEG for
/// the rest of the app's run, said once. Video stops while the app is in the background and starts again on return.
///
/// Full screen ([ShellController.fullscreen]) hosts the same viewer, with the same stream, in the root overlay
/// through an [OverlayPortal], so it covers the dock, the rail and both panes, spans a fold, and survives a fold or
/// unfold with nothing restarting (a texture is only an id, so the decoder carries on behind either place).
class ScreenPage extends StatefulWidget {
  const ScreenPage({super.key});

  @override
  State<ScreenPage> createState() => _ScreenPageState();
}

class _Quality {
  const _Quality(this.label, this.quality, this.scale);

  final String label;
  final int quality;
  final double scale;
}

class _ScreenPageState extends State<ScreenPage> with WidgetsBindingObserver {
  static const List<_Quality> _qualities = [_Quality("Low", 40, 0.35), _Quality("Medium", 60, 0.5), _Quality("High", 80, 0.75)];
  static const List<int> _fpsChoices = [5, 10, 15, 30];

  final ScreenSource _screen = UiSources.screen;
  final InputSource _input = UiSources.input;

  List<ScreenOutput>? _outputs;
  String? _error;
  String? _output;
  int _quality = 1;
  int _fps = 15;
  bool _starting = false;

  ScreenFrame? _frame;
  int _ackedSeq = -1;

  // Video. The choice and a failure last for the app's run, not the page's.
  static bool _preferVideo = true;
  static bool _videoBroken = false;
  static const Duration _firstPictureTimeout = Duration(seconds: 4);
  bool _phoneDecodes = false;
  bool _captureFailed = false; // the desktop's encoder gave up on this page: still pictures until the user asks for video again
  String _format = ScreenClient.formatJpeg; // of the running stream
  VideoDecoder? _decoder;
  H264ParameterSets? _decoderSets; // what the decoder was configured with; null = wait for a keyframe
  Size? _videoSize;
  bool _videoShown = false;
  bool _suspended = false;
  Timer? _firstPicture; // a decoder fed this long without drawing anything counts as failed
  Future<void> _videoChain = Future.value();
  StreamSubscription<ScreenVideoUnit>? _videoUnits;
  StreamSubscription<int>? _videoDecoded;
  StreamSubscription<String>? _videoErrors;
  int _framesThisSecond = 0;
  int _shownFps = 0;
  Timer? _fpsTimer;
  StreamSubscription<ScreenFrame>? _frames;
  StreamSubscription<String>? _stopped;

  // View transform: scale about the centre, then offset.
  double _zoom = 1;
  Offset _pan = Offset.zero;
  double _zoomStart = 1;
  Offset _panStart = Offset.zero;
  Offset _focalStart = Offset.zero;
  int _pointerCount = 0;
  Size _viewSize = Size.zero;

  // Full screen.
  final OverlayPortalController _portal = OverlayPortalController();
  ShellController? _shell;
  bool _full = false;
  bool _cluster = true;
  Timer? _clusterTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = ShellScope.of(context);
    if (identical(shell, _shell)) return;
    _shell?.removeListener(_onShell);
    _shell = shell..addListener(_onShell);
  }

  void _onShell() {
    final full = _shell?.fullscreen ?? false;
    if (full == _full || !mounted) return;
    setState(() {
      _full = full;
      _zoom = 1;
      _pan = Offset.zero;
    });
    if (full) {
      _portal.show();
      _showCluster();
    }
    else {
      _portal.hide();
      _clusterTimer?.cancel();
    }
    _applySystemUi(full);
  }

  /// Hides the system bars and allows every orientation while full screen; the app is edge to edge and never locks
  /// an orientation otherwise.
  Future<void> _applySystemUi(bool full) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(const []);
    } catch (e) {
      debugPrint("Could not change the system bars: $e");
    }
  }

  void _showCluster() {
    _clusterTimer?.cancel();
    setState(() => _cluster = true);
    _clusterTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _cluster = false);
    });
  }

  void _toggleCluster() {
    if (_cluster) {
      _clusterTimer?.cancel();
      setState(() => _cluster = false);
    }
    else {
      _showCluster();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ScreenAwake.hold();
    _videoUnits = _screen.video.listen(_onVideoUnit);
    _frames = _screen.frames.listen((frame) {
      _framesThisSecond++;
      if (mounted) setState(() => _frame = frame);
    });
    _stopped = _screen.stopped.listen((reason) {
      if (!mounted || _suspended) return;
      final output = _output;
      final wasVideo = _format == ScreenClient.formatH264;
      setState(() {
        _frame = null;
        _videoShown = false;
      });
      if (reason == "capture_failed" && wasVideo && output != null && !_captureFailed) {
        // The encoder can fail for a while (the screen off, a mode change) while grim still works, so ask for stills.
        _captureFailed = true;
        showMessage(context, "The desktop couldn't encode video, so the screen is shown as still pictures.");
        _releaseDecoder().whenComplete(() {
          if (mounted) _start(output);
        });
        return;
      }
      showMessage(context, switch (reason) {
        "output_gone" => "That screen was unplugged or turned off.",
        "stalled" => "The picture stopped coming through. Start it again.",
        _ => "The desktop couldn't capture the screen.",
      });
    });
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _shownFps = _framesThisSecond;
        _framesThisSecond = 0;
      });
    });
    _init();
  }

  Future<void> _init() async {
    _phoneDecodes = await LinkPlatform.instance.canDecodeH264();
    if (mounted) await _loadOutputs();
  }

  bool get _useVideo => _screen.canVideo && _phoneDecodes && _preferVideo && !_videoBroken && !_captureFailed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A decoder has nothing to draw on while the app is away, and a stream nobody sees only costs the desktop. JPEG
    // keeps its old behaviour (frames simply stop being acked).
    if ((state == AppLifecycleState.hidden || state == AppLifecycleState.paused) && _format == ScreenClient.formatH264 && !_suspended) {
      _suspended = true;
      _screen.stop().catchError((_) {});
      _releaseDecoder();
      setState(() => _videoShown = false);
    }
    else if (state == AppLifecycleState.resumed && _suspended) {
      _suspended = false;
      final output = _output;
      if (output != null) _start(output);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ScreenAwake.release();
    _clusterTimer?.cancel();
    final shell = _shell?..removeListener(_onShell);
    if (_full) {
      _applySystemUi(false);
      WidgetsBinding.instance.addPostFrameCallback((_) => shell?.setFullscreen(false));
    }
    _fpsTimer?.cancel();
    _frames?.cancel();
    _stopped?.cancel();
    _videoUnits?.cancel();
    _screen.stop().catchError((_) {});
    _releaseDecoder();
    super.dispose();
  }

  Future<void> _loadOutputs() async {
    try {
      // A phone's own desktop is the Phone desktop page's, not a screen to look at.
      final outputs = [for (final o in await _screen.outputs()) if (!o.virtual) o];
      if (!mounted) return;
      setState(() {
        _outputs = outputs;
        _error = null;
      });
      if (outputs.isNotEmpty && _output == null) {
        final focused = outputs.where((o) => o.focused);
        _start((focused.isEmpty ? outputs.first : focused.first).name);
      }
    } on LinkException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _start(String output) async {
    var video = _useVideo;
    _firstPicture?.cancel();
    _firstPicture = null;
    setState(() {
      _output = output;
      _starting = true;
      _frame = null;
      _ackedSeq = -1;
      _videoShown = false;
      _videoSize = null;
      _decoderSets = null; // a new stream starts the decoder afresh on its first keyframe
      _zoom = 1;
      _pan = Offset.zero;
    });
    try {
      if (video) {
        video = await _ensureDecoder();
      }
      else {
        await _releaseDecoder();
      }
      final q = _qualities[_quality];
      final info = await _screen.start(output, scale: q.scale, quality: q.quality, maxFps: _fps, format: video ? ScreenClient.formatH264 : ScreenClient.formatJpeg);
      if (mounted) setState(() => _format = info.format);
    } on LinkException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// A decoder for the next video stream; false (and the switch to JPEG is announced) when the phone cannot make one.
  Future<bool> _ensureDecoder() async {
    if (_decoder != null) return true;
    try {
      final decoder = await LinkPlatform.instance.createH264Decoder();
      if (!mounted) {
        await decoder.dispose();
        return false;
      }
      _decoder = decoder;
      _videoDecoded = decoder.decoded.listen(_onVideoDecoded);
      _videoErrors = decoder.errors.listen(_onVideoError);
      decoder.picture.addListener(_onVideoPicture);
      return true;
    } on UnsupportedError catch (e) {
      _videoFailed(e.message ?? "The phone cannot decode video.");
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
    if (decoder == null || !mounted || _format != ScreenClient.formatH264) return;
    if (unit.keyframe) {
      final sets = H264.parameterSets(unit.bytes);
      final size = Size(unit.width.toDouble(), unit.height.toDouble());
      if (sets != null && (!sets.sameAs(_decoderSets) || size != _videoSize)) {
        // A new stream, or the same one at a new size (the output changed): start the decoder again.
        _decoderSets = sets;
        _videoSize = size;
        await decoder.configure(width: unit.width, height: unit.height, sps: sets.sps, pps: sets.pps);
      }
    }
    if (_decoderSets == null || !identical(decoder, _decoder)) return;
    // Some decoders swallow a stream they cannot handle without reporting an error.
    if (!_videoShown) _firstPicture ??= Timer(_firstPictureTimeout, () => _onVideoError("The phone's video decoder showed nothing."));
    decoder.decode(unit.seq, unit.bytes, keyframe: unit.keyframe);
  }

  void _onVideoDecoded(int seq) {
    _framesThisSecond++;
    _firstPicture?.cancel();
    _firstPicture = null;
    _screen.ack(seq);
    if (!_videoShown && mounted) setState(() => _videoShown = true);
  }

  void _onVideoPicture() {
    final picture = _decoder?.picture.value;
    if (picture == null || !mounted) return;
    setState(() => _videoSize = Size(picture.width.toDouble(), picture.height.toDouble()));
  }

  void _onVideoError(String message) {
    if (_decoder == null) return;
    debugPrint("ionix-link: $message");
    _videoFailed(message);
    final output = _output;
    _releaseDecoder().whenComplete(() {
      if (mounted && output != null) _start(output);
    });
  }

  void _videoFailed(String message) {
    if (_videoBroken) return;
    _videoBroken = true;
    if (mounted) showMessage(context, "Video didn't work on this phone, so the screen is shown as still pictures.");
  }

  /// The picture's size in px, once there is one to show.
  Size? get _pictureSize {
    if (_format == ScreenClient.formatH264) return _videoShown ? _videoSize : null;
    final frame = _frame;
    return frame == null ? null : Size(frame.width.toDouble(), frame.height.toDouble());
  }

  /// "1280×720 · H.264 · 30 fps", with the zoom when zoomed in.
  String get _stats {
    final size = _pictureSize;
    if (size == null) return "…";
    final mode = _format == ScreenClient.formatH264 ? "H.264" : "JPEG";
    return "${size.width.round()}×${size.height.round()} · $mode · $_shownFps fps${_zoom > 1.01 ? " · ${_zoom.toStringAsFixed(1)}×" : ""}";
  }

  void _ack(int seq) {
    if (_ackedSeq == seq) return;
    _ackedSeq = seq;
    WidgetsBinding.instance.addPostFrameCallback((_) => _screen.ack(seq));
  }

  // The rectangle the picture occupies inside the viewer before zoom: the frame fitted to the viewer.
  Rect _fitted(Size view, Size picture) {
    final aspect = picture.width / picture.height;
    var w = view.width;
    var h = w / aspect;
    if (h > view.height) {
      h = view.height;
      w = h * aspect;
    }
    return Rect.fromLTWH((view.width - w) / 2, (view.height - h) / 2, w, h);
  }

  Offset? _toNormalised(Offset local) {
    final picture = _pictureSize;
    if (picture == null || _viewSize.isEmpty) return null;
    final center = _viewSize.center(Offset.zero);
    final unzoomed = center + (local - center - _pan) / _zoom;
    final rect = _fitted(_viewSize, picture);
    if (!rect.contains(unzoomed)) return null;
    return Offset((unzoomed.dx - rect.left) / rect.width, (unzoomed.dy - rect.top) / rect.height);
  }

  void _setViewSize(Size size) {
    if ((size.width - _viewSize.width).abs() < 1 && (size.height - _viewSize.height).abs() < 1) return;
    final hadSize = !_viewSize.isEmpty;
    _viewSize = size;
    if (hadSize && (_zoom != 1 || _pan != Offset.zero)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _zoom = 1;
          _pan = Offset.zero;
        });
      });
    }
  }

  void _pointTo(Offset local) {
    final n = _toNormalised(local);
    final output = _output;
    if (n == null || output == null) return;
    _input.moveAbsolute(output, n.dx, n.dy);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _zoomStart = _zoom;
    _panStart = _pan;
    _focalStart = d.localFocalPoint;
    _pointerCount = d.pointerCount;
    if (d.pointerCount == 1) _pointTo(d.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount == 1 && _pointerCount == 1) {
      _pointTo(d.localFocalPoint);
      return;
    }
    _pointerCount = d.pointerCount;
    if (d.pointerCount < 2) return;
    final pinching = (d.scale - 1).abs() > 0.05;
    if (!pinching && _zoom <= 1.01) {
      _input.scroll(0, -d.focalPointDelta.dy * 1.6);
      return;
    }
    setState(() {
      _zoom = (_zoomStart * d.scale).clamp(1.0, 5.0);
      _pan = _zoom <= 1.01 ? Offset.zero : _panStart + (d.localFocalPoint - _focalStart);
    });
  }

  void _onTapUp(TapUpDetails d) {
    if (_toNormalised(d.localPosition) == null) return;
    _pointTo(d.localPosition);
    _input.button(PointerButton.left, ButtonAction.click);
  }

  Future<void> _showOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final text = Theme.of(context).textTheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(IonixSpace.lg, 0, IonixSpace.lg, IonixSpace.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_screen.canVideo && _phoneDecodes && !_videoBroken) ...[
                    Text("Picture type", style: text.titleMedium),
                    const SizedBox(height: IonixSpace.sm),
                    SegmentedButton<bool>(
                      segments: const [ButtonSegment(value: true, label: Text("Video")), ButtonSegment(value: false, label: Text("Still frames"))],
                      selected: {_preferVideo && !_captureFailed},
                      onSelectionChanged: (s) => setSheet(() {
                        _preferVideo = s.first;
                        if (s.first) _captureFailed = false;
                      }),
                    ),
                    const SizedBox(height: IonixSpace.xs),
                    Text("Video is smoother; still frames are sharper on a slow connection.", style: text.bodySmall),
                    const SizedBox(height: IonixSpace.lg),
                  ],
                  Text("Picture quality", style: text.titleMedium),
                  const SizedBox(height: IonixSpace.sm),
                  SegmentedButton<int>(
                    segments: [for (var i = 0; i < _qualities.length; i++) ButtonSegment(value: i, label: Text(_qualities[i].label))],
                    selected: {_quality},
                    onSelectionChanged: (s) => setSheet(() => _quality = s.first),
                  ),
                  const SizedBox(height: IonixSpace.lg),
                  Text("Frames per second", style: text.titleMedium),
                  const SizedBox(height: IonixSpace.sm),
                  SegmentedButton<int>(
                    segments: [for (final f in _fpsChoices) ButtonSegment(value: f, label: Text("$f"))],
                    selected: {_fps},
                    onSelectionChanged: (s) => setSheet(() => _fps = s.first),
                  ),
                  const SizedBox(height: IonixSpace.lg),
                  Text("Lower settings use less Wi-Fi and battery.", style: text.bodySmall),
                ],
              ),
            ),
          );
        },
      ),
    );
    final output = _output;
    if (output != null && mounted) await _start(output);
  }

  Widget _viewer({required bool bare}) {
    final outputs = _outputs;
    if (_error != null) {
      return EmptyState(icon: Icons.desktop_access_disabled_outlined, title: "Can't list the screens", message: _error, actionLabel: "Try again", action: _loadOutputs);
    }
    if (outputs == null) return const Center(child: CircularProgressIndicator());
    if (outputs.isEmpty) {
      return const EmptyState(icon: Icons.desktop_access_disabled_outlined, title: "No screens found", message: "Your desktop didn't report any display to show.");
    }
    return _Viewer(
      pictureSize: _pictureSize,
      picture: _picture(),
      stats: _stats,
      starting: _starting,
      zoom: _zoom,
      pan: _pan,
      bare: bare,
      onSize: _setViewSize,
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onTapUp: _onTapUp,
    );
  }

  /// The current picture: the video texture, or the newest JPEG frame (acked once painted).
  Widget? _picture() {
    final decoder = _decoder;
    if (_format == ScreenClient.formatH264) {
      if (decoder == null || !_videoShown) return null;
      return _VideoView(textureId: decoder.textureId, picture: decoder.picture.value, size: _videoSize);
    }
    final f = _frame;
    if (f == null) return null;
    return Image.memory(
      f.bytes,
      gaplessPlayback: true,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frameNumber, sync) {
        if (frameNumber != null || sync) _ack(f.seq);
        return child;
      },
      errorBuilder: (context, error, stack) {
        _ack(f.seq);
        return const SizedBox.shrink();
      },
    );
  }

  Widget _pad() {
    return Padding(
      padding: const EdgeInsets.all(IonixSpace.md),
      child: Column(
        children: [
          Expanded(child: Touchpad(input: _input)),
          const SizedBox(height: IonixSpace.sm),
          Row(
            children: [
              for (final (label, key) in const [("Esc", "Escape"), ("Tab", "Tab"), ("Enter", "Return"), ("Bksp", "BackSpace")])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: OutlinedButton(onPressed: () => _input.key(key), style: OutlinedButton.styleFrom(padding: EdgeInsets.zero), child: Text(label)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showKeyboard() async {
    _clusterTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: KeysPanel(input: _input))),
    );
    if (mounted && _full) _showCluster();
  }

  /// The full-screen layer: the picture over the whole window (the upright half only in tabletop posture, with the
  /// touchpad and keys on the flat half) and the auto-hiding controls.
  Widget _fullscreen(BuildContext context) {
    final root = MediaQuery.of(Overlay.of(context, rootOverlay: true).context);
    return MediaQuery(
      data: root,
      child: Builder(
        builder: (context) {
          final t = IonixTokens.of(context);
          final layout = WindowLayout.of(context);
          final padding = MediaQuery.paddingOf(context);
          final picture = ColoredBox(color: t.bgDeep, child: _viewer(bare: true));
          final Widget content = layout.isTabletop
              ? ColoredBox(
                  color: t.bgDeep,
                  child: FoldSplit(top: picture, bottom: SafeArea(top: false, child: _pad()), flat: picture),
                )
              : picture;

          // Controls stay inside the safe area, left of a vertical fold and above a horizontal one.
          final fold = layout.fold;
          final left = padding.left + 12;
          final top = padding.top + 8;
          final right = layout.hasVerticalFold ? fold!.left - 8 : layout.size.width - padding.right - 12;
          final outputs = _outputs ?? const <ScreenOutput>[];
          return Material(
            color: t.bgDeep,
            child: Stack(
              fit: StackFit.expand,
              children: [
                content,
                Positioned(
                  left: left,
                  top: top,
                  width: (right - left).clamp(44.0, layout.size.width),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topLeft,
                    child: Row(
                      children: [
                        Tooltip(
                          message: "Controls",
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _toggleCluster,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: t.bar(),
                              child: Icon(_cluster ? Icons.keyboard_arrow_left_rounded : Icons.more_horiz_rounded, color: t.accentLight),
                            ),
                          ),
                        ),
                        const SizedBox(width: IonixSpace.sm),
                        IgnorePointer(
                          ignoring: !_cluster,
                          child: AnimatedOpacity(
                            opacity: _cluster ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Container(
                              height: 44,
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: t.bar(),
                              child: Row(
                                children: [
                                  IconButton(tooltip: "Leave full screen", icon: Icon(Icons.fullscreen_exit_rounded, color: t.textBright), onPressed: () => _shell?.setFullscreen(false)),
                                  if (outputs.length > 1)
                                    PopupMenuButton<String>(
                                      tooltip: "Screens",
                                      icon: Icon(Icons.desktop_windows_outlined, color: t.textBright),
                                      onOpened: _clusterTimer?.cancel,
                                      onCanceled: _showCluster,
                                      onSelected: (name) {
                                        _start(name);
                                        _showCluster();
                                      },
                                      itemBuilder: (_) => [for (final o in outputs) CheckedPopupMenuItem<String>(value: o.name, checked: o.name == _output, child: Text(o.name))],
                                    ),
                                  IconButton(tooltip: "Keyboard", icon: Icon(Icons.keyboard_outlined, color: t.textBright), onPressed: _showKeyboard),
                                  IconButton(tooltip: "Picture options", icon: Icon(Icons.tune_rounded, color: t.textBright), onPressed: _output == null ? null : _showOptions),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: IonixSpace.sm),
                                    child: Text(_stats, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.textBright)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final outputs = _outputs;
    final viewer = _full ? const SizedBox.expand() : _viewer(bare: false);

    final picker = (outputs == null || outputs.length < 2)
        ? const SizedBox.shrink()
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: IonixSpace.md, vertical: IonixSpace.xs),
            child: Row(
              children: [
                for (final o in outputs)
                  Padding(
                    padding: const EdgeInsets.only(right: IonixSpace.sm),
                    child: ChoiceChip(label: Text(o.name), selected: o.name == _output, onSelected: (_) => _start(o.name)),
                  ),
              ],
            ),
          );

    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: _fullscreen,
      child: IonPage(
        title: "Screen",
        plugin: true,
        actions: [
          BarPill(icon: Icons.fullscreen_rounded, tooltip: "Full screen", onTap: _output == null ? null : () => _shell?.setFullscreen(true)),
          BarPill(icon: Icons.tune_rounded, tooltip: "Picture options", onTap: _output == null ? null : _showOptions),
        ],
        body: FoldSplit(
          top: Column(children: [picker, Expanded(child: Padding(padding: const EdgeInsets.all(IonixSpace.md), child: viewer))]),
          bottom: _pad(),
          flat: Column(
            children: [
              Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(IonixSpace.md, IonixSpace.xs, IonixSpace.md, IonixSpace.xs), child: viewer)),
              picker,
              Padding(
                padding: const EdgeInsets.fromLTRB(IonixSpace.lg, 0, IonixSpace.lg, IonixSpace.sm),
                child: Text("Tap to click · drag to point · pinch to zoom · two fingers to scroll", style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.dim), textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Viewer extends StatelessWidget {
  const _Viewer({
    required this.pictureSize,
    required this.picture,
    required this.stats,
    required this.starting,
    required this.zoom,
    required this.pan,
    required this.bare,
    required this.onSize,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onTapUp,
  });

  /// The picture's size in px, or null while there is nothing to show.
  final Size? pictureSize;

  /// The picture, fitted (contained and centred) to whatever box it gets.
  final Widget? picture;

  /// The statistics line.
  final String stats;
  final bool starting;
  final double zoom;
  final Offset pan;

  /// Edge to edge, with no frame or frame statistics, for full screen.
  final bool bare;
  final ValueChanged<Size> onSize;
  final GestureScaleStartCallback onScaleStart;
  final GestureScaleUpdateCallback onScaleUpdate;
  final GestureTapUpCallback onTapUp;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return DecoratedBox(
      decoration: bare ? BoxDecoration(color: t.bgDeep) : BoxDecoration(color: t.bgDeep, borderRadius: t.rSm, border: Border.all(color: t.accentBright.withValues(alpha: 0.25))),
      child: ClipRRect(
        borderRadius: bare ? BorderRadius.zero : t.rSm,
        child: LayoutBuilder(
          builder: (context, constraints) {
            onSize(constraints.biggest);
            final image = picture;
            if (image == null || pictureSize == null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    const SizedBox(height: IonixSpace.md),
                    Text(starting ? "Starting the picture…" : "Waiting for the first frame…", style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.dim)),
                  ],
                ),
              );
            }
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: onScaleStart,
              onScaleUpdate: onScaleUpdate,
              onTapUp: onTapUp,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translateByDouble(pan.dx, pan.dy, 0, 1)
                      ..scaleByDouble(zoom, zoom, 1, 1),
                    child: image,
                  ),
                  if (!bare)
                    Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: t.bgDeep.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(8)),
                      child: Text(stats, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: t.textBright, fontSize: 11)),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A video texture fitted like `BoxFit.contain`. When the texture holds more than the picture (decoders work in
/// 16-px blocks, and not every renderer applies the crop), the texture is enlarged and shifted so that only the
/// picture shows.
class _VideoView extends StatelessWidget {
  const _VideoView({required this.textureId, required this.picture, required this.size});

  final int textureId;
  final VideoPicture? picture;

  /// The stream's picture size, used until the decoder reports its own.
  final Size? size;

  @override
  Widget build(BuildContext context) {
    final p = picture;
    final width = p?.width.toDouble() ?? size?.width ?? 16;
    final height = p?.height.toDouble() ?? size?.height ?? 9;
    final texture = Texture(textureId: textureId, filterQuality: FilterQuality.medium);
    return Center(
      child: AspectRatio(
        aspectRatio: width / height,
        child: p == null || !p.cropped
            ? texture
            : ClipRect(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final sx = box.maxWidth / p.width;
                    final sy = box.maxHeight / p.height;
                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Positioned(left: -p.cropLeft * sx, top: -p.cropTop * sy, width: p.textureWidth * sx, height: p.textureHeight * sy, child: texture),
                      ],
                    );
                  },
                ),
              ),
      ),
    );
  }
}
