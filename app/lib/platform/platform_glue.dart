import "dart:async";

import "package:flutter/foundation.dart";

import "../link/link.dart";
import "link_platform.dart";

/// Wires the link layer to the platform: the only place that subscribes to [Link] streams on behalf of the OS.
///
/// - [Link.connectionStatus] → [LinkPlatform.startKeepAlive] / [LinkPlatform.stopKeepAlive]
/// - [NotificationsClient.posted] / [NotificationsClient.closed] → show / cancel mirrored notifications
/// - [StatusClient.ringRequests] → [LinkPlatform.ring]; [StatusClient.pings] → [LinkPlatform.showMessage]
/// - [LinkPlatform.batteryChanges] (and [LinkPlatform.battery] at start) → [StatusClient.setBattery]
/// - [ClipboardClient.received] → [LinkPlatform.setClipboard] + a message
class PlatformGlue {
  PlatformGlue._();

  static bool _started = false;
  static final List<StreamSubscription<Object?>> _subscriptions = [];
  static LinkState? _lastKeepAlive;

  /// Subscribe everything listed above. Idempotent.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    final platform = LinkPlatform.instance;

    // The first notification permission prompt: the keep-alive and mirrored notifications are useless without it.
    unawaited(platform.requestNotificationPermission());

    Link.connectionStatus.addListener(() => _syncKeepAlive(Link.connectionStatus.value));
    _syncKeepAlive(Link.connectionStatus.value);

    _subscriptions.add(Link.notifications.posted.listen((n) async {
      final host = Link.connectionStatus.value.host?.name ?? "desktop";
      await _safe(() => platform.showDesktopNotification(n, hostName: host));
    }));
    _subscriptions.add(Link.notifications.closed.listen((id) => _safe(() => platform.cancelDesktopNotification(id))));

    _subscriptions.add(Link.status.ringRequests.listen((_) => _safe(() => platform.ring())));
    _subscriptions.add(Link.status.pings.listen((message) {
      final host = Link.connectionStatus.value.host?.name ?? "your desktop";
      _safe(() => platform.showMessage("Ping from $host", message ?? "Your desktop says hi."));
    }));

    final battery = await _safe(platform.battery);
    if (battery != null) Link.status.setBattery(battery);
    _subscriptions.add(platform.batteryChanges.listen(Link.status.setBattery));

    _subscriptions.add(Link.clipboard.received.listen((text) async {
      final host = Link.connectionStatus.value.host?.name ?? "your desktop";
      await _safe(() => platform.setClipboard(text));
      await _safe(() => platform.showMessage("Clipboard from $host", "Copied to this phone."));
    }));
  }

  static void _syncKeepAlive(LinkStatus status) {
    final platform = LinkPlatform.instance;
    final host = status.host?.name ?? "your desktop";
    switch (status.state) {
      case LinkState.idle:
      case LinkState.forgotten:
        if (_lastKeepAlive != null) _safe(platform.stopKeepAlive);
        _lastKeepAlive = null;
      case LinkState.ready:
        _lastKeepAlive = status.state;
        _safe(() => platform.startKeepAlive(title: "Ionix Link", text: "Connected to $host"));
      case LinkState.connecting:
      case LinkState.authenticating:
      case LinkState.retrying:
        _lastKeepAlive = status.state;
        _safe(() => platform.startKeepAlive(title: "Ionix Link", text: status.state == LinkState.retrying ? "Waiting for $host…" : "Connecting to $host…"));
    }
  }

  /// Runs a platform call and logs instead of throwing: a failed notification must never take the connection down.
  static Future<T?> _safe<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e, stack) {
      debugPrint("Platform call failed: $e\n$stack");
      return null;
    }
  }
}
