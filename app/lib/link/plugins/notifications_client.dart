import "dart:async";

import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "plugin_client.dart";

/// `notifications.*`: desktop notifications mirrored to the phone (`PROTOCOL.md` 8.1).
class NotificationsClient extends PluginClient {
  // Message types
  static const String typePosted = "notifications.posted";
  static const String typeClosed = "notifications.closed";
  static const String typeList = "notifications.list";
  static const String typeDismiss = "notifications.dismiss";

  /// Phone cap: it mirrors notifications.
  static const String capMirror = "mirror";

  /// Daemon cap: it can close notifications on request.
  static const String capDismiss = "dismiss";

  @override
  String get name => LinkPlugins.notifications;

  @override
  List<String> get localCaps => const [capMirror];

  final ValueNotifier<List<DesktopNotification>> _active = ValueNotifier(const []);
  final StreamController<DesktopNotification> _posted = StreamController.broadcast();
  final StreamController<int> _closed = StreamController.broadcast();

  /// Notifications currently open on the desktop, newest first. Filled by `notifications.list` on attach and kept
  /// up to date by pushes. Cleared on detach.
  ValueListenable<List<DesktopNotification>> get active => _active;

  /// Each new or updated notification as it is posted (not the initial list). For the platform layer to show.
  Stream<DesktopNotification> get posted => _posted.stream;

  /// Ids of notifications closed on the desktop.
  Stream<int> get closed => _closed.stream;

  /// Re-fetch the list.
  Future<void> refresh() async {
    final body = await request(typeList);
    final list = JsonRead.objects(body, "notifications", DesktopNotification.fromJson);
    if (!isAvailable) return;
    _active.value = List.unmodifiable(list.reversed);
  }

  /// Ask the desktop to close notification [id]. Returns `false` when it refused or lacks [capDismiss].
  Future<bool> dismiss(int id) async {
    if (!hasCap(capDismiss)) return false;
    final body = await request(typeDismiss, {"id": id});
    return body["ok"] == true;
  }

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    listen(typePosted, (message) {
      final notification = DesktopNotification.fromJson(message.body);
      _active.value = List.unmodifiable([notification, ..._active.value.where((entry) => entry.id != notification.id)]);
      _posted.add(notification);
    });
    listen(typeClosed, (message) {
      final id = JsonRead.integer(message.body, "id");
      _active.value = List.unmodifiable(_active.value.where((entry) => entry.id != id));
      _closed.add(id);
    });
    runQuietly(refresh(), "list");
  }

  @override
  void onDetach() {
    _active.value = const [];
  }
}

/// Urgency of a [DesktopNotification].
enum NotificationUrgency {
  low,
  normal,
  critical;

  /// Parse the wire value; unknown → [normal].
  static NotificationUrgency fromWire(String? value) {
    for (final urgency in values) {
      if (urgency.name == value) return urgency;
    }
    return normal;
  }
}

/// The `Notification` object of `PROTOCOL.md` 8.1.
class DesktopNotification {
  DesktopNotification({
    required this.id,
    required this.app,
    this.appIcon,
    required this.summary,
    required this.body,
    required this.urgency,
    required this.time,
  });

  /// The desktop's notification id.
  final int id;

  /// Sending application, may be empty.
  final String app;

  /// Freedesktop icon name or path, if sent.
  final String? appIcon;

  /// Title line.
  final String summary;

  /// Plain-text body.
  final String body;

  /// Urgency.
  final NotificationUrgency urgency;

  /// When the daemon saw it.
  final DateTime time;

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "app": app,
      if (appIcon != null) "appIcon": appIcon,
      "summary": summary,
      "body": body,
      "urgency": urgency.name,
      "time": time.millisecondsSinceEpoch,
    };
  }

  /// Throws [LinkFormatException] on a missing `id` or `summary`.
  static DesktopNotification fromJson(Map<String, dynamic> json) {
    final time = JsonRead.optInt(json, "time");
    final icon = JsonRead.optString(json, "appIcon");
    return DesktopNotification(
      id: JsonRead.integer(json, "id"),
      app: JsonRead.optString(json, "app") ?? "",
      appIcon: icon == null || icon.isEmpty ? null : icon,
      summary: JsonRead.string(json, "summary"),
      body: JsonRead.optString(json, "body") ?? "",
      urgency: NotificationUrgency.fromWire(JsonRead.optString(json, "urgency")),
      time: time == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(time),
    );
  }
}
