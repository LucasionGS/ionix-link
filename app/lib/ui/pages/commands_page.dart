import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "../widgets/empty_state.dart";
import "../widgets/ion_card.dart";
import "../widgets/ion_page.dart";

/// Grid of the desktop's commands grouped by [LinkCommand.group]; asks first when [LinkCommand.confirm], then shows
/// the result in a snackbar (and the output when there is some).
class CommandsPage extends StatefulWidget {
  const CommandsPage({super.key});

  @override
  State<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends State<CommandsPage> {
  final CommandsSource _source = UiSources.commands;
  final Set<String> _running = {};

  static const Map<String, IconData> _icons = {
    "lock": Icons.lock_outline_rounded,
    "bedtime": Icons.bedtime_outlined,
    "logout": Icons.logout_rounded,
    "restart": Icons.restart_alt_rounded,
    "power": Icons.power_settings_new_rounded,
    "terminal": Icons.terminal_rounded,
    "play": Icons.play_arrow_rounded,
    "screen": Icons.desktop_windows_outlined,
    "volume": Icons.volume_up_outlined,
    "wifi": Icons.wifi_rounded,
    "bolt": Icons.bolt_rounded,
    "star": Icons.star_outline_rounded,
    "apps": Icons.apps_rounded,
    "code": Icons.code_rounded,
    "folder": Icons.folder_open_rounded,
  };

  Future<void> _run(LinkCommand command) async {
    if (_running.contains(command.id)) return;
    if (command.confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(command.title),
          content: const Text("Run this on your desktop now?"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text("Run")),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _running.add(command.id));
    try {
      final result = await _source.run(command.id);
      if (!mounted) return;
      final output = result.output?.trim() ?? "";
      if (output.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(command.title),
            content: SingleChildScrollView(child: SelectableText(output, style: const TextStyle(fontFamily: "monospace", fontSize: 13))),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))],
          ),
        );
      }
      else if (mounted) {
        showMessage(context, result.detached ? "${command.title} is still running." : (result.ok ? "${command.title} done." : "${command.title} failed (exit ${result.exitCode ?? "?"})."));
      }
    } on LinkException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _running.remove(command.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IonPage(
      title: "Commands",
      plugin: true,
      body: ValueListenableBuilder<List<LinkCommand>>(
        valueListenable: _source.commands,
        builder: (context, commands, _) {
          if (commands.isEmpty) {
            return const EmptyState(
              icon: Icons.bolt_outlined,
              title: "No commands yet",
              message: "Add some to commands.json in your desktop's Ionix Link config folder and they appear here.",
            );
          }
          final groups = <String, List<LinkCommand>>{};
          for (final command in commands) {
            groups.putIfAbsent(command.group ?? "Commands", () => []).add(command);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(IonixSpace.lg, 0, IonixSpace.lg, IonixSpace.xl),
            children: [
              for (final entry in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(IonixSpace.xs, IonixSpace.lg, 0, IonixSpace.sm),
                  child: Text(entry.key.toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: IonixTokens.of(context).dim, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.maxWidth / 150).floor().clamp(2, 4);
                    const gap = IonixSpace.md;
                    final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final command in entry.value)
                          SizedBox(width: width, height: 108, child: _CommandTile(command: command, icon: _icons[command.icon] ?? Icons.terminal_rounded, running: _running.contains(command.id), onTap: () => _run(command))),
                      ],
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({required this.command, required this.icon, required this.running, required this.onTap});

  final LinkCommand command;
  final IconData icon;
  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return IonPill(
      onTap: running ? null : onTap,
      padding: const EdgeInsets.all(IonixSpace.md),
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, size: 24, color: command.confirm ? t.orange : t.accentLight),
              if (running) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          Text(command.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textBright, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
