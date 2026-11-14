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
  static const String _notificationIcon = "@drawable/ic_stat_ionix";

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
    await _notifications.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings(_notificationIcon)));
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
      notificationIcon: const NotificationIcon(metaDataName: "dev.ionnet.ionix_link.NOTIFICATION_ICON"),
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
          icon: _notificationIcon,
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
        android: AndroidNotificationDetails(_messagesChannel, "Messages", channelDescription: "Pings and clipboard text sent from your desktop.", icon: _notificationIcon),
      ),
    );
  }

  // PhoneNotifications.kt answers the methods and feeds the events; LinkNotificationListener.kt is what reads them.
  static const MethodChannel _phoneMethods = MethodChannel("dev.ionnet.ionix_link/phone_notifications");
  static const EventChannel _phoneEvents = EventChannel("dev.ionnet.ionix_link/phone_notifications/events");

  @override
  bool get canForwardNotifications => true;

  @override
  Future<bool> notificationAccessGranted() async => await _phoneMethods.invokeMethod<bool>("isAccessGranted") ?? false;

  @override
  Future<void> openNotificationAccessSettings() => _phoneMethods.invokeMethod<void>("openAccessSettings");

  @override
  Future<bool> phoneNotificationsEnabled() async => await _phoneMethods.invokeMethod<bool>("isEnabled") ?? false;

  @override
  Future<void> setPhoneNotificationsEnabled(bool enabled) => _phoneMethods.invokeMethod<void>("setEnabled", enabled);

  @override
  Future<List<PhoneNotificationApp>> phoneNotificationApps() async {
    final list = await _phoneMethods.invokeListMethod<Map<Object?, Object?>>("apps") ?? const [];
    return [
      for (final entry in list)
        PhoneNotificationApp(package: entry["package"] as String? ?? "", name: entry["name"] as String? ?? "", allowed: entry["allowed"] != false),
    ];
  }

  @override
  Future<void> setPhoneNotificationApp(String package, bool allowed) {
    return _phoneMethods.invokeMethod<void>("setAppAllowed", {"package": package, "allowed": allowed});
  }

  @override
  Stream<PhoneNotificationEvent> get phoneNotifications {
    return _phoneEvents.receiveBroadcastStream().map((event) => _phoneEvent(event as Map<Object?, Object?>)).where((event) => event != null).cast<PhoneNotificationEvent>();
  }

  static PhoneNotificationEvent? _phoneEvent(Map<Object?, Object?> event) {
    final key = event["key"];
    if (key is! String || key.isEmpty) return null;
    if (event["event"] == "removed") return PhoneNotificationEvent(key: key);
    final time = event["time"];
    return PhoneNotificationEvent(
      key: key,
      posted: PhoneNotification(
        key: key,
        app: event["app"] as String? ?? "",
        appName: event["appName"] as String? ?? "",
        title: event["title"] as String? ?? "",
        text: event["text"] as String? ?? "",
        time: time is int ? DateTime.fromMillisecondsSinceEpoch(time) : DateTime.now(),
        silent: event["silent"] == true,
      ),
    );
  }

  @override
  Future<void> cancelPhoneNotification(String key) => _phoneMethods.invokeMethod<void>("cancel", key);

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

  // MainActivity.kt answers this channel by setting or clearing FLAG_KEEP_SCREEN_ON on its window.
  static const MethodChannel _window = MethodChannel("dev.ionnet.ionix_link/window");

  @override
  Future<void> setKeepScreenOn(bool on) async {
    try {
      await _window.invokeMethod<void>("keepScreenOn", on);
    } on PlatformException catch (error) {
      debugPrint("ionix-link: could not ${on ? "keep the screen on" : "let the screen sleep"}: ${error.message}");
    }
  }

  // ShareIntake.kt: shares from other apps, and the cache copies Dart reads in chunks.
  static const MethodChannel _share = MethodChannel("dev.ionnet.ionix_link/share");
  final StreamController<IncomingShare> _shares = StreamController.broadcast();
  bool _shareHandlerSet = false;

  void _listenForShares() {
    if (_shareHandlerSet) return;
    _shareHandlerSet = true;
    _share.setMethodCallHandler((call) async {
      if (call.method != "share") return;
      final share = _parseShare(call.arguments);
      if (share != null) _shares.add(share);
    });
  }

  static IncomingShare? _parseShare(Object? raw) {
    if (raw is! Map) return null;
    final files = <SharedFile>[];
    for (final entry in (raw["files"] as List<Object?>? ?? const [])) {
      if (entry is! Map || entry["uri"] is! String) continue;
      files.add(SharedFile(
        uri: entry["uri"] as String,
        name: entry["name"] is String ? entry["name"] as String : "shared file",
        size: entry["size"] is int ? entry["size"] as int : -1,
        mime: entry["mime"] as String?,
      ));
    }
    final share = IncomingShare(text: raw["text"] as String?, subject: raw["subject"] as String?, files: files);
    return share.isEmpty ? null : share;
  }

  @override
  Stream<IncomingShare> get incomingShares {
    _listenForShares();
    return _shares.stream;
  }

  @override
  Future<IncomingShare?> takeLaunchShare() async {
    _listenForShares();
    return _parseShare(await _share.invokeMethod<Object?>("takeLaunchShare"));
  }

  @override
  Future<StagedFile> stageSharedFile(SharedFile file) async {
    final result = await _share.invokeMapMethod<String, Object?>("stage", {"uri": file.uri});
    if (result == null) throw PlatformException(code: "stage_failed", message: "The file could not be read.");
    return StagedFile(path: result["path"]! as String, size: result["size"]! as int, sha256: result["sha256"] as String?);
  }

  @override
  Future<void> clearStagedFiles() async {
    try {
      await _share.invokeMethod<void>("clear");
    } on PlatformException catch (error) {
      debugPrint("ionix-link: could not clear shared files: ${error.message}");
    }
  }
}
