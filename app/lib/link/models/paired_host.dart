import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "../protocol/link_crypto.dart";

/// A desktop this phone is paired with, as stored by [LinkStore]. The device key is **not** part of it: it lives in
/// secure storage, read with [LinkStore.keyFor].
class PairedHost {
  /// Create a host. Throws [LinkFormatException] if [id] is not hex32, [fingerprint] not hex64, or [port] out of range.
  PairedHost({
    required String id,
    required this.name,
    required String fingerprint,
    required this.port,
    required List<String> addresses,
    required this.pairedAt,
    this.lastAddress,
    this.lastSeen,
  }) : id = id.toLowerCase(),
       fingerprint = fingerprint.toLowerCase(),
       addresses = List.unmodifiable(addresses.where((address) => address.isNotEmpty).toSet().take(maxAddresses)) {
    if (!LinkCrypto.isHex(this.id, 16)) throw LinkFormatException("The host id must be 32 hex characters.");
    if (!LinkCrypto.isHex(this.fingerprint, 32)) throw LinkFormatException("The fingerprint must be 64 hex characters.");
    if (port < 1 || port > 65535) throw LinkFormatException("Port $port is not a TCP port.");
  }

  /// Most addresses kept per host. The session puts each address that reached `ready` first, so these are the most
  /// recently successful ones.
  static const int maxAddresses = 4;

  /// Host id, hex32.
  final String id;

  /// Host name as the desktop reported it last.
  final String name;

  /// Pinned certificate fingerprint, hex64.
  final String fingerprint;

  /// TCP port.
  final int port;

  /// Known addresses, preference order (from the pairing URI or discovery), at most [maxAddresses].
  final List<String> addresses;

  /// When pairing completed.
  final DateTime pairedAt;

  /// The address of the last successful connection. Tried first.
  final String? lastAddress;

  /// When the last connection reached `ready`.
  final DateTime? lastSeen;

  /// Every address to try, in order: [lastAddress] first, then [addresses] without duplicates.
  List<String> get connectOrder => {?lastAddress, ...addresses}.toList();

  /// A copy with the given fields replaced.
  PairedHost copyWith({String? name, int? port, List<String>? addresses, String? lastAddress, DateTime? lastSeen}) {
    return PairedHost(
      id: id,
      name: name ?? this.name,
      fingerprint: fingerprint,
      port: port ?? this.port,
      addresses: addresses ?? this.addresses,
      pairedAt: pairedAt,
      lastAddress: lastAddress ?? this.lastAddress,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// JSON for the store file. Times as Unix ms.
  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "name": name,
      "fingerprint": fingerprint,
      "port": port,
      "addresses": addresses,
      "paired": pairedAt.millisecondsSinceEpoch,
      if (lastAddress != null) "lastAddress": lastAddress,
      if (lastSeen != null) "lastSeen": lastSeen!.millisecondsSinceEpoch,
    };
  }

  /// Throws [LinkFormatException] on a missing or mistyped field.
  static PairedHost fromJson(Map<String, dynamic> json) {
    final lastSeen = JsonRead.optInt(json, "lastSeen");
    return PairedHost(
      id: JsonRead.string(json, "id"),
      name: JsonRead.string(json, "name"),
      fingerprint: JsonRead.string(json, "fingerprint"),
      port: JsonRead.integer(json, "port"),
      addresses: [
        for (final address in JsonRead.list(json, "addresses"))
          if (address is String) address,
      ],
      pairedAt: DateTime.fromMillisecondsSinceEpoch(JsonRead.integer(json, "paired")),
      lastAddress: JsonRead.optString(json, "lastAddress"),
      lastSeen: lastSeen == null ? null : DateTime.fromMillisecondsSinceEpoch(lastSeen),
    );
  }

  @override
  String toString() => "PairedHost($name, $id)";
}
