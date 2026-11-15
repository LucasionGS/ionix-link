import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../link/link.dart";
import "link_platform.dart";

/// [VideoDecoder] over `VideoDecoders.kt`: a `MediaCodec` for `video/avc` drawing into a Flutter `SurfaceProducer`.
///
/// Three channels, shared by every decoder and keyed by texture id: methods (`available`, `create`, `configure`,
/// `release`), one event stream (`frame`, `format`, `error` maps), and a binary message channel for the access units,
/// so their bytes are not copied through the standard codec. A unit message is `u64 textureId · u32 seq · u8 flags`
/// (bit 0: keyframe), big-endian, then the access unit.
class AndroidVideoDecoder extends VideoDecoder {
  AndroidVideoDecoder._(this.textureId) {
    _subscription = _allEvents.where((event) => event["id"] == textureId).listen(_onEvent);
  }

  static const MethodChannel _methods = MethodChannel("dev.ionnet.ionix_link/video");
  static const EventChannel _events = EventChannel("dev.ionnet.ionix_link/video/events");
  static const BasicMessageChannel<ByteData> _units = BasicMessageChannel("dev.ionnet.ionix_link/video/units", BinaryCodec());
  static const int _headerLength = 13;
  static const int _flagKeyframe = 1;

  static final Stream<Map<Object?, Object?>> _allEvents =
      _events.receiveBroadcastStream().where((event) => event is Map).cast<Map<Object?, Object?>>();

  /// Whether the phone lists a `video/avc` decoder.
  static Future<bool> available() async {
    try {
      return await _methods.invokeMethod<bool>("available") ?? false;
    } on PlatformException catch (error) {
      debugPrint("ionix-link: cannot list video decoders: ${error.message}");
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// A decoder with a new texture.
  /// @throws UnsupportedError when the phone cannot make one.
  static Future<AndroidVideoDecoder> create() async {
    try {
      final id = await _methods.invokeMethod<int>("create");
      if (id == null) throw UnsupportedError("The phone did not make a video texture.");
      return AndroidVideoDecoder._(id);
    } on PlatformException catch (error) {
      throw UnsupportedError("The phone cannot decode video: ${error.message}");
    }
  }

  @override
  final int textureId;

  final ValueNotifier<VideoPicture?> _picture = ValueNotifier(null);
  final StreamController<int> _decoded = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  StreamSubscription<Map<Object?, Object?>>? _subscription;
  bool _disposed = false;
  H264Sps? _sps;

  @override
  ValueListenable<VideoPicture?> get picture => _picture;

  @override
  Stream<int> get decoded => _decoded.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> configure({required int width, required int height, required Uint8List sps, required Uint8List pps}) async {
    if (_disposed) return;
    _sps = H264.parseSps(sps);
    try {
      await _methods.invokeMethod<void>("configure", {"id": textureId, "width": width, "height": height, "sps": sps, "pps": pps});
    } on PlatformException catch (error) {
      _fail("The phone's video decoder would not start: ${error.message}");
    }
  }

  @override
  void decode(int seq, Uint8List accessUnit, {required bool keyframe}) {
    if (_disposed) return;
    final message = Uint8List(_headerLength + accessUnit.length);
    ByteData.sublistView(message)
      ..setUint64(0, textureId)
      ..setUint32(8, seq)
      ..setUint8(12, keyframe ? _flagKeyframe : 0);
    message.setRange(_headerLength, message.length, accessUnit);
    _units.send(ByteData.sublistView(message)).catchError((Object error) {
      _fail("Could not pass video to the decoder: $error");
      return null;
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    try {
      await _methods.invokeMethod<void>("release", {"id": textureId});
    } on PlatformException catch (error) {
      debugPrint("ionix-link: releasing the video decoder: ${error.message}");
    }
    await _decoded.close();
    await _errors.close();
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (_disposed) return;
    switch (event["event"]) {
      case "frame":
        final seq = event["seq"];
        if (seq is int) _decoded.add(seq);
      case "format":
        final picture = _layout(event);
        if (picture != null) _picture.value = picture;
      case "error":
        _fail(event["message"] is String ? event["message"] as String : "The phone's video decoder failed.");
    }
  }

  // Where the visible picture is in the texture. The output format's crop keys win when the decoder sets them; else
  // the SPS's frame cropping does. A producer that handles crop shows just the visible part; otherwise the texture is
  // the whole buffer, which is at least the SPS's coded size even when a decoder reports the visible size instead.
  VideoPicture? _layout(Map<Object?, Object?> event) {
    int? read(String key) => event[key] is int ? event[key] as int : null;
    final width = read("width");
    final height = read("height");
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    final sps = _sps;
    final cropLeft = read("crop-left");
    final cropTop = read("crop-top");
    final cropRight = read("crop-right");
    final cropBottom = read("crop-bottom");
    int left, top, visibleWidth, visibleHeight;
    if (cropLeft != null && cropTop != null && cropRight != null && cropBottom != null) {
      left = cropLeft;
      top = cropTop;
      visibleWidth = cropRight - cropLeft + 1;
      visibleHeight = cropBottom - cropTop + 1;
    }
    else if (sps != null) {
      left = sps.cropLeft;
      top = sps.cropTop;
      visibleWidth = sps.width;
      visibleHeight = sps.height;
    }
    else {
      left = 0;
      top = 0;
      visibleWidth = width;
      visibleHeight = height;
    }
    if (visibleWidth <= 0 || visibleHeight <= 0) return null;
    if (event["handlesCrop"] == true) {
      return VideoPicture(width: visibleWidth, height: visibleHeight, textureWidth: visibleWidth, textureHeight: visibleHeight, cropLeft: 0, cropTop: 0);
    }
    var textureWidth = width;
    var textureHeight = height;
    if (sps != null) {
      if (sps.codedWidth > textureWidth) textureWidth = sps.codedWidth;
      if (sps.codedHeight > textureHeight) textureHeight = sps.codedHeight;
    }
    return VideoPicture(
      width: visibleWidth,
      height: visibleHeight,
      textureWidth: textureWidth < left + visibleWidth ? left + visibleWidth : textureWidth,
      textureHeight: textureHeight < top + visibleHeight ? top + visibleHeight : textureHeight,
      cropLeft: left,
      cropTop: top,
    );
  }

  void _fail(String message) {
    if (!_disposed && !_errors.isClosed) _errors.add(message);
  }
}
