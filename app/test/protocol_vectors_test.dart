// The test vectors of PROTOCOL.md (sections 3.2, 4.4, 5). The daemon checks the same numbers, so passing here means
// the two sides agree on framing, the pairing code and the auth MAC. Further cases cover the decoder's split/merge
// handling and limits, the pairing URI and the theme object.

import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:ionix_link/link/models/link_theme.dart";
import "package:ionix_link/link/models/pairing_uri.dart";
import "package:ionix_link/link/plugins/desktop_client.dart";
import "package:ionix_link/link/protocol/constants.dart";
import "package:ionix_link/link/protocol/errors.dart";
import "package:ionix_link/link/protocol/frame_codec.dart";
import "package:ionix_link/link/protocol/link_crypto.dart";
import "package:ionix_link/link/protocol/message.dart";

const String fingerprint = "a3d2ff5e747654c2fb788234d1347bf975b61e03cafca531a34cc6595277e60b";
const String pingFrame = "00000021007b2274797065223a2270696e67222c226964223a372c22626f6479223a7b7d7d";
const String screenFrame =
    "0000002f0100287b2274797065223a2273637265656e2e6672616d65222c22626f6479223a7b22736571223a317d7dffd8ffd9";

Matcher throwsProtocol(LinkErrorCode code) =>
    throwsA(isA<LinkProtocolException>().having((error) => error.code, "code", code));

Uint8List frameHeader(int length, int kind) {
  final bytes = Uint8List(5);
  ByteData.sublistView(bytes).setUint32(0, length, Endian.big);
  bytes[4] = kind;
  return bytes;
}

void main() {
  test("fingerprint vector is SHA-256 of the test string", () {
    expect(LinkCrypto.toHex(LinkCrypto.sha256(utf8.encode("ionix-link test certificate"))), fingerprint);
  });

  test("auth MAC", () {
    final mac = LinkCrypto.authMac(
      key: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
      nonce: "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
      fingerprint: fingerprint,
    );
    expect(mac, "7c0ad5f413446203954a9262d09fd5a3df91edb941f35deaf0d44a1a23eb09a3");
  });

  test("pairing commit and code", () {
    const phoneNonce = "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f";
    const desktopNonce = "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f";
    expect(LinkCrypto.commitment(phoneNonce), "ca2a4fe727faaecf16ecd130a86e0885c5540c05375340445071c0657555fd42");
    final digest = LinkCrypto.sha256(LinkCrypto.fromHex(fingerprint + phoneNonce + desktopNonce));
    expect(LinkCrypto.toHex(digest), "f46f3e956a64d16be595aa587fb42aef026cdd137a6ead9d8d82e20546cae4cf");
    expect(LinkCrypto.pairingCode(fingerprint: fingerprint, phoneNonce: phoneNonce, desktopNonce: desktopNonce), "931221");
  });

  test("hex accepts uppercase and rejects junk", () {
    expect(LinkCrypto.fromHex("FFd8"), Uint8List.fromList([0xff, 0xd8]));
    expect(LinkCrypto.isHex(fingerprint.toUpperCase(), 32), isTrue);
    expect(() => LinkCrypto.fromHex("abc"), throwsA(isA<LinkFormatException>()));
    expect(() => LinkCrypto.fromHex("zz"), throwsA(isA<LinkFormatException>()));
  });

  group("frames", () {
    test("kind 0 frame decodes", () {
      final messages = FrameDecoder().add(LinkCrypto.fromHex(pingFrame));
      expect(messages, hasLength(1));
      expect(messages.single.type, "ping");
      expect(messages.single.id, 7);
      expect(messages.single.data, isNull);
    });

    test("kind 1 frame decodes, split across chunks", () {
      final frame = LinkCrypto.fromHex(screenFrame);
      final decoder = FrameDecoder();
      expect(decoder.add(Uint8List.sublistView(frame, 0, 7)), isEmpty);
      final messages = decoder.add(Uint8List.sublistView(frame, 7));
      expect(messages.single.type, "screen.frame");
      expect(messages.single.body["seq"], 1);
      expect(messages.single.data, Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]));
    });

    test("encoder reproduces both vectors byte for byte", () {
      expect(LinkCrypto.toHex(FrameCodec.encode(LinkMessage("ping", id: 7))), pingFrame);
      final binary = LinkMessage("screen.frame", body: {"seq": 1}, data: Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]));
      expect(LinkCrypto.toHex(FrameCodec.encode(binary)), screenFrame);
    });

    test("encode then decode round-trips", () {
      final sent = LinkMessage("media.control", id: 3, body: {"action": "next"});
      final received = FrameDecoder().add(FrameCodec.encode(sent)).single;
      expect(received.type, sent.type);
      expect(received.id, 3);
      expect(received.body["action"], "next");
    });

    test("every split point of two merged frames yields both, in order", () {
      final stream = Uint8List.fromList([...LinkCrypto.fromHex(pingFrame), ...LinkCrypto.fromHex(screenFrame)]);
      for (var cut = 0; cut <= stream.length; cut++) {
        final decoder = FrameDecoder();
        final messages = [
          ...decoder.add(Uint8List.sublistView(stream, 0, cut)),
          ...decoder.add(Uint8List.sublistView(stream, cut)),
        ];
        expect(messages.map((message) => message.type), ["ping", "screen.frame"], reason: "cut at $cut");
        expect(decoder.pending, 0);
      }
    });

    test("byte-at-a-time feed of many frames", () {
      final frames = <int>[];
      for (var i = 1; i <= 50; i++) {
        frames.addAll(FrameCodec.encode(LinkMessage("input.move", body: {"dx": i, "dy": -i})));
        frames.addAll(FrameCodec.encode(LinkMessage("x.bin", id: i, data: Uint8List.fromList(List.filled(i, i)))));
      }
      final decoder = FrameDecoder(maxFrameLength: LinkProtocol.maxFrame);
      final messages = <LinkMessage>[];
      for (final byte in frames) {
        messages.addAll(decoder.add(Uint8List.fromList([byte])));
      }
      expect(messages, hasLength(100));
      expect(messages[98].body["dx"], 50);
      expect(messages[99].data, hasLength(50));
      expect(messages[99].id, 50);
    });

    test("a frame over the limit fails as soon as its length is in, before the payload", () {
      final decoder = FrameDecoder();
      final header = frameHeader(LinkProtocol.maxFrameUnauthenticated + 1, 0);
      expect(() => decoder.add(Uint8List.sublistView(header, 0, 4)), throwsProtocol(LinkErrorCode.tooLarge));
      // The decoder stays failed.
      expect(() => decoder.add(Uint8List(1)), throwsProtocol(LinkErrorCode.tooLarge));
    });

    test("the limit can be raised between two frames of one chunk (after ready)", () {
      final big = FrameCodec.encode(LinkMessage("media.players", body: {"pad": "x" * 70000}));
      final stream = Uint8List.fromList([...FrameCodec.encode(LinkMessage("ready")), ...big]);
      final decoder = FrameDecoder();
      decoder.feed(stream);
      expect(decoder.next()!.type, "ready");
      decoder.maxFrameLength = LinkProtocol.maxFrame;
      expect(decoder.next()!.type, "media.players");
      expect(decoder.next(), isNull);
      // Without the raise, the same stream fails.
      expect(() => FrameDecoder().add(stream), throwsProtocol(LinkErrorCode.tooLarge));
    });

    test("bad frames", () {
      expect(() => FrameDecoder().add(frameHeader(3, 2)), throwsProtocol(LinkErrorCode.badFrame));
      expect(() => FrameDecoder().add(frameHeader(2, 0)), throwsProtocol(LinkErrorCode.badFrame));
      // kind 1 whose header length runs past the frame
      expect(() => FrameDecoder().add(Uint8List.fromList([0, 0, 0, 5, 1, 0, 9, 0x7b, 0x7d])), throwsProtocol(LinkErrorCode.badFrame));
      final notJson = Uint8List.fromList([...frameHeader(4, 0).sublist(0, 5), 0x7b, 0x7b, 0x7b]);
      expect(() => FrameDecoder().add(notJson), throwsProtocol(LinkErrorCode.badJson));
      final array = Uint8List.fromList([...frameHeader(3, 0), 0x5b, 0x5d]);
      expect(() => FrameDecoder().add(array), throwsProtocol(LinkErrorCode.badJson));
    });

    test("a message without a type is skipped, the stream goes on", () {
      final noType = utf8.encode('{"body":{}}');
      final stream = Uint8List.fromList([...frameHeader(1 + noType.length, 0), ...noType, ...LinkCrypto.fromHex(pingFrame)]);
      expect(FrameDecoder().add(stream).single.type, "ping");
    });

    test("stream transformer: arbitrary chunking, then a fatal error ends the stream", () async {
      final stream = Uint8List.fromList([...LinkCrypto.fromHex(pingFrame), ...LinkCrypto.fromHex(screenFrame), ...frameHeader(3, 9)]);
      final chunks = Stream.fromIterable([
        Uint8List.sublistView(stream, 0, 3),
        Uint8List.sublistView(stream, 3, 40),
        Uint8List.sublistView(stream, 40),
      ]);
      final types = <String>[];
      Object? failure;
      final done = Completer<void>();
      chunks.transform(FrameDecoder.transformer()).listen(
        (message) => types.add(message.type),
        onError: (Object error) => failure = error,
        onDone: done.complete,
      );
      await done.future;
      expect(types, ["ping", "screen.frame"]);
      expect(failure, isA<LinkProtocolException>().having((error) => error.code, "code", LinkErrorCode.badFrame));
    });
  });

  group("messages", () {
    test("validation", () {
      expect(() => LinkMessage(""), throwsA(isA<LinkFormatException>()));
      expect(() => LinkMessage("a.b", id: 0), throwsA(isA<LinkFormatException>()));
      expect(() => LinkMessage("a.b", id: 1, re: 1), throwsA(isA<LinkFormatException>()));
      expect(LinkMessage("a.b").toJson(), {"type": "a.b", "body": {}});
      expect(LinkMessage.fromJson({"type": "a.b", "re": 4}).body, isEmpty);
      expect(() => LinkMessage.fromJson({"type": "a.b", "body": []}), throwsA(isA<LinkProtocolException>()));
    });

    test("error bodies", () {
      final error = LinkRemoteException.fromBody({"code": "replaced", "message": "Gone.", "fatal": true});
      expect(error.code, LinkErrorCode.replaced);
      expect(error.fatal, isTrue);
      expect(LinkRemoteException.fromBody({"code": "brand_new"}).code, LinkErrorCode.failed);
      expect(LinkErrorCode.fromWire("connection"), LinkErrorCode.failed);
    });
  });

  group("pairing URI", () {
    const uri = "ionixlink://pair?v=1&host=0123456789abcdef0123456789abcdef&name=my%20eonix%20%C3%A6&port=47110"
        "&fp=$fingerprint&token=00112233445566778899aabbccddeeff&exp=1763150120000"
        "&addr=192.168.1.20&addr=fe80%3A%3A1%25wlan0&future=ignored";

    test("parses every field", () {
      final parsed = PairingUri.parse(uri);
      expect(parsed.hostId, "0123456789abcdef0123456789abcdef");
      expect(parsed.hostName, "my eonix æ");
      expect(parsed.port, 47110);
      expect(parsed.fingerprint, fingerprint);
      expect(parsed.token, "00112233445566778899aabbccddeeff");
      expect(parsed.expires.millisecondsSinceEpoch, 1763150120000);
      expect(parsed.addresses, ["192.168.1.20", "fe80::1%wlan0"]);
    });

    test("round-trips through toString", () {
      final parsed = PairingUri.parse(uri);
      final again = PairingUri.parse(parsed.toString());
      expect(again.hostName, parsed.hostName);
      expect(again.addresses, parsed.addresses);
      expect(again.token, parsed.token);
    });

    test("rejects other codes and newer versions with readable messages", () {
      expect(() => PairingUri.parse("https://example.com"),
          throwsA(isA<LinkFormatException>().having((e) => e.message, "message", contains("not an Ionix Link"))));
      expect(() => PairingUri.parse(uri.replaceFirst("v=1", "v=2")),
          throwsA(isA<LinkFormatException>().having((e) => e.message, "message", contains("Update Ionix Link"))));
      expect(() => PairingUri.parse(uri.replaceFirst("&addr=192.168.1.20&addr=fe80%3A%3A1%25wlan0", "")),
          throwsA(isA<LinkFormatException>()));
      expect(() => PairingUri.parse(uri.replaceFirst("token=00", "token=zz")), throwsA(isA<LinkFormatException>()));
    });
  });

  group("theme", () {
    test("forgiving parse falls back per field", () {
      final theme = LinkTheme.fromJson({
        "name": "winix",
        "colors": {"bgDeep": "#101010", "accent": "#80ff0000", "text": "nope"},
        "flat": true,
        "radius": {"sm": 4, "pill": "x"},
        "revision": "abc",
        "wallpaper": "def",
      });
      expect(theme.name, "winix");
      expect(theme.colors.bgDeep, 0xFF101010);
      expect(theme.colors.accent, 0xFFFF0000);
      expect(theme.colors.text, LinkColors.ionix.text);
      expect(theme.radiusSm, 4);
      expect(theme.radiusPill, 12);
      expect(theme.flat, isTrue);
      expect(LinkTheme.fromJson(theme.toJson()), theme);
      expect(LinkTheme.fromJson(const {}), LinkTheme.ionix);
    });
  });

  group("desktop commit splitting", () {
    int bytes(String s) => utf8.encode(s).length;

    test("text that fits goes as one commit", () {
      expect(DesktopClient.splitCommit("héllo"), ["héllo"]);
      expect(DesktopClient.splitCommit("a" * 100, maxBytes: 100), ["a" * 100]);
    });

    test("the limit is UTF-8 bytes, not UTF-16 units, and a piece is never cut inside a code point", () {
      // 30000 three-byte characters are 30000 UTF-16 units but 90000 bytes: over the 64 KiB limit.
      final text = "漢" * 30000;
      final parts = DesktopClient.splitCommit(text);
      expect(parts.length, 2);
      expect(parts.join(), text);
      for (final part in parts) {
        expect(bytes(part), lessThanOrEqualTo(64 * 1024));
      }
      // Four-byte code points are two UTF-16 units and must stay whole.
      final emoji = "😀" * 10;
      final pieces = DesktopClient.splitCommit(emoji, maxBytes: 10);
      expect(pieces, ["😀😀", "😀😀", "😀😀", "😀😀", "😀😀"]);
      expect(pieces.join(), emoji);
    });
  });
}
