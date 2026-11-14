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

  // Sharing into the app

  /// What other apps share to this one (Android's share sheet) while the app is running.
  Stream<IncomingShare> get incomingShares;

  /// The share that started the app, once; null if it was started normally.
  Future<IncomingShare?> takeLaunchShare();

  /// Make a shared file readable by path: the platform copies it into the app's cache (and hashes it on the way).
  /// @throws PlatformException when the sending app no longer provides the file.
  Future<StagedFile> stageSharedFile(SharedFile file);

  /// Delete every staged copy.
  Future<void> clearStagedFiles();
}

/// Text or files another app handed to Ionix Link to send to the desktop.
class IncomingShare {
  const IncomingShare({this.text, this.subject, this.files = const []});

  /// Shared text or link; null when files were shared.
  final String? text;

  /// The sharing app's subject line (a page title from a browser), if any.
  final String? subject;

  /// Shared files, in the order the app gave them.
  final List<SharedFile> files;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && files.isEmpty;
}

/// One file in an [IncomingShare], not yet copied.
class SharedFile {
  const SharedFile({required this.uri, required this.name, required this.size, this.mime});

  /// `content://` (or `file://`) address the platform reads it from.
  final String uri;

  /// Display name the sharing app gave it.
  final String name;

  /// Bytes, or -1 when the app did not say.
  final int size;
  final String? mime;
}

/// A shared file copied to a path this app can read.
class StagedFile {
  const StagedFile({required this.path, required this.size, this.sha256});

  /// Local path.
  final String path;

  /// Real size in bytes.
  final int size;

  /// Hex SHA-256 when the platform computed it while copying, else null.
  final String? sha256;
}

/// The phone's name and model as the platform reports them.
class PlatformDevice {
  const PlatformDevice({required this.name, required this.model});

  /// User-visible device name, e.g. "Lucas's Pixel".
  final String name;

  /// Model, e.g. "Pixel 8".
  final String model;
}
