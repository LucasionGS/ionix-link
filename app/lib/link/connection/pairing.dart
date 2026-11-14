import "dart:async";

import "package:flutter/foundation.dart";

import "../models/device_identity.dart";
import "../models/discovered_host.dart";
import "../models/paired_host.dart";
import "../models/pairing_uri.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "../protocol/link_crypto.dart";
import "../protocol/message.dart";
import "../store/link_store.dart";
import "link_connection.dart";

/// The two pairing flows (`PROTOCOL.md` sections 4.2–4.5). Both end with the host and its key saved in [LinkStore];
/// the caller ([Link]) then connects normally. The pairing socket is closed afterwards in v1.
class LinkPairing {
  LinkPairing._();

  /// Pairing A: connect to [uri]'s addresses pinned to its fingerprint, send `pair.request {token}`, save the host.
  /// @throws LinkPairingException on `pair.reject` (`token_invalid` when expired or used).
  /// @throws LinkCertificateException / LinkConnectionException when no address works.
  static Future<PairedHost> withUri(PairingUri uri, DeviceIdentity identity, LinkStore store) async {
    final connection = await LinkConnection.openAny(uri.addresses, uri.port, pin: uri.fingerprint, timeout: LinkProtocol.connectTimeout);
    try {
      final reply = await connection.request(
        LinkTypes.pairRequest,
        _requestBody(identity, {"token": uri.token}),
        LinkProtocol.pairTimeout,
      );
      return await _accepted(
        reply,
        connection,
        store,
        port: uri.port,
        addresses: [connection.address, ...uri.addresses],
        expectedHostId: uri.hostId,
      );
    } finally {
      await connection.close();
    }
  }

  /// Pairing B (`PROTOCOL.md` 4.3): connect to [host] unpinned (trust on first use), then commit-then-reveal: send
  /// `pair.request {commit: SHA-256(Np)}`, get `pair.challenge {nonce: Nd}`, compute the code from the certificate
  /// seen, `Np` and `Nd`, and send `pair.confirm {nonce: Np}`. Returns once the request is sent; [CodePairing.code]
  /// appears when the challenge arrives, and [CodePairing.result] completes when the desktop user decides.
  /// @throws LinkConnectionException when the host cannot be reached.
  /// @throws LinkPairingException (`changed`) when the host presents another certificate than it announced: the list
  /// of nearby desktops is out of date. The announce proves nothing either way; only the code comparison does.
  static Future<CodePairing> withCode(DiscoveredHost host, DeviceIdentity identity, LinkStore store) async {
    // The only unpinned connection the app ever makes.
    final connection = await LinkConnection.open(host.address, host.port, timeout: LinkProtocol.connectTimeout);
    if (connection.fingerprint != host.fingerprint) {
      await connection.close();
      throw LinkPairingException(
        "${host.name} changed while pairing. Search again and pick it from the list.",
        reason: LinkPairingException.reasonChanged,
      );
    }
    // The certificate is fixed by the handshake now; only after that may Np exist.
    final phoneNonce = LinkCrypto.toHex(LinkCrypto.randomBytes(32));
    final pairing = CodePairing._(host, connection.fingerprint);
    pairing._connection = connection;
    pairing._pendingSubscription = connection.messages(LinkTypes.pairPending).listen((_) {
      pairing._pending.value = true;
      if (pairing._step.value == CodePairingStep.confirming) pairing._step.value = CodePairingStep.pending;
    });
    unawaited(_exchange(pairing, connection, phoneNonce, identity, store));
    return pairing;
  }

  static Future<void> _exchange(CodePairing pairing, LinkConnection connection, String phoneNonce, DeviceIdentity identity, LinkStore store) async {
    try {
      final challenge = await connection.request(
        LinkTypes.pairRequest,
        _requestBody(identity, {"commit": LinkCrypto.commitment(phoneNonce)}),
        LinkProtocol.pairCommitTimeout,
      );
      if (challenge.type == LinkTypes.pairReject) {
        final reason = challenge.body["reason"];
        throw _rejected(reason is String ? reason : LinkPairingException.reasonRejected);
      }
      final desktopNonce = challenge.body["nonce"];
      if (challenge.type != LinkTypes.pairChallenge || desktopNonce is! String || !LinkCrypto.isHex(desktopNonce, 32)) {
        throw LinkProtocolException("The desktop answered the pairing request with a malformed ${challenge.type}.");
      }
      if (pairing._result.isCompleted) return;
      pairing._code = LinkCrypto.pairingCode(fingerprint: connection.fingerprint, phoneNonce: phoneNonce, desktopNonce: desktopNonce.toLowerCase());
      pairing._step.value = pairing._pending.value ? CodePairingStep.pending : CodePairingStep.confirming;
      final reply = await connection.request(LinkTypes.pairConfirm, {"nonce": phoneNonce}, LinkProtocol.pairTimeout);
      pairing._succeed(await _accepted(
        reply,
        connection,
        store,
        port: pairing.host.port,
        addresses: [pairing.host.address],
        expectedHostId: pairing.host.id,
      ));
    } catch (error) {
      pairing._fail(error);
    }
  }

  static Map<String, dynamic> _requestBody(DeviceIdentity identity, Map<String, dynamic> proof) {
    return {
      ...proof,
      "deviceId": identity.id,
      "name": identity.name,
      "model": identity.model,
      "protocol": LinkProtocol.version,
    };
  }

  /// Turn the reply to `pair.request` into a saved host, or throw the matching exception.
  static Future<PairedHost> _accepted(
    LinkMessage reply,
    LinkConnection connection,
    LinkStore store, {
    required int port,
    required List<String> addresses,
    required String expectedHostId,
  }) async {
    if (reply.type == LinkTypes.pairReject) {
      final reason = reply.body["reason"];
      throw _rejected(reason is String ? reason : "rejected");
    }
    if (reply.type != LinkTypes.pairAccept) {
      throw LinkProtocolException("The desktop answered the pairing request with ${reply.type}.");
    }
    final String key;
    final String hostId;
    final String hostName;
    final String fingerprint;
    try {
      key = JsonRead.string(reply.body, "key");
      hostId = JsonRead.string(reply.body, "hostId").toLowerCase();
      hostName = JsonRead.string(reply.body, "hostName");
      fingerprint = JsonRead.string(reply.body, "fingerprint").toLowerCase();
    } on LinkFormatException catch (error) {
      throw LinkProtocolException("The desktop's pairing answer is malformed: ${error.message}");
    }
    if (!LinkCrypto.isHex(key, 32)) throw LinkProtocolException("The desktop sent a malformed device key.");
    if (fingerprint != connection.fingerprint) {
      throw LinkCertificateException(
        "The desktop's pairing answer names another certificate than the one it presented.",
        expected: connection.fingerprint,
        actual: fingerprint,
      );
    }
    if (hostId != expectedHostId) {
      throw LinkProtocolException("The desktop that answered is not the one that was asked to pair.");
    }
    final host = PairedHost(
      id: hostId,
      name: hostName,
      fingerprint: fingerprint,
      port: port,
      addresses: addresses,
      pairedAt: DateTime.now(),
      lastAddress: connection.address,
    );
    await store.saveHost(host, key: key);
    return store.host(host.id) ?? host;
  }

  static LinkPairingException _rejected(String reason) {
    final message = switch (reason) {
      LinkPairingException.reasonTokenInvalid => "This pairing code has expired or was already used. Run `ionix-link pair` on the desktop again.",
      LinkPairingException.reasonNotOpen => "The desktop is not accepting phones right now. Run `ionix-link pair` on it first, then try again.",
      LinkPairingException.reasonBadCommit => "The desktop could not verify this phone's answer, so something interfered with the pairing. Try again.",
      LinkPairingException.reasonRejected => "The desktop declined the pairing.",
      LinkPairingException.reasonTimeout => "Nobody answered on the desktop in time. Try again and accept the notification there.",
      LinkPairingException.reasonBusy => "The desktop is already pairing with another phone. Try again in a minute.",
      LinkPairingException.reasonRateLimited => "Too many pairing attempts. Run `ionix-link pair` on the desktop again, then retry.",
      LinkPairingException.reasonProtocol => "The desktop runs a version of Ionix Link this app cannot talk to. Update both.",
      _ => "The desktop refused the pairing ($reason).",
    };
    return LinkPairingException(message, reason: reason);
  }
}

/// Where a pairing B exchange is.
enum CodePairingStep {
  /// The commit is sent; the desktop's nonce, and so the code, is not known yet.
  exchanging,

  /// [CodePairing.code] is known and shown; waiting for the desktop to ask its user.
  confirming,

  /// The desktop is asking its user (`pair.pending` arrived).
  pending,
}

/// A pairing B request in flight.
class CodePairing {
  CodePairing._(this.host, this.fingerprint) {
    // Nobody may be listening yet when the desktop answers; an unobserved failure must not be reported as uncaught.
    _result.future.ignore();
  }

  /// The host being paired with.
  final DiscoveredHost host;

  /// The fingerprint that will be pinned on success, hex64.
  final String fingerprint;

  final Completer<PairedHost> _result = Completer();
  final ValueNotifier<bool> _pending = ValueNotifier(false);
  final ValueNotifier<CodePairingStep> _step = ValueNotifier(CodePairingStep.exchanging);
  String? _code;
  LinkConnection? _connection;
  StreamSubscription<LinkMessage>? _pendingSubscription;

  /// The 6-digit code to show, from [LinkCrypto.pairingCode]; null until the desktop's challenge arrived
  /// ([step] past [CodePairingStep.exchanging]). Display as `"931 221"`.
  String? get code => _code;

  /// [code] split into two groups of three, as the desktop shows it (`931 221`), or null while not known.
  String? get displayCode {
    final code = _code;
    return code == null ? null : "${code.substring(0, 3)} ${code.substring(3)}";
  }

  /// The exchange's progress; listen to it to show the code once it exists.
  ValueListenable<CodePairingStep> get step => _step;

  /// Whether the desktop has said it is waiting for its user (`pair.pending` arrived).
  bool get isPending => _pending.value;

  /// [isPending] as a listenable.
  ValueListenable<bool> get pending => _pending;

  /// Completes with the saved host on `pair.accept`.
  /// @throws LinkPairingException on `pair.reject` (`not_open`, `bad_commit`, `rejected`, `timeout`, `busy`,
  /// `rate_limited`, `protocol`) or [cancel] (`cancelled`).
  Future<PairedHost> get result => _result.future;

  /// Give up: close the socket; [result] fails with reason `cancelled`.
  Future<void> cancel() async {
    if (!_result.isCompleted) {
      _result.completeError(LinkPairingException("Pairing was cancelled.", reason: LinkPairingException.reasonCancelled));
    }
    await _finish();
  }

  void _succeed(PairedHost host) {
    if (!_result.isCompleted) _result.complete(host);
    unawaited(_finish());
  }

  void _fail(Object error) {
    if (!_result.isCompleted) {
      _result.completeError(error is LinkException ? error : LinkException("Pairing failed: $error"));
    }
    unawaited(_finish());
  }

  Future<void> _finish() async {
    await _pendingSubscription?.cancel();
    _pendingSubscription = null;
    final connection = _connection;
    _connection = null;
    await connection?.close();
  }
}
