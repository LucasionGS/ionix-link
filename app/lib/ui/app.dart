import "package:material_ui/material_ui.dart";

import "../link/link.dart";
import "sources.dart";
import "theme.dart";
import "widgets/adaptive_scaffold.dart";
import "widgets/backdrop.dart";
import "pages/pair/pair_page.dart";

/// Root widget: a `MaterialApp` wearing the desktop's current theme (a theme change on the desktop recolours the
/// running app), the backdrop behind every route, [PairPage] when nothing is paired and the [AppShell] otherwise.
class IonixLinkApp extends StatefulWidget {
  const IonixLinkApp({super.key, this.shell, this.builder});

  /// What is open in the shell. Owned by the app when null.
  final ShellController? shell;

  /// Wraps every route, below the app's own `MediaQuery`. For previews and tests that need to fake a window.
  final TransitionBuilder? builder;

  @override
  State<IonixLinkApp> createState() => _IonixLinkAppState();
}

class _IonixLinkAppState extends State<IonixLinkApp> with WidgetsBindingObserver {
  late final ShellController _shell = widget.shell ?? ShellController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.shell == null) _shell.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && UiSources.home.currentHost.value != null && !UiSources.home.status.value.isReady) {
      UiSources.home.reconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LinkTheme>(
      valueListenable: UiSources.theme.theme,
      builder: (context, theme, _) => MaterialApp(
        title: "Ionix Link",
        debugShowCheckedModeBanner: false,
        theme: buildTheme(theme),
        themeMode: ThemeMode.light,
        builder: (context, child) {
          final stacked = Stack(fit: StackFit.expand, children: [const AppBackdrop(), ?child]);
          return widget.builder == null ? stacked : widget.builder!(context, stacked);
        },
        home: ValueListenableBuilder<List<PairedHost>>(
          valueListenable: UiSources.home.hosts,
          builder: (context, hosts, _) => hosts.isEmpty ? const PairPage() : AppShell(controller: _shell),
        ),
      ),
    );
  }
}
