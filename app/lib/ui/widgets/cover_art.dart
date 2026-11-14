import "dart:typed_data";

import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";

/// A player's cover, fetched through [MediaSource.art] whenever its `artUrl` changes, faded in over an accent gradient
/// that stays as the placeholder while loading and for tracks without one. [icon] is drawn on the placeholder only.
class CoverArt extends StatefulWidget {
  const CoverArt({super.key, required this.player, required this.size, required this.radius, this.icon});

  final MediaPlayer player;
  final double size;
  final BorderRadius radius;
  final IconData? icon;

  @override
  State<CoverArt> createState() => _CoverArtState();
}

class _CoverArtState extends State<CoverArt> {
  final MediaSource _source = UiSources.media;
  String? _url;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.player.artUrl != _url || widget.player.name != oldWidget.player.name) _load();
  }

  Future<void> _load() async {
    final url = widget.player.artUrl;
    _url = url;
    if (url == null) {
      if (_bytes != null) setState(() => _bytes = null);
      return;
    }
    final bytes = await _source.art(widget.player);
    // Only the answer for the cover still wanted; a slow reply for the previous track is dropped.
    if (mounted && _url == url) setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: widget.radius,
      child: SizedBox.square(
        dimension: widget.size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [t.accent.withValues(alpha: 0.85), t.cyan.withValues(alpha: 0.85)]),
              ),
              child: widget.icon == null || bytes != null ? null : Icon(widget.icon, size: widget.size * 0.4, color: t.onColor(t.accent)),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: bytes == null
                  ? const SizedBox.expand(key: ValueKey<String?>(null))
                  : Image.memory(bytes, key: ValueKey(_url), fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium),
            ),
          ],
        ),
      ),
    );
  }
}
