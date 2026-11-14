import "dart:async";

import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "../pages/pair/pair_page.dart";

/// Thin banner for the connection: hidden when ready; "Connecting…", "Retrying in 8 s" (tap = retry now), or "This
/// desktop forgot this phone" with a "Pair again" action.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final source = UiSources.home;
    return ValueListenableBuilder<LinkStatus>(
      valueListenable: source.status,
      builder: (context, status, _) {
        final t = IonixTokens.of(context);
        final name = status.host?.name ?? "your desktop";
        switch (status.state) {
          case LinkState.ready:
          case LinkState.idle:
            return const SizedBox.shrink();
          case LinkState.connecting:
          case LinkState.authenticating:
            return _Bar(
              color: t.cyan,
              leading: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              text: "Connecting to $name…",
            );
          case LinkState.retrying:
            final warning = status.warning;
            if (warning == null) return _Retry(status: status, name: name, onRetry: source.reconnect);
            // Something else answered in the desktop's place and was skipped; say so, it explains the wait.
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Retry(status: status, name: name, onRetry: source.reconnect),
                const SizedBox(height: IonixSpace.sm),
                _Bar(color: t.orange, leading: Icon(Icons.gpp_maybe_outlined, size: 20, color: t.orange), text: warning),
              ],
            );
          case LinkState.forgotten:
            return _Bar(
              color: t.orange,
              leading: Icon(Icons.link_off_rounded, size: 20, color: t.orange),
              text: "$name no longer knows this phone.",
              actionLabel: "Pair again",
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairPage())),
            );
        }
      },
    );
  }
}

class _Retry extends StatefulWidget {
  const _Retry({required this.status, required this.name, required this.onRetry});

  final LinkStatus status;
  final String name;
  final VoidCallback onRetry;

  @override
  State<_Retry> createState() => _RetryState();
}

class _RetryState extends State<_Retry> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final retryAt = widget.status.retryAt;
    final seconds = retryAt == null ? 0 : retryAt.difference(DateTime.now()).inSeconds.clamp(0, 999);
    return _Bar(
      color: t.orange,
      leading: Icon(Icons.wifi_off_rounded, size: 20, color: t.orange),
      text: "Can't reach ${widget.name}. Is it on the same Wi-Fi? Retrying in $seconds s.",
      actionLabel: "Retry now",
      onTap: widget.onRetry,
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.color, required this.leading, required this.text, this.actionLabel, this.onTap});

  final Color color;
  final Widget leading;
  final String text;
  final String? actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: IonixSpace.md),
      child: Material(
      color: color.withValues(alpha: 0.14),
      shape: RoundedRectangleBorder(borderRadius: t.rSm, side: BorderSide(color: color.withValues(alpha: 0.4))),
      child: InkWell(
        onTap: onTap,
        borderRadius: t.rSm,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: IonixSpace.md, vertical: IonixSpace.md),
          child: Row(
            children: [
              leading,
              const SizedBox(width: IonixSpace.md),
              Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textBright))),
              if (actionLabel != null) ...[
                const SizedBox(width: IonixSpace.sm),
                Text(actionLabel!, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color)),
              ],
            ],
          ),
        ),
      ),
    ));
  }
}
