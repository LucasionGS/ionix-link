import "dart:async";

import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "../protocol/message.dart";
import "plugin_client.dart";

/// `screen.*`: view a desktop output as a JPEG stream (`PROTOCOL.md` 8.6).
///
/// Flow control is one frame in flight: **the UI must call [ack] once it has decoded and painted a frame**, or the
/// desktop sends nothing more.
class ScreenClient extends PluginClient {
  // Message types
  static const String typeOutputs = "screen.outputs";
  static const String typeStart = "screen.start";
  static const String typeFrame = "screen.frame";
  static const String typeAck = "screen.ack";
  static const String typeStop = "screen.stop";
  static const String typeStopped = "screen.stopped";

  /// Daemon cap: JPEG frames.
  static const String capJpeg = "jpeg";

  @override
  String get name => LinkPlugins.screen;

  final StreamController<ScreenFrame> _frames = StreamController.broadcast();
  final StreamController<String> _stopped = StreamController.broadcast();
  final ValueNotifier<ScreenStreamInfo?> _stream = ValueNotifier(null);
  int _lastAcked = 0;

  /// The desktop's outputs.
  Future<List<ScreenOutput>> outputs() async {
    return List.unmodifiable(JsonRead.objects(await request(typeOutputs), "outputs", ScreenOutput.fromJson));
  }

  /// Start (or restart with new values) a stream of [output].
  /// @param scale Fraction of the logical size, 0.1..1.0.
  /// @param quality JPEG quality, 1..100.
  /// @param maxFps Upper bound on frames per second, 1..30.
  /// @throws LinkRemoteException with `invalid_argument` for an unknown output or a value out of range.
  Future<ScreenStreamInfo> start(String output, {double scale = 0.5, int quality = 60, int maxFps = 15}) async {
    final body = await request(typeStart, {"output": output, "scale": scale, "quality": quality, "maxFps": maxFps});
    final info = ScreenStreamInfo(output: output, width: JsonRead.integer(body, "width"), height: JsonRead.integer(body, "height"));
    if (isAvailable) {
      _lastAcked = 0;
      _stream.value = info;
    }
    return info;
  }

  /// Stop the stream. No-op when not streaming.
  Future<void> stop() async {
    if (_stream.value == null) return;
    _stream.value = null;
    if (!isAvailable) return;
    await request(typeStop);
  }

  /// Report frame [seq] as shown, allowing the next one.
  void ack(int seq) {
    // Only the newest frame matters: an ack for an older one (a late paint) would not free the slot anyway.
    if (_stream.value == null || !isAvailable || seq <= _lastAcked) return;
    _lastAcked = seq;
    try {
      send(typeAck, {"seq": seq});
    } on LinkException {
      return;
    }
  }

  /// Every frame received. Broadcast.
  Stream<ScreenFrame> get frames => _frames.stream;

  /// The current stream, or null when not streaming (stopped, `screen.stopped`, detached).
  ValueListenable<ScreenStreamInfo?> get stream => _stream;

  /// Reasons of `screen.stopped` pushes (`output_gone`, `capture_failed`, `stalled`).
  Stream<String> get stopped => _stopped.stream;

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    listen(typeFrame, _onFrame);
    listen(typeStopped, (message) {
      final reason = message.body["reason"];
      _stream.value = null;
      _stopped.add(reason is String ? reason : "stopped");
    });
  }

  @override
  void onDetach() {
    // The desktop stops the stream when the connection goes; a new connection starts without one.
    if (_stream.value != null) _stopped.add("disconnected");
    _stream.value = null;
  }

  void _onFrame(LinkMessage message) {
    final data = message.data;
    if (data == null || _stream.value == null) return;
    final time = JsonRead.optInt(message.body, "time");
    _frames.add(ScreenFrame(
      output: JsonRead.optString(message.body, "output") ?? _stream.value!.output,
      width: JsonRead.integer(message.body, "w"),
      height: JsonRead.integer(message.body, "h"),
      seq: JsonRead.integer(message.body, "seq"),
      format: JsonRead.optString(message.body, "format") ?? "jpeg",
      time: time == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(time),
      bytes: data,
    ));
  }
}

/// The `Output` object of `PROTOCOL.md` 8.6. Sizes in logical px.
class ScreenOutput {
  const ScreenOutput({
    required this.name,
    required this.description,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scale,
    required this.focused,
  });

  /// Output name (`DP-1`), the handle for [ScreenClient.start] and [InputClient.moveAbsolute].
  final String name;
  final String description;
  final int x;
  final int y;
  final int width;
  final int height;
  final double scale;
  final bool focused;

  /// Throws [LinkFormatException] on a missing `name` or size.
  static ScreenOutput fromJson(Map<String, dynamic> json) {
    final name = JsonRead.string(json, "name");
    final description = JsonRead.optString(json, "description");
    return ScreenOutput(
      name: name,
      description: description == null || description.isEmpty ? name : description,
      x: JsonRead.optInt(json, "x") ?? 0,
      y: JsonRead.optInt(json, "y") ?? 0,
      width: JsonRead.integer(json, "width"),
      height: JsonRead.integer(json, "height"),
      scale: JsonRead.optNumber(json, "scale") ?? 1.0,
      focused: JsonRead.optBool(json, "focused") ?? false,
    );
  }
}

/// A running stream, from the `screen.start` reply.
class ScreenStreamInfo {
  const ScreenStreamInfo({required this.output, required this.width, required this.height});

  final String output;

  /// Frame size in px.
  final int width;
  final int height;
}

/// One `screen.frame`.
class ScreenFrame {
  const ScreenFrame({
    required this.output,
    required this.width,
    required this.height,
    required this.seq,
    required this.format,
    required this.time,
    required this.bytes,
  });

  final String output;
  final int width;
  final int height;

  /// Frame number within the stream; pass to [ScreenClient.ack].
  final int seq;

  /// Always `"jpeg"` in v1.
  final String format;

  /// Capture time on the desktop.
  final DateTime time;

  /// The encoded image.
  final Uint8List bytes;
}
