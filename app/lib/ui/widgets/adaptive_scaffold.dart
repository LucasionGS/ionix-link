import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../pages/desktop/desktop_session.dart";
import "../pages/home_page.dart";
import "../pages/settings_page.dart";
import "../plugin_pages.dart";
import "../sources.dart";
import "../theme.dart";
import "empty_state.dart";
import "ion_page.dart";
import "window_layout.dart";

/// Top-level places of the shell (the rail or bottom bar).
enum ShellSection { home, settings }

/// What is open in the shell: one section and at most one plugin page. Owned above [AppShell], so a fold, an unfold
/// or a rotation changes only how it is laid out, never what is open.
class ShellController extends ChangeNotifier {
  ShellSection _section = ShellSection.home;
  String? _plugin;
  bool _fullscreen = false;

  /// The section shown in the dashboard pane.
  ShellSection get section => _section;

  /// The plugin whose page is open, or null.
  String? get openPlugin => _plugin;

  void showSection(ShellSection section) {
    if (_section == section) return;
    _section = section;
    notifyListeners();
  }

  void openPage(String plugin) {
    if (_plugin == plugin) return;
    _plugin = plugin;
    notifyListeners();
  }

  void closePlugin() {
    if (_plugin == null) return;
    _plugin = null;
    _fullscreen = false;
    notifyListeners();
  }

  /// Whether the open page has taken over the whole window (the screen viewer). Lives here, with the selection,
  /// so a fold or unfold keeps it.
  bool get fullscreen => _fullscreen;

  /// The Phone desktop that is running, if any. It lives here for the same reason [fullscreen] does: a fold or unfold
  /// rebuilds the page in another place of the tree, and the desktop must not notice.
  DesktopSession? desktopSession;

  /// Set by a page that takes the system's back for itself (the Phone desktop sends it to the desktop). While set,
  /// back calls it instead of leaving full screen or closing the page.
  VoidCallback? backHandler;

  void setFullscreen(bool value) {
    if (_fullscreen == value) return;
    _fullscreen = value;
    notifyListeners();
  }
}

/// How much a scrolling page leaves free at its end for the floating dock: nothing beside an open page, where
/// the rail stands at the side.
double dockClearance(BuildContext context) {
  if (WindowLayout.of(context).isTwoPane) return IonixSpace.lg;
  return IonixSpace.dockClearance + MediaQuery.paddingOf(context).bottom;
}

/// Gives pages their [ShellController].
class ShellScope extends InheritedNotifier<ShellController> {
  const ShellScope({super.key, required ShellController controller, required super.child}) : super(notifier: controller);

  static ShellController of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ShellScope>()!.notifier!;
  }
}

/// The adaptive frame of the paired app. Single pane with a bottom bar on a phone; navigation rail plus the
/// dashboard beside the open plugin page on a wider window, with the pane boundary on the hinge when the device
/// reports one. In tabletop posture the open page gets the whole window so it can use both halves.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final ShellController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const double _railWidth = 56;

  /// One key per page, so a page keeps its state when it moves between the full-screen and the side pane.
  final Map<String, GlobalKey> _keys = {};

  GlobalKey _key(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  Widget _sectionPage(ShellSection section) {
    return KeyedSubtree(
      key: _key("section:${section.name}"),
      child: section == ShellSection.home ? const HomePage() : const SettingsPage(),
    );
  }

  Widget _pluginPage(BuildContext context, String plugin) {
    final spec = PluginPages.byPlugin(plugin);
    if (spec == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: UiSources.home.plugins,
      builder: (context, plugins, _) {
        if (!plugins.any((p) => p.name == plugin)) {
          return _Unavailable(spec: spec);
        }
        return KeyedSubtree(key: _key("plugin:$plugin"), child: spec.builder(context));
      },
    );
  }

  int _activeIndex(ShellController c) {
    return switch (c.openPlugin) {
      LinkPlugins.input => 1,
      LinkPlugins.screen => 2,
      _ => c.section == ShellSection.home ? 0 : 3,
    };
  }

  void _select(ShellController c, int index) {
    switch (index) {
      case 0:
        c.showSection(ShellSection.home);
      case 1:
        c.openPage(LinkPlugins.input);
      case 2:
        c.openPage(LinkPlugins.screen);
      case 3:
        c.showSection(ShellSection.settings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = WindowLayout.of(context);
    return ShellScope(
      controller: widget.controller,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final plugin = controller.openPlugin;
          final Widget body;
          if (layout.isTwoPane) {
            body = _twoPane(context, layout, controller);
          }
          else if (plugin != null) {
            body = _pluginPage(context, plugin);
          }
          else {
            final bottom = MediaQuery.paddingOf(context).bottom;
            body = Stack(
              children: [
                Positioned.fill(child: _sectionPage(controller.section)),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottom + 22,
                  child: Center(child: _Navigation(vertical: false, active: _activeIndex(controller), onSelect: (i) => _select(controller, i))),
                ),
              ],
            );
          }
          // Back leaves full screen first, then (on a single pane) closes the open page.
          final closesPage = !layout.isTwoPane && plugin != null;
          return PopScope(
            canPop: controller.backHandler == null && !controller.fullscreen && !closesPage,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              if (controller.backHandler != null) {
                controller.backHandler!();
              }
              else if (controller.fullscreen) {
                controller.setFullscreen(false);
              }
              else {
                controller.closePlugin();
              }
            },
            child: body,
          );
        },
      ),
    );
  }

  Widget _twoPane(BuildContext context, WindowLayout layout, ShellController controller) {
    final width = layout.size.width;
    final inset = MediaQuery.paddingOf(context);
    final fold = layout.hasVerticalFold ? layout.fold : null;

    var leftWidth = (width * 0.48).clamp(340.0, 460.0);
    var gap = 0.0;
    if (fold != null && fold.left >= 340 && width - fold.right >= 300) {
      leftWidth = fold.left;
      gap = fold.width;
    }

    final plugin = controller.openPlugin;
    final right = plugin == null ? const _PickSomething() : _pluginPage(context, plugin);

    return Row(
      children: [
        SizedBox(
          width: leftWidth,
          child: Stack(
            children: [
              Positioned.fill(
                left: _railWidth + 26,
                child: MediaQuery.removePadding(context: context, removeLeft: true, child: _sectionPage(controller.section)),
              ),
              Positioned(
                left: 16,
                top: inset.top + 20,
                bottom: inset.bottom + 20,
                width: _railWidth,
                child: _Navigation(vertical: true, active: _activeIndex(controller), onSelect: (i) => _select(controller, i)),
              ),
            ],
          ),
        ),
        if (gap > 0) SizedBox(width: gap) else const SizedBox(width: 12),
        Expanded(child: MediaQuery.removePadding(context: context, removeLeft: true, child: right)),
      ],
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// The floating dock (compact) or rail (two-pane): Home, Touchpad, Screen and Settings.
class _Navigation extends StatelessWidget {
  const _Navigation({required this.vertical, required this.active, required this.onSelect});

  final bool vertical;
  final int active;
  final ValueChanged<int> onSelect;

  static const List<_NavItem> _items = [
    _NavItem(Icons.home_outlined, "Home"),
    _NavItem(Icons.touch_app_outlined, "Touchpad"),
    _NavItem(Icons.desktop_windows_outlined, "Screen"),
    _NavItem(Icons.settings_outlined, "Settings"),
  ];

  Widget _button(BuildContext context, int i) {
    final t = IonixTokens.of(context);
    final on = i == active;
    return Semantics(
      button: true,
      selected: on,
      label: _items[i].label,
      child: Tooltip(
        message: _items[i].label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelect(i),
          child: Container(
            width: vertical ? 44 : 48,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? t.accentBright.withValues(alpha: 0.22) : null, borderRadius: BorderRadius.circular(14)),
            child: Icon(_items[i].icon, size: 22, color: on ? t.textBright : t.text),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    if (vertical) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: t.bar(radius: 18),
        child: Column(
          children: [
            for (var i = 0; i < 3; i++) ...[_button(context, i), const SizedBox(height: 6)],
            const Spacer(),
            _button(context, 3),
          ],
        ),
      );
    }
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: t.bar(radius: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++) ...[if (i > 0) const SizedBox(width: 6), _button(context, i)],
        ],
      ),
    );
  }
}

class _PickSomething extends StatelessWidget {
  const _PickSomething();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.touch_app_outlined,
      title: "Pick something to control",
      message: "Choose media, the touchpad or the screen from the list.",
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.spec});

  final PluginPageSpec spec;

  @override
  Widget build(BuildContext context) {
    return IonPage(
      title: spec.title,
      plugin: true,
      body: EmptyState(
        icon: spec.icon,
        title: "${spec.title} isn't available",
        message: "Your desktop is offline or has turned this feature off. It comes back by itself when the connection does.",
      ),
    );
  }
}
