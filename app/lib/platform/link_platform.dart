import "dart:io";

import "package:flutter/foundation.dart";

import "../link/link.dart";
import "android_platform.dart";
import "fallback_platform.dart";

/// Everything the app needs from the operating system, behind one interface so `ui/` and the glue never touch a
/// platform plugin directly. [AndroidPlatform] is the real one; [FallbackPlatform] keeps the Linux build (used to run
/// the UI on the desktop) working with no-ops.
abstract class LinkPlatform {
  /// The active implementation, set by [select] in `main`.
  static late final LinkPlatform instance;

  /// Pick the implementation for the running OS and assign [instance].
  static LinkPlatform select() {
    instance = Platform.isAndroid ? AndroidPlatform() : FallbackPlatform();
    return instance;
  }

  /// Initialise plugins (notification channels, foreground task config). Called once, before [Link.init].
  Future<void> init();

  /// The phone's name and model, for [Link.init].
  Future<PlatformDevice> device();

  /// Whether a camera QR scanner is available (false on Linux).
  bool get canScanQr;

  // Keep-alive

  /// Start (or update) the foreground service that keeps the process and its connection alive while the app is in
  /// the background, with a persistent notification "Connected to myeonix" / "Connecting…".
  Future<void> startKeepAlive({required String title, required String text});

  /// Stop the foreground service (no current host, or the user disconnected).
  Future<void> stopKeepAlive();

  // Notifications

  /// Ask for the notification permission (Android 13+). Returns whether it is granted.
  Future<bool> requestNotificationPermission();

  /// Show or update a mirrored desktop notification (keyed by [DesktopNotification.id]).
  Future<void> showDesktopNotification(DesktopNotification notification, {required String hostName});

  /// Remove a mirrored notification.
  Future<void> cancelDesktopNotification(int id);

  /// A one-off informational notification ("Ping from myeonix", "Clipboard from myeonix").
  Future<void> showMessage(String title, String body);

  // Battery

  /// Current battery, or null if unknown.
  Future<BatteryState?> battery();

  /// Battery changes (level or charging state).
  Stream<BatteryState> get batteryChanges;

  // Ringing

  /// Ring at alarm volume until [stopRinging] or [timeout].
  Future<void> ring({Duration timeout = const Duration(seconds: 30)});

  /// Stop ringing.
  Future<void> stopRinging();

  /// Whether it is ringing now (the UI shows a "Stop" button).
  ValueListenable<bool> get ringing;

  // Clipboard

  /// Put [text] on the phone's clipboard.
  Future<void> setClipboard(String text);

  /// Read the phone's clipboard text ("" if none). Only works while the app is in the foreground on Android 10+.
  Future<String> getClipboard();

  // Window

  /// Keep the screen from timing out while the app's window is showing (it applies only to the app's own window, so
  /// leaving the app lets the phone sleep as usual).
  Future<void> setKeepScreenOn(bool on);
}

/// The phone's name and model as the platform reports them.
class PlatformDevice {
  const PlatformDevice({required this.name, required this.model});

  /// User-visible device name, e.g. "Lucas's Pixel".
  final String name;

  /// Model, e.g. "Pixel 8".
  final String model;
}
