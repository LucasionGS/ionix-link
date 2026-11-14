import "dart:math";

import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "../protocol/link_crypto.dart";

/// A desktop that answered a UDP discovery query (`announce`, `PROTOCOL.md` section 4.1).
class DiscoveredHost {
  /// Create one. Throws [LinkFormatException] on a malformed id or fingerprint.
  DiscoveredHost({
    required String id,
    required this.name,
    required this.address,
    required this.port,
    required String fingerprint,
    required this.protocol,
    required this.protocolMin,
  }) : id = id.toLowerCase(),
       fingerprint = fingerprint.toLowerCase() {
    if (!LinkCrypto.isHex(this.id, 16)) throw LinkFormatException("The host id must be 32 hex characters.");
    if (!LinkCrypto.isHex(this.fingerprint, 32)) throw LinkFormatException("The fingerprint must be 64 hex characters.");
    if (port < 1 || port > 65535) throw LinkFormatException("Port $port is not a TCP port.");
    if (address.isEmpty) throw LinkFormatException("The host needs an address.");
  }

  /// Host id, hex32.
  final String id;

  /// Host name.
  final String name;

  /// The source address of the announce datagram.
  final String address;

  /// TCP port.
  final int port;

  /// Certificate fingerprint the host claims, hex64.
  final String fingerprint;

  /// Highest protocol version the host speaks.
  final int protocol;

  /// Lowest protocol version the host speaks.
  final int protocolMin;

  /// Whether this app can talk to it (protocol ranges overlap).
  bool get isCompatible =>
      max(protocolMin, LinkProtocol.versionMin) <= min(protocol, LinkProtocol.version);

  /// Parse an `announce` datagram body plus its source [address]. Returns null for anything that is not a valid
  /// announce (no `ionixlink: 1`, wrong `type`, bad fields).
  static DiscoveredHost? fromAnnounce(Map<String, dynamic> json, String address) {
    if (json["ionixlink"] != 1 || json["type"] != "announce") return null;
    try {
      final protocol = JsonRead.integer(json, "protocol");
      return DiscoveredHost(
        id: JsonRead.string(json, "hostId"),
        name: JsonRead.string(json, "hostName"),
        address: address,
        port: JsonRead.integer(json, "port"),
        fingerprint: JsonRead.string(json, "fingerprint"),
        protocol: protocol,
        protocolMin: JsonRead.optInt(json, "protocolMin") ?? protocol,
      );
    } on LinkException {
      return null;
    }
  }

  @override
  String toString() => "DiscoveredHost($name, $address:$port)";
}
