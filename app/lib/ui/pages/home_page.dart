import "dart:async";

import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../plugin_pages.dart";
import "../sources.dart";
import "../theme.dart";
import "../widgets/adaptive_scaffold.dart";
import "../widgets/connection_banner.dart";
import "../widgets/cover_art.dart";
import "../widgets/empty_state.dart";
import "../widgets/floating_bar.dart";
import "../widgets/ion_card.dart";
import "../widgets/ion_page.dart";
import "../widgets/volume_row.dart";
import "../widgets/window_layout.dart";
import "pair/pair_page.dart";

/// Dashboard of the current host: connection banner, a hero panel (host, state, lock, volume), what is playing, a
/// tile for every plugin the desktop offers, and the latest notifications. On a wide window it is the left pane
/// beside the open plugin page.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return IonPage(
      title: "link",
      home: true,
      underDock: true,
      body: ValueListenableBuilder<PairedHost?>(
        valueListenable: UiSources.home.currentHost,
        builder: (context, host, _) {
          if (host == null) return const _NoHost();
          final twoPane = WindowLayout.of(context).isTwoPane;
          return ListView(
            padding: EdgeInsets.fromLTRB(14, IonixSpace.xs, twoPane ? IonixSpace.sm : 14, dockClearance(context)),
            children: [
              _Hero(host: host),
              const SizedBox(height: IonixSpace.md),
              const ConnectionBanner(),
              _NowPlaying(compact: twoPane),
              const _Tiles(),
              const _Recent(),
            ],
          );
        },
      ),
    );
  }
}

class _NoHost extends StatelessWidget {
  const _NoHost();

  @override
  Widget build(BuildContext context) {
    final source = UiSources.home;
    return ValueListenableBuilder<List<PairedHost>>(
      valueListenable: source.hosts,
      builder: (context, hosts, _) {
        final first = hosts.isEmpty ? null : hosts.first;
        return EmptyState(
          icon: Icons.desktop_access_disabled_outlined,
          title: "Not connected to a desktop",
          message: first == null ? "Pair this phone with your Ionix desktop to get started." : "Pick one of your paired desktops to connect.",
          actionLabel: first == null ? "Pair a desktop" : "Connect to ${first.name}",
          action: first == null ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairPage())) : () => source.selectHost(first.id),
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.host});

  final PairedHost host;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final source = UiSources.home;
    return IonCard(
      blur: true,
      padding: const EdgeInsets.all(IonixSpace.lg),
      child: Column(
        children: [
          Row(
            children: [
              const IonBadge(icon: Icons.desktop_windows_outlined, size: 46),
              const SizedBox(width: IonixSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(host.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleLarge),
                    ValueListenableBuilder<LinkStatus>(
                      valueListenable: source.status,
                      builder: (context, status, _) => ValueListenableBuilder<HostStatus?>(
                        valueListenable: source.hostStatus,
                        builder: (context, info, _) => ValueListenableBuilder<LinkTheme>(
                          valueListenable: UiSources.theme.theme,
                          builder: (context, theme, _) => Text(_state(status, info, theme), maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: t.dim)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const _LockButton(),
            ],
          ),
          const SizedBox(height: IonixSpace.sm),
          const VolumeRow(),
        ],
      ),
    );
  }

  static String _state(LinkStatus status, HostStatus? info, LinkTheme theme) {
    switch (status.state) {
      case LinkState.ready:
        final battery = info?.battery;
        final parts = ["Connected", "theme ${theme.name}", if (battery != null) "${battery.level}%${battery.charging ? " charging" : ""}"];
        return parts.join(" · ");
      case LinkState.connecting:
      case LinkState.authenticating:
        return "Connecting…";
      case LinkState.retrying:
        return "Not reachable";
      case LinkState.forgotten:
        return "Needs pairing again";
      case LinkState.idle:
        return "Disconnected";
    }
  }
}

class _LockButton extends StatelessWidget {
  const _LockButton();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PluginInfo>>(
      valueListenable: UiSources.home.plugins,
      builder: (context, plugins, _) {
        if (!plugins.any((p) => p.name == LinkPlugins.commands)) return const SizedBox.shrink();
        return IonIconButton(
          icon: Icons.lock_outline_rounded,
          tooltip: "Lock the desktop",
          onTap: () async {
            try {
              await UiSources.commands.run("lock");
            } on LinkException catch (e) {
              if (context.mounted) showMessage(context, e.message);
            }
          },
        );
      },
    );
  }
}

class _NowPlaying extends StatefulWidget {
  const _NowPlaying({required this.compact});

  final bool compact;

  @override
  State<_NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<_NowPlaying> {
  final MediaSource _source = UiSources.media;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  MediaPlayer? _active(List<MediaPlayer> players, String? name) {
    if (players.isEmpty) return null;
    for (final p in players) {
      if (p.name == name) return p;
    }
    return players.first;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<MediaPlayer>>(
      valueListenable: _source.players,
      builder: (context, players, _) => ValueListenableBuilder<String?>(
        valueListenable: _source.activePlayer,
        builder: (context, active, _) {
          final player = _active(players, active);
          if (player == null) return const SizedBox.shrink();
          final t = IonixTokens.of(context);
          final text = Theme.of(context).textTheme;
          final length = player.length?.inMilliseconds ?? 0;
          final position = _source.positionOf(player, DateTime.now())?.inMilliseconds ?? 0;
          final progress = length > 0 ? (position / length).clamp(0.0, 1.0) : 0.0;
          final playing = player.status == MediaStatus.playing;
          final art = widget.compact ? 44.0 : 56.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: IonixSpace.md),
            child: IonCard(
              blur: true,
              padding: EdgeInsets.all(widget.compact ? 12 : 14),
              onTap: () => ShellScope.of(context).openPage(LinkPlugins.media),
              child: Row(
                children: [
                  CoverArt(player: player, size: art, radius: BorderRadius.circular(t.radiusSm + 2)),
                  const SizedBox(width: IonixSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(player.title.isEmpty ? "Unknown title" : player.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium?.copyWith(fontSize: widget.compact ? 13 : 14)),
                        const SizedBox(height: 2),
                        Text(widget.compact ? player.artist : [player.artist, player.identity].where((s) => s.isNotEmpty).join(" · "), maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: t.dim)),
                        if (!widget.compact) ...[
                          const SizedBox(height: 6),
                          ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: progress, minHeight: 3, backgroundColor: t.border.withValues(alpha: 0.6), color: t.accentLight)),
                        ],
                      ],
                    ),
                  ),
                  if (!widget.compact) IonIconButton(icon: Icons.skip_previous_rounded, onTap: player.canPrevious ? () => _source.control(MediaAction.previous, player: player.name) : null, tooltip: "Previous"),
                  const SizedBox(width: IonixSpace.xs),
                  _RoundButton(
                    icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    tooltip: playing ? "Pause" : "Play",
                    onTap: () => _source.control(MediaAction.playPause, player: player.name),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap, required this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: t.accentBright,
        shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22, color: t.onAccent))),
      ),
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles();

  @override
  Widget build(BuildContext context) {
    final source = UiSources.home;
    return ValueListenableBuilder<List<PluginInfo>>(
      valueListenable: source.plugins,
      builder: (context, plugins, _) {
        final specs = [for (final spec in PluginPages.all) if (plugins.any((p) => p.name == spec.plugin)) spec];
        return ValueListenableBuilder<LinkStatus>(
          valueListenable: source.status,
          builder: (context, status, _) {
            if (specs.isEmpty) return _TilesEmpty(status: status);
            final shell = ShellScope.of(context);
            final twoPane = WindowLayout.of(context).isTwoPane;
            return ListenableBuilder(
              listenable: shell,
              builder: (context, _) => LayoutBuilder(
                builder: (context, constraints) {
                  final columns = twoPane ? 2 : 3;
                  const gap = 10.0;
                  final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return ValueListenableBuilder<List<DesktopNotification>>(
                    valueListenable: source.notifications,
                    builder: (context, notifications, _) => Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final spec in specs)
                          SizedBox(
                            width: width,
                            // Shorter tiles on a short screen, so the grid clears the dock without scrolling.
                            height: twoPane || MediaQuery.sizeOf(context).height < 700 ? 76 : 96,
                            child: _Tile(
                              spec: spec,
                              selected: twoPane && shell.openPlugin == spec.plugin,
                              count: spec.plugin == LinkPlugins.notifications ? notifications.length : 0,
                              onTap: () => shell.openPage(spec.plugin),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.spec, required this.selected, required this.count, required this.onTap});

  final PluginPageSpec spec;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Semantics(
      button: true,
      label: spec.description,
      child: Stack(
        children: [
          Positioned.fill(
            child: IonPill(
              onTap: onTap,
              selected: selected,
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(spec.icon, size: 24, color: selected ? t.textBright : t.accentLight),
                  const SizedBox(height: 8),
                  Text(spec.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: selected ? t.textBright : t.text)),
                ],
              ),
            ),
          ),
          if (count > 0)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: t.accentBright, borderRadius: BorderRadius.circular(10)),
                child: Text("$count", style: Theme.of(context).textTheme.labelSmall?.copyWith(color: t.onAccent, fontWeight: FontWeight.w700, fontSize: 11)),
              ),
            ),
        ],
      ),
    );
  }
}

class _TilesEmpty extends StatelessWidget {
  const _TilesEmpty({required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    final name = status.host?.name ?? "your desktop";
    final source = UiSources.home;
    switch (status.state) {
      case LinkState.ready:
        return EmptyState(
          icon: Icons.extension_off_outlined,
          title: "Nothing to control yet",
          message: "$name is connected but hasn't turned any features on. Check its Ionix Link settings.",
        );
      case LinkState.forgotten:
        return const SizedBox.shrink();
      case LinkState.idle:
      case LinkState.connecting:
      case LinkState.authenticating:
      case LinkState.retrying:
        final retrying = status.state == LinkState.retrying;
        return Padding(
          padding: const EdgeInsets.only(top: IonixSpace.xl),
          child: EmptyState(
            icon: Icons.wifi_find_outlined,
            title: retrying ? "Can't reach $name" : "Waiting for $name",
            message: retrying ? "Is it on the same Wi-Fi? Its controls show up here as soon as it answers." : "Its controls show up here once the connection is up.",
            actionLabel: retrying ? "Try again" : null,
            action: source.reconnect,
          ),
        );
    }
  }
}

/// The latest notifications: one strip on a phone, a "Recent" panel beside an open page.
class _Recent extends StatelessWidget {
  const _Recent();

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return "now";
    if (d.inHours < 1) return "${d.inMinutes}m";
    if (d.inDays < 1) return "${d.inHours}h";
    return "${d.inDays}d";
  }

  @override
  Widget build(BuildContext context) {
    final twoPane = WindowLayout.of(context).isTwoPane;
    return ValueListenableBuilder<List<DesktopNotification>>(
      valueListenable: UiSources.home.notifications,
      builder: (context, items, _) {
        if (items.isEmpty) return const SizedBox.shrink();
        final t = IonixTokens.of(context);
        final text = Theme.of(context).textTheme;
        final shown = items.take(twoPane ? 3 : 1).toList();
        return Padding(
          padding: const EdgeInsets.only(top: IonixSpace.md),
          child: IonCard(
            radius: twoPane ? null : t.radiusPill,
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: twoPane ? IonixSpace.md : IonixSpace.md),
            onTap: () => ShellScope.of(context).openPage(LinkPlugins.notifications),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (twoPane) ...[
                  Text("Recent", style: text.bodyMedium?.copyWith(color: t.dim)),
                  const SizedBox(height: IonixSpace.sm),
                ],
                for (final n in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: n.urgency == NotificationUrgency.critical ? t.orange : t.cyan, shape: BoxShape.circle)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(n.app.isEmpty ? "Desktop" : n.app, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelLarge),
                              Text(n.body.isEmpty ? n.summary : "${n.summary}: ${n.body}", maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: t.dim)),
                            ],
                          ),
                        ),
                        Text(_ago(n.time), style: text.labelSmall?.copyWith(color: t.dim, fontSize: 11)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
