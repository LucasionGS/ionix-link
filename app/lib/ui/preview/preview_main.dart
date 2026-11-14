import "dart:async";
import "dart:io";
import "dart:ui" as ui;

import "package:flutter/rendering.dart";
import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../../platform/link_platform.dart";
import "../app.dart";
import "../pages/pair/code_confirm_page.dart";
import "../pages/share/share_session.dart";
import "../pages/share/share_sheet.dart";
import "../sources.dart";
import "../widgets/adaptive_scaffold.dart";
import "fakes.dart";

/// Renders the app's pages with made-up data and saves a PNG of each scenario, so the layouts can be looked at
/// without a desktop to connect to. Run it on a virtual display:
/// `PREVIEW_OUT=/some/dir xvfb-run -a ./ionix_link` after `flutter build linux --debug -t lib/ui/preview/preview_main.dart`.
/// `PREVIEW_ONLY=name,name` limits it to some scenarios.

const LinkTheme _winix = LinkTheme(
  name: "winix",
  flat: true,
  radiusSm: 4,
  radiusPill: 6,
  radiusPanel: 8,
  colors: LinkColors(
    bgDeep: 0xFF1B1B1B,
    bgWindow: 0xFF202020,
    bgCard: 0xFF2B2B2B,
    hover: 0xFF383838,
    border: 0xFF454545,
    muted: 0xFFA0A0A0,
    text: 0xFFE0E0E0,
    textBright: 0xFFFFFFFF,
    accent: 0xFF0078D4,
    accentBright: 0xFF4CC2FF,
    accentLight: 0xFF60CDFF,
    green: 0xFF6CCB5F,
    orange: 0xFFF7630C,
    red: 0xFFE81123,
    cyan: 0xFF3A96DD,
    link: 0xFF4CC2FF,
  ),
);

class _Scenario {
  const _Scenario(this.name, this.size, {this.theme = LinkTheme.ionix, this.open, this.features = const [], this.paired = true, this.offline = false, this.code = false, this.settings = false, this.fullscreen = false, this.share, this.thenSize, this.thenFeatures = const []});

  final String name;
  final Size size;
  final LinkTheme theme;
  final String? open;
  final List<ui.DisplayFeature> features;
  final bool paired;
  final bool offline;
  final bool code;
  final bool settings;

  /// Enter full screen once the page is up (screen viewer only).
  final bool fullscreen;

  /// Open the share sheet in this state once the app is up (`sending`, `waiting`, `done`, `failed`, `nohost`, `text`).
  final String? share;

  /// Resize to this after the first picture, in the same app instance, as a fold or unfold would.
  final Size? thenSize;
  final List<ui.DisplayFeature> thenFeatures;
}

const Size _phone = Size(412, 915);
const Size _unfolded = Size(840, 900);
const Size _tabletop = Size(412, 880);

// A book-style foldable: a short, wide 16:10 cover and a 4:3 inner display with the fold down the middle.
const Size _bookCover = Size(400, 640);
const Size _bookOpen = Size(944, 708);
const Size _bookOpenTurned = Size(708, 944);
const List<ui.DisplayFeature> _bookFold = [ui.DisplayFeature(bounds: Rect.fromLTWH(472, 0, 0, 708), type: ui.DisplayFeatureType.fold, state: ui.DisplayFeatureState.postureFlat)];
const List<ui.DisplayFeature> _bookFoldTurned = [ui.DisplayFeature(bounds: Rect.fromLTWH(0, 472, 708, 0), type: ui.DisplayFeatureType.fold, state: ui.DisplayFeatureState.postureFlat)];
const List<ui.DisplayFeature> _bookTabletop = [ui.DisplayFeature(bounds: Rect.fromLTWH(0, 472, 708, 0), type: ui.DisplayFeatureType.fold, state: ui.DisplayFeatureState.postureHalfOpened)];

const List<ui.DisplayFeature> _hinge = [ui.DisplayFeature(bounds: Rect.fromLTWH(408, 0, 24, 900), type: ui.DisplayFeatureType.hinge, state: ui.DisplayFeatureState.postureFlat)];
const List<ui.DisplayFeature> _fold = [ui.DisplayFeature(bounds: Rect.fromLTWH(0, 428, 412, 24), type: ui.DisplayFeatureType.fold, state: ui.DisplayFeatureState.postureHalfOpened)];

final List<_Scenario> _scenarios = [
  const _Scenario("phone-home-ionix", _phone),
  _Scenario("phone-home-winix", _phone, theme: _winix),
  const _Scenario("phone-offline-ionix", _phone, offline: true),
  const _Scenario("phone-media-ionix", _phone, open: LinkPlugins.media),
  _Scenario("phone-commands-winix", _phone, theme: _winix, open: LinkPlugins.commands),
  const _Scenario("phone-touchpad-ionix", _phone, open: LinkPlugins.input),
  const _Scenario("phone-screen-ionix", _phone, open: LinkPlugins.screen, thenSize: _unfolded, thenFeatures: _hinge),
  const _Scenario("phone-settings-ionix", _phone, settings: true),
  const _Scenario("phone-pairing-ionix", _phone, paired: false),
  const _Scenario("phone-code-ionix", _phone, paired: false, code: true),
  const _Scenario("unfolded-media-ionix", _unfolded, open: LinkPlugins.media, features: _hinge),
  _Scenario("unfolded-screen-winix", _unfolded, theme: _winix, open: LinkPlugins.screen, features: _hinge),
  const _Scenario("unfolded-idle-ionix", _unfolded, features: _hinge),
  const _Scenario("unfolded-media-noHinge", _unfolded, open: LinkPlugins.media),
  const _Scenario("tabletop-media-ionix", _tabletop, open: LinkPlugins.media, features: _fold),
  _Scenario("tabletop-screen-winix", _tabletop, theme: _winix, open: LinkPlugins.screen, features: _fold),
  const _Scenario("tabletop-touchpad-ionix", _tabletop, open: LinkPlugins.input, features: _fold),
  const _Scenario("book-cover-home", _bookCover),
  const _Scenario("book-cover-media", _bookCover, open: LinkPlugins.media),
  const _Scenario("book-cover-touchpad", _bookCover, open: LinkPlugins.input),
  const _Scenario("book-cover-pairing", _bookCover, paired: false),
  const _Scenario("book-open-idle", _bookOpen, features: _bookFold),
  const _Scenario("book-open-media", _bookOpen, open: LinkPlugins.media, features: _bookFold),
  const _Scenario("book-open-screen", _bookOpen, open: LinkPlugins.screen, features: _bookFold),
  const _Scenario("book-open-commands", _bookOpen, open: LinkPlugins.commands, features: _bookFold),
  const _Scenario("book-turned-media", _bookOpenTurned, open: LinkPlugins.media, features: _bookFoldTurned),
  const _Scenario("book-tabletop-screen", _bookOpenTurned, open: LinkPlugins.screen, features: _bookTabletop),
  const _Scenario("book-tabletop-media", _bookOpenTurned, open: LinkPlugins.media, features: _bookTabletop),
  const _Scenario("share-phone-confirm", _phone, share: "confirm"),
  const _Scenario("share-phone-confirm-link", _phone, share: "confirm-link"),
  const _Scenario("share-phone-sending", _phone, share: "sending"),
  const _Scenario("share-phone-waiting", _phone, share: "waiting"),
  const _Scenario("share-phone-done", _phone, share: "done"),
  const _Scenario("share-phone-failed", _phone, share: "failed"),
  const _Scenario("share-phone-nohost", _phone, paired: false, share: "nohost"),
  const _Scenario("share-phone-link", _phone, share: "link"),
  _Scenario("share-phone-sending-winix", _phone, theme: _winix, share: "sending"),
  const _Scenario("share-unfolded-sending", _unfolded, features: _hinge, share: "sending"),
  const _Scenario("share-book-open-sending", _bookOpen, features: _bookFold, share: "sending"),
  const _Scenario("share-book-tabletop-done", _bookOpenTurned, features: _bookTabletop, share: "done"),
  const _Scenario("fs-phone", _phone, open: LinkPlugins.screen, fullscreen: true),
  const _Scenario("fs-phone-landscape", Size(915, 412), open: LinkPlugins.screen, fullscreen: true),
  const _Scenario("fs-book-cover", _bookCover, open: LinkPlugins.screen, fullscreen: true),
  const _Scenario("fs-book-open", _bookOpen, open: LinkPlugins.screen, features: _bookFold, fullscreen: true),
  const _Scenario("fs-book-tabletop", _bookOpenTurned, open: LinkPlugins.screen, features: _bookTabletop, fullscreen: true),
  _Scenario("fs-book-tabletop-winix", _bookOpenTurned, theme: _winix, open: LinkPlugins.screen, features: _bookTabletop, fullscreen: true),
  const _Scenario("fs-fold-switch", _bookCover, open: LinkPlugins.screen, fullscreen: true, thenSize: _bookOpen, thenFeatures: _bookFold),
];

/// A frozen share session in the named state, for a picture of the sheet.
ShareSession _sharePreview(String state) {
  const photos = IncomingShare(files: [
    SharedFile(uri: "content://media/1", name: "IMG_20261114_182233.jpg", size: 4823411, mime: "image/jpeg"),
    SharedFile(uri: "content://media/2", name: "Holiday clip.mp4", size: 61203455, mime: "video/mp4"),
    SharedFile(uri: "content://media/3", name: "Notes.pdf", size: 183204, mime: "application/pdf"),
  ]);
  ShareItem item(int at, ShareItemStatus status, {int sent = 0, String? error}) => ShareItem(photos.files[at])
    ..status = status
    ..sentBytes = sent
    ..error = error;
  const link = IncomingShare(text: "https://www.example.com/articles/a-very-long-address-that-a-browser-would-share?utm_source=share", subject: "A page worth reading");
  switch (state) {
    case "confirm":
      return ShareSession.preview(photos, stage: ShareStage.confirm, items: [item(0, ShareItemStatus.queued), item(1, ShareItemStatus.queued), item(2, ShareItemStatus.queued)]);
    case "confirm-link":
      return ShareSession.preview(link, stage: ShareStage.confirm);
    case "sending":
      return ShareSession.preview(photos, stage: ShareStage.sending, items: [item(0, ShareItemStatus.done), item(1, ShareItemStatus.sending, sent: 23400000), item(2, ShareItemStatus.queued)]);
    case "waiting":
      return ShareSession.preview(photos, stage: ShareStage.waiting, items: [item(0, ShareItemStatus.queued), item(1, ShareItemStatus.queued), item(2, ShareItemStatus.queued)]);
    case "done":
      return ShareSession.preview(photos, stage: ShareStage.done, message: "Saved to Downloads on fakeix.", items: [item(0, ShareItemStatus.done), item(1, ShareItemStatus.done), item(2, ShareItemStatus.done)]);
    case "failed":
      return ShareSession.preview(photos, stage: ShareStage.failed, message: "Not enough free space in /home/ion/Downloads for 58 MiB.", items: [item(0, ShareItemStatus.done), item(1, ShareItemStatus.failed, error: "Not enough free space in /home/ion/Downloads for 58 MiB."), item(2, ShareItemStatus.queued)]);
    case "nohost":
      return ShareSession.preview(photos, stage: ShareStage.noHost, message: "No desktop is paired yet. Pair one, then share again.", items: [item(0, ShareItemStatus.queued), item(1, ShareItemStatus.queued), item(2, ShareItemStatus.queued)]);
    default:
      return ShareSession.preview(
        link,
        stage: ShareStage.done,
        message: "Opened on fakeix.",
        textAction: ShareAction.opened,
      );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LinkPlatform.select();
  runApp(const _Preview());
}

class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final GlobalKey _boundary = GlobalKey();
  _Scenario? _current;
  ShellController _shell = ShellController();
  int _generation = 0;
  Size? _size;
  List<ui.DisplayFeature>? _features;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final out = Directory(Platform.environment["PREVIEW_OUT"] ?? "/tmp/ionix-link-preview")..createSync(recursive: true);
    final only = Platform.environment["PREVIEW_ONLY"]?.split(",");
    for (final scenario in _scenarios) {
      if (only != null && !only.contains(scenario.name)) continue;
      UiSources.theme = FakeThemeSource(scenario.theme);
      UiSources.home = FakeHomeSource(paired: scenario.paired, status: scenario.offline ? LinkStatus(LinkState.retrying, host: fakeHost, retryAt: DateTime.now().add(const Duration(seconds: 8))) : null);
      if (scenario.offline) (UiSources.home as FakeHomeSource).plugins.value = [];
      UiSources.media = FakeMediaSource(two: true);
      UiSources.commands = FakeCommandsSource();
      UiSources.input = FakeInputSource();
      UiSources.screen = FakeScreenSource();
      UiSources.pair = FakePairSource();
      UiSources.share = FakeShareSource(paired: scenario.paired);
      final shell = ShellController();
      if (scenario.open != null) shell.openPage(scenario.open!);
      if (scenario.settings) shell.showSection(ShellSection.settings);
      setState(() {
        _shell = shell;
        _current = scenario;
        _generation++;
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (scenario.fullscreen) {
        shell.setFullscreen(true);
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      if (scenario.code) {
        _navigator()?.push(MaterialPageRoute<void>(builder: (_) => CodeConfirmPage(host: DiscoveredHost(id: "a" * 32, name: "myeonix", address: "192.168.1.42", port: 47110, fingerprint: "b" * 64, protocol: 1, protocolMin: 1))));
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      if (scenario.share != null) {
        final navigator = _navigator();
        final session = _sharePreview(scenario.share!);
        if (navigator != null && navigator.mounted && navigator.overlay != null) {
          unawaited(showShareSheet(navigator.overlay!.context, session.share, session: session));
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File("${out.path}/${scenario.name}.png").writeAsBytesSync(data!.buffer.asUint8List());
      stdout.writeln("saved ${scenario.name}");
      if (scenario.thenSize != null) {
        setState(() {
          _size = scenario.thenSize;
          _features = scenario.thenFeatures;
        });
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final after = await (_boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
        final afterData = await after.toByteData(format: ui.ImageByteFormat.png);
        File("${out.path}/${scenario.name}-unfolded.png").writeAsBytesSync(afterData!.buffer.asUint8List());
        final screen = UiSources.screen as FakeScreenSource;
        stdout.writeln("fold check ${scenario.name}: starts=${screen.starts} stops=${screen.stops} open=${shell.openPlugin} fullscreen=${shell.fullscreen}");
      }
      _size = null;
      _features = null;
    }
    exit(0);
  }

  NavigatorState? _navigator() {
    NavigatorState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        found = element.state as NavigatorState;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final s = _current;
    if (s == null) return const SizedBox.shrink();
    final size = _size ?? s.size;
    final features = _features ?? s.features;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: size.height,
          maxHeight: size.height,
          child: RepaintBoundary(
            key: _boundary,
            child: IonixLinkApp(
              key: ValueKey(_generation),
              shell: _shell,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: size, padding: const EdgeInsets.only(top: 36, bottom: 20), displayFeatures: features),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
