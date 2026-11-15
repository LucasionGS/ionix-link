import "dart:async";

import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "../protocol/message.dart";
import "plugin_client.dart";

/// `screen.*`: view a desktop output as a JPEG stream or as H.264 video (`PROTOCOL.md` 8.6).
///
/// JPEG flow control is one frame in flight: **the UI must call [ack] once it has decoded and painted a frame**, or
/// the desktop sends nothing more. Video is not held up per frame, but the desktop drops frames once too many are
/// unacknowledged, so the UI calls [ack] for each decoded video frame too; the client sends at most one ack per
/// [videoAckInterval].
class ScreenClient extends PluginClient {
  // Message types
  static const String typeOutputs = "screen.outputs";
  static const String typeStart = "screen.start";
  static const String typeFrame = "screen.frame";
  static const String typeVideo = "screen.video";
  static const String typeAck = "screen.ack";
  static const String typeStop = "screen.stop";
  static const String typeStopped = "screen.stopped";

  /// Daemon cap: JPEG frames.
  static const String capJpeg = "jpeg";

  /// Daemon cap: H.264 video (`screen.start` with `format: "h264"`).
  static const String capH264 = "h264";

  /// `screen.start` formats.
  static const String formatJpeg = "jpeg";
  static const String formatH264 = "h264";

  /// Shortest time between two video acks.
  static const Duration videoAckInterval = Duration(milliseconds: 100);

  @override
  String get name => LinkPlugins.screen;

  final StreamController<ScreenFrame> _frames = StreamController.broadcast();
  final StreamController<ScreenVideoUnit> _video = StreamController.broadcast();
  final StreamController<String> _stopped = StreamController.broadcast();
  final ValueNotifier<ScreenStreamInfo?> _stream = ValueNotifier(null);
  int _lastAcked = 0;
  int _videoAckPending = 0;
  int _videoReceived = 0;
  DateTime _videoAckedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _videoAckTimer;

  /// Whether the desktop can stream video.
  bool get canVideo => hasCap(capH264);

  /// The desktop's outputs.
  Future<List<ScreenOutput>> outputs() async {
    return List.unmodifiable(JsonRead.objects(await request(typeOutputs), "outputs", ScreenOutput.fromJson));
  }

  /// Start (or restart with new values) a stream of [output].
  /// @param scale Fraction of the logical size, 0.1..1.0.
  /// @param quality JPEG quality, 1..100; for video it sets the default bitrate.
  /// @param maxFps Upper bound on frames per second, 1..30.
  /// @param format [formatJpeg] (frames on [frames]) or [formatH264] (access units on [video]; needs [canVideo]).
  /// @param bitrate Video bits per second, 100 000..50 000 000; the desktop picks one from the size when null.
  /// @throws LinkRemoteException with `invalid_argument` for an unknown output, a value out of range, or video the
  /// desktop cannot encode.
  Future<ScreenStreamInfo> start(String output, {double scale = 0.5, int quality = 60, int maxFps = 15, String format = formatJpeg, int? bitrate}) async {
    final body = await request(typeStart, {
      "output": output,
      "scale": scale,
      "quality": quality,
      "maxFps": maxFps,
      // Older desktops know no format field; leaving it out for JPEG keeps the request exactly as before.
      if (format != formatJpeg) "format": format,
      "bitrate": ?bitrate,
    });
    final info = ScreenStreamInfo(
      output: output,
      width: JsonRead.integer(body, "width"),
      height: JsonRead.integer(body, "height"),
      format: JsonRead.optString(body, "format") ?? formatJpeg,
    );
    if (isAvailable) {
      _lastAcked = 0;
      _resetVideoAck();
      _stream.value = info;
    }
    return info;
  }

  /// Stop the stream. No-op when not streaming.
  Future<void> stop() async {
    if (_stream.value == null) return;
    _stream.value = null;
    _resetVideoAck();
    if (!isAvailable) return;
    await request(typeStop);
  }

  /// Report frame [seq] as shown, allowing the next one.
  void ack(int seq) {
    // Only the newest frame matters: an ack for an older one (a late paint) would not free the slot anyway.
    final stream = _stream.value;
    if (stream == null || !isAvailable || seq <= _lastAcked) return;
    if (stream.format == formatH264) {
      // A late frame of the previous stream can carry a seq this one has not reached; it must not hold real acks back.
      if (seq > _videoReceived) return;
      _lastAcked = seq;
      _ackVideo(seq);
      return;
    }
    _lastAcked = seq;
    _sendAck(seq);
  }

  // Video: the newest decoded seq, at most once per videoAckInterval, the last one of a burst never held back
  // longer than that.
  void _ackVideo(int seq) {
    _videoAckPending = seq;
    final wait = videoAckInterval - DateTime.now().difference(_videoAckedAt);
    if (wait <= Duration.zero) {
      _flushVideoAck();
    }
    else {
      _videoAckTimer ??= Timer(wait, _flushVideoAck);
    }
  }

  void _flushVideoAck() {
    _videoAckTimer?.cancel();
    _videoAckTimer = null;
    if (_videoAckPending == 0 || _stream.value == null) return;
    _videoAckedAt = DateTime.now();
    _sendAck(_videoAckPending);
    _videoAckPending = 0;
  }

  void _resetVideoAck() {
    _videoAckTimer?.cancel();
    _videoAckTimer = null;
    _videoAckPending = 0;
    _videoReceived = 0;
  }

  void _sendAck(int seq) {
    try {
      send(typeAck, {"seq": seq});
    } on LinkException {
      return;
    }
  }

  /// Every frame received. Broadcast.
  Stream<ScreenFrame> get frames => _frames.stream;

  /// Every video access unit received, in order. Broadcast.
  Stream<ScreenVideoUnit> get video => _video.stream;

  /// The current stream, or null when not streaming (stopped, `screen.stopped`, detached).
  ValueListenable<ScreenStreamInfo?> get stream => _stream;

  /// Reasons of `screen.stopped` pushes (`output_gone`, `capture_failed`, `stalled`).
  Stream<String> get stopped => _stopped.stream;

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    listen(typeFrame, _onFrame);
    listen(typeVideo, _onVideo);
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
    _resetVideoAck();
  }

  void _onVideo(LinkMessage message) {
    final data = message.data;
    final stream = _stream.value;
    if (data == null || stream == null || stream.format != formatH264) return;
    final time = JsonRead.optInt(message.body, "time");
    final seq = JsonRead.integer(message.body, "seq");
    if (seq > _videoReceived) _videoReceived = seq;
    _video.add(ScreenVideoUnit(
      output: JsonRead.optString(message.body, "output") ?? stream.output,
      width: JsonRead.integer(message.body, "w"),
      height: JsonRead.integer(message.body, "h"),
      seq: seq,
      keyframe: JsonRead.optBool(message.body, "keyframe") ?? false,
      pts: JsonRead.optInt(message.body, "pts") ?? 0,
      time: time == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(time),
      bytes: data,
    ));
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
  const ScreenStreamInfo({required this.output, required this.width, required this.height, this.format = ScreenClient.formatJpeg});

  final String output;

  /// Frame size in px.
  final int width;
  final int height;

  /// [ScreenClient.formatJpeg] or [ScreenClient.formatH264].
  final String format;
}

/// One `screen.video`: one H.264 access unit (one frame), Annex-B with 4-byte start codes. A keyframe carries its
/// SPS and PPS in band.
class ScreenVideoUnit {
  const ScreenVideoUnit({
    required this.output,
    required this.width,
    required this.height,
    required this.seq,
    required this.keyframe,
    required this.pts,
    required this.time,
    required this.bytes,
  });

  final String output;

  /// Picture size in px.
  final int width;
  final int height;

  /// Frame number within the stream (1, 2, 3…, no gaps); pass to [ScreenClient.ack] once decoded.
  final int seq;

  /// Whether this unit is an IDR picture, where decoding can start.
  final bool keyframe;

  /// Presentation time in ms since the stream started.
  final int pts;

  /// When the desktop had the frame.
  final DateTime time;

  /// The access unit.
  final Uint8List bytes;
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
