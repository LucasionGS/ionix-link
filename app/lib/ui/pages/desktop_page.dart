import "dart:async";

import "package:flutter/services.dart";
import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../../platform/link_platform.dart";
import "../theme.dart";
import "../widgets/adaptive_scaffold.dart";
import "desktop/desktop_controls.dart";
import "desktop/desktop_keyboard.dart";
import "desktop/desktop_session.dart";
import "desktop/touch_tracker.dart";

/// Phone desktop: a monitor of the phone's own on the desktop, shown over the whole window as live video and
/// touched with real multitouch, so the desktop behaves like a phone OS. Always full screen and immersive, on every
/// orientation, spanning a fold.
///
/// What runs lives in a [DesktopSession] kept by the [ShellController], so a fold, an unfold or a rotation moves the
/// page and resizes the desktop (after a short pause, over the last picture) without ever closing it. The picture is
/// drawn in the root overlay through an [OverlayPortal], like the screen viewer's full screen.
///
/// Touch: a raw [Listener] over the picture, no gesture recognisers. Every finger that is down goes to the desktop as
/// a set, normalised to the picture, and the desktop interprets them. The keyboard is the system's, opened when the
/// desktop's focused field asks, and it floats over the picture: the desktop is not resized or panned for it.
class DesktopPage extends StatefulWidget {
  const DesktopPage({super.key});

  @override
  State<DesktopPage> createState() => _DesktopPageState();
}

class _DesktopPageState extends State<DesktopPage> with WidgetsBindingObserver {
  final OverlayPortalController _portal = OverlayPortalController();
  final ValueNotifier<bool> _keyboardUp = ValueNotifier(false);
  late final TouchTracker _touches = TouchTracker((touches) => _session?.touch(touches));
  late final DesktopKeyboard _keyboard = DesktopKeyboard(
    onCommit: (text, deleteBefore) => _session?.commit(text, deleteBefore),
    onEnter: () => _session?.enter(),
    onClosed: () => _keyboardUp.value = false,
  );

  ShellController? _shell;
  DesktopSession? _session;
  ({Size size, double dpr})? _reported;
  Size _box = Size.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = ShellScope.of(context);
    if (identical(shell, _shell)) return;
    _shell?.backHandler = null;
    _shell = shell;
    final session = shell.desktopSession ??= DesktopSession();
    _session?.textInput.removeListener(_onTextInput);
    _session?.removeListener(_onSession);
    _session?.detach();
    _session = session
      ..attach()
      ..textInput.addListener(_onTextInput)
      ..addListener(_onSession);
    shell.backHandler = _onBack;
    if (session.textInput.value != null) scheduleMicrotask(_onTextInput);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _portal.show();
      _applySystemUi(true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _touches.clear();
    _keyboard.hide();
    final shell = _shell;
    final session = _session;
    if (shell != null && shell.backHandler == _onBack) shell.backHandler = null;
    session?.textInput.removeListener(_onTextInput);
    session?.removeListener(_onSession);
    final alone = session?.detach() ?? true;
    // A fold or unfold disposes this state and builds another in the same frame; only a page that is really gone
    // (another page opened, the dashboard shown) ends the desktop.
    if (session != null && alone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (shell!.desktopSession != session || session.left) return;
        if (session.hasPages || shell.openPlugin == LinkPlugins.desktop) return;
        _end(shell, session);
      });
    }
    super.dispose();
  }

  static Future<void> _end(ShellController shell, DesktopSession session) async {
    shell.desktopSession = null;
    await _applySystemUi(false);
    await session.leave();
  }

  static Future<void> _applySystemUi(bool immersive) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(const []);
    } catch (e) {
      debugPrint("Could not change the system bars: $e");
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = _session;
    if (session == null) return;
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _touches.clear();
      session.suspend();
    }
    else if (state == AppLifecycleState.resumed) {
      session.resume();
      if (!session.suspended) _applySystemUi(true);
    }
  }

  void _onSession() {
    // Fingers that were down when the picture went away would otherwise stay down on the desktop.
    final session = _session;
    if (session != null && session.phase != DesktopPhase.live && session.phase != DesktopPhase.starting) _touches.clear();
  }

  void _onTextInput() {
    final input = _session?.textInput.value;
    if (input == null) {
      _keyboard.hide();
      _keyboardUp.value = false;
    }
    else {
      _keyboard.show(input.purpose);
      _keyboardUp.value = true;
    }
  }

  void _toggleKeyboard() {
    if (_keyboard.isShown) {
      _keyboard.hide();
      _keyboardUp.value = false;
    }
    else {
      _keyboard.show(_session?.textInput.value?.purpose ?? DesktopTextPurpose.normal);
      _keyboardUp.value = true;
    }
  }

  void _onBack() {
    final session = _session;
    if (session == null) return;
    if (session.phase == DesktopPhase.live) {
      session.nav(DesktopClient.navBack);
    }
    else {
      _leave();
    }
  }

  void _leave() {
    final shell = _shell;
    final session = _session;
    if (shell == null || session == null) return;
    _touches.clear();
    _keyboard.hide();
    _keyboardUp.value = false;
    _portal.hide();
    shell.backHandler = null;
    _end(shell, session);
    shell.closePlugin();
  }

  /// The rectangle the picture takes inside the window: the frame fitted (contained) to it. The desktop is made the
  /// window's own size, so this is the whole window except for a rounding sliver, or while a resize is under way.
  static Rect fitted(Size box, Size picture) {
    final aspect = picture.width / picture.height;
    var w = box.width;
    var h = w / aspect;
    if (h > box.height) {
      h = box.height;
      w = h * aspect;
    }
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Rect? _pictureRect() {
    final picture = _session?.pictureSize;
    if (picture == null || picture.isEmpty || _box.isEmpty) return null;
    return fitted(_box, picture);
  }

  void _pointer(void Function(Rect picture) apply) {
    final rect = _pictureRect();
    if (rect == null || _session?.phase == DesktopPhase.closedByDesktop) return;
    apply(rect);
  }

  Future<void> _openSheet() {
    return showDesktopSheet(context, _session!, DesktopSheetActions(keyboardUp: _keyboardUp, toggleKeyboard: _toggleKeyboard, leave: _leave));
  }

  void _report(Size size, double dpr) {
    final last = _reported;
    if (last != null && last.size == size && last.dpr == dpr) return;
    _reported = (size: size, dpr: dpr);
    // After the frame: reporting may open the desktop, which notifies listeners that are building right now.
    WidgetsBinding.instance.addPostFrameCallback((_) => _session?.setWindow(size, dpr));
  }

  Widget _overlay(BuildContext context) {
    final root = MediaQuery.of(Overlay.of(context, rootOverlay: true).context);
    return MediaQuery(
      data: root,
      child: Builder(
        builder: (context) {
          final t = IonixTokens.of(context);
          final session = _session!;
          final size = MediaQuery.sizeOf(context);
          _box = size;
          _report(size, MediaQuery.devicePixelRatioOf(context));
          return Material(
            color: t.bgDeep,
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) => Stack(
                fit: StackFit.expand,
                children: [
                  Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => _pointer((rect) => _touches.down(e.pointer, e.localPosition, rect)),
                    onPointerMove: (e) => _pointer((rect) => _touches.move(e.pointer, e.localPosition, rect)),
                    onPointerUp: (e) => _touches.up(e.pointer, _pictureRect() ?? Rect.zero),
                    onPointerCancel: (e) => _touches.up(e.pointer, _pictureRect() ?? Rect.zero),
                    child: _Picture(session: session, box: size),
                  ),
                  if (session.phase != DesktopPhase.live) ...[
                    // The last picture stays under a message; it is dimmed so the message reads as the state.
                    IgnorePointer(child: ColoredBox(color: t.bgDeep.withValues(alpha: session.pictureSize == null ? 1 : 0.6))),
                    DesktopNotice(session: session, leave: _leave),
                  ],
                  if (session.phase == DesktopPhase.live) Positioned(top: 0, left: 0, right: 0, child: DesktopHints(session: session)),
                  DesktopHandle(key: const ValueKey("handle"), session: session, onTap: _openSheet),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: _overlay,
      child: ColoredBox(color: t.bgDeep, child: const SizedBox.expand()),
    );
  }
}

/// The desktop's picture in its fitted rectangle: the video texture, or the newest JPEG frame.
class _Picture extends StatelessWidget {
  const _Picture({required this.session, required this.box});

  final DesktopSession session;
  final Size box;

  @override
  Widget build(BuildContext context) {
    final size = session.pictureSize;
    if (size == null || size.isEmpty) return const SizedBox.expand();
    final rect = _DesktopPageState.fitted(box, size);
    final Widget? content;
    if (session.isVideo) {
      final decoder = session.decoder!;
      content = session.videoShown ? _VideoView(textureId: decoder.textureId, picture: decoder.picture.value) : null;
    }
    else {
      content = ValueListenableBuilder<ScreenFrame?>(
        valueListenable: session.frame,
        builder: (context, frame, _) => frame == null ? const SizedBox.shrink() : Image.memory(frame.bytes, gaplessPlayback: true, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
      );
    }
    return Stack(
      children: [
        if (content != null) Positioned.fromRect(rect: rect, child: content),
      ],
    );
  }
}

/// A video texture filling its box. When the texture holds more than the picture (decoders work in 16-px blocks, and
/// not every renderer applies the crop), the texture is enlarged and shifted so that only the picture shows.
class _VideoView extends StatelessWidget {
  const _VideoView({required this.textureId, required this.picture});

  final int textureId;
  final VideoPicture? picture;

  @override
  Widget build(BuildContext context) {
    final p = picture;
    final texture = Texture(textureId: textureId, filterQuality: FilterQuality.medium);
    if (p == null || !p.cropped) return texture;
    return ClipRect(
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
    );
  }
}
