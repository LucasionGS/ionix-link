import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";

import "../models/discovered_host.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";

/// UDP discovery (`PROTOCOL.md` section 4.1): broadcast a `discover` query to `255.255.255.255:<port>` three times,
/// collect unicast `announce` replies on the same ephemeral socket. The query carries nothing about this phone.
///
/// An announce is unauthenticated: anyone on the network can send one. It only says where a desktop might be; the
/// pinned certificate (or, while pairing, the code) decides whether it is the right one.
class LinkDiscovery {
  LinkDiscovery._();

  /// Where queries are sent. Tests point it at `127.0.0.1` to reach a daemon on the same machine without a network.
  static String broadcastAddress = "255.255.255.255";

  /// Scan for every host for [duration]. Each host is emitted once (first announce wins; later ones with a new
  /// address replace it under the same id only if emitted again). The stream closes when the scan ends.
  /// A socket failure (no network) is emitted as a [LinkConnectionException] before the stream closes.
  static Stream<DiscoveredHost> scan({Duration duration = const Duration(seconds: 3), int port = 47110}) {
    late final StreamController<DiscoveredHost> controller;
    _Query? query;
    final seen = <String>{};
    controller = StreamController<DiscoveredHost>(
      onListen: () async {
        try {
          query = await _Query.start(port, {"ionixlink": 1, "type": "discover"}, (host) {
            if (seen.add(host.id) && !controller.isClosed) controller.add(host);
          });
        } on LinkException catch (error) {
          controller.addError(error);
          await controller.close();
          return;
        }
        if (controller.isClosed) {
          query?.stop();
          return;
        }
        query!.finishAfter(duration, () => controller.close());
      },
      onCancel: () {
        query?.stop();
      },
    );
    return controller.stream;
  }

  /// Refind one host by id (query with `want`). Completes with null after [timeout], or at once when the network
  /// cannot be used.
  /// @param fingerprint When set, an announce claiming another fingerprint is ignored (passed to [onIgnored]) and the
  /// search goes on, so a forged announce cannot hide the real one.
  static Future<DiscoveredHost?> find(
    String hostId, {
    String? fingerprint,
    void Function(DiscoveredHost announce)? onIgnored,
    Duration timeout = const Duration(seconds: 3),
    int port = 47110,
  }) async {
    final want = hostId.toLowerCase();
    final pin = fingerprint?.toLowerCase();
    final found = Completer<DiscoveredHost?>();
    final _Query query;
    try {
      query = await _Query.start(port, {"ionixlink": 1, "type": "discover", "want": want}, (host) {
        if (host.id != want || found.isCompleted) return;
        if (pin != null && host.fingerprint != pin) {
          onIgnored?.call(host);
          return;
        }
        found.complete(host);
      });
    } on LinkException catch (error) {
      debugPrint("ionix-link: refind failed: ${error.message}");
      return null;
    }
    query.finishAfter(timeout, () {
      if (!found.isCompleted) found.complete(null);
    });
    try {
      return await found.future;
    } finally {
      query.stop();
    }
  }
}

/// One discovery socket: sends the query three times and parses every answer until stopped.
class _Query {
  _Query._(this._socket);

  final RawDatagramSocket _socket;
  final List<Timer> _timers = [];
  StreamSubscription<RawSocketEvent>? _subscription;
  bool _stopped = false;

  static Future<_Query> start(int port, Map<String, dynamic> body, void Function(DiscoveredHost host) onHost) async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
    } on SocketException catch (error) {
      throw LinkConnectionException("Could not search the network (${error.osError?.message ?? error.message}).");
    }
    final query = _Query._(socket);
    query._subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final host = _parse(datagram!);
        if (host != null) onHost(host);
      }
    }, onError: (Object error) => debugPrint("ionix-link: discovery socket: $error"));

    final payload = utf8.encode(jsonEncode(body));
    final target = InternetAddress(LinkDiscovery.broadcastAddress);
    void send() {
      if (query._stopped) return;
      try {
        socket.send(payload, target, port);
      } on SocketException catch (error) {
        debugPrint("ionix-link: discovery query not sent: ${error.osError?.message ?? error.message}");
      }
    }
    try {
      socket.send(payload, target, port);
    } on SocketException catch (error) {
      query.stop();
      throw LinkConnectionException("Could not search the network (${error.osError?.message ?? error.message}).");
    }
    query._timers.add(Timer(LinkProtocol.discoveryRepeat, send));
    query._timers.add(Timer(LinkProtocol.discoveryRepeat * 2, send));
    return query;
  }

  void finishAfter(Duration duration, void Function() onFinish) {
    _timers.add(Timer(duration, () {
      stop();
      onFinish();
    }));
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _subscription?.cancel();
    _socket.close();
  }

  static DiscoveredHost? _parse(Datagram datagram) {
    if (datagram.data.length > LinkProtocol.maxDatagram) return null;
    try {
      final json = jsonDecode(utf8.decode(datagram.data));
      if (json is! Map<String, dynamic>) return null;
      return DiscoveredHost.fromAnnounce(json, datagram.address.address);
    } on FormatException {
      return null;
    }
  }
}
