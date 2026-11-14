import "dart:typed_data";
import "dart:ui" show ImageFilter;

import "package:material_ui/material_ui.dart";

import "../sources.dart";
import "../theme.dart";

/// Full-bleed background behind the whole app: the desktop's wallpaper dimmed with the deepest background colour,
/// or, without one, soft blooms of the accent colours over it. Static.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: UiSources.theme.wallpaper,
      builder: (context, bytes, _) {
        if (bytes != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              // Blurred and dimmed: the wallpaper is ambience here, and text sits straight on it on some pages.
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14, tileMode: TileMode.clamp),
                child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => ColoredBox(color: t.bgDeep)),
              ),
              ColoredBox(color: t.bgDeep.withValues(alpha: 0.6)),
            ],
          );
        }
        if (t.flat) return ColoredBox(color: t.bgDeep);
        return ColoredBox(
          color: t.bgDeep,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Bloom(color: t.accent.withValues(alpha: 0.5), center: const Alignment(0.64, -0.84), radius: 0.9),
              _Bloom(color: t.link.withValues(alpha: 0.32), center: const Alignment(-0.84, 0.24), radius: 1.0),
              _Bloom(color: t.accentBright.withValues(alpha: 0.28), center: const Alignment(0.8, 0.96), radius: 0.8),
            ],
          ),
        );
      },
    );
  }
}

class _Bloom extends StatelessWidget {
  const _Bloom({required this.color, required this.center, required this.radius});

  final Color color;
  final Alignment center;
  final double radius;

  @override
  Widget build(BuildContext context) {
    // A blurred disc rather than a radial gradient: gradient stops show as rings on a dark ground.
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest.shortestSide * radius * 1.3;
        final centre = center.alongSize(box.biggest);
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: centre.dx - size / 2,
              top: centre.dy - size / 2,
              width: size,
              height: size,
              // A soft radial disc, then a light blur over it: the gradient alone shows its stops as rings on a
              // dark ground, and a heavy blur alone is rendered at a visibly low resolution.
              child: RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20, tileMode: TileMode.decal),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [for (var i = 0; i <= 12; i++) color.withValues(alpha: color.a * 0.7 * (1 - i / 12) * (1 - i / 12))],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
