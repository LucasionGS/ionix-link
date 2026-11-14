import "dart:async";
import "dart:ui" as ui;

import "package:flutter/foundation.dart";
import "package:flutter/painting.dart";

import "../../link/link.dart";
import "../../platform/link_platform.dart";
import "../sources.dart";

/// Made-up data and fake sources for the preview entrypoint. Nothing here talks to a network.

final PairedHost fakeHost = PairedHost(
  id: "a" * 32,
  name: "myeonix",
  fingerprint: "b" * 64,
  port: 47110,
  addresses: const ["192.168.1.42"],
  pairedAt: DateTime(2026, 11, 1),
);

final PairedHost fakeSecondHost = PairedHost(
  id: "c" * 32,
  name: "laptop",
  fingerprint: "d" * 64,
  port: 47110,
  addresses: const ["192.168.1.58"],
  pairedAt: DateTime(2026, 11, 3),
);

List<PluginInfo> fakePlugins() => [
      for (final name in [LinkPlugins.notifications, LinkPlugins.media, LinkPlugins.commands, LinkPlugins.clipboard, LinkPlugins.input, LinkPlugins.screen, LinkPlugins.status])
        PluginInfo(name: name, version: 1),
    ];

final List<DesktopNotification> fakeNotifications = [
  DesktopNotification(id: 1, app: "Discord", summary: "Mara", body: "are you around? the build is green now", urgency: NotificationUrgency.normal, time: DateTime.now().subtract(const Duration(minutes: 2))),
  DesktopNotification(id: 2, app: "Firefox", summary: "Download finished", body: "archlinux-2026.11.01-x86_64.iso", urgency: NotificationUrgency.low, time: DateTime.now().subtract(const Duration(minutes: 14))),
  DesktopNotification(id: 3, app: "systemd", summary: "backup.service failed", body: "Exit status 23", urgency: NotificationUrgency.critical, time: DateTime.now().subtract(const Duration(hours: 1))),
];

class FakeHomeSource extends HomeSource {
  FakeHomeSource({LinkStatus? status, bool paired = true})
      : status = ValueNotifier(status ?? LinkStatus(LinkState.ready, host: fakeHost, address: "192.168.1.42")),
        hosts = ValueNotifier(paired ? [fakeHost] : []),
        currentHost = ValueNotifier(paired ? fakeHost : null);

  @override
  final ValueNotifier<LinkStatus> status;
  @override
  final ValueNotifier<List<PairedHost>> hosts;
  @override
  final ValueNotifier<PairedHost?> currentHost;
  @override
  final ValueNotifier<List<PluginInfo>> plugins = ValueNotifier(fakePlugins());
  @override
  final ValueNotifier<HostStatus?> hostStatus = ValueNotifier(const HostStatus(hostName: "myeonix", volume: 0.62, muted: false));
  @override
  final ValueNotifier<List<DesktopNotification>> notifications = ValueNotifier(fakeNotifications);

  @override
  void reconnect() {}

  @override
  Future<void> selectHost(String hostId) async {}

  @override
  Future<void> unpair(String hostId) async {}

  @override
  DeviceIdentity get identity => DeviceIdentity(id: "e" * 32, name: "Pixel 8", model: "Pixel 8");

  @override
  Future<void> setDeviceName(String? name) async {}
}

class FakeThemeSource extends ThemeSource {
  FakeThemeSource(LinkTheme initial) : _theme = ValueNotifier(initial);

  final ValueNotifier<LinkTheme> _theme;
  final ValueNotifier<Uint8List?> _wallpaper = ValueNotifier(null);

  @override
  ValueListenable<LinkTheme> get theme => _theme;

  @override
  ValueListenable<Uint8List?> get wallpaper => _wallpaper;

  void use(LinkTheme theme) => _theme.value = theme;
}

class FakeMediaSource extends MediaSource {
  FakeMediaSource({bool two = false}) {
    players = ValueNotifier([
      _player("spotify", "Spotify", "Night Drive", "Neon Harbor", "Glass Coast", artUrl: "file:///preview/night-drive.png"),
      if (two) _player("firefox", "Firefox", "Lo-fi beats to build to", "Various", "Stream"),
    ]);
  }

  @override
  late final ValueNotifier<List<MediaPlayer>> players;
  @override
  final ValueNotifier<String?> activePlayer = ValueNotifier("spotify");
  @override
  final ValueNotifier<VolumeState?> volume = ValueNotifier(const VolumeState(volume: 0.62, muted: false));

  static MediaPlayer _player(String name, String identity, String title, String artist, String album, {String? artUrl}) {
    return MediaPlayer(
      name: name,
      identity: identity,
      status: MediaStatus.playing,
      title: title,
      artist: artist,
      album: album,
      length: const Duration(minutes: 3, seconds: 48),
      position: const Duration(minutes: 1, seconds: 38),
      positionTime: DateTime.now(),
      canSeek: true,
      canNext: true,
      canPrevious: true,
      canPlay: true,
      canPause: true,
      artUrl: artUrl,
    );
  }

  @override
  Future<void> refresh() async {}

  Future<Uint8List>? _cover;

  @override
  Future<Uint8List?> art(MediaPlayer player) async => player.artUrl == null ? null : await (_cover ??= _drawCover());

  /// A made-up album cover (sunset over water), as PNG bytes.
  static Future<Uint8List> _drawCover() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const s = 512.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, s, s), Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(0, s), const [Color(0xFF2A0F45), Color(0xFFE0457B), Color(0xFFFFB86B)], const [0.0, 0.62, 1.0]));
    canvas.drawCircle(const Offset(s / 2, s * 0.62), s * 0.22, Paint()..color = const Color(0xFFFFE3A3));
    canvas.drawRect(const Rect.fromLTWH(0, s * 0.68, s, s * 0.32), Paint()..shader = ui.Gradient.linear(const Offset(0, s * 0.68), const Offset(0, s), const [Color(0xFF14325C), Color(0xFF0F0A18)]));
    for (var i = 0; i < 6; i++) {
      canvas.drawRect(Rect.fromLTWH(s * (0.3 + i * 0.015), s * (0.72 + i * 0.04), s * (0.4 - i * 0.03), 4), Paint()..color = const Color(0x66FFE3A3));
    }
    final image = await recorder.endRecording().toImage(s.toInt(), s.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  @override
  Future<void> control(MediaAction action, {String? player}) async {}

  @override
  Future<void> seek(Duration position, {String? player}) async {}

  @override
  Future<VolumeState> setVolume(double v) async => volume.value = VolumeState(volume: v, muted: false);

  @override
  Future<VolumeState> setMuted(bool muted) async => volume.value = VolumeState(volume: volume.value?.volume ?? 0, muted: muted);

  @override
  Duration? positionOf(MediaPlayer player, DateTime now) => player.position;
}

class FakeCommandsSource extends CommandsSource {
  @override
  final ValueNotifier<List<LinkCommand>> commands = ValueNotifier([
    LinkCommand(id: "lock", title: "Lock", icon: "lock", confirm: false, group: "System"),
    LinkCommand(id: "suspend", title: "Suspend", icon: "bedtime", confirm: false, group: "System"),
    LinkCommand(id: "logout", title: "Log out", icon: "logout", confirm: true, group: "System"),
    LinkCommand(id: "reboot", title: "Restart", icon: "restart", confirm: true, group: "System"),
    LinkCommand(id: "poweroff", title: "Shut down", icon: "power", confirm: true, group: "System"),
    LinkCommand(id: "screen-off", title: "Screen off", icon: "screen", confirm: false, group: "System"),
    LinkCommand(id: "backup", title: "Run backup", icon: "folder", confirm: true, group: "Tasks"),
    LinkCommand(id: "say-hi", title: "Say hi", icon: "terminal", confirm: false, group: "Tasks"),
  ]);

  @override
  Future<List<LinkCommand>> refresh() async => commands.value;

  @override
  Future<CommandResult> run(String id) async => const CommandResult(ok: true, exitCode: 0, detached: false);
}

class FakeInputSource extends InputSource {
  @override
  bool get hasPointer => true;

  @override
  bool get hasKeyboard => true;

  @override
  void move(double dx, double dy) {}

  @override
  void moveAbsolute(String output, double x, double y) {}

  @override
  void button(PointerButton button, ButtonAction action) {}

  @override
  void scroll(double dx, double dy) {}

  @override
  Future<void> text(String text) async {}

  @override
  Future<void> key(String keysym, {Set<KeyModifier> modifiers = const {}}) async {}
}

class FakeScreenSource extends ScreenSource {
  final StreamController<ScreenFrame> _frames = StreamController.broadcast();
  @override
  final ValueNotifier<ScreenStreamInfo?> stream = ValueNotifier(null);
  Uint8List? _picture;

  /// How many times the page started or stopped the stream, to show that a fold does neither.
  int starts = 0;
  int stops = 0;

  @override
  Future<List<ScreenOutput>> outputs() async => const [
        ScreenOutput(name: "DP-1", description: "Main monitor", x: 0, y: 0, width: 2560, height: 1440, scale: 1, focused: true),
        ScreenOutput(name: "HDMI-A-1", description: "Side monitor", x: 2560, y: 0, width: 1920, height: 1080, scale: 1, focused: false),
      ];

  @override
  Future<ScreenStreamInfo> start(String output, {double scale = 0.5, int quality = 60, int maxFps = 15}) async {
    starts++;
    final info = ScreenStreamInfo(output: output, width: 1280, height: 720);
    stream.value = info;
    _picture ??= await _drawDesktop();
    Timer(const Duration(milliseconds: 150), () => _frames.add(ScreenFrame(output: output, width: 1280, height: 720, seq: 1, format: "jpeg", time: DateTime.now(), bytes: _picture!)));
    return info;
  }

  @override
  Future<void> stop() async {
    stops++;
    stream.value = null;
  }

  @override
  void ack(int seq) {}

  @override
  Stream<ScreenFrame> get frames => _frames.stream;

  @override
  Stream<String> get stopped => const Stream.empty();

  /// A made-up desktop: wallpaper, a bar and two windows, as PNG bytes.
  static Future<Uint8List> _drawDesktop() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const w = 1280.0;
    const h = 720.0;
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(w, h), const [Color(0xFF1B1030), Color(0xFF5B2A86), Color(0xFF14325C)], const [0.0, 0.5, 1.0]),
    );
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(20, 14, w - 40, 34), const Radius.circular(10)), Paint()..color = const Color(0xCC0F0A18));
    void window(Rect r, Color body, Color edge) {
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(12));
      canvas.drawRRect(rr, Paint()..color = body);
      canvas.drawRRect(rr, Paint()..color = edge..style = PaintingStyle.stroke..strokeWidth = 2);
      canvas.drawRect(Rect.fromLTWH(r.left + 16, r.top + 40, r.width - 32, 8), Paint()..color = const Color(0x33FFFFFF));
      for (var i = 0; i < 6; i++) {
        canvas.drawRect(Rect.fromLTWH(r.left + 16, r.top + 70 + i * 26, (r.width - 32) * (0.9 - i * 0.1), 10), Paint()..color = const Color(0x22FFFFFF));
      }
    }
    window(const Rect.fromLTWH(70, 110, 560, 420), const Color(0xFF0F0A18), const Color(0xFF4A3D60));
    window(const Rect.fromLTWH(480, 220, 640, 400), const Color(0xFF1A1025), const Color(0xFFA855F7));
    final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}

class FakeCode extends CodeAttempt {
  @override
  String? get code => "931221";

  @override
  bool get isPending => true;

  @override
  Future<PairedHost> get result => Completer<PairedHost>().future;

  @override
  Future<void> cancel() async {}
}

class FakePairSource extends PairSource {
  @override
  bool get canScanQr => true;

  @override
  Stream<DiscoveredHost> discover() async* {
    yield DiscoveredHost(id: "a" * 32, name: "myeonix", address: "192.168.1.42", port: 47110, fingerprint: "b" * 64, protocol: 1, protocolMin: 1);
    yield DiscoveredHost(id: "c" * 32, name: "laptop", address: "192.168.1.58", port: 47110, fingerprint: "d" * 64, protocol: 1, protocolMin: 1);
    await Future<void>.delayed(const Duration(seconds: 60));
  }

  @override
  bool isCompatible(DiscoveredHost host) => true;

  @override
  Future<CodeAttempt> pairWithCode(DiscoveredHost host) async => FakeCode();

  @override
  Future<PairedHost> pairWithUri(PairingUri uri) => Completer<PairedHost>().future;

  @override
  PairingUri parseUri(String text) => throw LinkFormatException("That doesn't look like an Ionix Link pairing link.");

  @override
  Future<void> selectHost(String hostId) async {}
}

/// A [ShareSource] that is always connected (or has no host) and never sends: the preview freezes its sessions.
class FakeShareSource extends ShareSource {
  FakeShareSource({bool paired = true})
      : hosts = ValueNotifier(paired ? [fakeHost] : []),
        status = ValueNotifier(paired ? LinkStatus(LinkState.ready, host: fakeHost, address: "192.168.1.42") : LinkStatus.idleStatus);

  @override
  final ValueNotifier<LinkStatus> status;
  @override
  final ValueNotifier<List<PairedHost>> hosts;
  @override
  final ValueNotifier<PluginInfo?> plugin = ValueNotifier(PluginInfo(name: LinkPlugins.share, version: 1, caps: ["text", "files"]));

  @override
  Stream<IncomingShare> get incoming => const Stream.empty();

  @override
  Future<IncomingShare?> takeLaunchShare() async => null;

  @override
  bool get canText => true;

  @override
  bool get canFiles => true;

  @override
  void reconnect() {}

  @override
  Future<ShareAction> sendText(String text, {String? subject}) async => ShareAction.copied;

  @override
  Future<StagedFile> stage(SharedFile file) async => StagedFile(path: file.uri, size: file.size);

  @override
  ShareUpload sendFile(StagedFile staged, SharedFile file) => throw UnsupportedError("The preview never sends.");

  @override
  Future<void> clearStaged() async {}
}
