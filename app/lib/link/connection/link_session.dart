import "dart:async";

import "package:flutter/foundation.dart";

import "../models/device_identity.dart";
import "../models/paired_host.dart";
import "../plugins/plugin_client.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../store/link_store.dart";
import "discovery.dart";
import "link_connection.dart";
import "link_status.dart";

/// Keeps one paired host connected: opens a [LinkConnection] per attempt, authenticates, attaches the plugin clients
/// on `ready`, detaches them on close, and retries with [LinkProtocol.reconnectBackoff].
///
/// Each attempt tries [PairedHost.connectOrder], then refinds the host by UDP ([LinkDiscovery.find]) and, if its
/// fingerprint matches, stores the new address. A wrong certificate at one address, or an announce claiming another
/// certificate, only rules out that candidate: anyone on the network can answer at an address or send an announce, so
/// neither may end the pairing. It shows up as [LinkStatus.warning] and the session keeps backing off. Only the pinned
/// desktop itself can end it: `unknown_device` or `auth_failed` over a pinned connection, or `pair.unpair`, end in
/// [LinkState.forgotten] with no retry; `pair.unpair` also removes the host from [LinkStore].
class LinkSession {
  /// Create a session; nothing happens until [start].
  /// @param identityProvider When set, read for every `hello` instead of [identity], so a renamed phone takes effect
  /// on the next connection.
  LinkSession({
    required this.host,
    required this.identity,
    required this.store,
    required this.clients,
    required this.appVersion,
    this.identityProvider,
  }) : _status = ValueNotifier(LinkStatus(LinkState.idle, host: host));

  /// The host this session is for.
  final PairedHost host;

  /// This phone.
  final DeviceIdentity identity;

  /// Returns the identity to send, read on every attempt. Null: always [identity].
  final DeviceIdentity Function()? identityProvider;

  /// Where the host's key is read and its addresses/lastSeen written.
  final LinkStore store;

  /// Plugin clients to attach on `ready`; their descriptors go into `hello.plugins`.
  final List<PluginClient> clients;

  /// Sent as `hello.appVersion`.
  final String appVersion;

  final ValueNotifier<LinkStatus> _status;
  bool _started = false;
  bool _stopped = false;
  bool _attempting = false;
  int _failures = 0;
  Timer? _retryTimer;
  LinkConnection? _attemptConnection;
  LinkConnection? _connection;
  StreamSubscription<Object?>? _unpairSubscription;
  String? _warning;

  /// Current status. Never null.
  ValueListenable<LinkStatus> get status => _status;

  /// The live connection while [LinkState.ready], else null.
  LinkConnection? get connection => _connection;

  /// The stored copy of [host] (addresses and name kept up to date), or [host] once it was removed.
  PairedHost get _current => store.host(host.id) ?? host;

  /// Start connecting (no-op when already started).
  void start() {
    if (_started || _stopped) return;
    _started = true;
    unawaited(_attempt());
  }

  /// Skip the backoff wait and try now (app resumed, network changed, user pulled to refresh). No-op while
  /// connecting, ready or forgotten.
  void retryNow() {
    if (_stopped || !_started || _status.value.state != LinkState.retrying) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_attempt());
  }

  /// Stop: close the connection, cancel timers, detach clients. Status becomes [LinkState.idle].
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    final attempt = _attemptConnection;
    final live = _connection;
    _attemptConnection = null;
    _detach();
    _status.value = const LinkStatus(LinkState.idle);
    await Future.wait([?attempt?.close(), ?live?.close()]);
  }

  Future<void> _attempt() async {
    if (_attempting || _stopped) return;
    _attempting = true;
    try {
      await _connectOnce();
    } on LinkException catch (error) {
      _onFailure(error);
    } catch (error, stack) {
      debugPrint("ionix-link: connection attempt failed: $error\n$stack");
      _onFailure(LinkException("Connecting failed unexpectedly ($error).", code: LinkErrorCode.internal));
    } finally {
      _attempting = false;
    }
  }

  Future<void> _connectOnce() async {
    _warning = null;
    _setStatus(LinkState.connecting, clearError: false);
    final key = await store.keyFor(host.id);
    if (_stopped) return;
    if (key == null) {
      throw LinkAuthException("The key for ${_current.name} is missing. Pair again.", code: LinkErrorCode.unknownDevice);
    }

    final connection = await _open();
    if (connection == null) return;
    _attemptConnection = connection;
    _setStatus(LinkState.authenticating, address: connection.address);
    await connection.authenticate(
      identity: identityProvider?.call() ?? identity,
      key: key,
      plugins: [for (final client in clients) client.localInfo],
      appVersion: appVersion,
      onReady: (ready) {
        if (_stopped) return;
        _connection = connection;
        for (final client in clients) {
          client.attach(connection, ready.plugin(client.name));
        }
        _unpairSubscription = connection.messages(LinkTypes.pairUnpair).listen((_) => _onUnpaired(connection));
      },
    );
    _attemptConnection = null;
    if (_stopped) {
      await connection.close();
      return;
    }
    _failures = 0;
    _setStatus(LinkState.ready, address: connection.address, clearError: true);
    final ready = connection.ready!;
    final current = _current;
    _saveQuietly(current.copyWith(
      name: ready.hostName.isEmpty ? null : ready.hostName,
      addresses: [connection.address, ...current.addresses],
      lastAddress: connection.address,
      lastSeen: DateTime.now(),
    ));
    unawaited(connection.done.then((reason) => _onClosed(connection, reason)));
  }

  /// Open a pinned connection: every known address in parallel, then a UDP refind. Returns null when stopped.
  Future<LinkConnection?> _open() async {
    final host = _current;
    try {
      final connection = await LinkConnection.openAny(
        host.connectOrder,
        host.port,
        pin: host.fingerprint,
        timeout: LinkProtocol.connectTimeout,
        onFailure: (address, error) {
          if (error is LinkCertificateException) _wrongCertificateAt(address);
        },
      );
      if (!_stopped) return connection;
      await connection.close();
      return null;
    } on LinkException catch (error) {
      // Unreachable, or only wrong certificates: either way, look for the host elsewhere.
      debugPrint("ionix-link: ${host.name} not reached at its known addresses: ${error.message}");
    }
    if (_stopped) return null;

    final found = await LinkDiscovery.find(
      host.id,
      fingerprint: host.fingerprint,
      port: host.port,
      onIgnored: (announce) {
        debugPrint("ionix-link: ignoring an announce for ${host.name} from ${announce.address} with fingerprint ${announce.fingerprint}");
        _warn("Something at ${announce.address} claims to be ${host.name} with a different certificate. It was ignored.");
      },
    );
    if (_stopped) return null;
    if (found == null) throw LinkConnectionException("Could not reach ${host.name}. Is it on the same network?");
    _setStatus(LinkState.connecting, address: found.address);
    final LinkConnection connection;
    try {
      connection = await LinkConnection.open(found.address, found.port, pin: host.fingerprint, timeout: LinkProtocol.connectTimeout);
    } on LinkCertificateException {
      _wrongCertificateAt(found.address);
      throw LinkConnectionException("Could not reach ${host.name}. Is it on the same network?");
    }
    if (_stopped) {
      await connection.close();
      return null;
    }
    _saveQuietly(host.copyWith(port: found.port, addresses: [found.address, ...host.addresses], lastAddress: found.address));
    return connection;
  }

  void _wrongCertificateAt(String address) {
    debugPrint("ionix-link: $address answered for ${_current.name} with a different certificate; skipped");
    _warn("Another device answered at $address with a different certificate. It was skipped.");
  }

  void _warn(String message) {
    _warning = message;
    if (_stopped) return;
    _status.value = _status.value.copyWith(warning: message);
  }

  void _onClosed(LinkConnection connection, Object? reason) {
    if (_connection != connection) return;
    _detach();
    if (_stopped || _status.value.state == LinkState.forgotten) return;
    if (reason is LinkRemoteException && (reason.code == LinkErrorCode.unknownDevice || reason.code == LinkErrorCode.authFailed)) {
      _forget(LinkAuthException(reason.message, code: reason.code));
      return;
    }
    _scheduleRetry(reason is LinkException ? reason : LinkConnectionException("The connection to ${_current.name} closed."));
  }

  void _onUnpaired(LinkConnection connection) {
    final name = _current.name;
    _forget(LinkAuthException("Unpaired by $name.", code: LinkErrorCode.unknownDevice));
    unawaited(store.removeHost(host.id).catchError((Object error) => debugPrint("ionix-link: removing $name failed: $error")));
    unawaited(connection.close());
  }

  void _onFailure(LinkException error) {
    final attempt = _attemptConnection;
    _attemptConnection = null;
    if (attempt != null) unawaited(attempt.close());
    if (_stopped) return;
    if (error is LinkAuthException && (error.code == LinkErrorCode.unknownDevice || error.code == LinkErrorCode.authFailed)) {
      _forget(error);
      return;
    }
    _scheduleRetry(error);
  }

  void _scheduleRetry(LinkException error) {
    final delays = LinkProtocol.reconnectBackoff;
    final delay = delays[_failures < delays.length ? _failures : delays.length - 1];
    _failures++;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_attempt());
    });
    _status.value = LinkStatus(
      LinkState.retrying,
      host: _current,
      address: _status.value.address,
      error: error,
      retryAt: DateTime.now().add(delay),
      warning: _warning,
    );
  }

  void _forget(LinkException error) {
    _retryTimer?.cancel();
    _retryTimer = null;
    _detach();
    _status.value = LinkStatus(LinkState.forgotten, host: _current, address: _status.value.address, error: error);
  }

  void _detach() {
    _unpairSubscription?.cancel();
    _unpairSubscription = null;
    if (_connection == null) return;
    _connection = null;
    for (final client in clients) {
      client.detach();
    }
  }

  void _setStatus(LinkState state, {String? address, bool clearError = false}) {
    if (_stopped) return;
    final previous = _status.value;
    _status.value = LinkStatus(
      state,
      host: _current,
      address: address ?? previous.address,
      error: clearError ? null : previous.error,
      warning: _warning,
    );
  }

  void _saveQuietly(PairedHost updated) {
    store.updateHost(updated).catchError((Object error) => debugPrint("ionix-link: saving ${updated.name} failed: $error"));
  }
}
