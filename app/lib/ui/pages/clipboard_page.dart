import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../../platform/link_platform.dart";
import "../theme.dart";
import "../widgets/empty_state.dart";
import "../widgets/ion_card.dart";
import "../widgets/ion_page.dart";

/// "Send my clipboard" (the phone's clipboard to the desktop), "Get desktop clipboard" (the desktop's onto the
/// phone's, shown here too), and a text field to send typed text.
class ClipboardPage extends StatefulWidget {
  const ClipboardPage({super.key});

  @override
  State<ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends State<ClipboardPage> {
  final TextEditingController _text = TextEditingController();
  String? _fetched;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _guard(String success, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showMessage(context, success);
    } on LinkException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendClipboard() => _guard("Sent to your desktop.", () async {
        final text = await LinkPlatform.instance.getClipboard();
        if (text.isEmpty) throw LinkException("Your phone's clipboard is empty. Copy something first.");
        await Link.clipboard.push(text);
      });

  Future<void> _fetch() => _guard("Copied to this phone.", () async {
        final text = await Link.clipboard.pull();
        if (text.isEmpty) throw LinkException("Your desktop's clipboard is empty, or holds something that isn't text.");
        await LinkPlatform.instance.setClipboard(text);
        if (mounted) setState(() => _fetched = text);
      });

  Future<void> _sendTyped() async {
    final text = _text.text;
    if (text.isEmpty) return;
    await _guard("Sent to your desktop.", () => Link.clipboard.push(text));
    if (mounted) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return IonPage(
      title: "Clipboard",
      plugin: true,
      body: ValueListenableBuilder<PluginInfo?>(
        valueListenable: Link.clipboard.remote,
        builder: (context, info, _) {
          if (info == null) {
            return const EmptyState(icon: Icons.content_paste_off_outlined, title: "Clipboard isn't available", message: "Your desktop is offline or has this feature off.");
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(IonixSpace.lg, 0, IonixSpace.lg, IonixSpace.xl),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: IonixSpace.maxContent),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: _Action(icon: Icons.upload_rounded, label: "Send my clipboard", hint: "Phone to desktop", onTap: _busy ? null : _sendClipboard)),
                          const SizedBox(width: IonixSpace.md),
                          Expanded(child: _Action(icon: Icons.download_rounded, label: "Get desktop clipboard", hint: "Desktop to phone", onTap: _busy ? null : _fetch)),
                        ],
                      ),
                      if (_fetched != null) ...[
                        const SizedBox(height: IonixSpace.md),
                        IonCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("From your desktop", style: text.labelMedium?.copyWith(color: t.dim)),
                              const SizedBox(height: IonixSpace.sm),
                              SelectableText(_fetched!, maxLines: 8, style: text.bodyMedium?.copyWith(color: t.textBright)),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: IonixSpace.xl),
                      Text("Send some text", style: text.titleMedium),
                      const SizedBox(height: IonixSpace.sm),
                      TextField(
                        controller: _text,
                        minLines: 3,
                        maxLines: 8,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(hintText: "Type or paste here. It lands on your desktop's clipboard."),
                      ),
                      const SizedBox(height: IonixSpace.md),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(onPressed: _busy ? null : _sendTyped, icon: const Icon(Icons.send_rounded), label: const Text("Send")),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.hint, required this.onTap});

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return IonPill(
      onTap: onTap,
      padding: const EdgeInsets.all(IonixSpace.lg),
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IonBadge(icon: icon),
          const SizedBox(height: IonixSpace.md),
          Text(label, style: text.titleSmall?.copyWith(color: t.textBright, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(hint, style: text.bodySmall?.copyWith(color: t.dim)),
        ],
      ),
    );
  }
}
