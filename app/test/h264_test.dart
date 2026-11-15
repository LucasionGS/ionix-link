import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:ionix_link/link/link.dart";

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group("H264.nalUnits", () {
    test("splits on 3- and 4-byte start codes and drops the zeros before them", () {
      final units = H264.nalUnits(bytes([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 0, 1, 0x65, 0x88, 4]));
      expect(units.map((unit) => unit.bytes.toList()), [
        [0x67, 1, 2],
        [0x68, 3],
        [0x65, 0x88, 4],
      ]);
      expect(units.map((unit) => unit.type), [7, 8, 5]);
    });

    test("ignores bytes before the first start code, empty units and trailing zeros", () {
      final units = H264.nalUnits(bytes([9, 9, 0, 0, 1, 0, 0, 1, 0x41, 0x9a, 0, 0]));
      expect(units.map((unit) => unit.bytes.toList()), [
        [0x41, 0x9a],
      ]);
      expect(H264.nalUnits(bytes([1, 2, 3])), isEmpty);
      expect(H264.nalUnits(Uint8List(0)), isEmpty);
    });
  });

  test("a keyframe gives its SPS and PPS with start codes; a P-frame gives none", () {
    final key = bytes([0, 0, 0, 1, 0x09, 0x10, 0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xce, 0, 0, 0, 1, 0x65, 0x88]);
    final sets = H264.parameterSets(key)!;
    expect(sets.sps, [0, 0, 0, 1, 0x67, 0x42]);
    expect(sets.pps, [0, 0, 0, 1, 0x68, 0xce]);
    expect(H264.isKeyframe(key), isTrue);
    expect(sets.sameAs(H264.parameterSets(Uint8List.fromList(key))), isTrue);
    expect(sets.sameAs(H264ParameterSets(sps: sets.sps, pps: bytes([0, 0, 0, 1, 0x68, 0xcf]))), isFalse);
    expect(sets.sameAs(null), isFalse);
    final p = bytes([0, 0, 0, 1, 0x41, 0x9a]);
    expect(H264.parameterSets(p), isNull);
    expect(H264.isKeyframe(p), isFalse);
  });

  test("SPS geometry: coded size and crop, baseline and high profile", () {
    Uint8List hex(String text) => Uint8List.fromList([for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)]);
    // x264, baseline, 640x360: coded 640x368, 8 rows cropped at the bottom.
    final baseline = H264.parseSps(hex("6742c016d900a02ff97011000003000100000300140f162e48"))!;
    expect([baseline.codedWidth, baseline.codedHeight, baseline.width, baseline.height, baseline.cropBottom], [640, 368, 640, 360, 8]);
    // x264, high, 650x362: coded 656x368, cropped right and bottom; with a start code in front.
    final high = H264.parseSps(hex("0000000167640016acd940a42fe493011000000300100000030140f162d960"))!;
    expect([high.codedWidth, high.codedHeight, high.width, high.height, high.cropLeft, high.cropTop], [656, 368, 650, 362, 0, 0]);
    // The test clip, 160x96: nothing to crop.
    final clip = H264.parseSps(H264.parameterSets(File("test/support/video.h264").readAsBytesSync())!.sps)!;
    expect([clip.codedWidth, clip.codedHeight, clip.width, clip.height], [160, 96, 160, 96]);
    expect(H264.parseSps(hex("6742c0")), isNull);
    expect(H264.parseSps(hex("68ce3c80")), isNull);
  });

  test("the recorded test clip: two keyframes with parameter sets, one slice per frame", () {
    final raw = File("test/support/video.h264").readAsBytesSync();
    final units = H264.nalUnits(raw);
    expect(units.where((unit) => unit.type == H264.typeIdr).length, 2);
    expect(units.where((unit) => unit.type == H264.typeSlice).length, 8);
    expect(units.where((unit) => unit.type == H264.typeSps).length, 2);
    expect(H264.parameterSets(raw), isNotNull);
  });
}
