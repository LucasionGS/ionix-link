import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "empty_state.dart";

/// Speaker icon (tap to mute), slider and percentage for the desktop's volume. Hidden while the volume is unknown.
class VolumeRow extends StatefulWidget {
  const VolumeRow({super.key});

  @override
  State<VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<VolumeRow> {
  final MediaSource _source = UiSources.media;
  double? _drag;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on LinkException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VolumeState?>(
      valueListenable: _source.volume,
      builder: (context, volume, _) {
        if (volume == null) return const SizedBox.shrink();
        final t = IonixTokens.of(context);
        final shown = volume.muted ? 0.0 : (_drag ?? volume.volume).clamp(0.0, 1.0);
        return Row(
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                tooltip: volume.muted ? "Unmute" : "Mute",
                padding: EdgeInsets.zero,
                icon: Icon(volume.muted ? Icons.volume_off_outlined : (shown < 0.34 ? Icons.volume_down_outlined : Icons.volume_up_outlined), size: 20, color: t.accentLight),
                onPressed: () => _run(() => _source.setMuted(!volume.muted)),
              ),
            ),
            Expanded(
              child: Slider(
                value: shown,
                onChanged: (v) => setState(() => _drag = v),
                onChangeEnd: (v) {
                  setState(() => _drag = null);
                  _run(() async {
                    if (volume.muted) await _source.setMuted(false);
                    await _source.setVolume(v);
                  });
                },
              ),
            ),
            SizedBox(width: 40, child: Text("${(shown * 100).round()}%", textAlign: TextAlign.end, style: Theme.of(context).textTheme.labelLarge)),
          ],
        );
      },
    );
  }
}
