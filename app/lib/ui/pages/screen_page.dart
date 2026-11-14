import "dart:async";

import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "../widgets/empty_state.dart";
import "../widgets/floating_bar.dart";
import "../widgets/fold_split.dart";
import "../widgets/ion_page.dart";
import "../widgets/touchpad.dart";

/// Screen viewer: output picker, then the desktop's frames painted with `Image.memory(gaplessPlayback: true)` and
/// acknowledged once shown; a tap is a click at that spot, a drag moves the pointer there, a pinch zooms, and two
/// fingers scroll (or pan when zoomed in). The stream stops when the page goes away. In tabletop posture the picture
/// is on the upright half and a touchpad with keys on the flat one.
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

class _ScreenPageState extends State<ScreenPage> {
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

  @override
  void initState() {
    super.initState();
    _frames = _screen.frames.listen((frame) {
      _framesThisSecond++;
      if (mounted) setState(() => _frame = frame);
    });
    _stopped = _screen.stopped.listen((reason) {
      if (!mounted) return;
      setState(() => _frame = null);
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
    _loadOutputs();
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _frames?.cancel();
    _stopped?.cancel();
    _screen.stop().catchError((_) {});
    super.dispose();
  }

  Future<void> _loadOutputs() async {
    try {
      final outputs = await _screen.outputs();
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
    setState(() {
      _output = output;
      _starting = true;
      _frame = null;
      _ackedSeq = -1;
      _zoom = 1;
      _pan = Offset.zero;
    });
    try {
      final q = _qualities[_quality];
      await _screen.start(output, scale: q.scale, quality: q.quality, maxFps: _fps);
    } on LinkException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _ack(int seq) {
    if (_ackedSeq == seq) return;
    _ackedSeq = seq;
    WidgetsBinding.instance.addPostFrameCallback((_) => _screen.ack(seq));
  }

  // The rectangle the picture occupies inside the viewer before zoom: the frame fitted to the viewer.
  Rect _fitted(Size view, ScreenFrame frame) {
    final aspect = frame.width / frame.height;
    var w = view.width;
    var h = w / aspect;
    if (h > view.height) {
      h = view.height;
      w = h * aspect;
    }
    return Rect.fromLTWH((view.width - w) / 2, (view.height - h) / 2, w, h);
  }

  Offset? _toNormalised(Offset local) {
    final frame = _frame;
    if (frame == null || _viewSize.isEmpty) return null;
    final center = _viewSize.center(Offset.zero);
    final unzoomed = center + (local - center - _pan) / _zoom;
    final rect = _fitted(_viewSize, frame);
    return Offset(((unzoomed.dx - rect.left) / rect.width).clamp(0.0, 1.0), ((unzoomed.dy - rect.top) / rect.height).clamp(0.0, 1.0));
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

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final outputs = _outputs;
    final Widget viewer;
    if (_error != null) {
      viewer = EmptyState(icon: Icons.desktop_access_disabled_outlined, title: "Can't list the screens", message: _error, actionLabel: "Try again", action: _loadOutputs);
    }
    else if (outputs == null) {
      viewer = const Center(child: CircularProgressIndicator());
    }
    else if (outputs.isEmpty) {
      viewer = const EmptyState(icon: Icons.desktop_access_disabled_outlined, title: "No screens found", message: "Your desktop didn't report any display to show.");
    }
    else {
      viewer = _Viewer(
        frame: _frame,
        starting: _starting,
        fps: _shownFps,
        zoom: _zoom,
        pan: _pan,
        onSize: (s) => _viewSize = s,
        onAck: _ack,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onTapUp: _onTapUp,
      );
    }

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

    final pad = Padding(
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

    return IonPage(
      title: "Screen",
      plugin: true,
      actions: [BarPill(icon: Icons.tune_rounded, tooltip: "Picture options", onTap: _output == null ? null : _showOptions)],
      body: FoldSplit(
        top: Column(children: [picker, Expanded(child: Padding(padding: const EdgeInsets.all(IonixSpace.md), child: viewer))]),
        bottom: pad,
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
    );
  }
}

class _Viewer extends StatelessWidget {
  const _Viewer({
    required this.frame,
    required this.starting,
    required this.fps,
    required this.zoom,
    required this.pan,
    required this.onSize,
    required this.onAck,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onTapUp,
  });

  final ScreenFrame? frame;
  final bool starting;
  final int fps;
  final double zoom;
  final Offset pan;
  final ValueChanged<Size> onSize;
  final ValueChanged<int> onAck;
  final GestureScaleStartCallback onScaleStart;
  final GestureScaleUpdateCallback onScaleUpdate;
  final GestureTapUpCallback onTapUp;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: t.bgDeep, borderRadius: t.rSm, border: Border.all(color: t.accentBright.withValues(alpha: 0.25))),
      child: ClipRRect(
        borderRadius: t.rSm,
        child: LayoutBuilder(
          builder: (context, constraints) {
            onSize(constraints.biggest);
            final f = frame;
            if (f == null) {
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
                    child: Image.memory(
                      f.bytes,
                      gaplessPlayback: true,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      frameBuilder: (context, child, frameNumber, sync) {
                        if (frameNumber != null || sync) onAck(f.seq);
                        return child;
                      },
                      errorBuilder: (context, error, stack) {
                        onAck(f.seq);
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: t.bgDeep.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(8)),
                      child: Text("${f.width}×${f.height} · $fps fps${zoom > 1.01 ? " · ${zoom.toStringAsFixed(1)}×" : ""}", style: Theme.of(context).textTheme.labelSmall?.copyWith(color: t.textBright, fontSize: 11)),
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
