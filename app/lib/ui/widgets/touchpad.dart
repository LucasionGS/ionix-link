import "dart:async";

import "package:flutter/services.dart";
import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "../ui_settings.dart";

/// Touchpad surface: one-finger drag moves the pointer (× [sensitivity]), tap is a left click, a two-finger tap a
/// right click, a two-finger drag scrolls, and press-and-hold then drag holds the left button down.
class Touchpad extends StatefulWidget {
  const Touchpad({super.key, this.sensitivity, this.input});

  /// Multiplier from phone logical px to desktop logical px; the setting from [UiSettings] when null.
  final double? sensitivity;

  /// Where gestures go; the link's input plugin when null.
  final InputSource? input;

  @override
  State<Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<Touchpad> {
  static const Duration _tapTime = Duration(milliseconds: 280);
  static const Duration _holdTime = Duration(milliseconds: 420);
  static const double _tapSlop = 14;
  static const double _scrollGain = 1.6;

  final Map<int, Offset> _pointers = {};
  Timer? _hold;
  DateTime _downAt = DateTime.now();
  double _travel = 0;
  int _maxPointers = 0;
  bool _dragging = false;

  InputSource get _input => widget.input ?? UiSources.input;

  @override
  void dispose() {
    _hold?.cancel();
    if (_dragging) _input.button(PointerButton.left, ButtonAction.up);
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      _downAt = DateTime.now();
      _travel = 0;
      _maxPointers = 0;
    }
    _pointers[event.pointer] = event.localPosition;
    _maxPointers = _pointers.length > _maxPointers ? _pointers.length : _maxPointers;
    _hold?.cancel();
    if (_pointers.length == 1) {
      _hold = Timer(_holdTime, () {
        if (_pointers.length == 1 && _travel < _tapSlop) {
          HapticFeedback.mediumImpact();
          _input.button(PointerButton.left, ButtonAction.down);
          setState(() => _dragging = true);
        }
      });
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    _travel += event.delta.distance;
    if (_pointers.length == 1) {
      if (_dragging || _travel >= _tapSlop) _hold?.cancel();
      if (_dragging || _travel >= 2) _input.move(event.delta.dx * (widget.sensitivity ?? UiSettings.touchSensitivity.value), event.delta.dy * (widget.sensitivity ?? UiSettings.touchSensitivity.value));
    }
    else if (_pointers.length == 2) {
      if (_travel >= _tapSlop) _input.scroll(0, -event.delta.dy / 2 * _scrollGain);
    }
  }

  void _onUp(PointerEvent event) {
    if (_pointers.remove(event.pointer) == null) return;
    _hold?.cancel();
    if (_pointers.isNotEmpty) return;
    if (_dragging) {
      _input.button(PointerButton.left, ButtonAction.up);
      setState(() => _dragging = false);
      return;
    }
    final quick = DateTime.now().difference(_downAt) < _tapTime;
    if (event is PointerUpEvent && quick && _travel < _tapSlop * _maxPointers) {
      if (_maxPointers == 1) {
        _input.button(PointerButton.left, ButtonAction.click);
      }
      else if (_maxPointers == 2) {
        _input.button(PointerButton.right, ButtonAction.click);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: t.glass(selected: _dragging),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(IonixSpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_dragging ? Icons.pan_tool_alt_rounded : Icons.touch_app_outlined, size: 40, color: t.accentLight.withValues(alpha: 0.5)),
                const SizedBox(height: IonixSpace.sm),
                Text(
                  _dragging ? "Dragging" : "Move to point · tap to click",
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: t.dim),
                ),
                if (!_dragging) Text("Two fingers: right click or scroll · hold to drag", textAlign: TextAlign.center, style: text.bodySmall?.copyWith(color: t.dim)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
