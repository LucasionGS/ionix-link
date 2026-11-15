import "package:flutter/foundation.dart";
import "package:material_ui/material_ui.dart";

import "../../../link/link.dart";
import "../../theme.dart";
import "../../widgets/window_layout.dart";
import "desktop_session.dart";

/// The small tab on the window's edge that opens the control sheet. It sits on the left or right edge, can be dragged
/// up and down (and across to the other side), remembers where it was left, and keeps out of the cutout, the system
/// insets and the fold.
class DesktopHandle extends StatefulWidget {
  const DesktopHandle({super.key, required this.session, required this.onTap});

  final DesktopSession session;
  final VoidCallback onTap;

  @override
  State<DesktopHandle> createState() => _DesktopHandleState();
}

class _DesktopHandleState extends State<DesktopHandle> {
  static const double _length = 56;
  static const double _thickness = 12;
  static const double _hit = 36;

  late bool _right;
  late double _pos;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    final saved = widget.session.handle;
    _right = saved.right;
    _pos = saved.pos;
  }

  /// The vertical range the handle may use: inside the insets, and not across a horizontal fold.
  ({double top, double bottom}) _range(WindowLayout layout, EdgeInsets padding) {
    return (top: padding.top + 8, bottom: layout.size.height - padding.bottom - 8);
  }

  double _top(WindowLayout layout, EdgeInsets padding) {
    final range = _range(layout, padding);
    var top = range.top + _pos * (range.bottom - range.top - _length);
    final fold = layout.fold;
    if (fold != null && !layout.hasVerticalFold && top + _length > fold.top - 4 && top < fold.bottom + 4) {
      // On the fold: the half it is nearer to.
      top = (top + _length / 2 < fold.center.dy) ? fold.top - 4 - _length : fold.bottom + 4;
    }
    return top.clamp(range.top, range.bottom - _length);
  }

  void _drag(DragUpdateDetails details, WindowLayout layout, EdgeInsets padding) {
    final range = _range(layout, padding);
    final span = range.bottom - range.top - _length;
    if (span <= 0) return;
    setState(() {
      _dragging = true;
      _right = details.globalPosition.dx > layout.size.width / 2;
      _pos = ((details.globalPosition.dy - _length / 2 - range.top) / span).clamp(0.0, 1.0);
    });
  }

  void _dragEnd() {
    setState(() => _dragging = false);
    widget.session.setHandle(right: _right, pos: _pos).catchError((Object e) => debugPrint("ionix-link: handle: $e"));
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final layout = WindowLayout.of(context);
    final padding = MediaQuery.paddingOf(context);
    final top = _top(layout, padding);
    final edge = _right ? layout.size.width - padding.right : padding.left;
    return Positioned(
      top: top,
      left: _right ? null : edge,
      right: _right ? layout.size.width - edge : null,
      width: _hit,
      height: _length,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onPanUpdate: (details) => _drag(details, layout, padding),
        onPanEnd: (_) => _dragEnd(),
        onPanCancel: _dragEnd,
        child: Align(
          alignment: _right ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedOpacity(
            opacity: _dragging ? 1 : 0.55,
            duration: const Duration(milliseconds: 150),
            child: Container(
              width: _thickness,
              height: _length,
              decoration: t.bar(radius: _thickness / 2),
              child: Center(child: Container(width: 3, height: 20, decoration: BoxDecoration(color: t.accentLight, borderRadius: BorderRadius.circular(2)))),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the page needs from the sheet's buttons.
class DesktopSheetActions {
  const DesktopSheetActions({required this.keyboardUp, required this.toggleKeyboard, required this.leave});

  /// Whether the phone's keyboard is up.
  final ValueListenable<bool> keyboardUp;
  final VoidCallback toggleKeyboard;
  final VoidCallback leave;
}

/// The compact control sheet: Home, Overview, Keyboard, the UI size, stream stats and Leave.
Future<void> showDesktopSheet(BuildContext context, DesktopSession session, DesktopSheetActions actions) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 420),
    builder: (context) => _DesktopSheet(session: session, actions: actions),
  );
}

class _DesktopSheet extends StatefulWidget {
  const _DesktopSheet({required this.session, required this.actions});

  final DesktopSession session;
  final DesktopSheetActions actions;

  @override
  State<_DesktopSheet> createState() => _DesktopSheetState();
}

class _DesktopSheetState extends State<_DesktopSheet> {
  late double _uiSize = widget.session.uiSize;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final session = widget.session;
    return Padding(
      padding: EdgeInsets.fromLTRB(IonixSpace.lg, 0, IonixSpace.lg, IonixSpace.lg + MediaQuery.paddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (session.hasNav) ...[
                Expanded(child: _Action(icon: Icons.home_outlined, label: "Home", onTap: () => _nav(DesktopClient.navHome))),
                const SizedBox(width: IonixSpace.sm),
                Expanded(child: _Action(icon: Icons.view_carousel_outlined, label: "Overview", onTap: () => _nav(DesktopClient.navOverview))),
                const SizedBox(width: IonixSpace.sm),
              ],
              if (session.hasKeyboard)
                Expanded(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: widget.actions.keyboardUp,
                    builder: (context, up, _) => _Action(
                      icon: Icons.keyboard_outlined,
                      label: "Keyboard",
                      selected: up,
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.actions.toggleKeyboard();
                      },
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: IonixSpace.lg),
          Row(
            children: [
              Expanded(child: Text("Room for windows", style: text.titleMedium)),
              Text("${_uiSize.toStringAsFixed(1)}×", style: text.titleMedium?.copyWith(color: t.accentLight)),
            ],
          ),
          Slider(
            value: _uiSize,
            min: 1.0,
            max: 2.0,
            divisions: 10,
            onChanged: (value) => setState(() => _uiSize = value),
            // Each change opens the desktop again at the new size, so it is applied when the finger lifts.
            onChangeEnd: (value) => session.setUiSize(value),
          ),
          Text("Higher gives windows more room and makes everything smaller.", style: text.bodySmall?.copyWith(color: t.dim)),
          const SizedBox(height: IonixSpace.lg),
          ListenableBuilder(
            listenable: Listenable.merge([session, session.fps]),
            builder: (context, _) {
              final mode = session.format == ScreenClient.formatH264 ? "H.264" : "JPEG";
              return Text("${session.sizeLabel} · $mode · ${session.fps.value} fps", style: text.labelMedium?.copyWith(color: t.dim));
            },
          ),
          const SizedBox(height: IonixSpace.md),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.actions.leave();
              },
              icon: const Icon(Icons.logout_rounded),
              label: const Text("Leave phone desktop"),
            ),
          ),
        ],
      ),
    );
  }

  void _nav(String action) {
    widget.session.nav(action);
    Navigator.of(context).pop();
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radiusPill),
        onTap: onTap,
        child: Container(
          height: 72,
          decoration: t.pill(selected: selected),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: selected ? t.accentLight : t.textBright),
              const SizedBox(height: IonixSpace.xs),
              Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.textBright)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dismissible notes along the top of the picture about what this desktop cannot do. They are only about
/// capabilities the daemon did not offer, so they show while the picture is live and are not repeated once closed.
class DesktopHints extends StatefulWidget {
  const DesktopHints({super.key, required this.session});

  final DesktopSession session;

  @override
  State<DesktopHints> createState() => _DesktopHintsState();
}

class _DesktopHintsState extends State<DesktopHints> {
  bool _touchDismissed = false;
  bool _imeDismissed = false;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final notes = [
      if (!session.hasTouch && !_touchDismissed)
        (
          key: "touch",
          icon: Icons.touch_app_outlined,
          text: "Touch is off on this desktop until you log out and in again there.",
          dismiss: () => setState(() => _touchDismissed = true),
        ),
      if (session.hasKeyboard && !session.hasIme && !_imeDismissed)
        (
          key: "ime",
          icon: Icons.keyboard_outlined,
          text: "The keyboard will not open by itself on this desktop. Use Keyboard in the menu.",
          dismiss: () => setState(() => _imeDismissed = true),
        ),
    ];
    if (notes.isEmpty) return const SizedBox.shrink();
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(IonixSpace.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final note in notes)
              Container(
                key: ValueKey("hint-${note.key}"),
                margin: const EdgeInsets.only(bottom: IonixSpace.sm),
                padding: const EdgeInsets.fromLTRB(IonixSpace.md, IonixSpace.xs, IonixSpace.xs, IonixSpace.xs),
                decoration: t.glass(),
                child: Row(
                  children: [
                    Icon(note.icon, color: t.accentLight, size: 20),
                    const SizedBox(width: IonixSpace.sm),
                    Expanded(child: Text(note.text, style: text.bodyMedium)),
                    IconButton(onPressed: note.dismiss, icon: const Icon(Icons.close_rounded), tooltip: "Dismiss"),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A plain sentence over the picture with a way back: shown while the desktop is not live.
class DesktopNotice extends StatelessWidget {
  const DesktopNotice({super.key, required this.session, required this.leave});

  final DesktopSession session;
  final VoidCallback leave;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final phase = session.phase;
    final working = phase == DesktopPhase.starting || phase == DesktopPhase.reconnecting;
    final (title, icon) = switch (phase) {
      DesktopPhase.starting => ("Opening the phone desktop…", Icons.desktop_windows_outlined),
      DesktopPhase.reconnecting => ("Connection lost", Icons.wifi_off_rounded),
      DesktopPhase.closedByDesktop => ("Phone desktop closed", Icons.desktop_access_disabled_outlined),
      DesktopPhase.busy => ("Already in use", Icons.phonelink_lock_outlined),
      DesktopPhase.unavailable => ("Not available", Icons.desktop_access_disabled_outlined),
      DesktopPhase.failed => ("The picture stopped", Icons.error_outline_rounded),
      DesktopPhase.live => ("", Icons.check),
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          margin: const EdgeInsets.all(IonixSpace.lg),
          padding: const EdgeInsets.all(IonixSpace.lg),
          decoration: t.glass(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (working) const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)) else Icon(icon, color: t.accentLight, size: 32),
              const SizedBox(height: IonixSpace.md),
              Text(title, textAlign: TextAlign.center, style: text.titleMedium),
              if (session.message != null) ...[
                const SizedBox(height: IonixSpace.xs),
                Text(session.message!, textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: t.dim)),
              ],
              const SizedBox(height: IonixSpace.lg),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: IonixSpace.sm,
                runSpacing: IonixSpace.sm,
                children: [
                  if (!working) FilledButton(onPressed: session.reopen, child: const Text("Try again")),
                  OutlinedButton(onPressed: leave, child: const Text("Back to the app")),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
