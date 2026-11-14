import "package:material_ui/material_ui.dart";

import "dart:async";

import "../link/link.dart";
import "../platform/link_platform.dart";
import "sources.dart";
import "theme.dart";
import "widgets/adaptive_scaffold.dart";
import "widgets/backdrop.dart";
import "pages/pair/pair_page.dart";
import "pages/share/share_session.dart";
import "pages/share/share_sheet.dart";

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
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  final List<IncomingShare> _shares = [];
  StreamSubscription<IncomingShare>? _shareIntake;
  bool _sheetOpen = false;
  ShareSession? _sheetSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shareIntake = UiSources.share.incoming.listen(_onShare);
    UiSources.share.takeLaunchShare().then((share) {
      if (share != null) _onShare(share);
    }, onError: (Object _) {});
  }

  /// A share sheet at a time: one that arrives while another is still waiting for Send or sending waits for it (so
  /// no app can swap what the open sheet is about to send), and one that arrives over a sheet that has finished (or
  /// failed) replaces it. A sheet only ever sends after its Send button is tapped.
  void _onShare(IncomingShare share) {
    _shares.add(share);
    if (!_sheetOpen) {
      _presentNextShare();
    }
    else if (_sheetSession?.isActive == false) {
      _navigator.currentState?.maybePop();
    }
  }

  Future<void> _presentNextShare() async {
    _sheetOpen = true;
    try {
      while (_shares.isNotEmpty && mounted) {
        var context = _navigator.currentState?.overlay?.context;
        // A share that started the app arrives before the first frame has built the navigator.
        while (context == null && mounted) {
          await WidgetsBinding.instance.endOfFrame;
          context = _navigator.currentState?.overlay?.context;
        }
        if (context == null || !context.mounted) return;
        final share = _shares.removeAt(0);
        final session = ShareSession(share)..start();
        _sheetSession = session;
        await showShareSheet(context, share, session: session);
        _sheetSession = null;
      }
    } finally {
      _sheetOpen = false;
    }
  }

  @override
  void dispose() {
    _shareIntake?.cancel();
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
        navigatorKey: _navigator,
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
