import "dart:async";
import "dart:io";
import "dart:ui" as ui;

import "package:flutter/rendering.dart";
import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../../platform/link_platform.dart";
import "../app.dart";
import "../pages/pair/code_confirm_page.dart";
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
  const _Scenario(this.name, this.size, {this.theme = LinkTheme.ionix, this.open, this.features = const [], this.paired = true, this.offline = false, this.code = false, this.settings = false, this.fullscreen = false, this.thenSize, this.thenFeatures = const []});

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
  const _Scenario("fs-phone", _phone, open: LinkPlugins.screen, fullscreen: true),
  const _Scenario("fs-phone-landscape", Size(915, 412), open: LinkPlugins.screen, fullscreen: true),
  const _Scenario("fs-book-cover", _bookCover, open: LinkPlugins.screen, fullscreen: true),
  const _Scenario("fs-book-open", _bookOpen, open: LinkPlugins.screen, features: _bookFold, fullscreen: true),
  const _Scenario("fs-book-tabletop", _bookOpenTurned, open: LinkPlugins.screen, features: _bookTabletop, fullscreen: true),
  _Scenario("fs-book-tabletop-winix", _bookOpenTurned, theme: _winix, open: LinkPlugins.screen, features: _bookTabletop, fullscreen: true),
  const _Scenario("fs-fold-switch", _bookCover, open: LinkPlugins.screen, fullscreen: true, thenSize: _bookOpen, thenFeatures: _bookFold),
];

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
