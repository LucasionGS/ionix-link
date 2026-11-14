import "../models/paired_host.dart";
import "../protocol/errors.dart";

/// Where the session with the current host is.
enum LinkState {
  /// No current host (nothing paired, or the user disconnected).
  idle,

  /// Opening TCP + TLS to one of the host's addresses, or refinding it by UDP.
  connecting,

  /// TLS is up; `hello`/`challenge`/`auth` in progress.
  authenticating,

  /// `ready` received; plugins are attached.
  ready,

  /// Waiting [LinkStatus.retryAt] before the next attempt.
  retrying,

  /// The desktop does not know this phone any more (`unknown_device`, `auth_failed`, `pair.unpair`), or its
  /// certificate changed. No retries; the UI offers to pair again.
  forgotten,
}

/// Immutable snapshot of the session state, published through `Link.connectionStatus`.
class LinkStatus {
  const LinkStatus(this.state, {this.host, this.address, this.error, this.retryAt, this.warning});

  /// The idle status.
  static const LinkStatus idleStatus = LinkStatus(LinkState.idle);

  /// Current state.
  final LinkState state;

  /// The host this status is about, null when [LinkState.idle].
  final PairedHost? host;

  /// Address of the current or last attempted connection.
  final String? address;

  /// Why the last attempt failed, if it did.
  final LinkException? error;

  /// When the next attempt runs, while [LinkState.retrying].
  final DateTime? retryAt;

  /// Something odd the last attempt saw but did not act on, such as another device answering at a known address with
  /// a different certificate, or an announce claiming another certificate. Not a reason to pair again. Null when
  /// nothing happened, and cleared on `ready`.
  final String? warning;

  /// Whether [state] is [LinkState.ready].
  bool get isReady => state == LinkState.ready;

  /// A copy with the given fields replaced. Pass `clearError: true` to drop [error]. [retryAt] only survives while the
  /// state stays [LinkState.retrying].
  LinkStatus copyWith({LinkState? state, PairedHost? host, String? address, LinkException? error, DateTime? retryAt, bool clearError = false, String? warning}) {
    final next = state ?? this.state;
    return LinkStatus(
      next,
      host: host ?? this.host,
      address: address ?? this.address,
      error: clearError ? error : (error ?? this.error),
      retryAt: next == LinkState.retrying ? (retryAt ?? this.retryAt) : null,
      warning: warning ?? this.warning,
    );
  }

  @override
  String toString() => "LinkStatus(${state.name}${address == null ? "" : " $address"}${error == null ? "" : ", ${error!.code.wire}"})";
}
