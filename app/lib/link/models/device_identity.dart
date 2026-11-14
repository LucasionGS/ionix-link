import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "../protocol/link_crypto.dart";

/// This phone as the desktop sees it: the `deviceId`, `name` and `model` of `hello` and `pair.request`.
class DeviceIdentity {
  /// Create an identity. Throws [LinkFormatException] if [id] is not hex32 or [name] is empty.
  DeviceIdentity({required String id, required String name, required this.model})
    : id = id.toLowerCase(),
      name = _truncate(name.trim()) {
    if (!LinkCrypto.isHex(this.id, 16)) throw LinkFormatException("The device id must be 32 hex characters.");
    if (this.name.isEmpty) throw LinkFormatException("The phone needs a name.");
  }

  /// Longest name sent to a desktop, in characters.
  static const int maxNameLength = 64;

  /// 16 random bytes as hex, made once per install by [LinkStore].
  final String id;

  /// User-visible phone name (from the platform, editable in settings).
  final String name;

  /// Device model, e.g. `Pixel 8`.
  final String model;

  /// A copy with another [name].
  DeviceIdentity withName(String name) => DeviceIdentity(id: id, name: name, model: model);

  Map<String, dynamic> toJson() => {"id": id, "name": name, "model": model};

  static DeviceIdentity fromJson(Map<String, dynamic> json) {
    return DeviceIdentity(
      id: JsonRead.string(json, "id"),
      name: JsonRead.string(json, "name"),
      model: JsonRead.optString(json, "model") ?? "",
    );
  }

  static String _truncate(String name) {
    final runes = name.runes;
    return runes.length <= maxNameLength ? name : String.fromCharCodes(runes.take(maxNameLength));
  }
}
