import "package:material_ui/material_ui.dart";

import "../link/link.dart";
import "pages/clipboard_page.dart";
import "pages/commands_page.dart";
import "pages/desktop_page.dart";
import "pages/input_page.dart";
import "pages/media_page.dart";
import "pages/notifications_page.dart";
import "pages/screen_page.dart";

/// One dashboard tile and the page it opens, for one plugin.
class PluginPageSpec {
  const PluginPageSpec({
    required this.plugin,
    required this.title,
    required this.description,
    required this.icon,
    required this.builder,
    this.offered,
  });

  /// Plugin name ([LinkPlugins]); the tile shows only while the plugin is negotiated on the connection.
  final String plugin;

  /// Tile and page title.
  final String title;

  /// One line under the tile's title.
  final String description;

  /// Tile icon.
  final IconData icon;

  /// Builds the plugin's page.
  final WidgetBuilder builder;

  /// Extra condition on what the desktop negotiated before the tile shows (the plugin itself must be there too),
  /// for a page that needs more than its own plugin, like the Phone desktop's video. Null = the plugin is enough.
  final bool Function(List<PluginInfo> plugins)? offered;

  /// Whether the tile shows for the plugins negotiated on the current connection.
  bool isOffered(List<PluginInfo> plugins) => plugins.any((p) => p.name == plugin) && (offered?.call(plugins) ?? true);
}

/// The plugin page registry. The dashboard renders one tile per entry, in order. **A new plugin's page is one entry
/// here.**
class PluginPages {
  PluginPages._();

  /// Every plugin page: media, commands, input, screen, desktop, clipboard, notifications. (`status` has no page: its
  /// data is on the dashboard header.)
  static List<PluginPageSpec> get all => _all;

  /// The spec of [plugin], or null.
  static PluginPageSpec? byPlugin(String? plugin) {
    for (final spec in _all) {
      if (spec.plugin == plugin) return spec;
    }
    return null;
  }

  static final List<PluginPageSpec> _all = [
    PluginPageSpec(
      plugin: LinkPlugins.notifications,
      title: "Alerts",
      description: "What your desktop is saying",
      icon: Icons.notifications_none_rounded,
      builder: (_) => const NotificationsPage(),
    ),
    PluginPageSpec(
      plugin: LinkPlugins.commands,
      title: "Commands",
      description: "Run things on your desktop",
      icon: Icons.bolt_rounded,
      builder: (_) => const CommandsPage(),
    ),
    PluginPageSpec(
      plugin: LinkPlugins.clipboard,
      title: "Clipboard",
      description: "Send and fetch text",
      icon: Icons.content_paste_rounded,
      builder: (_) => const ClipboardPage(),
    ),
    PluginPageSpec(
      plugin: LinkPlugins.input,
      title: "Touchpad",
      description: "Mouse and keyboard",
      icon: Icons.touch_app_outlined,
      builder: (_) => const InputPage(),
    ),
    PluginPageSpec(
      plugin: LinkPlugins.screen,
      title: "Screen",
      description: "See and tap your desktop",
      icon: Icons.desktop_windows_outlined,
      builder: (_) => const ScreenPage(),
    ),
    PluginPageSpec(
      plugin: LinkPlugins.desktop,
      title: "Phone desktop",
      description: "Your desktop as a phone screen",
      icon: Icons.smartphone_rounded,
      builder: (_) => const DesktopPage(),
      // The picture is worth showing only as sharp, fast video.
      offered: (plugins) {
        for (final plugin in plugins) {
          if (plugin.name == LinkPlugins.screen) return plugin.has(ScreenClient.capH264) && plugin.has(ScreenClient.capHires);
        }
        return false;
      },
    ),
    PluginPageSpec(
      plugin: LinkPlugins.media,
      title: "Media",
      description: "Play, skip and set the volume",
      icon: Icons.play_circle_outline_rounded,
      builder: (_) => const MediaPage(),
    ),
  ];
}
