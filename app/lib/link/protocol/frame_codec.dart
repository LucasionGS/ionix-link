import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "constants.dart";
import "errors.dart";
import "message.dart";

/// Encodes messages into frames: `u32 BE length | u8 kind | payload` (`PROTOCOL.md` section 3).
class FrameCodec {
  FrameCodec._();

  /// Encode [message] as a kind 0 frame, or as a kind 1 frame when [LinkMessage.data] is set.
  /// Throws [LinkProtocolException] (`too_large`) if the JSON exceeds [LinkProtocol.maxJson].
  static Uint8List encode(LinkMessage message) {
    final json = utf8.encode(jsonEncode(message.toJson()));
    if (json.length > LinkProtocol.maxJson) {
      throw LinkProtocolException("The ${message.type} message is too large to send.", code: LinkErrorCode.tooLarge);
    }
    final data = message.data;
    if (data == null) {
      final frame = Uint8List(5 + json.length);
      ByteData.sublistView(frame).setUint32(0, 1 + json.length, Endian.big);
      frame[4] = LinkProtocol.kindJson;
      frame.setRange(5, frame.length, json);
      return frame;
    }
    if (json.length > 0xffff) {
      throw LinkProtocolException("The ${message.type} header is too large to send.", code: LinkErrorCode.tooLarge);
    }
    final length = 1 + 2 + json.length + data.length;
    if (length > LinkProtocol.maxFrame) {
      throw LinkProtocolException("The ${message.type} data is too large to send.", code: LinkErrorCode.tooLarge);
    }
    final frame = Uint8List(4 + length);
    final view = ByteData.sublistView(frame);
    view.setUint32(0, length, Endian.big);
    frame[4] = LinkProtocol.kindBinary;
    view.setUint16(5, json.length, Endian.big);
    frame.setRange(7, 7 + json.length, json);
    frame.setRange(7 + json.length, frame.length, data);
    return frame;
  }
}

/// Incremental frame decoder. Feed it socket chunks with [add]; it returns every complete message.
/// One instance per connection.
///
/// Frames may be split or merged arbitrarily across chunks. A frame's `length` is checked against
/// [maxFrameLength] as soon as its four length bytes are in, before any of its payload is waited for. The pull API
/// ([feed] + [next]) lets a caller change [maxFrameLength] between two frames of the same chunk, which is what the
/// switch to the larger limit right after `ready` needs.
class FrameDecoder {
  /// Create a decoder that starts with the pre-authentication limit.
  FrameDecoder({this.maxFrameLength = LinkProtocol.maxFrameUnauthenticated});

  /// Largest `length` accepted. Raise it to [LinkProtocol.maxFrame] once `ready` arrives.
  int maxFrameLength;

  Uint8List _buffer = Uint8List(0);
  int _start = 0;
  int _end = 0;
  LinkProtocolException? _failure;

  /// Append [chunk] and return the messages it completes, in order.
  /// Throws [LinkProtocolException] with `bad_frame`, `too_large` or `bad_json`; the connection must then close.
  /// A well-framed message that is not a valid message object (`bad_message`) is skipped.
  List<LinkMessage> add(Uint8List chunk) {
    feed(chunk);
    final messages = <LinkMessage>[];
    while (true) {
      try {
        final message = next();
        if (message == null) return messages;
        messages.add(message);
      } on LinkProtocolException catch (error) {
        if (error.code != LinkErrorCode.badMessage) rethrow;
      }
    }
  }

  /// Bytes held that do not yet form a frame.
  int get pending => _end - _start;

  /// Append [chunk] without decoding; take messages out with [next].
  /// Throws the earlier [LinkProtocolException] again if the stream already failed.
  void feed(Uint8List chunk) {
    final failure = _failure;
    if (failure != null) throw failure;
    if (chunk.isEmpty) return;
    if (_end + chunk.length > _buffer.length) {
      final held = _end - _start;
      if (held + chunk.length <= _buffer.length) {
        _buffer.setRange(0, held, _buffer, _start);
      }
      else {
        final grown = Uint8List(_capacityFor(held + chunk.length));
        grown.setRange(0, held, _buffer, _start);
        _buffer = grown;
      }
      _start = 0;
      _end = held;
    }
    _buffer.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// The next complete message, or null when the held bytes do not form one yet.
  /// Throws [LinkProtocolException]: `bad_frame`, `too_large` and `bad_json` are fatal and every later call throws
  /// them again; `bad_message` only skips that one frame.
  LinkMessage? next() {
    final failure = _failure;
    if (failure != null) throw failure;
    final held = _end - _start;
    if (held < 4) return null;
    final view = ByteData.sublistView(_buffer, _start, _end);
    final length = view.getUint32(0, Endian.big);
    if (length > maxFrameLength) _fail("A frame of $length bytes is over the limit of $maxFrameLength.", LinkErrorCode.tooLarge);
    if (held >= 5) {
      final kind = _buffer[_start + 4];
      if (kind != LinkProtocol.kindJson && kind != LinkProtocol.kindBinary) _fail("Unknown frame kind $kind.", LinkErrorCode.badFrame);
    }
    if (length < 3) _fail("A frame of $length bytes is too short.", LinkErrorCode.badFrame);
    if (held < 4 + length) return null;

    final buffer = _buffer;
    final kind = buffer[_start + 4];
    final payloadStart = _start + 5;
    final frameEnd = _start + 4 + length;
    _start = frameEnd;
    if (_start == _end) {
      _start = 0;
      _end = 0;
      if (_buffer.length > _keepCapacity) _buffer = Uint8List(0);
    }

    if (kind == LinkProtocol.kindJson) {
      // The bytes stay valid until the next feed(), and they are decoded before that.
      return _decode(Uint8List.sublistView(buffer, payloadStart, frameEnd), null);
    }
    final headerLength = ByteData.sublistView(buffer, payloadStart, payloadStart + 2).getUint16(0, Endian.big);
    if (3 + headerLength > length) _fail("A binary frame's header is longer than the frame.", LinkErrorCode.badFrame);
    final headerEnd = payloadStart + 2 + headerLength;
    final data = Uint8List.fromList(Uint8List.sublistView(buffer, headerEnd, frameEnd));
    return _decode(Uint8List.sublistView(buffer, payloadStart + 2, headerEnd), data);
  }

  /// A stream transformer that decodes socket chunks into messages, one decoder per bound stream. Each message is
  /// emitted before the next frame is decoded, so a listener may change [FrameDecoder.maxFrameLength] of [decoder]
  /// (when given) in between. A fatal [LinkProtocolException] is emitted as an error and ends the stream.
  static StreamTransformer<Uint8List, LinkMessage> transformer([FrameDecoder? decoder]) {
    return StreamTransformer<Uint8List, LinkMessage>((input, cancelOnError) {
      final frames = decoder ?? FrameDecoder();
      late final StreamController<LinkMessage> output;
      StreamSubscription<Uint8List>? subscription;
      output = StreamController<LinkMessage>(
        sync: true,
        onListen: () {
          subscription = input.listen(
            (chunk) {
              try {
                frames.feed(chunk);
                while (!output.isClosed && !output.isPaused) {
                  final message = _nextSkippingBad(frames);
                  if (message == null) break;
                  output.add(message);
                }
              } on LinkProtocolException catch (error) {
                output.addError(error);
                subscription?.cancel();
                output.close();
              }
            },
            onError: output.addError,
            onDone: output.close,
            cancelOnError: cancelOnError,
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () {
          subscription?.resume();
          try {
            while (!output.isClosed && !output.isPaused) {
              final message = _nextSkippingBad(frames);
              if (message == null) break;
              output.add(message);
            }
          } on LinkProtocolException catch (error) {
            output.addError(error);
            subscription?.cancel();
            output.close();
          }
        },
        onCancel: () => subscription?.cancel(),
      );
      return output.stream.listen(null, cancelOnError: cancelOnError);
    });
  }

  static LinkMessage? _nextSkippingBad(FrameDecoder decoder) {
    while (true) {
      try {
        return decoder.next();
      } on LinkProtocolException catch (error) {
        if (error.code != LinkErrorCode.badMessage) rethrow;
      }
    }
  }

  /// Buffers above this size are dropped once empty, so one large frame does not pin its memory.
  static const int _keepCapacity = 256 * 1024;

  int _capacityFor(int needed) {
    var capacity = _buffer.isEmpty ? 16 * 1024 : _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    return capacity;
  }

  Never _fail(String message, LinkErrorCode code) {
    final failure = LinkProtocolException(message, code: code);
    _failure = failure;
    _buffer = Uint8List(0);
    _start = 0;
    _end = 0;
    throw failure;
  }

  LinkMessage _decode(Uint8List json, Uint8List? data) {
    if (json.length > LinkProtocol.maxJson) _fail("A message of ${json.length} bytes is over the JSON limit.", LinkErrorCode.tooLarge);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(json));
    } on FormatException {
      _fail("A frame's payload is not UTF-8 JSON.", LinkErrorCode.badJson);
    }
    if (decoded is! Map<String, dynamic>) _fail("A frame's payload is not a JSON object.", LinkErrorCode.badJson);
    return LinkMessage.fromJson(decoded, data: data);
  }
}
