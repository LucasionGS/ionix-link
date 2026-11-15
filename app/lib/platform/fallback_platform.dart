import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../link/link.dart";
import "link_platform.dart";

/// [LinkPlatform] for anything that is not Android (the Linux build, used to run the UI on a desktop): no service,
/// notifications go to the debug log, no battery, no sound, clipboard through Flutter's `Clipboard`.
class FallbackPlatform extends LinkPlatform {
  final ValueNotifier<bool> _ringing = ValueNotifier(false);
  Timer? _ringTimer;

  @override
  Future<void> init() async {}

  @override
  Future<PlatformDevice> device() async => PlatformDevice(name: Platform.localHostname, model: "Linux");

  @override
  bool get canScanQr => false;

  @override
  Future<void> startKeepAlive({required String title, required String text}) async => debugPrint("keep-alive: $title, $text");

  @override
  Future<void> stopKeepAlive() async => debugPrint("keep-alive: stopped");

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> showDesktopNotification(DesktopNotification notification, {required String hostName}) async {
    debugPrint("notification from $hostName: ${notification.app}: ${notification.summary}");
  }

  @override
  Future<void> cancelDesktopNotification(int id) async {}

  @override
  Future<void> showMessage(String title, String body) async => debugPrint("message: $title: $body");

  @override
  bool get canForwardNotifications => false;

  @override
  Future<bool> notificationAccessGranted() async => false;

  @override
  Future<void> openNotificationAccessSettings() async {}

  @override
  Future<bool> phoneNotificationsEnabled() async => false;

  @override
  Future<void> setPhoneNotificationsEnabled(bool enabled) async {}

  @override
  Future<List<PhoneNotificationApp>> phoneNotificationApps() async => const [];

  @override
  Future<void> setPhoneNotificationApp(String package, bool allowed) async {}

  @override
  Stream<PhoneNotificationEvent> get phoneNotifications => const Stream.empty();

  @override
  Future<void> cancelPhoneNotification(String key) async {}

  @override
  Future<BatteryState?> battery() async => null;

  @override
  Stream<BatteryState> get batteryChanges => const Stream.empty();

  @override
  Future<void> ring({Duration timeout = const Duration(seconds: 30)}) async {
    debugPrint("ring (no sound on this platform)");
    _ringing.value = true;
    _ringTimer?.cancel();
    _ringTimer = Timer(timeout, stopRinging);
  }

  @override
  Future<void> stopRinging() async {
    _ringTimer?.cancel();
    _ringing.value = false;
  }

  @override
  ValueListenable<bool> get ringing => _ringing;

  @override
  Future<void> setClipboard(String text) => Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String> getClipboard() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? "";

  @override
  Future<void> setKeepScreenOn(bool on) async {}

  final StreamController<IncomingShare> _shares = StreamController.broadcast();

  /// Pretend another app shared [share] (Linux has no share sheet; the headless checks use this).
  void debugShare(IncomingShare share) => _shares.add(share);

  @override
  Stream<IncomingShare> get incomingShares => _shares.stream;

  @override
  Future<IncomingShare?> takeLaunchShare() async => null;

  /// Files are read where they are: a `file://` uri or a plain path, with no copy and no hash.
  @override
  Future<StagedFile> stageSharedFile(SharedFile file) async {
    final path = file.uri.startsWith("file://") ? Uri.parse(file.uri).toFilePath() : file.uri;
    return StagedFile(path: path, size: await File(path).length());
  }

  @override
  Future<void> clearStagedFiles() async {}

  @override
  Future<bool> canDecodeH264() async => false;

  @override
  Future<VideoDecoder> createH264Decoder() => Future.error(UnsupportedError("Video decoding is only available on Android."));
}
