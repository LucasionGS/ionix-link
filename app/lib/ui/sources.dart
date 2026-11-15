import "dart:async";
import "package:flutter/foundation.dart";

import "../link/link.dart";
import "../platform/link_platform.dart";

/// The seams between the pages and the link layer. Each page reads one small interface from [UiSources]; the
/// defaults delegate to [Link], and the preview entrypoint swaps in fakes, so a page never names `Link` directly.
class UiSources {
  UiSources._();

  static ThemeSource theme = LinkThemeSource();
  static HomeSource home = LinkHomeSource();
  static PairSource pair = LinkPairSource();
  static MediaSource media = LinkMediaSource();
  static CommandsSource commands = LinkCommandsSource();
  static InputSource input = LinkInputSource();
  static ScreenSource screen = LinkScreenSource();
  static ShareSource share = LinkShareSource();
}

//#region Theme

/// The desktop's active theme and wallpaper.
abstract class ThemeSource {
  ValueListenable<LinkTheme> get theme;

  /// Wallpaper bytes, null when the desktop sent none.
  ValueListenable<Uint8List?> get wallpaper;
}

/// [ThemeSource] over [Link.theme].
class LinkThemeSource extends ThemeSource {
  @override
  ValueListenable<LinkTheme> get theme => Link.theme.theme;

  @override
  ValueListenable<Uint8List?> get wallpaper => Link.theme.wallpaper;
}

//#endregion

//#region Home

/// What the dashboard and the connection banner show.
abstract class HomeSource {
  ValueListenable<LinkStatus> get status;
  ValueListenable<PairedHost?> get currentHost;
  ValueListenable<List<PairedHost>> get hosts;

  /// Plugins negotiated on the current connection.
  ValueListenable<List<PluginInfo>> get plugins;

  /// Battery and volume of the desktop, null while unknown.
  ValueListenable<HostStatus?> get hostStatus;

  /// The desktop's open notifications, newest first.
  ValueListenable<List<DesktopNotification>> get notifications;

  /// Retry the current host now.
  void reconnect();

  /// Make [hostId] the current host.
  Future<void> selectHost(String hostId);

  /// Forget [hostId] here and on the desktop.
  Future<void> unpair(String hostId);

  /// This phone as desktops see it.
  DeviceIdentity get identity;

  /// Rename this phone (null = the platform's name).
  Future<void> setDeviceName(String? name);
}

/// [HomeSource] over [Link].
class LinkHomeSource extends HomeSource {
  @override
  ValueListenable<LinkStatus> get status => Link.connectionStatus;

  @override
  ValueListenable<PairedHost?> get currentHost => Link.currentHost;

  @override
  ValueListenable<List<PairedHost>> get hosts => Link.hosts;

  @override
  ValueListenable<List<PluginInfo>> get plugins => Link.plugins;

  @override
  ValueListenable<HostStatus?> get hostStatus => Link.status.host;

  @override
  ValueListenable<List<DesktopNotification>> get notifications => Link.notifications.active;

  @override
  void reconnect() => Link.reconnect();

  @override
  Future<void> selectHost(String hostId) => Link.selectHost(hostId);

  @override
  Future<void> unpair(String hostId) => Link.unpair(hostId);

  @override
  DeviceIdentity get identity => Link.identity;

  @override
  Future<void> setDeviceName(String? name) => Link.setDeviceName(name);
}

//#endregion

//#region Pairing

/// A pairing-by-code request in flight, as the confirm page sees it.
abstract class CodeAttempt {
  /// The 6-digit code, unformatted; null until the desktop's challenge has arrived.
  String? get code;

  /// Whether the desktop is showing its own prompt.
  bool get isPending;

  Future<PairedHost> get result;

  Future<void> cancel();
}

/// Everything the pairing pages need.
abstract class PairSource {
  /// Whether this device can scan QR codes.
  bool get canScanQr;

  Stream<DiscoveredHost> discover();

  bool isCompatible(DiscoveredHost host);

  Future<CodeAttempt> pairWithCode(DiscoveredHost host);

  Future<PairedHost> pairWithUri(PairingUri uri);

  /// Parse a pairing link or scanned text.
  PairingUri parseUri(String text);

  Future<void> selectHost(String hostId);
}

/// [PairSource] over [Link].
class LinkPairSource extends PairSource {
  @override
  bool get canScanQr => LinkPlatform.instance.canScanQr;

  @override
  Stream<DiscoveredHost> discover() => Link.discover();

  @override
  bool isCompatible(DiscoveredHost host) => host.isCompatible;

  @override
  Future<CodeAttempt> pairWithCode(DiscoveredHost host) async => _LinkCodeAttempt(await Link.pairWithCode(host));

  @override
  Future<PairedHost> pairWithUri(PairingUri uri) => Link.pairWithUri(uri);

  @override
  PairingUri parseUri(String text) => PairingUri.parse(text.trim());

  @override
  Future<void> selectHost(String hostId) => Link.selectHost(hostId);
}

class _LinkCodeAttempt extends CodeAttempt {
  _LinkCodeAttempt(this._pairing);

  final CodePairing _pairing;

  @override
  String? get code => _pairing.code;

  @override
  bool get isPending => _pairing.isPending;

  @override
  Future<PairedHost> get result => _pairing.result;

  @override
  Future<void> cancel() => _pairing.cancel();
}

//#endregion

//#region Media

/// The media plugin as the remote page uses it.
abstract class MediaSource {
  ValueListenable<List<MediaPlayer>> get players;
  ValueListenable<String?> get activePlayer;
  ValueListenable<VolumeState?> get volume;

  Future<void> refresh();
  Future<void> control(MediaAction action, {String? player});
  Future<void> seek(Duration position, {String? player});
  Future<VolumeState> setVolume(double volume);
  Future<VolumeState> setMuted(bool muted);

  /// [player]'s cover as JPEG bytes, null when there is none.
  Future<Uint8List?> art(MediaPlayer player);

  /// [player]'s position at [now], extrapolated while playing.
  Duration? positionOf(MediaPlayer player, DateTime now);
}

/// [MediaSource] over [Link.media].
class LinkMediaSource extends MediaSource {
  @override
  ValueListenable<List<MediaPlayer>> get players => Link.media.players;

  @override
  ValueListenable<String?> get activePlayer => Link.media.activePlayer;

  @override
  ValueListenable<VolumeState?> get volume => Link.media.volume;

  @override
  Future<void> refresh() => Link.media.refresh();

  @override
  Future<Uint8List?> art(MediaPlayer player) => Link.media.art(player);

  @override
  Future<void> control(MediaAction action, {String? player}) => Link.media.control(action, player: player);

  @override
  Future<void> seek(Duration position, {String? player}) => Link.media.seek(position, player: player);

  @override
  Future<VolumeState> setVolume(double volume) => Link.media.setVolume(volume);

  @override
  Future<VolumeState> setMuted(bool muted) => Link.media.setMuted(muted);

  @override
  Duration? positionOf(MediaPlayer player, DateTime now) => player.positionAt(now);
}

//#endregion

//#region Commands

/// The commands plugin.
abstract class CommandsSource {
  ValueListenable<List<LinkCommand>> get commands;

  Future<List<LinkCommand>> refresh();

  Future<CommandResult> run(String id);
}

/// [CommandsSource] over [Link.commands].
class LinkCommandsSource extends CommandsSource {
  @override
  ValueListenable<List<LinkCommand>> get commands => Link.commands.commands;

  @override
  Future<List<LinkCommand>> refresh() => Link.commands.refresh();

  @override
  Future<CommandResult> run(String id) => Link.commands.run(id);
}

//#endregion

//#region Input

/// The input plugin: pointer and keyboard.
abstract class InputSource {
  bool get hasPointer;
  bool get hasKeyboard;

  void move(double dx, double dy);
  void moveAbsolute(String output, double x, double y);
  void button(PointerButton button, ButtonAction action);
  void scroll(double dx, double dy);
  Future<void> text(String text);
  Future<void> key(String keysym, {Set<KeyModifier> modifiers = const {}});
}

/// [InputSource] over [Link.input].
class LinkInputSource extends InputSource {
  @override
  bool get hasPointer => Link.input.hasPointer;

  @override
  bool get hasKeyboard => Link.input.hasKeyboard;

  @override
  void move(double dx, double dy) => Link.input.move(dx, dy);

  @override
  void moveAbsolute(String output, double x, double y) => Link.input.moveAbsolute(output, x, y);

  @override
  void button(PointerButton button, ButtonAction action) => Link.input.button(button, action);

  @override
  void scroll(double dx, double dy) => Link.input.scroll(dx, dy);

  @override
  Future<void> text(String text) => Link.input.text(text);

  @override
  Future<void> key(String keysym, {Set<KeyModifier> modifiers = const {}}) => Link.input.key(keysym, modifiers: modifiers);
}

//#endregion

//#region Screen

/// Keeps the phone's screen on while any page holds it (the touchpad and the screen view), counted so that two holders
/// overlapping in a page transition do not switch it off early.
class ScreenAwake {
  ScreenAwake._();

  static int _holders = 0;

  /// Start keeping the screen on; pair with one [release].
  static void hold() {
    if (_holders++ == 0) _apply(true);
  }

  /// Undo one [hold].
  static void release() {
    if (_holders == 0) return;
    if (--_holders == 0) _apply(false);
  }

  static void _apply(bool on) {
    LinkPlatform.instance.setKeepScreenOn(on).catchError((Object error) => debugPrint("ionix-link: keep screen on: $error"));
  }
}

/// The screen plugin.
abstract class ScreenSource {
  Future<List<ScreenOutput>> outputs();
  Future<ScreenStreamInfo> start(String output, {double scale = 0.5, int quality = 60, int maxFps = 15, String format = ScreenClient.formatJpeg});
  Future<void> stop();
  void ack(int seq);
  Stream<ScreenFrame> get frames;

  /// Whether the desktop can stream H.264 video.
  bool get canVideo;

  /// Video access units, for a stream started with [ScreenClient.formatH264].
  Stream<ScreenVideoUnit> get video;
  ValueListenable<ScreenStreamInfo?> get stream;
  Stream<String> get stopped;
}

/// [ScreenSource] over [Link.screen].
class LinkScreenSource extends ScreenSource {
  @override
  Future<List<ScreenOutput>> outputs() => Link.screen.outputs();

  @override
  Future<ScreenStreamInfo> start(String output, {double scale = 0.5, int quality = 60, int maxFps = 15, String format = ScreenClient.formatJpeg}) {
    return Link.screen.start(output, scale: scale, quality: quality, maxFps: maxFps, format: format);
  }

  @override
  Future<void> stop() => Link.screen.stop();

  @override
  void ack(int seq) => Link.screen.ack(seq);

  @override
  Stream<ScreenFrame> get frames => Link.screen.frames;

  @override
  bool get canVideo => Link.screen.canVideo;

  @override
  Stream<ScreenVideoUnit> get video => Link.screen.video;

  @override
  ValueListenable<ScreenStreamInfo?> get stream => Link.screen.stream;

  @override
  Stream<String> get stopped => Link.screen.stopped;
}

//#endregion

//#region Share

/// Sharing to the desktop from other apps: the intake from the platform and the sending through the link.
abstract class ShareSource {
  /// Shares other apps hand over while the app runs.
  Stream<IncomingShare> get incoming;

  /// The share the app was started with, once.
  Future<IncomingShare?> takeLaunchShare();

  ValueListenable<LinkStatus> get status;
  ValueListenable<List<PairedHost>> get hosts;

  /// The share plugin as negotiated on the current connection, null while offline or unavailable.
  ValueListenable<PluginInfo?> get plugin;

  bool get canText;
  bool get canFiles;

  /// Retry the current host now.
  void reconnect();

  Future<ShareAction> sendText(String text, {String? subject});

  /// Copy [file] where this app can read it.
  Future<StagedFile> stage(SharedFile file);

  ShareUpload sendFile(StagedFile staged, SharedFile file);

  /// Drop every staged copy.
  Future<void> clearStaged();
}

/// [ShareSource] over [LinkPlatform] and [Link.share].
class LinkShareSource extends ShareSource {
  @override
  Stream<IncomingShare> get incoming => LinkPlatform.instance.incomingShares;

  @override
  Future<IncomingShare?> takeLaunchShare() => LinkPlatform.instance.takeLaunchShare();

  @override
  ValueListenable<LinkStatus> get status => Link.connectionStatus;

  @override
  ValueListenable<List<PairedHost>> get hosts => Link.hosts;

  @override
  ValueListenable<PluginInfo?> get plugin => Link.share.remote;

  @override
  bool get canText => Link.share.canText;

  @override
  bool get canFiles => Link.share.canFiles;

  @override
  void reconnect() => Link.reconnect();

  @override
  Future<ShareAction> sendText(String text, {String? subject}) => Link.share.sendText(text, subject: subject);

  @override
  Future<StagedFile> stage(SharedFile file) => LinkPlatform.instance.stageSharedFile(file);

  @override
  ShareUpload sendFile(StagedFile staged, SharedFile file) {
    return Link.share.sendFile(path: staged.path, name: file.name, size: staged.size, mime: file.mime, sha256: staged.sha256);
  }

  @override
  Future<void> clearStaged() => LinkPlatform.instance.clearStagedFiles();
}

//#endregion
