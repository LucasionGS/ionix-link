/// The link layer's exception hierarchy. Every exception the link layer throws is a [LinkException],
/// so the UI can catch one type and show [LinkException.message].
library;

/// Error codes of `error` messages (`PROTOCOL.md` section 7), plus local-only ones.
enum LinkErrorCode {
  badFrame("bad_frame"),
  tooLarge("too_large"),
  badJson("bad_json"),
  badMessage("bad_message"),
  unknownType("unknown_type"),
  notAuthenticated("not_authenticated"),
  protocolVersion("protocol_version"),
  unknownDevice("unknown_device"),
  authFailed("auth_failed"),
  rateLimited("rate_limited"),
  replaced("replaced"),
  pluginUnavailable("plugin_unavailable"),
  invalidArgument("invalid_argument"),
  notFound("not_found"),
  busy("busy"),
  unavailable("unavailable"),
  timeout("timeout"),
  failed("failed"),
  internal("internal"),
  shutdown("shutdown"),

  // Local only, never on the wire
  /// The socket could not be opened or closed under a pending request.
  connection("connection"),
  /// The certificate did not match the pinned fingerprint.
  certificate("certificate"),
  /// Pairing was refused or failed.
  pairing("pairing");

  const LinkErrorCode(this.wire);

  /// The code as written in an `error` body.
  final String wire;

  /// Parse a wire code. Unknown codes map to [LinkErrorCode.failed], as the protocol requires.
  static LinkErrorCode fromWire(String code) {
    for (final value in values) {
      if (value.wire == code && !value.isLocal) return value;
    }
    return LinkErrorCode.failed;
  }

  /// Whether this code is local only and must never be written on the wire.
  bool get isLocal => this == connection || this == certificate || this == pairing;

  /// The code to put in an outgoing `error` body: local-only codes are sent as [LinkErrorCode.failed].
  String get outgoing => isLocal ? LinkErrorCode.failed.wire : wire;
}

/// Base of every exception the link layer throws.
class LinkException implements Exception {
  LinkException(this.message, {this.code = LinkErrorCode.failed});

  /// One readable sentence, suitable for a snackbar.
  final String message;

  /// What kind of failure this is.
  final LinkErrorCode code;

  @override
  String toString() => "LinkException(${code.wire}): $message";
}

/// The socket failed: connect refused, timed out, or closed while a request was pending.
class LinkConnectionException extends LinkException {
  LinkConnectionException(super.message) : super(code: LinkErrorCode.connection);
}

/// The host presented a certificate whose SHA-256 is not the pinned one. The user must pair again.
class LinkCertificateException extends LinkException {
  LinkCertificateException(super.message, {required this.expected, required this.actual})
    : super(code: LinkErrorCode.certificate);

  /// Pinned fingerprint, hex.
  final String expected;

  /// Fingerprint the host presented, hex.
  final String actual;
}

/// The peer sent something that breaks the framing or message rules.
class LinkProtocolException extends LinkException {
  LinkProtocolException(super.message, {super.code = LinkErrorCode.badMessage});
}

/// The peer answered with an `error` message.
class LinkRemoteException extends LinkException {
  LinkRemoteException(super.message, {required super.code, this.fatal = false, this.details = const {}});

  /// Whether the peer closes the connection after it.
  final bool fatal;

  /// The error's `details` object.
  final Map<String, dynamic> details;

  /// Build one from an `error` message body.
  static LinkRemoteException fromBody(Map<String, dynamic> body) {
    final code = body["code"];
    final message = body["message"];
    final details = body["details"];
    return LinkRemoteException(
      message is String && message.isNotEmpty ? message : "The desktop reported an error (${code ?? "unknown"}).",
      code: LinkErrorCode.fromWire(code is String ? code : ""),
      fatal: body["fatal"] == true,
      details: details is Map<String, dynamic> ? details : const {},
    );
  }
}

/// A request got no reply within its timeout.
class LinkTimeoutException extends LinkException {
  LinkTimeoutException(super.message) : super(code: LinkErrorCode.timeout);
}

/// Authentication failed: unknown device, bad MAC, rate limited, or no common protocol.
class LinkAuthException extends LinkException {
  LinkAuthException(super.message, {required super.code});
}

/// Pairing was rejected, timed out, or the token was invalid.
class LinkPairingException extends LinkException {
  LinkPairingException(super.message, {required this.reason}) : super(code: LinkErrorCode.pairing);

  /// The `pair.reject` reason (one of the `reason*` constants below), `cancelled` when the phone gave up, or
  /// `changed` when the desktop presented another certificate than it announced.
  final String reason;

  // pair.reject reasons (PROTOCOL.md 4.5)
  static const String reasonTokenInvalid = "token_invalid";
  static const String reasonNotOpen = "not_open";
  static const String reasonBadCommit = "bad_commit";
  static const String reasonRejected = "rejected";
  static const String reasonTimeout = "timeout";
  static const String reasonBusy = "busy";
  static const String reasonRateLimited = "rate_limited";
  static const String reasonProtocol = "protocol";

  // Local reasons
  static const String reasonCancelled = "cancelled";
  static const String reasonChanged = "changed";

  /// Whether the desktop has no pairing window open: the user must run `ionix-link pair` there first.
  bool get isNotOpen => reason == reasonNotOpen;
}

/// A plugin method was called while that plugin is not negotiated on the current connection.
class LinkPluginUnavailableException extends LinkException {
  LinkPluginUnavailableException(this.plugin)
    : super("The desktop does not offer $plugin right now.", code: LinkErrorCode.pluginUnavailable);

  /// Plugin name.
  final String plugin;
}

/// A model was constructed from invalid data (bad URI, bad JSON field).
class LinkFormatException extends LinkException {
  LinkFormatException(super.message) : super(code: LinkErrorCode.invalidArgument);
}
