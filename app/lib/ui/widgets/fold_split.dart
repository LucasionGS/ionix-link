import "package:flutter/scheduler.dart";
import "package:material_ui/material_ui.dart";

import "window_layout.dart";

/// A page body in two parts. Normally it is [flat] (or [top] above [bottom]); in tabletop posture [top] fills the
/// upright half and [bottom] the half lying flat, with the fold between them left empty.
class FoldSplit extends StatefulWidget {
  const FoldSplit({super.key, required this.top, required this.bottom, this.flat});

  /// The upper half in tabletop posture.
  final Widget top;

  /// The lower half in tabletop posture.
  final Widget bottom;

  /// What to show instead of the two halves when the device is not in tabletop posture. Defaults to [top] over
  /// [bottom] in a column.
  final Widget? flat;

  @override
  State<FoldSplit> createState() => _FoldSplitState();
}

class _FoldSplitState extends State<FoldSplit> {
  double? _originY;

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final y = box.localToGlobal(Offset.zero).dy;
    if (_originY == null || (_originY! - y).abs() > 0.5) setState(() => _originY = y);
  }

  @override
  Widget build(BuildContext context) {
    final layout = WindowLayout.of(context);
    if (!layout.isTabletop) {
      return widget.flat ?? Column(children: [Expanded(child: widget.top), widget.bottom]);
    }
    SchedulerBinding.instance.addPostFrameCallback((_) => _measure());
    final fold = layout.fold!;
    return LayoutBuilder(builder: (context, constraints) {
      final height = constraints.maxHeight;
      final origin = _originY ?? 0;
      final topHeight = (fold.top - origin).clamp(0.0, height);
      final bottomStart = (fold.bottom - origin).clamp(topHeight, height);
      return Column(children: [
        SizedBox(height: topHeight, child: widget.top),
        SizedBox(height: bottomStart - topHeight),
        Expanded(child: widget.bottom),
      ]);
    });
  }
}
