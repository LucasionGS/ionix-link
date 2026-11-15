import "dart:async";

import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "../protocol/message.dart";
import "plugin_client.dart";

/// `desktop.*`: a monitor of the phone's own on the desktop (`PROTOCOL.md` 8.11). The picture itself is the
/// `screen` plugin's: start a stream on [DesktopInfo.output] after every [open]. This client opens, resizes and
/// closes the monitor, sends the fingers that are down, and carries the keyboard in both directions.
///
/// [touch] is state, not events: the whole set of fingers each time. A set whose ids differ from the last one sent
/// goes out at once; pure motion is coalesced to at most [LinkProtocol.maxMoveRate] messages per second, and waits
/// while the connection still has unsent bytes, so a slow link sends fewer, newer sets instead of queueing old ones.
class DesktopClient extends PluginClient {
  // Message types
  static const String typeOpen = "desktop.open";
  static const String typeClose = "desktop.close";
  static const String typeClosed = "desktop.closed";
  static const String typeTouch = "desktop.touch";
  static const String typeTextInput = "desktop.textInput";
  static const String typeCommit = "desktop.commit";
  static const String typeNav = "desktop.nav";

  /// Daemon cap: touch input through uinput.
  static const String capTouch = "touch";

  /// Daemon cap: the daemon is the input method, so [textInput] and [commit] work.
  static const String capIme = "ime";

  /// Daemon cap: [nav] reaches the shell.
  static const String capNav = "nav";

  /// `desktop.closed` reasons the desktop sends.
  static const String closedDesktop = "desktop";
  static const String closedFailed = "failed";
  static const String closedShutdown = "shutdown";

  /// `desktop.nav` actions.
  static const String navBack = "back";
  static const String navHome = "home";
  static const String navOverview = "overview";

  /// Most fingers the protocol carries.
  static const int maxTouches = 10;

  /// A tick holds pure motion back while more than this many bytes wait to be written.
  static const int _backlogLimit = 512;

  static final Duration _interval = Duration(microseconds: 1000000 ~/ LinkProtocol.maxMoveRate);

  @override
  String get name => LinkPlugins.desktop;

  final StreamController<String> _closed = StreamController.broadcast();
  final ValueNotifier<DesktopInfo?> _info = ValueNotifier(null);
  final ValueNotifier<DesktopTextInput?> _textInput = ValueNotifier(null);
  List<DesktopTouch> _sent = const [];
  List<DesktopTouch>? _pending;
  Timer? _timer;
  final Stopwatch _sinceSent = Stopwatch();

  /// Whether the desktop can take touch input (`/dev/uinput`). An open desktop says for itself whether its touch
  /// device could be made.
  bool get hasTouch => hasCap(capTouch) && (_info.value?.touch ?? true);

  /// Whether the desktop's input method is available: [textInput] arrives. The cap only says the compositor has one;
  /// whether the seat was free is known once a desktop is open.
  bool get hasIme => hasCap(capIme) && (_info.value?.ime ?? true);

  /// Whether the desktop's shell answers [nav].
  bool get hasNav => hasCap(capNav);

  /// The open desktop as the last [open] reply described it, null while there is none (closed, [closed] pushed, or
  /// the connection went).
  ValueListenable<DesktopInfo?> get info => _info;

  /// The focused text field on the phone's desktop, or null while none has focus. The phone shows its keyboard for
  /// it.
  ValueListenable<DesktopTextInput?> get textInput => _textInput;

  /// Reasons of `desktop.closed` pushes (`desktop`, `failed`, `shutdown`). Not sent for [close]. Broadcast.
  Stream<String> get closed => _closed.stream;

  /// Create the phone's monitor, or resize it when it exists. The desktop moves [scale] to the nearest one that
  /// gives whole logical pixels, so read it back from the reply.
  /// @param width Pixels, 320..4096, even.
  /// @param height Pixels, 320..4096, even.
  /// @param scale 1.0..4.0.
  /// @param refresh 30 or 60 Hz.
  /// @throws LinkRemoteException with `busy` when another phone has the desktop, `unavailable` when the output could
  /// not be made, `invalid_argument` for a value out of range.
  Future<DesktopInfo> open({required int width, required int height, required double scale, int refresh = 60}) async {
    final body = await request(typeOpen, {"width": width, "height": height, "scale": scale, "refresh": refresh}, const Duration(seconds: 15));
    final info = DesktopInfo.fromJson(body);
    if (isAvailable) _info.value = info;
    return info;
  }

  /// Close the desktop: windows go back to the real monitor. Idempotent.
  Future<void> close() async {
    _clearTouches();
    _info.value = null;
    _textInput.value = null;
    if (!isAvailable) return;
    await request(typeClose);
  }

  /// Set the fingers that are down right now; `[]` lifts them all. Fire and forget, and silent while unavailable, so
  /// a pointer handler can call it at event rate. Ids are 0..9 and stay the same while a finger stays down; at most
  /// [maxTouches] are sent.
  void touch(List<DesktopTouch> touches) {
    if (!isAvailable || !hasTouch) return;
    final next = touches.length > maxTouches ? touches.sublist(0, maxTouches) : List<DesktopTouch>.of(touches);
    if (next.isEmpty && _sent.isEmpty && _pending == null) return;
    // Pending motion always has the ids of the last set sent (a change of ids flushes at once), so compare with that.
    final idsChanged = !_sameIds(next, _sent);
    _pending = next;
    if (next.isEmpty || idsChanged) {
      // Fingers coming or going are never delayed; an empty set is how a stuck finger is lifted.
      _flush(force: true);
      return;
    }
    _schedule();
  }

  /// Commit [text] (and delete [deleteBefore] code points before the cursor first) in the desktop's focused field.
  /// Without the `ime` cap the desktop types it instead. Fire and forget. The desktop takes at most 64 KiB of UTF-8
  /// per commit, so longer text goes as several commits, split between code points, and the deletion goes with the
  /// first.
  void commit({String? text, int deleteBefore = 0}) {
    final parts = text == null || text.isEmpty ? const <String>[""] : splitCommit(text);
    var delete = deleteBefore;
    for (final part in parts) {
      if (part.isEmpty && delete <= 0) return;
      try {
        send(typeCommit, {
          if (part.isNotEmpty) "text": part,
          if (delete > 0) "deleteBefore": delete.clamp(0, 1024),
        });
      } on LinkException {
        return;
      }
      delete = 0;
    }
  }

  /// [text] cut into pieces of at most [maxBytes] UTF-8 bytes, only ever between code points. One piece when it fits.
  @visibleForTesting
  static List<String> splitCommit(String text, {int maxBytes = _maxCommit}) {
    final parts = <String>[];
    var start = 0;
    var bytes = 0;
    var i = 0;
    while (i < text.length) {
      final unit = text.codeUnitAt(i);
      final isPair = unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length && (text.codeUnitAt(i + 1) & 0xFC00) == 0xDC00;
      // A lone surrogate is encoded as U+FFFD, three bytes, like any other BMP character above 0x7FF.
      final width = unit < 0x80 ? 1 : (unit < 0x800 ? 2 : (isPair ? 4 : 3));
      if (bytes + width > maxBytes) {
        parts.add(text.substring(start, i));
        start = i;
        bytes = 0;
      }
      bytes += width;
      i += isPair ? 2 : 1;
    }
    parts.add(text.substring(start));
    return parts;
  }

  /// Ask the desktop's shell for `back`, `home` or `overview`. Fire and forget.
  void nav(String action) {
    try {
      send(typeNav, {"action": action});
    } on LinkException {
      return;
    }
  }

  static const int _maxCommit = 64 * 1024;

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    _sinceSent
      ..reset()
      ..start();
    listen(typeClosed, (message) {
      final reason = JsonRead.optString(message.body, "reason") ?? closedDesktop;
      _info.value = null;
      _textInput.value = null;
      _clearTouches();
      _closed.add(reason);
    });
    listen(typeTextInput, _onTextInput);
  }

  @override
  void onDetach() {
    // The desktop lifts the fingers and keeps the monitor for its grace period; this side starts again from nothing.
    _clearTouches();
    _info.value = null;
    _textInput.value = null;
  }

  void _onTextInput(LinkMessage message) {
    if (JsonRead.optBool(message.body, "active") != true) {
      _textInput.value = null;
      return;
    }
    _textInput.value = DesktopTextInput(DesktopTextPurpose.fromWire(JsonRead.optString(message.body, "purpose")));
  }

  void _clearTouches() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _sent = const [];
  }

  static bool _sameIds(List<DesktopTouch> a, List<DesktopTouch> b) {
    if (a.length != b.length) return false;
    final ids = {for (final touch in b) touch.id};
    for (final touch in a) {
      if (!ids.contains(touch.id)) return false;
    }
    return true;
  }

  void _schedule() {
    if (_timer != null) return;
    final wait = _interval - _sinceSent.elapsed;
    if (wait <= Duration.zero) {
      _flush(force: false);
      if (_pending != null) _timer = Timer(_interval, _tick);
      return;
    }
    _timer = Timer(wait, _tick);
  }

  void _tick() {
    _timer = null;
    _flush(force: false);
    if (_pending != null) _timer = Timer(_interval, _tick);
  }

  void _flush({required bool force}) {
    final pending = _pending;
    if (pending == null) return;
    final connection = this.connection;
    if (connection == null || !connection.isOpen) {
      _clearTouches();
      return;
    }
    if (!force && connection.pendingWriteBytes > _backlogLimit) return;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _sent = pending;
    _sinceSent.reset();
    try {
      send(typeTouch, {
        "touches": [for (final touch in pending) touch.toJson()],
      });
    } on LinkException {
      return;
    }
  }
}

/// The `desktop.open` reply: the monitor as the compositor made it.
class DesktopInfo {
  const DesktopInfo({required this.output, required this.width, required this.height, required this.scale, required this.logicalWidth, required this.logicalHeight, required this.created, this.touch = true, this.ime = true});

  /// Output name (`IONIX-LINK-1`), the handle for [ScreenClient.start].
  final String output;

  /// Pixel size.
  final int width;
  final int height;

  /// The scale the compositor applied, which may differ from the one asked for.
  final double scale;

  /// Size in logical px, what the desktop's windows see.
  final int logicalWidth;
  final int logicalHeight;

  /// False when an existing desktop was resized (or found again after a reconnect).
  final bool created;

  /// Whether this desktop takes touches and has the input method. An older daemon says neither, which means yes.
  final bool touch;
  final bool ime;

  /// Throws [LinkFormatException] on a missing field.
  static DesktopInfo fromJson(Map<String, dynamic> json) {
    return DesktopInfo(
      output: JsonRead.string(json, "output"),
      width: JsonRead.integer(json, "width"),
      height: JsonRead.integer(json, "height"),
      scale: JsonRead.optNumber(json, "scale") ?? 1.0,
      logicalWidth: JsonRead.optInt(json, "logicalWidth") ?? JsonRead.integer(json, "width"),
      logicalHeight: JsonRead.optInt(json, "logicalHeight") ?? JsonRead.integer(json, "height"),
      created: JsonRead.optBool(json, "created") ?? true,
      touch: JsonRead.optBool(json, "touch") ?? true,
      ime: JsonRead.optBool(json, "ime") ?? true,
    );
  }
}

/// One finger: [id] 0..9, stable while it stays down; [x] and [y] 0..1 within the output, 0,0 top left.
class DesktopTouch {
  const DesktopTouch(this.id, this.x, this.y);

  final int id;
  final double x;
  final double y;

  Map<String, dynamic> toJson() => {"id": id, "x": x, "y": y};

  @override
  String toString() => "DesktopTouch($id, ${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})";
}

/// What kind of text the desktop's focused field wants (`desktop.textInput.purpose`).
enum DesktopTextPurpose {
  normal,
  number,
  phone,
  email,
  url,
  password,
  terminal;

  /// The purpose named [wire]; [normal] for null or one this app does not know.
  static DesktopTextPurpose fromWire(String? wire) {
    for (final purpose in values) {
      if (purpose.name == wire) return purpose;
    }
    return normal;
  }
}

/// A text field on the phone's desktop that has focus.
class DesktopTextInput {
  const DesktopTextInput(this.purpose);

  final DesktopTextPurpose purpose;

  @override
  bool operator ==(Object other) => other is DesktopTextInput && other.purpose == purpose;

  @override
  int get hashCode => purpose.hashCode;
}
