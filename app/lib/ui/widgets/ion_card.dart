import "dart:ui" show ImageFilter;

import "package:material_ui/material_ui.dart";

import "../theme.dart";

/// The app's glass panel: a translucent window-coloured surface with an accent hairline (opaque on flat themes).
/// [blur] adds a real backdrop blur; use it on a few large panels, not on every list row.
class IonCard extends StatelessWidget {
  const IonCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.blur = false,
    this.padding = const EdgeInsets.all(IonixSpace.lg),
    this.radius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Marks the card as the current item of a list.
  final bool selected;

  /// Blur what is behind the panel.
  final bool blur;
  final EdgeInsetsGeometry padding;

  /// Corner radius; the theme's panel radius when null.
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final r = BorderRadius.circular(radius ?? t.radiusPanel);
    Widget content = DecoratedBox(
      decoration: t.glass(selected: selected, radius: radius),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: r,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, borderRadius: r, child: Padding(padding: padding, child: child)),
      ),
    );
    if (blur && !t.flat) {
      content = ClipRRect(borderRadius: r, child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: content));
    }
    return content;
  }
}

/// A pill, tile or control surface: half-transparent card fill, `border` hairline; [selected] tints it with the
/// accent. Minimum touch size is kept by the caller's constraints.
class IonPill extends StatelessWidget {
  const IonPill({
    super.key,
    required this.child,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: IonixSpace.md),
    this.radius,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final double? radius;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final r = BorderRadius.circular(radius ?? t.radiusPill);
    return DecoratedBox(
      decoration: t.pill(selected: selected, radius: radius),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: r,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, borderRadius: r, child: Padding(padding: padding, child: Align(alignment: alignment, child: child))),
      ),
    );
  }
}

/// A rounded icon on a tinted square.
class IonBadge extends StatelessWidget {
  const IonBadge({super.key, required this.icon, this.color, this.size = 44, this.circle = false});

  final IconData icon;

  /// Tint; the accent when null. The icon itself is `accentLight` unless tinted.
  final Color? color;
  final double size;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return Container(
      width: size,
      height: size,
      decoration: t.badge(color: color, circle: circle),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: color ?? t.accentLight),
    );
  }
}
