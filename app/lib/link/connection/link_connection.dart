import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";

import "../models/device_identity.dart";
import "../models/plugin_info.dart";
import "../models/ready_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/frame_codec.dart";
import "../protocol/link_crypto.dart";
import "../protocol/message.dart";

/// Handler of an incoming request. Returns the reply body; throwing a [LinkException] sends an `error` reply with
/// its code instead.
typedef LinkRequestHandler = FutureOr<Map<String, dynamic>> Function(LinkMessage request);

/// One TLS socket to a daemon: framing, certificate pinning, the handshake, request/reply matching and keepalive.
/// It does **not** reconnect; [LinkSession] makes a new one per attempt.
///
/// Lifecycle: [open] → (optionally a pairing request via [request]) → [authenticate] → messages → [close] / [done].
class LinkConnection {
  LinkConnection._(this.address, this.port, this.fingerprint);

  /// Address this socket is connected to.
  final String address;

  /// TCP port.
  final int port;

  /// Fingerprint (hex64) of the certificate the host presented. Equals the pin when one was given.
  final String fingerprint;

  /// Time from [authenticate] to `ready` before giving up.
  static const Duration handshakeTimeout = Duration(seconds: 10);

  /// How long [close] waits for queued frames to reach the socket.
  static const Duration _closeGrace = Duration(seconds: 2);

  /// `TCP_NOTSENT_LOWAT` on Linux and Android: caps the kernel's unsent queue, so a stalled link backs up into
  /// [pendingWriteBytes] (where the input client sees it) instead of into a buffer of hundreds of kilobytes.
  static const int _tcpNotSentLowat = 25;
  static const int _notSentLowatBytes = 16 * 1024;

  late final SecureSocket _socket;
  StreamSubscription<Uint8List>? _subscription;
  final FrameDecoder _decoder = FrameDecoder();
  final Map<int, _PendingRequest> _pending = {};
  final Map<String, LinkRequestHandler> _handlers = {};
  final StreamController<LinkMessage> _pushes = StreamController.broadcast();
  final Completer<Object?> _done = Completer();
  final Stopwatch _sinceReceived = Stopwatch();
  Future<void>? _closing;
  bool _closed = false;
  bool _destroyed = false;
  int _lastId = 0;
  ReadyInfo? _ready;
  _Handshake? _handshake;
  Timer? _keepalive;
  bool _pinged = false;

  // Writer: one flush at a time, frames added meanwhile are queued and written together when it completes.
  bool _flushing = false;
  final List<Uint8List> _queue = [];
  int _queuedBytes = 0;
  int _flushingBytes = 0;
  Completer<void>? _drained;

  /// Connect with TLS and check the certificate.
  /// @param pin The expected fingerprint, hex64. Null only for pairing B's trust on first use.
  /// @throws LinkConnectionException on connect failure or [timeout].
  /// @throws LinkCertificateException when [pin] is set and does not match (checked in `onBadCertificate` **and**
  /// against `socket.peerCertificate` after the handshake).
  static Future<LinkConnection> open(String address, int port, {String? pin, Duration timeout = const Duration(seconds: 3)}) async {
    final expected = pin?.toLowerCase();
    String? presented;
    final connecting = SecureSocket.connect(
      address,
      port,
      context: SecurityContext(withTrustedRoots: false),
      timeout: timeout,
      onBadCertificate: (certificate) {
        presented = LinkCrypto.fingerprint(certificate.der);
        return expected == null || presented == expected;
      },
    );
    final SecureSocket socket;
    try {
      socket = await connecting.timeout(timeout);
    } on TimeoutException {
      // The handshake may still finish later; that socket must not leak.
      unawaited(connecting.then((late) => late.destroy(), onError: (Object _) {}));
      throw LinkConnectionException("$address:$port did not answer within ${timeout.inSeconds} s.");
    } on TlsException catch (error) {
      final seen = presented;
      if (expected != null && seen != null && seen != expected) throw _certificateChanged(expected, seen);
      throw LinkConnectionException("The secure connection to $address:$port failed (${error.message}).");
    } on SocketException catch (error) {
      throw LinkConnectionException("Could not reach $address:$port (${error.osError?.message ?? error.message}).");
    } on ArgumentError catch (error) {
      throw LinkConnectionException("\"$address\" is not a usable address (${error.message}).");
    }

    final certificate = socket.peerCertificate;
    if (certificate == null) {
      socket.destroy();
      throw LinkConnectionException("$address:$port presented no certificate.");
    }
    final actual = LinkCrypto.fingerprint(certificate.der);
    if (expected != null && actual != expected) {
      socket.destroy();
      throw _certificateChanged(expected, actual);
    }
    final connection = LinkConnection._(address, port, actual);
    connection._start(socket);
    return connection;
  }

  /// Connect to the first of [addresses] that succeeds, trying all in parallel; the losers are closed.
  /// @param onFailure Called for each address that failed, also after another one already won.
  /// @throws LinkCertificateException if any address presented a wrong certificate and none succeeded.
  /// @throws LinkConnectionException if none could be reached.
  static Future<LinkConnection> openAny(
    List<String> addresses,
    int port, {
    String? pin,
    Duration timeout = const Duration(seconds: 3),
    void Function(String address, LinkException error)? onFailure,
  }) {
    final unique = addresses.where((address) => address.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return Future.error(LinkConnectionException("No address is known for this desktop."));
    final winner = Completer<LinkConnection>();
    final failures = <Object>[];
    for (final address in unique) {
      open(address, port, pin: pin, timeout: timeout).then(
        (connection) {
          if (winner.isCompleted) {
            unawaited(connection.close());
          }
          else {
            winner.complete(connection);
          }
        },
        onError: (Object error) {
          failures.add(error);
          if (error is LinkException) onFailure?.call(address, error);
          if (failures.length < unique.length || winner.isCompleted) return;
          final certificate = failures.whereType<LinkCertificateException>().firstOrNull;
          if (certificate != null) {
            winner.completeError(certificate);
          }
          else if (unique.length == 1 && error is LinkException) {
            winner.completeError(error);
          }
          else {
            winner.completeError(LinkConnectionException("Could not reach the desktop at ${unique.join(", ")}."));
          }
        },
      );
    }
    return winner.future;
  }

  static LinkCertificateException _certificateChanged(String expected, String actual) {
    return LinkCertificateException(
      "The desktop's certificate changed. If you reinstalled it, pair again; otherwise someone may be intercepting the connection.",
      expected: expected,
      actual: actual,
    );
  }

  void _start(SecureSocket socket) {
    _socket = socket;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (error) {
      debugPrint("ionix-link: TCP_NODELAY not set: $error");
    }
    if (Platform.isLinux || Platform.isAndroid) {
      try {
        socket.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelTcp, _tcpNotSentLowat, _notSentLowatBytes));
      } catch (error) {
        debugPrint("ionix-link: TCP_NOTSENT_LOWAT not set: $error");
      }
    }
    // Write errors surface here; without a listener they would be uncaught.
    socket.done.then((_) {}, onError: (Object error) {
      _shutdown(LinkConnectionException("The connection to the desktop failed ($error)."), graceful: false);
    });
    _subscription = socket.listen(
      _onData,
      onError: (Object error) {
        _shutdown(LinkConnectionException("The connection to the desktop failed ($error)."), graceful: false);
      },
      onDone: () => _shutdown(LinkConnectionException("The desktop closed the connection."), graceful: false),
      cancelOnError: true,
    );
    _sinceReceived.start();
    _scheduleKeepalive();
  }

  /// Run `hello` → `challenge` → `auth` → `ready`. On success raises the frame limit to [LinkProtocol.maxFrame] and
  /// returns the negotiated [ReadyInfo].
  /// @param key The device key for this host, hex64.
  /// @param plugins What the phone supports, sent in `hello.plugins`.
  /// @param appVersion Sent as `hello.appVersion`.
  /// @param onReady Called synchronously when `ready` arrives, before any later frame is handled: attach listeners
  /// here so the pushes the desktop sends right after `ready` are not missed.
  /// @throws LinkAuthException for `unknown_device`, `auth_failed`, `rate_limited`, `protocol_version`.
  /// @throws LinkTimeoutException if `ready` does not arrive within 10 s.
  Future<ReadyInfo> authenticate({
    required DeviceIdentity identity,
    required String key,
    required List<PluginInfo> plugins,
    required String appVersion,
    void Function(ReadyInfo ready)? onReady,
  }) {
    if (_closed) return Future.error(LinkConnectionException("The connection to the desktop is closed."));
    if (_ready != null || _handshake != null) return Future.error(LinkException("This connection is already authenticated."));
    if (!LinkCrypto.isHex(key, 32)) return Future.error(LinkFormatException("The stored device key is malformed. Pair again."));
    final handshake = _Handshake(key.toLowerCase(), onReady);
    handshake.timer = Timer(handshakeTimeout, () {
      _failHandshake(LinkTimeoutException("The desktop did not finish the handshake within ${handshakeTimeout.inSeconds} s."));
      _shutdown(LinkConnectionException("The handshake timed out."), graceful: false);
    });
    _handshake = handshake;
    try {
      _write(LinkMessage(LinkTypes.hello, body: {
        "deviceId": identity.id,
        "name": identity.name,
        "model": identity.model,
        "appVersion": appVersion,
        "protocol": LinkProtocol.version,
        "protocolMin": LinkProtocol.versionMin,
        "plugins": [for (final plugin in plugins) plugin.toJson()],
      }));
    } on LinkException catch (error) {
      _failHandshake(error);
    }
    return handshake.completer.future;
  }

  /// The `ready` info, once [authenticate] succeeded.
  ReadyInfo? get ready => _ready;

  /// Whether the socket is still open.
  bool get isOpen => !_closed;

  /// Bytes handed to the socket that it has not yet accepted, plus frames queued behind them. Stays near zero on a
  /// healthy link; grows when the link stalls.
  int get pendingWriteBytes => _flushingBytes + _queuedBytes;

  /// Send a push (no reply expected).
  /// @throws LinkConnectionException if the socket is closed.
  void send(String type, [Map<String, dynamic> body = const {}]) {
    if (_closed) throw LinkConnectionException("Not connected to the desktop.");
    _write(LinkMessage(type, body: body));
  }

  /// Send a request and wait for its reply. Completes with the reply message (its `type` may differ from [type], e.g.
  /// `pong`, `pair.accept`).
  /// @throws LinkRemoteException when the reply is an `error`.
  /// @throws LinkTimeoutException after [timeout] (default [LinkProtocol.requestTimeout]).
  /// @param data Raw bytes that go with the request in a binary frame (`share.chunk`).
  /// @throws LinkConnectionException if the socket closes first.
  Future<LinkMessage> request(String type, [Map<String, dynamic> body = const {}, Duration? timeout, Uint8List? data]) {
    if (_closed) return Future.error(LinkConnectionException("Not connected to the desktop."));
    final id = _nextId();
    final completer = Completer<LinkMessage>();
    final limit = timeout ?? LinkProtocol.requestTimeout;
    final timer = Timer(limit, () {
      if (_pending.remove(id) == null) return;
      completer.completeError(LinkTimeoutException("The desktop did not answer $type within ${limit.inSeconds} s."));
    });
    _pending[id] = _PendingRequest(completer, timer);
    try {
      _write(LinkMessage(type, id: id, body: body, data: data));
    } on LinkException catch (error) {
      _pending.remove(id);
      timer.cancel();
      return Future.error(error);
    }
    return completer.future;
  }

  /// Register the handler for incoming requests of [type], replacing any earlier one. A request with no handler gets
  /// `error {code: "unknown_type"}`.
  void onRequest(String type, LinkRequestHandler handler) => _handlers[type] = handler;

  /// Remove the handler of [type].
  void removeRequestHandler(String type) => _handlers.remove(type);

  /// Incoming pushes of [type] (requests go to [onRequest] handlers, replies to [request] futures). Broadcast.
  Stream<LinkMessage> messages(String type) => _pushes.stream.where((message) => message.type == type);

  /// Every incoming push, any type. Broadcast. Mostly for logging.
  Stream<LinkMessage> get pushes => _pushes.stream;

  /// Close the socket. Pending requests fail with [LinkConnectionException]. Safe to call twice.
  Future<void> close() => _shutdown(null, graceful: true);

  /// Completes when the socket is closed, for any reason, with the reason: null for a local [close], the
  /// [LinkRemoteException] of a fatal `error`, or a [LinkConnectionException]/[LinkProtocolException]. Never errors.
  Future<Object?> get done => _done.future;

  //#region Reading

  void _onData(Uint8List chunk) {
    if (_closed) return;
    _sinceReceived.reset();
    _pinged = false;
    try {
      _decoder.feed(chunk);
    } on LinkProtocolException catch (error) {
      _protocolFailure(error);
      return;
    }
    while (!_closed) {
      final LinkMessage? message;
      try {
        message = _decoder.next();
      } on LinkProtocolException catch (error) {
        if (error.code == LinkErrorCode.badMessage) {
          debugPrint("ionix-link: ignoring a bad message: ${error.message}");
          continue;
        }
        _protocolFailure(error);
        return;
      }
      if (message == null) return;
      _dispatch(message);
    }
  }

  void _dispatch(LinkMessage message) {
    if (message.isReply) {
      _onReply(message);
    }
    else if (message.isError) {
      final error = LinkRemoteException.fromBody(message.body);
      if (error.fatal || _handshake != null) {
        _shutdown(error, graceful: false);
      }
      else {
        _pushes.add(message);
      }
    }
    else if (message.isRequest) {
      _onRequest(message);
    }
    else if (!_onHandshakeMessage(message)) {
      _pushes.add(message);
    }
  }

  void _onReply(LinkMessage message) {
    final pending = _pending.remove(message.re);
    pending?.timer.cancel();
    if (message.isError) {
      final error = LinkRemoteException.fromBody(message.body);
      pending?.completer.completeError(error);
      if (error.fatal) _shutdown(error, graceful: false);
      return;
    }
    pending?.completer.complete(message);
  }

  void _onRequest(LinkMessage request) {
    if (request.type == LinkTypes.ping) {
      _reply(request, LinkTypes.pong, const {});
      return;
    }
    final handler = _handlers[request.type];
    if (handler == null) {
      _sendError(request.id, LinkErrorCode.unknownType.wire, "The phone does not handle ${request.type}.");
      return;
    }
    Future<Map<String, dynamic>>.sync(() => handler(request)).then(
      (body) => _reply(request, request.type, body),
      onError: (Object error, StackTrace stack) {
        if (error is LinkException) {
          _sendError(request.id, error.code.outgoing, error.message);
        }
        else {
          debugPrint("ionix-link: handler of ${request.type} failed: $error\n$stack");
          _sendError(request.id, LinkErrorCode.internal.wire, "The phone failed to handle ${request.type}.");
        }
      },
    );
  }

  void _reply(LinkMessage request, String type, Map<String, dynamic> body) {
    if (_closed) return;
    try {
      _write(LinkMessage(type, re: request.id, body: body));
    } on LinkException catch (error) {
      _sendError(request.id, error.code.outgoing, error.message);
    }
  }

  void _sendError(int? re, String code, String message, {bool fatal = false}) {
    if (_destroyed) return;
    try {
      _write(LinkMessage(LinkTypes.error, re: re, body: {"code": code, "message": message, if (fatal) "fatal": true}));
    } on LinkException catch (error) {
      debugPrint("ionix-link: could not send an error: ${error.message}");
    }
  }

  void _protocolFailure(LinkProtocolException error) {
    debugPrint("ionix-link: protocol error from $address: ${error.message}");
    _sendError(null, error.code.wire, error.message, fatal: true);
    _shutdown(error, graceful: true);
  }

  //#endregion

  //#region Handshake

  /// Handle `challenge` and `ready` while authenticating. Returns whether [message] was consumed.
  bool _onHandshakeMessage(LinkMessage message) {
    final handshake = _handshake;
    if (handshake == null) return false;
    if (message.type == LinkTypes.challenge && !handshake.authSent) {
      final nonce = message.body["nonce"];
      if (nonce is! String || !LinkCrypto.isHex(nonce, 32)) {
        _protocolFailure(LinkProtocolException("The desktop sent a malformed challenge."));
        return true;
      }
      handshake.authSent = true;
      _write(LinkMessage(LinkTypes.auth, body: {
        "mac": LinkCrypto.authMac(key: handshake.key, nonce: nonce, fingerprint: fingerprint),
      }));
      return true;
    }
    if (message.type == LinkTypes.ready && handshake.authSent) {
      final ReadyInfo ready;
      try {
        ready = ReadyInfo.fromJson(message.body);
      } on LinkException catch (error) {
        _protocolFailure(LinkProtocolException("The desktop sent a malformed ready: ${error.message}"));
        return true;
      }
      handshake.timer?.cancel();
      _handshake = null;
      _ready = ready;
      _decoder.maxFrameLength = LinkProtocol.maxFrame;
      try {
        handshake.onReady?.call(ready);
      } catch (error, stack) {
        debugPrint("ionix-link: onReady failed: $error\n$stack");
      }
      handshake.completer.complete(ready);
      return true;
    }
    return false;
  }

  void _failHandshake(Object? reason) {
    final handshake = _handshake;
    if (handshake == null) return;
    _handshake = null;
    handshake.timer?.cancel();
    final LinkException error;
    if (reason is LinkRemoteException && _authCodes.contains(reason.code)) {
      error = LinkAuthException(reason.message, code: reason.code);
    }
    else if (reason is LinkException) {
      error = reason;
    }
    else {
      error = LinkConnectionException("The connection closed during the handshake.");
    }
    handshake.completer.completeError(error);
  }

  static const Set<LinkErrorCode> _authCodes = {
    LinkErrorCode.unknownDevice,
    LinkErrorCode.authFailed,
    LinkErrorCode.rateLimited,
    LinkErrorCode.protocolVersion,
  };

  //#endregion

  //#region Writing

  int _nextId() {
    do {
      _lastId = _lastId >= LinkProtocol.maxId ? 1 : _lastId + 1;
    } while (_pending.containsKey(_lastId));
    return _lastId;
  }

  /// Encode and write [message]. Throws [LinkProtocolException] (`too_large`) from the encoder.
  void _write(LinkMessage message) {
    final frame = FrameCodec.encode(message);
    if (_destroyed) return;
    if (_flushing) {
      _queue.add(frame);
      _queuedBytes += frame.length;
      return;
    }
    _socket.add(frame);
    _flushingBytes = frame.length;
    _flush();
  }

  void _flush() {
    _flushing = true;
    _socket.flush().then(
      (_) {
        _flushing = false;
        _flushingBytes = 0;
        if (_destroyed) return;
        if (_queue.isEmpty) {
          _drained?.complete();
          _drained = null;
          return;
        }
        for (final frame in _queue) {
          _socket.add(frame);
        }
        _flushingBytes = _queuedBytes;
        _queue.clear();
        _queuedBytes = 0;
        _flush();
      },
      onError: (Object error) {
        _flushing = false;
        _drained?.complete();
        _drained = null;
        _shutdown(LinkConnectionException("Could not send to the desktop ($error)."), graceful: false);
      },
    );
  }

  Future<void> _drain() {
    if (!_flushing) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  //#endregion

  //#region Keepalive and shutdown

  void _scheduleKeepalive() {
    _keepalive?.cancel();
    if (_closed) return;
    final idle = _sinceReceived.elapsed;
    if (idle >= LinkProtocol.deadPeer) {
      _shutdown(LinkConnectionException("The desktop stopped answering."), graceful: false);
      return;
    }
    if (idle >= LinkProtocol.pingIdle && !_pinged) {
      _pinged = true;
      request(LinkTypes.ping, const {}, LinkProtocol.deadPeer - LinkProtocol.pingIdle).then((_) {}, onError: (Object _) {});
    }
    final due = !_pinged && idle < LinkProtocol.pingIdle ? LinkProtocol.pingIdle - idle : LinkProtocol.deadPeer - idle;
    _keepalive = Timer(due + const Duration(milliseconds: 50), _scheduleKeepalive);
  }

  /// Mark the connection closed (once), fail everything waiting on it, and close the socket: after the queued frames
  /// are written when [graceful], at once otherwise.
  Future<void> _shutdown(Object? reason, {required bool graceful}) {
    if (!_closed) {
      _closed = true;
      _keepalive?.cancel();
      _failHandshake(reason);
      final failure = LinkConnectionException(_closedMessage(reason));
      for (final pending in _pending.values) {
        pending.timer.cancel();
        pending.completer.completeError(failure);
      }
      _pending.clear();
      _handlers.clear();
      _pushes.close();
      _done.complete(reason);
    }
    return _closing ??= graceful ? _closeGracefully() : _destroy();
  }

  Future<void> _closeGracefully() async {
    try {
      await _drain().timeout(_closeGrace);
      await _socket.close().timeout(_closeGrace);
    } catch (error) {
      debugPrint("ionix-link: closing $address was not clean: $error");
    }
    await _destroy();
  }

  Future<void> _destroy() async {
    _destroyed = true;
    _queue.clear();
    _queuedBytes = 0;
    _socket.destroy();
    await _subscription?.cancel();
    _subscription = null;
  }

  static String _closedMessage(Object? reason) {
    if (reason is LinkException) return reason.message;
    return "The connection to the desktop was closed.";
  }

  //#endregion

  @override
  String toString() => "LinkConnection($address:$port)";
}

class _PendingRequest {
  _PendingRequest(this.completer, this.timer);

  final Completer<LinkMessage> completer;
  final Timer timer;
}

class _Handshake {
  _Handshake(this.key, this.onReady);

  final String key;
  final void Function(ReadyInfo ready)? onReady;
  final Completer<ReadyInfo> completer = Completer();
  Timer? timer;
  bool authSent = false;
}
