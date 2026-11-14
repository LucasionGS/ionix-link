import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "empty_state.dart";

/// A text field that sends what is typed, sticky Ctrl/Alt/Shift/Super and the special keys (Esc, Tab, arrows,
/// Backspace, Enter), all to the desktop through [InputSource]. Used by the touchpad page and over the full-screen
/// screen viewer.
class KeysPanel extends StatefulWidget {
  const KeysPanel({super.key, this.input});

  /// Where keys go; the link's input plugin when null.
  final InputSource? input;

  @override
  State<KeysPanel> createState() => _KeysPanelState();
}

class _KeysPanelState extends State<KeysPanel> {
  final TextEditingController _text = TextEditingController();
  final Set<KeyModifier> _mods = {};

  InputSource get _input => widget.input ?? UiSources.input;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on LinkException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  void _key(String keysym) {
    final mods = Set<KeyModifier>.of(_mods);
    setState(_mods.clear);
    _guard(() => _input.key(keysym, modifiers: mods));
  }

  void _send() {
    final value = _text.text;
    if (value.isEmpty) return;
    final mods = Set<KeyModifier>.of(_mods);
    _text.clear();
    setState(_mods.clear);
    if (mods.isNotEmpty && value.length == 1) {
      _guard(() => _input.key(value, modifiers: mods));
    }
    else {
      _guard(() => _input.text(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Keys(controller: _text, mods: _mods, onSend: _send, onKey: _key, onToggle: (m) => setState(() => _mods.contains(m) ? _mods.remove(m) : _mods.add(m)));
  }
}

class _Keys extends StatelessWidget {
  const _Keys({required this.controller, required this.mods, required this.onSend, required this.onKey, required this.onToggle});

  final TextEditingController controller;
  final Set<KeyModifier> mods;
  final VoidCallback onSend;
  final void Function(String) onKey;
  final void Function(KeyModifier) onToggle;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(IonixSpace.md, IonixSpace.sm, IonixSpace.md, IonixSpace.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: const InputDecoration(hintText: "Type here, then send", isDense: true),
                ),
              ),
              const SizedBox(width: IonixSpace.sm),
              IconButton.filled(tooltip: "Send text", onPressed: onSend, icon: const Icon(Icons.send_rounded)),
            ],
          ),
          const SizedBox(height: IonixSpace.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (label, mod) in const [("Ctrl", KeyModifier.ctrl), ("Alt", KeyModifier.alt), ("Shift", KeyModifier.shift), ("Super", KeyModifier.superKey)])
                  Padding(
                    padding: const EdgeInsets.only(right: IonixSpace.sm),
                    child: FilterChip(label: Text(label), selected: mods.contains(mod), onSelected: (_) => onToggle(mod), selectedColor: t.accentBright.withValues(alpha: 0.3)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: IonixSpace.xs),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                KeyButton(label: "Esc", onTap: () => onKey("Escape")),
                KeyButton(label: "Tab", onTap: () => onKey("Tab")),
                KeyButton(icon: Icons.keyboard_arrow_left_rounded, tooltip: "Left", onTap: () => onKey("Left")),
                KeyButton(icon: Icons.keyboard_arrow_up_rounded, tooltip: "Up", onTap: () => onKey("Up")),
                KeyButton(icon: Icons.keyboard_arrow_down_rounded, tooltip: "Down", onTap: () => onKey("Down")),
                KeyButton(icon: Icons.keyboard_arrow_right_rounded, tooltip: "Right", onTap: () => onKey("Right")),
                KeyButton(icon: Icons.backspace_outlined, tooltip: "Backspace", onTap: () => onKey("BackSpace")),
                KeyButton(icon: Icons.keyboard_return_rounded, tooltip: "Enter", onTap: () => onKey("Return")),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class KeyButton extends StatelessWidget {
  const KeyButton({super.key, this.label, this.icon, this.tooltip, required this.onTap});

  final String? label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: IonixSpace.sm),
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(minimumSize: const Size(52, IonixSpace.touch), padding: const EdgeInsets.symmetric(horizontal: IonixSpace.md)),
        child: icon != null ? Tooltip(message: tooltip ?? "", child: Icon(icon)) : Text(label!),
      ),
    );
  }
}
