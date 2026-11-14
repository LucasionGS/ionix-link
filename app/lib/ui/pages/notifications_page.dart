import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../theme.dart";
import "../widgets/empty_state.dart";
import "../widgets/ion_card.dart";
import "../widgets/ion_page.dart";

/// The desktop's open notifications, newest first; swipe to close one on the desktop (when it can).
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return "now";
    if (d.inHours < 1) return "${d.inMinutes} min ago";
    if (d.inDays < 1) return "${d.inHours} h ago";
    return "${d.inDays} d ago";
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return IonPage(
      title: "Notifications",
      plugin: true,
      body: ValueListenableBuilder<List<DesktopNotification>>(
        valueListenable: Link.notifications.active,
        builder: (context, items, _) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.notifications_off_outlined,
              title: "All quiet",
              message: "Notifications on your desktop show up here, and on this phone while it's connected.",
            );
          }
          final canDismiss = Link.notifications.hasCap(NotificationsClient.capDismiss);
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(IonixSpace.lg, 0, IonixSpace.lg, IonixSpace.xl),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: IonixSpace.sm),
            itemBuilder: (context, i) {
              final n = items[i];
              final urgent = n.urgency == NotificationUrgency.critical;
              final card = IonCard(
                padding: const EdgeInsets.all(IonixSpace.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IonBadge(icon: urgent ? Icons.priority_high_rounded : Icons.notifications_none_rounded, size: 40, color: urgent ? t.red : null),
                    const SizedBox(width: IonixSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(n.app.isEmpty ? "Desktop" : n.app, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelMedium?.copyWith(color: t.dim))),
                              Text(_ago(n.time), style: text.labelSmall?.copyWith(color: t.dim)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(n.summary, style: text.titleSmall?.copyWith(color: t.textBright, fontWeight: FontWeight.w600)),
                          if (n.body.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(n.body, maxLines: 4, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
              if (!canDismiss) return card;
              return Dismissible(
                key: ValueKey(n.id),
                background: Container(alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: IonixSpace.xl), decoration: BoxDecoration(color: t.accentBright.withValues(alpha: 0.18), borderRadius: t.rPanel), child: const Icon(Icons.done_all_rounded)),
                secondaryBackground: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: IonixSpace.xl), decoration: BoxDecoration(color: t.accentBright.withValues(alpha: 0.18), borderRadius: t.rPanel), child: const Icon(Icons.done_all_rounded)),
                confirmDismiss: (_) async {
                  final ok = await Link.notifications.dismiss(n.id);
                  if (!ok && context.mounted) showMessage(context, "Your desktop wouldn't close that one.");
                  return ok;
                },
                child: card,
              );
            },
          );
        },
      ),
    );
  }
}
