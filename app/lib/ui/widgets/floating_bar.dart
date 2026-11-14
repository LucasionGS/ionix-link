import "dart:async";

import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "ion_card.dart";

/// The desktop's floating bar: a rounded translucent strip with a leading, a centred and a trailing slot. Sits
/// inset from the screen edges; the page lays out below it.
class FloatingBar extends StatelessWidget {
  const FloatingBar({super.key, this.leading, this.center, this.trailing = const []});

  final Widget? leading;
  final Widget? center;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Container(
      height: IonixSpace.bar,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: t.bar(),
      child: Row(
        children: [
          ?leading,
          Expanded(child: Center(child: center)),
          ...trailing,
        ],
      ),
    );
  }
}

/// A small pill inside a [FloatingBar]: 28 px of pill in a 44 px touch target.
class BarPill extends StatelessWidget {
  const BarPill({super.key, this.icon, this.label, this.leading, this.onTap, this.tooltip, this.selected = false});

  final IconData? icon;
  final String? label;

  /// A custom leading widget (the Ion mark).
  final Widget? leading;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final pill = Container(
      height: 28,
      padding: EdgeInsets.symmetric(horizontal: label == null ? 6 : 10),
      decoration: t.pill(selected: selected, radius: t.radiusPill * 0.85),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?leading,
          if (icon != null) Icon(icon, size: 16, color: t.accentLight),
          if (label != null && (icon != null || leading != null)) const SizedBox(width: 6),
          if (label != null) Flexible(child: Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: t.accentLight))),
        ],
      ),
    );
    final target = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      child: Center(widthFactor: 1, child: pill),
    );
    final tapped = onTap == null ? target : InkResponse(onTap: onTap, radius: 22, child: target);
    return tooltip == null ? tapped : Tooltip(message: tooltip!, child: tapped);
  }
}

/// A status dot and the current host's name, for the centre of a bar.
class HostDot extends StatelessWidget {
  const HostDot({super.key});

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final source = UiSources.home;
    return ValueListenableBuilder<LinkStatus>(
      valueListenable: source.status,
      builder: (context, status, _) => ValueListenableBuilder<PairedHost?>(
        valueListenable: source.currentHost,
        builder: (context, host, _) {
          final color = switch (status.state) {
            LinkState.ready => t.green,
            LinkState.connecting || LinkState.authenticating => t.cyan,
            LinkState.retrying => t.orange,
            LinkState.forgotten => t.red,
            LinkState.idle => t.dim,
          };
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: t.glow(color))),
              const SizedBox(width: 7),
              Flexible(child: Text(host?.name ?? "No desktop", maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textBright))),
            ],
          );
        },
      ),
    );
  }
}

/// The time, in a bar pill.
class BarClock extends StatefulWidget {
  const BarClock({super.key});

  @override
  State<BarClock> createState() => _BarClockState();
}

class _BarClockState extends State<BarClock> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = _now.hour.toString().padLeft(2, "0");
    final m = _now.minute.toString().padLeft(2, "0");
    return BarPill(label: "$h:$m");
  }
}

/// A round icon button used in cards and bars: 44 px target, optional pill surface.
class IonIconButton extends StatelessWidget {
  const IonIconButton({super.key, required this.icon, required this.onTap, this.tooltip, this.selected = false, this.size = 44});

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final button = SizedBox(
      width: size,
      height: size,
      child: IonPill(onTap: onTap, selected: selected, padding: EdgeInsets.zero, child: Icon(icon, size: 20, color: onTap == null ? t.dim.withValues(alpha: 0.5) : (selected ? t.textBright : t.text))),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
