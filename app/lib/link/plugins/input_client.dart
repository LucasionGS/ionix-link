import "dart:async";
import "dart:convert";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "plugin_client.dart";

/// `input.*`: remote touchpad and keyboard (`PROTOCOL.md` 8.5). Pointer calls are fire-and-forget and silently do
/// nothing while unavailable, so a gesture handler can call them at frame rate without checks.
///
/// Motion is coalesced: [move], [scroll] and [moveAbsolute] only update what is pending, and a timer sends it at most
/// [LinkProtocol.maxMoveRate] times per second. A tick also waits while the connection still has unsent bytes
/// ([LinkConnection.pendingWriteBytes]), so a slow link sends fewer, larger moves instead of queueing stale ones.
/// Buttons are never dropped or delayed: they send any pending motion first, then themselves.
class InputClient extends PluginClient {
  // Message types
  static const String typeMove = "input.move";
  static const String typeMoveAbsolute = "input.moveAbsolute";
  static const String typeButton = "input.button";
  static const String typeScroll = "input.scroll";
  static const String typeText = "input.text";
  static const String typeKey = "input.key";

  /// Daemon cap: virtual pointer.
  static const String capPointer = "pointer";

  /// Daemon cap: keyboard (wtype).
  static const String capKeyboard = "keyboard";

  /// A tick holds its motion back while more than this many bytes wait to be written.
  static const int _backlogLimit = 512;

  static final Duration _interval = Duration(microseconds: 1000000 ~/ LinkProtocol.maxMoveRate);

  @override
  String get name => LinkPlugins.input;

  double _dx = 0;
  double _dy = 0;
  double _scrollX = 0;
  double _scrollY = 0;
  _AbsoluteMove? _absolute;
  Timer? _timer;
  final Stopwatch _sinceSent = Stopwatch();

  /// Whether pointer messages do anything.
  bool get hasPointer => hasCap(capPointer);

  /// Whether [text] and [key] work.
  bool get hasKeyboard => hasCap(capKeyboard);

  /// Relative move in logical px. Accumulated and flushed at most [LinkProtocol.maxMoveRate] times per second.
  void move(double dx, double dy) {
    if (!hasPointer || !dx.isFinite || !dy.isFinite) return;
    _dx += dx;
    _dy += dy;
    _schedule();
  }

  /// Move to a normalised point (0..1) on [output], for tap-to-click in the screen viewer. Flushes pending moves.
  /// Relative motion still pending is dropped, since the absolute position replaces it; repeated absolute moves are
  /// coalesced to the latest.
  void moveAbsolute(String output, double x, double y) {
    if (!hasPointer || !x.isFinite || !y.isFinite) return;
    _dx = 0;
    _dy = 0;
    _absolute = _AbsoluteMove(output, x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    _schedule();
  }

  /// Press, release or click [button]. Flushes pending moves first so the click lands where the pointer is.
  void button(PointerButton button, ButtonAction action) {
    if (!hasPointer) return;
    _flush(force: true);
    _push(typeButton, {"button": button.name, "action": action.name});
  }

  /// Shorthand for `button(button, ButtonAction.click)`.
  void click([PointerButton button = PointerButton.left]) => this.button(button, ButtonAction.click);

  /// Scroll in px-equivalent units; positive [dy] scrolls down. Coalesced like [move].
  void scroll(double dx, double dy) {
    if (!hasPointer || !dx.isFinite || !dy.isFinite) return;
    _scrollX += dx;
    _scrollY += dy;
    _schedule();
  }

  /// Type [text] on the desktop.
  /// @throws LinkFormatException if [text] exceeds [LinkProtocol.maxText] bytes as UTF-8.
  Future<void> text(String text) async {
    _requireKeyboard();
    if (utf8.encode(text).length > LinkProtocol.maxText) {
      throw LinkFormatException("The text is too long to type; the limit is 512 KiB.");
    }
    final body = await request(typeText, {"text": text});
    if (body["ok"] != true) throw LinkException("The desktop could not type the text.");
  }

  /// Press one key (an XKB keysym name such as `Return`) with [modifiers] held.
  Future<void> key(String keysym, {Set<KeyModifier> modifiers = const {}}) async {
    _requireKeyboard();
    final body = await request(typeKey, {
      "key": keysym,
      if (modifiers.isNotEmpty) "modifiers": [for (final modifier in modifiers) modifier.wire],
    });
    if (body["ok"] != true) throw LinkException("The desktop could not press $keysym.");
  }

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    _sinceSent
      ..reset()
      ..start();
  }

  @override
  void onDetach() {
    _timer?.cancel();
    _timer = null;
    _dx = 0;
    _dy = 0;
    _scrollX = 0;
    _scrollY = 0;
    _absolute = null;
  }

  void _requireKeyboard() {
    if (!isAvailable) throw LinkPluginUnavailableException(name);
    if (!hasKeyboard) {
      throw LinkException("The desktop cannot type: `wtype` is not installed there.", code: LinkErrorCode.pluginUnavailable);
    }
  }

  bool get _hasPending => _dx != 0 || _dy != 0 || _scrollX != 0 || _scrollY != 0 || _absolute != null;

  void _schedule() {
    if (_timer != null) return;
    final wait = _interval - _sinceSent.elapsed;
    if (wait <= Duration.zero) {
      _flush(force: false);
      if (_hasPending) _timer = Timer(_interval, _tick);
      return;
    }
    _timer = Timer(wait, _tick);
  }

  void _tick() {
    _timer = null;
    _flush(force: false);
    // Still pending: the link was backed up. Look again after another interval, with whatever has added up.
    if (_hasPending) _timer = Timer(_interval, _tick);
  }

  /// Send what is pending. Unless [force], wait while the connection is backed up.
  void _flush({required bool force}) {
    if (!_hasPending) return;
    final connection = this.connection;
    if (connection == null || !connection.isOpen) {
      onDetach();
      return;
    }
    if (!force && connection.pendingWriteBytes > _backlogLimit) return;
    final absolute = _absolute;
    if (absolute != null) {
      _push(typeMoveAbsolute, {"output": absolute.output, "x": absolute.x, "y": absolute.y});
      _absolute = null;
    }
    if (_dx != 0 || _dy != 0) {
      _push(typeMove, {"dx": _dx, "dy": _dy});
      _dx = 0;
      _dy = 0;
    }
    if (_scrollX != 0 || _scrollY != 0) {
      _push(typeScroll, {"dx": _scrollX, "dy": _scrollY});
      _scrollX = 0;
      _scrollY = 0;
    }
    _sinceSent.reset();
  }

  void _push(String type, Map<String, dynamic> body) {
    try {
      send(type, body);
    } on LinkException {
      // Pointer input is best effort: a closing connection drops it.
      return;
    }
  }
}

class _AbsoluteMove {
  const _AbsoluteMove(this.output, this.x, this.y);

  final String output;
  final double x;
  final double y;
}

/// Pointer buttons; [name] is the wire value.
enum PointerButton { left, right, middle }

/// Button actions; [name] is the wire value.
enum ButtonAction { down, up, click }

/// Key modifiers; [wire] is the value sent (`super` is a Dart keyword, hence [superKey]).
enum KeyModifier {
  ctrl("ctrl"),
  alt("alt"),
  shift("shift"),
  superKey("super");

  const KeyModifier(this.wire);

  final String wire;
}
