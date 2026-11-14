import "package:material_ui/material_ui.dart";

import "../theme.dart";
import "ion_card.dart";

/// A centred explanation with an optional action, for empty lists and failures. Written for people: say what
/// happened and what to do next.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action, this.actionLabel, this.tint});

  final IconData icon;
  final String title;
  final String? message;

  /// Primary action; shown with [actionLabel].
  final VoidCallback? action;
  final String? actionLabel;

  /// Icon tint; the accent when null.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(IonixSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IonBadge(icon: icon, size: 72, circle: true, color: tint),
              const SizedBox(height: IonixSpace.lg),
              Text(title, textAlign: TextAlign.center, style: text.titleLarge),
              if (message != null) ...[
                const SizedBox(height: IonixSpace.sm),
                Text(message!, textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: t.text.withValues(alpha: 0.85))),
              ],
              if (action != null && actionLabel != null) ...[
                const SizedBox(height: IonixSpace.xl),
                FilledButton(onPressed: action, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small uppercase section label above a group.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(IonixSpace.xs, IonixSpace.lg, IonixSpace.xs, IonixSpace.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.dim, letterSpacing: 1.2, fontWeight: FontWeight.w700),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Shows [message] in a snackbar, replacing any current one.
void showMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}
