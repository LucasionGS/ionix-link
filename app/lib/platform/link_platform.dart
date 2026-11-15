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

  // Phone notifications on the desktop

  /// Whether this platform can read the phone's own notifications and forward them (Android). The settings page hides
  /// its section otherwise.
  bool get canForwardNotifications;

  /// Whether the user has granted notification access to this app in the system settings.
  Future<bool> notificationAccessGranted();

  /// Open the system's notification access settings.
  Future<void> openNotificationAccessSettings();

  /// Whether the user turned "Phone notifications on the desktop" on. Kept by the platform: the service that reads the
  /// notifications is started by the system and has to know without Dart.
  Future<bool> phoneNotificationsEnabled();

  Future<void> setPhoneNotificationsEnabled(bool enabled);

  /// Apps that have posted a notification since the feature was turned on, by name, each with whether it is forwarded.
  Future<List<PhoneNotificationApp>> phoneNotificationApps();

  /// Forward (or stop forwarding) the notifications of the app with package [package].
  Future<void> setPhoneNotificationApp(String package, bool allowed);

  /// Notifications posted and removed on this phone, already filtered (feature on, app allowed, nothing ongoing).
  Stream<PhoneNotificationEvent> get phoneNotifications;

  /// Cancel the phone notification [key] because the user closed it on the desktop. Some cannot be cancelled.
  Future<void> cancelPhoneNotification(String key);

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

  /// Send the app to the background, showing whatever was in front before it (the app a share came from).
  Future<void> returnToPreviousApp();

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

  // Video

  /// Whether the phone has an H.264 decoder that can draw into a Flutter texture.
  Future<bool> canDecodeH264();

  /// A new H.264 decoder with its own texture. [dispose] it when done.
  /// @throws UnsupportedError where [canDecodeH264] is false.
  Future<VideoDecoder> createH264Decoder();
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

/// An H.264 decoder drawing into a Flutter texture (`Texture(textureId: ...)`). Feed it access units in order,
/// starting at a keyframe after each [configure].
abstract class VideoDecoder {
  /// The texture the decoded pictures appear in.
  int get textureId;

  /// The size of the decoded pictures and how they sit in the texture, once the decoder knows; null before.
  ValueListenable<VideoPicture?> get picture;

  /// The seq of every frame drawn into the texture, in order.
  Stream<int> get decoded;

  /// Decoder failures, as readable sentences. The decoder is unusable after one.
  Stream<String> get errors;

  /// (Re)start the decoder for pictures of [width]×[height] with the stream's SPS and PPS (each with a start code).
  Future<void> configure({required int width, required int height, required Uint8List sps, required Uint8List pps});

  /// Queue one access unit. [seq] comes back on [decoded] once it is drawn.
  void decode(int seq, Uint8List accessUnit, {required bool keyframe});

  /// Stop decoding and free the decoder and its texture.
  Future<void> dispose();
}

/// Where the visible picture is in a [VideoDecoder]'s texture: decoders work in 16-px macroblocks, so a 640×360
/// stream is decoded as 640×368 with an 8-px crop, and whether the texture already leaves that out depends on the
/// renderer.
class VideoPicture {
  const VideoPicture({
    required this.width,
    required this.height,
    required this.textureWidth,
    required this.textureHeight,
    required this.cropLeft,
    required this.cropTop,
  });

  /// The visible picture, in px.
  final int width;
  final int height;

  /// The texture's own size and the picture's offset in it; equal to [width]×[height] at 0,0 when nothing is cropped.
  final int textureWidth;
  final int textureHeight;
  final int cropLeft;
  final int cropTop;

  /// Whether the texture holds more than the picture.
  bool get cropped => textureWidth != width || textureHeight != height;
}

/// The phone's name and model as the platform reports them.
class PlatformDevice {
  const PlatformDevice({required this.name, required this.model});

  /// User-visible device name, e.g. "Lucas's Pixel".
  final String name;

  /// Model, e.g. "Pixel 8".
  final String model;
}

/// An app in the phone-notification filter list.
class PhoneNotificationApp {
  const PhoneNotificationApp({required this.package, required this.name, required this.allowed});

  final String package;
  final String name;

  /// Whether its notifications are forwarded (the default).
  final bool allowed;
}

/// A phone notification appearing or going away: [posted] is set for the first, null for the second.
class PhoneNotificationEvent {
  const PhoneNotificationEvent({required this.key, this.posted});

  /// The Android notification key.
  final String key;

  final PhoneNotification? posted;
}
