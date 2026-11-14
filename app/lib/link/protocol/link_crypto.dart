import "dart:math";
import "dart:typed_data";

import "package:crypto/crypto.dart" as crypto;

import "errors.dart";

/// Hashing, MAC and encoding helpers. Built on `package:crypto` (SHA-256, HMAC) and `Random.secure()`.
/// Test vectors are in `PROTOCOL.md` sections 4.4 and 5.
class LinkCrypto {
  LinkCrypto._();

  static final Random _random = Random.secure();
  static final RegExp _hexPattern = RegExp(r"^[0-9a-fA-F]*$");
  static const String _digits = "0123456789abcdef";

  /// `count` bytes from `Random.secure()`.
  static Uint8List randomBytes(int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  /// A fresh random id: 16 bytes as lowercase hex. Used for the device id.
  static String randomId() => toHex(randomBytes(16));

  /// SHA-256 of [bytes].
  static Uint8List sha256(List<int> bytes) => Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

  /// Certificate fingerprint: SHA-256 of the certificate's DER bytes, as lowercase hex.
  static String fingerprint(Uint8List der) => toHex(sha256(der));

  /// The `auth.mac`: `HMAC-SHA256(key, nonce || fingerprint)` over the raw bytes, as lowercase hex.
  /// @param key The device key, hex64.
  /// @param nonce The challenge nonce, hex64.
  /// @param fingerprint The pinned certificate fingerprint, hex64.
  static String authMac({required String key, required String nonce, required String fingerprint}) {
    final hmac = crypto.Hmac(crypto.sha256, _hex32(key, "key"));
    return toHex(hmac.convert([..._hex32(nonce, "nonce"), ..._hex32(fingerprint, "fingerprint")]).bytes);
  }

  /// The 6-digit pairing code of pairing B (`PROTOCOL.md` 4.4):
  /// `u32 BE of SHA-256(fingerprint || phoneNonce || desktopNonce)[0..4] mod 1000000`, zero-padded.
  /// @param fingerprint The fingerprint of the certificate the phone saw, hex64.
  /// @param phoneNonce `Np`, the phone's nonce it committed to, hex64.
  /// @param desktopNonce `Nd` from `pair.challenge`, hex64.
  static String pairingCode({required String fingerprint, required String phoneNonce, required String desktopNonce}) {
    final digest = sha256([
      ..._hex32(fingerprint, "fingerprint"),
      ..._hex32(phoneNonce, "phone nonce"),
      ..._hex32(desktopNonce, "desktop nonce"),
    ]);
    final value = ByteData.sublistView(digest).getUint32(0, Endian.big);
    return (value % 1000000).toString().padLeft(6, "0");
  }

  /// The `pair.request.commit` of pairing B: SHA-256 of the raw [nonce] (`Np`), as lowercase hex.
  static String commitment(String nonce) => toHex(sha256(_hex32(nonce, "nonce")));

  /// Lowercase hex of [bytes].
  static String toHex(List<int> bytes) {
    final out = StringBuffer();
    for (final byte in bytes) {
      out.write(_digits[(byte >> 4) & 0x0f]);
      out.write(_digits[byte & 0x0f]);
    }
    return out.toString();
  }

  /// Bytes of a hex string (either case). Throws [LinkFormatException] on odd length or a non-hex character.
  static Uint8List fromHex(String hex) {
    if (hex.length.isOdd || !_hexPattern.hasMatch(hex)) throw LinkFormatException("\"$hex\" is not a hex string.");
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// Whether [value] is lowercase or uppercase hex of exactly [bytes] bytes.
  static bool isHex(String value, int bytes) => value.length == bytes * 2 && _hexPattern.hasMatch(value);

  /// Bytes of a 32-byte hex value, with a readable error naming [what].
  static Uint8List _hex32(String value, String what) {
    if (!isHex(value, 32)) throw LinkFormatException("The $what must be 64 hex characters.");
    return fromHex(value);
  }
}
