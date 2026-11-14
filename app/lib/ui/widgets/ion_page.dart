import "package:material_ui/material_ui.dart";

import "../theme.dart";
import "adaptive_scaffold.dart";
import "floating_bar.dart";
import "ion_mark.dart";
import "window_layout.dart";

/// The frame every screen goes through: a floating bar (back chevron and title, the host in the middle, actions on
/// the right) and a body that respects the safe area. A [plugin] page shows a back chevron when the window is single
/// pane, where it covers the whole screen; in two-pane it sits beside the dashboard and needs none.
class IonPage extends StatelessWidget {
  const IonPage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.plugin = false,
    this.home = false,
    this.underDock = false,
    this.onBack,
  });

  final String title;
  final List<Widget> actions;
  final Widget body;

  /// Whether this is a plugin page opened from the dashboard.
  final bool plugin;

  /// The dashboard: the bar carries the Ion mark and the clock, and is left out beside an open page.
  final bool home;

  /// The body scrolls under the floating dock, so it pads its own end ([dockClearance]).
  final bool underDock;

  /// Shows a back chevron that calls this, for pages pushed as routes.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final twoPane = WindowLayout.of(context).isTwoPane;
    final inset = MediaQuery.paddingOf(context);
    final showBar = !(home && twoPane);

    Widget leading;
    if (home) {
      leading = BarPill(leading: IonMark(color: t.accentLight), label: "link");
    }
    else if (onBack != null) {
      leading = BarPill(icon: Icons.chevron_left_rounded, label: title, tooltip: "Back", onTap: onBack);
    }
    else if (plugin && !twoPane) {
      leading = BarPill(icon: Icons.chevron_left_rounded, label: title, tooltip: "Back", onTap: () => ShellScope.of(context).closePlugin());
    }
    else {
      leading = BarPill(label: title);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: EdgeInsets.only(top: inset.top + (twoPane ? 20 : 8), bottom: underDock ? 0 : inset.bottom + (twoPane ? 20 : 0)),
        child: Column(
          children: [
            if (showBar) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: FloatingBar(
                  leading: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 150), child: leading),
                  center: const HostDot(),
                  trailing: home ? const [BarClock()] : actions,
                ),
              ),
              const SizedBox(height: IonixSpace.sm),
            ],
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}
