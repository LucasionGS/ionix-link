import "dart:async";

import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "plugin_client.dart";

/// `status.*`: battery both ways, host info, find-my-phone and pings (`PROTOCOL.md` 8.7).
///
/// The phone's battery comes from the platform layer through [setBattery]; the client sends it after every attach
/// and on change. Ring and ping requests are answered `ok: true` once [ringRequests]/[pings] have a listener, and
/// `ok: false` otherwise.
class StatusClient extends PluginClient {
  // Message types
  static const String typeBattery = "status.battery";
  static const String typeHost = "status.host";
  static const String typeRing = "status.ring";
  static const String typePing = "status.ping";

  /// Cap: has a battery (phone and daemon).
  static const String capBattery = "battery";

  /// Phone cap: can ring.
  static const String capRing = "ring";

  /// Daemon cap: reports volume in `status.host`.
  static const String capVolume = "volume";

  @override
  String get name => LinkPlugins.status;

  @override
  List<String> get localCaps => const [capBattery, capRing];

  final ValueNotifier<HostStatus?> _host = ValueNotifier(null);
  final StreamController<void> _ring = StreamController.broadcast();
  final StreamController<String?> _pings = StreamController.broadcast();
  BatteryState? _battery;
  BatteryState? _sentBattery;

  /// The desktop's status, null while detached.
  ValueListenable<HostStatus?> get host => _host;

  /// Re-request [host].
  Future<HostStatus> refresh() async {
    final status = HostStatus.fromJson(await request(typeHost));
    if (isAvailable) _host.value = status;
    return status;
  }

  /// Record the phone's battery; pushed now if attached and different from the last one sent, and again on every
  /// attach.
  void setBattery(BatteryState battery) {
    _battery = battery;
    _sendBattery();
  }

  /// The phone battery last given to [setBattery], or null.
  BatteryState? get battery => _battery;

  /// A `status.ring` arrived: the platform layer rings.
  Stream<void> get ringRequests => _ring.stream;

  /// A `status.ping` arrived, with its optional message.
  Stream<String?> get pings => _pings.stream;

  /// Ping the desktop (it shows a notification).
  Future<void> ping([String? message]) async {
    final body = await request(typePing, {"message": ?message});
    if (body["ok"] != true) throw LinkException("The desktop could not show the ping.");
  }

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    listen(typeHost, (message) => _host.value = HostStatus.fromJson(message.body));
    handle(typeRing, (_) {
      if (!_ring.hasListener) return {"ok": false};
      _ring.add(null);
      return {"ok": true};
    });
    handle(typePing, (request) {
      if (!_pings.hasListener) return {"ok": false};
      final message = request.body["message"];
      _pings.add(message is String && message.isNotEmpty ? message : null);
      return {"ok": true};
    });
    _sentBattery = null;
    _sendBattery();
  }

  @override
  void onDetach() {
    _host.value = null;
    _sentBattery = null;
  }

  void _sendBattery() {
    final battery = _battery;
    if (battery == null || !isAvailable || battery == _sentBattery) return;
    try {
      send(typeBattery, battery.toJson());
      _sentBattery = battery;
    } on LinkException catch (error) {
      debugPrint("ionix-link: battery not sent: ${error.message}");
    }
  }
}

/// The `Battery` object of `PROTOCOL.md` 8.7.
class BatteryState {
  const BatteryState({required this.level, required this.charging});

  /// 0..100.
  final int level;

  final bool charging;

  Map<String, dynamic> toJson() => {"level": level, "charging": charging};

  /// Throws [LinkFormatException] on a missing `level`.
  static BatteryState fromJson(Map<String, dynamic> json) {
    return BatteryState(
      level: JsonRead.integer(json, "level").clamp(0, 100),
      charging: JsonRead.optBool(json, "charging") ?? false,
    );
  }

  @override
  bool operator ==(Object other) => other is BatteryState && other.level == level && other.charging == charging;

  @override
  int get hashCode => Object.hash(level, charging);
}

/// The `status.host` body.
class HostStatus {
  const HostStatus({required this.hostName, this.battery, this.volume, this.muted});

  final String hostName;

  /// Null when the desktop has no battery.
  final BatteryState? battery;

  /// Null without the `volume` cap.
  final double? volume;
  final bool? muted;

  /// Throws [LinkFormatException] on a missing `hostName`.
  static HostStatus fromJson(Map<String, dynamic> json) {
    final battery = JsonRead.optObject(json, "battery");
    return HostStatus(
      hostName: JsonRead.string(json, "hostName"),
      battery: battery == null ? null : BatteryState.fromJson(battery),
      volume: JsonRead.optNumber(json, "volume"),
      muted: JsonRead.optBool(json, "muted"),
    );
  }
}
