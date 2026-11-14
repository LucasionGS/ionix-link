import "dart:async";

import "package:battery_plus/battery_plus.dart" as bp;
import "package:device_info_plus/device_info_plus.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter_foreground_task/flutter_foreground_task.dart";
import "package:flutter_local_notifications/flutter_local_notifications.dart";
import "package:flutter_ringtone_player/flutter_ringtone_player.dart";

import "../link/link.dart";
import "link_platform.dart";

/// Entry point of the foreground service's isolate. The service only exists to keep the process (and so the
/// connection in the main isolate) alive, so its handler does nothing.
@pragma("vm:entry-point")
void linkKeepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Android implementation of [LinkPlatform]: `flutter_foreground_task` (keep-alive, foreground service type
/// `connectedDevice`), `flutter_local_notifications` (channels `desktop` and `messages`), `battery_plus`,
/// `device_info_plus`, `flutter_ringtone_player` (alarm stream), and Flutter's `Clipboard`.
class AndroidPlatform extends LinkPlatform {
  static const int _serviceId = 4710;
  static const String _desktopChannel = "desktop";
  static const String _messagesChannel = "messages";
  static const String _launcherIcon = "@mipmap/ic_launcher";

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  final bp.Battery _battery = bp.Battery();
  final FlutterRingtonePlayer _ringtone = FlutterRingtonePlayer();
  final ValueNotifier<bool> _ringing = ValueNotifier(false);
  Timer? _ringTimer;

  @override
  Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: "link_connection",
        channelName: "Connection",
        channelDescription: "Shown while Ionix Link keeps its connection to your desktop.",
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    await _notifications.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings(_launcherIcon)));
    final android = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(_desktopChannel, "Desktop notifications", description: "Notifications mirrored from your desktop.", importance: Importance.high));
    await android?.createNotificationChannel(const AndroidNotificationChannel(_messagesChannel, "Messages", description: "Pings and clipboard text sent from your desktop."));
  }

  @override
  Future<PlatformDevice> device() async {
    final info = await DeviceInfoPlugin().androidInfo;
    final brand = info.manufacturer.isEmpty ? "" : "${info.manufacturer[0].toUpperCase()}${info.manufacturer.substring(1)} ";
    final model = info.model.isEmpty ? "Android phone" : info.model;
    return PlatformDevice(name: model.toLowerCase().startsWith(brand.trim().toLowerCase()) ? model : "$brand$model", model: model);
  }

  @override
  bool get canScanQr => true;

  @override
  Future<void> startKeepAlive({required String title, required String text}) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      return;
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: title,
      notificationText: text,
      callback: linkKeepAliveCallback,
    );
    if (result is ServiceRequestFailure) debugPrint("Could not start the keep-alive service: ${result.error}");
  }

  @override
  Future<void> stopKeepAlive() async {
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
  }

  @override
  Future<bool> requestNotificationPermission() async {
    final android = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> showDesktopNotification(DesktopNotification notification, {required String hostName}) {
    final critical = notification.urgency == NotificationUrgency.critical;
    final low = notification.urgency == NotificationUrgency.low;
    return _notifications.show(
      id: notification.id,
      title: notification.summary,
      body: notification.body.isEmpty ? null : notification.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _desktopChannel,
          "Desktop notifications",
          channelDescription: "Notifications mirrored from your desktop.",
          icon: _launcherIcon,
          subText: notification.app.isEmpty ? hostName : "${notification.app} · $hostName",
          importance: critical ? Importance.max : (low ? Importance.low : Importance.high),
          priority: critical ? Priority.max : (low ? Priority.low : Priority.high),
          styleInformation: BigTextStyleInformation(notification.body),
          onlyAlertOnce: true,
        ),
      ),
    );
  }

  @override
  Future<void> cancelDesktopNotification(int id) => _notifications.cancel(id: id);

  @override
  Future<void> showMessage(String title, String body) {
    return _notifications.show(
      id: DateTime.now().millisecondsSinceEpoch & 0x3fffffff,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(_messagesChannel, "Messages", channelDescription: "Pings and clipboard text sent from your desktop.", icon: _launcherIcon),
      ),
    );
  }

  @override
  Future<BatteryState?> battery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (level < 0) return null;
      return BatteryState(level: level.clamp(0, 100), charging: state == bp.BatteryState.charging || state == bp.BatteryState.full);
    } on PlatformException {
      return null;
    }
  }

  @override
  Stream<BatteryState> get batteryChanges async* {
    final ticks = StreamController<void>();
    final sub = _battery.onBatteryStateChanged.listen((_) => ticks.add(null));
    final timer = Timer.periodic(const Duration(minutes: 1), (_) => ticks.add(null));
    try {
      await for (final _ in ticks.stream) {
        final state = await battery();
        if (state != null) yield state;
      }
    } finally {
      await sub.cancel();
      timer.cancel();
      await ticks.close();
    }
  }

  @override
  Future<void> ring({Duration timeout = const Duration(seconds: 30)}) async {
    await _ringtone.playAlarm(looping: true, asAlarm: true, volume: 1.0);
    _ringing.value = true;
    _ringTimer?.cancel();
    _ringTimer = Timer(timeout, stopRinging);
  }

  @override
  Future<void> stopRinging() async {
    _ringTimer?.cancel();
    _ringing.value = false;
    await _ringtone.stop();
  }

  @override
  ValueListenable<bool> get ringing => _ringing;

  @override
  Future<void> setClipboard(String text) => Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String> getClipboard() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? "";
}
