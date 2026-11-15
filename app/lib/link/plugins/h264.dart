import "dart:typed_data";

/// One NAL unit of an Annex-B H.264 stream, without its start code.
class NalUnit {
  const NalUnit(this.bytes);

  /// The unit, header byte first.
  final Uint8List bytes;

  /// `nal_unit_type` (H.264 table 7-1): 1 slice, 5 IDR slice, 6 SEI, 7 SPS, 8 PPS, 9 access unit delimiter.
  int get type => bytes.isEmpty ? 0 : bytes[0] & 0x1f;
}

/// Annex-B helpers for the `screen.video` access units of `PROTOCOL.md` 8.6. The daemon already cuts the stream into
/// one access unit per message and puts the SPS and PPS in band before every keyframe; the phone only needs to find
/// them, to configure its decoder and notice a new stream.
class H264 {
  H264._();

  static const int typeSlice = 1;
  static const int typeIdr = 5;
  static const int typeSps = 7;
  static const int typePps = 8;

  /// The NAL units of an Annex-B byte sequence, split on 3- and 4-byte start codes. Bytes before the first start
  /// code are ignored, as are the zero bytes before each start code (a 4-byte start code and `trailing_zero_8bits`).
  static List<NalUnit> nalUnits(Uint8List data) {
    final units = <NalUnit>[];
    var start = -1;
    var i = 0;
    while (i + 2 < data.length) {
      if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
        if (start >= 0) units.add(NalUnit(_trimmed(data, start, i)));
        i += 3;
        start = i;
        continue;
      }
      i++;
    }
    if (start >= 0 && start < data.length) units.add(NalUnit(_trimmed(data, start, data.length)));
    return units.where((unit) => unit.bytes.isNotEmpty).toList();
  }

  /// Whether the access unit holds an IDR slice.
  static bool isKeyframe(Uint8List accessUnit) => nalUnits(accessUnit).any((unit) => unit.type == typeIdr);

  /// The SPS and PPS of an access unit, each with a 4-byte start code (the form `MediaCodec` takes as `csd-0` and
  /// `csd-1`), or null when it lacks either.
  static H264ParameterSets? parameterSets(Uint8List accessUnit) {
    Uint8List? sps;
    Uint8List? pps;
    for (final unit in nalUnits(accessUnit)) {
      if (unit.type == typeSps) {
        sps ??= _withStartCode(unit.bytes);
      }
      else if (unit.type == typePps) {
        pps ??= _withStartCode(unit.bytes);
      }
    }
    if (sps == null || pps == null) return null;
    return H264ParameterSets(sps: sps, pps: pps);
  }

  /// The picture geometry an SPS (one NAL unit, with or without its start code) describes, or null when it cannot
  /// be read.
  static H264Sps? parseSps(Uint8List sps) {
    final units = nalUnits(sps);
    final unit = units.isEmpty ? sps : units.first.bytes;
    if (unit.length < 4 || unit[0] & 0x1f != typeSps) return null;
    try {
      return H264Sps._parse(_BitReader(_unescape(Uint8List.sublistView(unit, 1))));
    } on RangeError {
      return null;
    }
  }

  // Remove emulation prevention bytes: 00 00 03 → 00 00.
  static Uint8List _unescape(Uint8List data) {
    final out = BytesBuilder(copy: false);
    var zeros = 0;
    for (final byte in data) {
      if (zeros >= 2 && byte == 3) {
        zeros = 0;
        continue;
      }
      zeros = byte == 0 ? zeros + 1 : 0;
      out.addByte(byte);
    }
    return out.toBytes();
  }

  static Uint8List _trimmed(Uint8List data, int start, int end) {
    while (end > start && data[end - 1] == 0) {
      end--;
    }
    return Uint8List.sublistView(data, start, end);
  }

  static Uint8List _withStartCode(Uint8List unit) {
    final out = Uint8List(unit.length + 4);
    out[3] = 1;
    out.setRange(4, out.length, unit);
    return out;
  }
}

/// A stream's SPS and PPS, each with a 4-byte start code.
class H264ParameterSets {
  const H264ParameterSets({required this.sps, required this.pps});

  final Uint8List sps;
  final Uint8List pps;

  /// Whether [other] holds the same bytes, so a decoder configured with one can keep going on the other.
  bool sameAs(H264ParameterSets? other) => other != null && _equal(sps, other.sps) && _equal(pps, other.pps);

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// What an SPS says about the picture (H.264 7.3.2.1.1): the coded size in whole macroblocks, and the frame cropping
/// that cuts the visible picture out of it. A decoder's output buffer is (at least) the coded size.
class H264Sps {
  const H264Sps({
    required this.codedWidth,
    required this.codedHeight,
    required this.cropLeft,
    required this.cropRight,
    required this.cropTop,
    required this.cropBottom,
  });

  /// Size in px of the decoded picture, a multiple of 16.
  final int codedWidth;
  final int codedHeight;

  /// px cut from each side.
  final int cropLeft;
  final int cropRight;
  final int cropTop;
  final int cropBottom;

  /// The visible picture.
  int get width => codedWidth - cropLeft - cropRight;
  int get height => codedHeight - cropTop - cropBottom;

  // Profiles whose SPS carries chroma format, bit depths and scaling lists.
  static const Set<int> _highProfiles = {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135};

  static H264Sps _parse(_BitReader r) {
    final profile = r.bits(8);
    r.bits(16); // constraint flags, level
    r.ue(); // seq_parameter_set_id
    var chromaFormat = 1;
    var separateColourPlanes = false;
    if (_highProfiles.contains(profile)) {
      chromaFormat = r.ue();
      if (chromaFormat == 3) separateColourPlanes = r.bit();
      r.ue(); // bit_depth_luma_minus8
      r.ue(); // bit_depth_chroma_minus8
      r.bit(); // qpprime_y_zero_transform_bypass_flag
      if (r.bit()) { // seq_scaling_matrix_present_flag
        for (var i = 0; i < (chromaFormat == 3 ? 12 : 8); i++) {
          if (r.bit()) _skipScalingList(r, i < 6 ? 16 : 64);
        }
      }
    }
    r.ue(); // log2_max_frame_num_minus4
    final pocType = r.ue();
    if (pocType == 0) {
      r.ue(); // log2_max_pic_order_cnt_lsb_minus4
    }
    else if (pocType == 1) {
      r.bit(); // delta_pic_order_always_zero_flag
      r.se(); // offset_for_non_ref_pic
      r.se(); // offset_for_top_to_bottom_field
      final cycle = r.ue();
      for (var i = 0; i < cycle; i++) {
        r.se();
      }
    }
    r.ue(); // max_num_ref_frames
    r.bit(); // gaps_in_frame_num_value_allowed_flag
    final widthMbs = r.ue() + 1;
    final heightMapUnits = r.ue() + 1;
    final frameMbsOnly = r.bit();
    if (!frameMbsOnly) r.bit(); // mb_adaptive_frame_field_flag
    r.bit(); // direct_8x8_inference_flag
    var left = 0, right = 0, top = 0, bottom = 0;
    if (r.bit()) { // frame_cropping_flag
      left = r.ue();
      right = r.ue();
      top = r.ue();
      bottom = r.ue();
    }
    // Crop offsets count in chroma samples (Table 6-1), and in field pairs for interlaced streams.
    final monochrome = chromaFormat == 0 || separateColourPlanes;
    final unitX = monochrome || chromaFormat == 3 ? 1 : 2;
    final unitY = (monochrome || chromaFormat != 1 ? 1 : 2) * (frameMbsOnly ? 1 : 2);
    return H264Sps(
      codedWidth: widthMbs * 16,
      codedHeight: heightMapUnits * 16 * (frameMbsOnly ? 1 : 2),
      cropLeft: left * unitX,
      cropRight: right * unitX,
      cropTop: top * unitY,
      cropBottom: bottom * unitY,
    );
  }

  static void _skipScalingList(_BitReader r, int size) {
    var last = 8;
    var next = 8;
    for (var j = 0; j < size; j++) {
      if (next != 0) next = (last + r.se() + 256) % 256;
      last = next == 0 ? last : next;
    }
  }
}

/// Reads bits and Exp-Golomb codes MSB first; throws [RangeError] past the end.
class _BitReader {
  _BitReader(this._data);

  final Uint8List _data;
  int _pos = 0;

  bool bit() {
    if (_pos >= _data.length * 8) throw RangeError("SPS ended early.");
    final value = (_data[_pos >> 3] >> (7 - (_pos & 7))) & 1;
    _pos++;
    return value == 1;
  }

  int bits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 1) | (bit() ? 1 : 0);
    }
    return value;
  }

  int ue() {
    var zeros = 0;
    while (!bit()) {
      if (++zeros > 31) throw RangeError("Bad Exp-Golomb code.");
    }
    return (1 << zeros) - 1 + bits(zeros);
  }

  int se() {
    final code = ue();
    return code.isOdd ? (code + 1) ~/ 2 : -(code ~/ 2);
  }
}
