import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/link_crypto.dart";

/// The `ionixlink://pair?...` URI from a QR code (`PROTOCOL.md` section 4.2).
class PairingUri {
  /// Create one from parts. Throws [LinkFormatException] on bad hex, an empty [addresses] list, or a bad [port].
  PairingUri({
    required String hostId,
    required this.hostName,
    required this.port,
    required String fingerprint,
    required String token,
    required this.expires,
    required List<String> addresses,
  }) : hostId = hostId.toLowerCase(),
       fingerprint = fingerprint.toLowerCase(),
       token = token.toLowerCase(),
       addresses = List.unmodifiable(addresses.map(_unbracket).where((address) => address.isNotEmpty).toSet()) {
    if (!LinkCrypto.isHex(this.hostId, 16)) throw LinkFormatException("The pairing code has a malformed host id.");
    if (!LinkCrypto.isHex(this.fingerprint, 32)) throw LinkFormatException("The pairing code has a malformed fingerprint.");
    if (!LinkCrypto.isHex(this.token, 16)) throw LinkFormatException("The pairing code has a malformed token.");
    if (port < 1 || port > 65535) throw LinkFormatException("The pairing code has an invalid port.");
    if (this.addresses.isEmpty) throw LinkFormatException("The pairing code lists no address for the desktop.");
  }

  /// The URI scheme.
  static const String scheme = "ionixlink";

  /// Host id, hex32.
  final String hostId;

  /// Host name, decoded.
  final String hostName;

  /// TCP port.
  final int port;

  /// Certificate fingerprint to pin, hex64.
  final String fingerprint;

  /// One-time pairing token, hex32.
  final String token;

  /// When the token expires (informational; the daemon enforces it).
  final DateTime expires;

  /// Addresses to try, preference order.
  final List<String> addresses;

  /// Whether [expires] has passed.
  bool get isExpired => DateTime.now().isAfter(expires);

  /// Parse a scanned string. Throws [LinkFormatException] with a readable message for a non-Ionix QR code, a newer
  /// URI version (`v` > [LinkProtocol.uriVersion]: "Update Ionix Link to pair with this desktop."), or bad params.
  static PairingUri parse(String text) {
    final Uri uri;
    try {
      uri = Uri.parse(text.trim());
    } on FormatException {
      throw LinkFormatException("This is not an Ionix Link pairing code.");
    }
    final target = uri.host.isNotEmpty ? uri.host : uri.path;
    if (uri.scheme != scheme || target.toLowerCase() != "pair") {
      throw LinkFormatException("This is not an Ionix Link pairing code.");
    }
    final Map<String, List<String>> params;
    try {
      params = uri.queryParametersAll;
    } on FormatException {
      throw LinkFormatException("The pairing code is damaged; scan it again.");
    }

    String one(String key, String what) {
      final values = params[key];
      if (values == null || values.isEmpty || values.first.isEmpty) {
        throw LinkFormatException("The pairing code has no $what. Run `ionix-link pair` again.");
      }
      return values.first;
    }

    int number(String key, String what) {
      final value = int.tryParse(one(key, what));
      if (value == null) throw LinkFormatException("The pairing code has an invalid $what.");
      return value;
    }

    final version = number("v", "version");
    if (version > LinkProtocol.uriVersion) throw LinkFormatException("Update Ionix Link to pair with this desktop.");
    if (version < 1) throw LinkFormatException("The pairing code has an invalid version.");
    return PairingUri(
      hostId: one("host", "host id"),
      hostName: one("name", "host name"),
      port: number("port", "port"),
      fingerprint: one("fp", "fingerprint"),
      token: one("token", "token"),
      expires: DateTime.fromMillisecondsSinceEpoch(number("exp", "expiry")),
      addresses: params["addr"] ?? const [],
    );
  }

  /// Format as a URI string (the inverse of [parse]).
  @override
  String toString() {
    final params = [
      "v=${LinkProtocol.uriVersion}",
      "host=$hostId",
      "name=${Uri.encodeComponent(hostName)}",
      "port=$port",
      "fp=$fingerprint",
      "token=$token",
      "exp=${expires.millisecondsSinceEpoch}",
      for (final address in addresses) "addr=${Uri.encodeComponent(address)}",
    ];
    return "$scheme://pair?${params.join("&")}";
  }

  /// IPv6 addresses are sent unbracketed; accept a bracketed one anyway.
  static String _unbracket(String address) {
    final trimmed = address.trim();
    if (trimmed.startsWith("[") && trimmed.endsWith("]")) return trimmed.substring(1, trimmed.length - 1);
    return trimmed;
  }
}
