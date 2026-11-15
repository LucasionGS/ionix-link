import "dart:ui" show Offset, Rect;

import "../../../link/link.dart";

/// The fingers that are down on the Phone desktop's picture, as the protocol wants them: ids 0..9 from a free list
/// (stable while a finger stays down, reused after it lifts) and positions normalised to the picture's rectangle.
///
/// No gesture recognition: every pointer event updates the map and [changed] gets the whole set, because the desktop
/// is the one that interprets the touches.
class TouchTracker {
  TouchTracker(this.changed);

  /// Called with every finger that is down now, after each event that changes anything; `[]` when none is left.
  final void Function(List<DesktopTouch> touches) changed;

  final Map<int, _Finger> _fingers = {}; // pointer -> finger
  final List<int> _free = [for (var i = 0; i < DesktopClient.maxTouches; i++) i];

  /// How many fingers are down.
  int get count => _fingers.length;

  /// A finger went down at [local]. Ignored when all ten slots are used.
  void down(int pointer, Offset local, Rect picture) {
    if (_fingers.containsKey(pointer) || _free.isEmpty) return;
    _fingers[pointer] = _Finger(_free.removeAt(0), local);
    _emit(picture);
  }

  void move(int pointer, Offset local, Rect picture) {
    final finger = _fingers[pointer];
    if (finger == null || finger.at == local) return;
    finger.at = local;
    _emit(picture);
  }

  /// A finger lifted, or its pointer was cancelled: either way it is no longer down.
  void up(int pointer, Rect picture) {
    final finger = _fingers.remove(pointer);
    if (finger == null) return;
    _free
      ..add(finger.id)
      ..sort();
    _emit(picture);
  }

  /// Lift everything (the page goes, the app pauses). Sends `[]` when there was anything to lift.
  void clear() {
    if (_fingers.isEmpty) return;
    _fingers.clear();
    _free
      ..clear()
      ..addAll([for (var i = 0; i < DesktopClient.maxTouches; i++) i]);
    changed(const []);
  }

  void _emit(Rect picture) {
    if (_fingers.isEmpty) {
      changed(const []);
      return;
    }
    if (picture.isEmpty) return;
    changed([
      for (final finger in _fingers.values)
        DesktopTouch(
          finger.id,
          ((finger.at.dx - picture.left) / picture.width).clamp(0.0, 1.0),
          ((finger.at.dy - picture.top) / picture.height).clamp(0.0, 1.0),
        ),
    ]);
  }
}

class _Finger {
  _Finger(this.id, this.at);

  final int id;
  Offset at;
}
