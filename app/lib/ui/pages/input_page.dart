import "package:material_ui/material_ui.dart";

import "../sources.dart";
import "../theme.dart";
import "../widgets/empty_state.dart";
import "../widgets/fold_split.dart";
import "../widgets/ion_page.dart";
import "../widgets/keys_panel.dart";
import "../widgets/touchpad.dart";

/// Remote touchpad ([Touchpad]) plus a keyboard bar: a text field sent as typed text, and special keys (Esc, Tab,
/// arrows, Enter, Backspace) with sticky Ctrl/Alt/Shift/Super. In tabletop posture the keys are on the upright half
/// and the pad on the half lying flat.
class InputPage extends StatefulWidget {
  const InputPage({super.key});

  @override
  State<InputPage> createState() => _InputPageState();
}

class _InputPageState extends State<InputPage> {
  final InputSource _input = UiSources.input;

  @override
  Widget build(BuildContext context) {
    final pad = _input.hasPointer
        ? const Padding(padding: EdgeInsets.all(IonixSpace.md), child: Touchpad())
        : const EmptyState(icon: Icons.mouse_outlined, title: "No pointer control", message: "Your desktop can't move its mouse. Check that Ionix Link has access to a virtual pointer.");
    final keys = _input.hasKeyboard ? const KeysPanel() : const Padding(padding: EdgeInsets.all(IonixSpace.lg), child: Text("Typing needs wtype on your desktop."));
    return IonPage(
      title: "Touchpad",
      plugin: true,
      body: FoldSplit(
        top: SingleChildScrollView(child: keys),
        bottom: pad,
        flat: Column(children: [Expanded(child: pad), keys]),
      ),
    );
  }
}
