import "dart:ui" show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import "package:material_ui/material_ui.dart";

/// Size and fold state of the window, read from [MediaQuery]. Works the same for a phone, an unfolded foldable, a
/// tablet, landscape and split-screen, because it only looks at the window it is given.
class WindowLayout {
  const WindowLayout({required this.size, this.fold, this.halfOpened = false});

  /// Narrowest window that gets two panes.
  static const double twoPaneWidth = 600;

  /// Width from which two panes are used even without a fold to split on.
  static const double comfortableTwoPaneWidth = 840;

  /// Read the layout of the window [context] is in. Rebuilds when size or display features change.
  static WindowLayout of(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final features = MediaQuery.displayFeaturesOf(context);
    DisplayFeature? found;
    for (final feature in features) {
      final isFold = feature.type == DisplayFeatureType.hinge || feature.type == DisplayFeatureType.fold;
      if (isFold && feature.bounds.overlaps(Offset.zero & size)) {
        found = feature;
        break;
      }
    }
    return WindowLayout(
      size: size,
      fold: found?.bounds,
      halfOpened: found?.state == DisplayFeatureState.postureHalfOpened,
    );
  }

  /// Window size in logical px.
  final Size size;

  /// Where the hinge or fold is, in window coordinates, or null when none is reported.
  final Rect? fold;

  /// Whether the device is half-opened.
  final bool halfOpened;

  /// Whether the fold runs top to bottom.
  bool get hasVerticalFold => fold != null && fold!.height >= fold!.width;

  /// A horizontal fold with the device half-opened: the screen's top half is upright and the bottom half is flat.
  bool get isTabletop => fold != null && !hasVerticalFold && halfOpened;

  /// Whether the dashboard and a plugin page sit side by side.
  /// Two panes need room for both: a fold down the middle gives each its own half; without one the window has
  /// to be wide enough ([comfortableTwoPaneWidth]) that neither pane is squeezed. A book-style foldable held
  /// with its fold horizontal is 700-odd dp wide, which is one comfortable pane, not two.
  bool get isTwoPane => !isTabletop && size.width >= twoPaneWidth && (hasVerticalFold || size.width >= comfortableTwoPaneWidth);
}
