import "dart:async";

import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../sources.dart";
import "../theme.dart";
import "../widgets/cover_art.dart";
import "../widgets/empty_state.dart";
import "../widgets/fold_split.dart";
import "../widgets/ion_card.dart";
import "../widgets/ion_page.dart";
import "../widgets/volume_row.dart";

/// Media remote: player picker, title/artist/album, a seek bar extrapolated with the player's position,
/// previous/play-pause/next, and a volume slider with mute. In tabletop posture the track is on the upright half and
/// the controls on the flat one.
class MediaPage extends StatefulWidget {
  const MediaPage({super.key});

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  final MediaSource _source = UiSources.media;
  String? _picked;
  double? _seekDrag;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _seekDrag == null) setState(() {});
    });
    _source.refresh().catchError((_) {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  MediaPlayer? _current(List<MediaPlayer> players, String? active) {
    if (players.isEmpty) return null;
    final name = _picked ?? active;
    for (final player in players) {
      if (player.name == name) return player;
    }
    return players.first;
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on LinkException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IonPage(
      title: "Media",
      plugin: true,
      body: ValueListenableBuilder<List<MediaPlayer>>(
        valueListenable: _source.players,
        builder: (context, players, _) => ValueListenableBuilder<String?>(
          valueListenable: _source.activePlayer,
          builder: (context, active, _) {
            final player = _current(players, active);
            if (player == null) {
              return const _NoPlayer(volume: VolumeRow());
            }
            final top = _Track(player: player, players: players, picked: player.name, onPick: (name) => setState(() => _picked = name));
            final bottom = _Controls(
              player: player,
              position: _source.positionOf(player, DateTime.now()),
              seekDrag: _seekDrag,
              onSeekChanged: (v) => setState(() => _seekDrag = v),
              onSeekEnd: (v) {
                setState(() => _seekDrag = null);
                _run(() => _source.seek(Duration(milliseconds: v.round()), player: player.name));
              },
              onControl: (action) => _run(() => _source.control(action, player: player.name)),
              volume: const VolumeRow(),
            );
            return FoldSplit(
              top: Padding(padding: const EdgeInsets.all(IonixSpace.md), child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: SizedBox(width: 320, child: top)))),
              bottom: Padding(padding: const EdgeInsets.all(IonixSpace.lg), child: Center(child: SingleChildScrollView(child: bottom))),
              flat: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(IonixSpace.lg),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: IonixSpace.maxContent),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [top, const SizedBox(height: IonixSpace.xl), bottom]),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NoPlayer extends StatelessWidget {
  const _NoPlayer({required this.volume});

  final Widget volume;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Expanded(
          child: EmptyState(
            icon: Icons.music_off_outlined,
            title: "Nothing is playing",
            message: "Start music or a video on your desktop and it shows up here.",
          ),
        ),
        Padding(padding: const EdgeInsets.all(IonixSpace.lg), child: IonCard(padding: const EdgeInsets.symmetric(horizontal: IonixSpace.sm), child: volume)),
      ],
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.player, required this.players, required this.picked, required this.onPick});

  final MediaPlayer player;
  final List<MediaPlayer> players;
  final String picked;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final subtitle = [player.artist, player.album].where((s) => s.isNotEmpty).join(" · ");
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (players.length > 1) ...[
          Wrap(
            spacing: IonixSpace.sm,
            runSpacing: IonixSpace.sm,
            alignment: WrapAlignment.center,
            children: [
              for (final p in players)
                ChoiceChip(label: Text(p.identity), selected: p.name == picked, onSelected: (_) => onPick(p.name)),
            ],
          ),
          const SizedBox(height: IonixSpace.lg),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            // Sized from the window's height too: on a short screen (a foldable's cover, or its inner display
            // in landscape) full-size artwork would push the transport controls off the bottom.
            final room = MediaQuery.sizeOf(context).height * 0.26;
            final side = (constraints.maxWidth.isFinite ? constraints.maxWidth : 240.0).clamp(96.0, room.clamp(96.0, 220.0));
            return CoverArt(
              player: player,
              size: side,
              radius: BorderRadius.circular(t.radiusPanel),
              icon: player.status == MediaStatus.stopped ? Icons.stop_circle_outlined : Icons.music_note_outlined,
            );
          },
        ),
        const SizedBox(height: IonixSpace.lg),
        Text(player.title.isEmpty ? "Unknown title" : player.title, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: text.headlineSmall),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: IonixSpace.xs),
          Text(subtitle, maxLines: 1, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: t.text.withValues(alpha: 0.8))),
        ],
        const SizedBox(height: IonixSpace.xs),
        Text(player.identity, style: text.labelMedium?.copyWith(color: t.dim)),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.player,
    required this.position,
    required this.seekDrag,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onControl,
    required this.volume,
  });

  final MediaPlayer player;
  final Duration? position;
  final double? seekDrag;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final void Function(MediaAction) onControl;
  final Widget volume;

  static String _format(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, "0");
    return d.inHours > 0 ? "${d.inHours}:${(m % 60).toString().padLeft(2, "0")}:$s" : "$m:$s";
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final length = player.length;
    final canSeek = player.canSeek && length != null && length.inMilliseconds > 0;
    final max = length?.inMilliseconds.toDouble() ?? 1;
    final value = (seekDrag ?? position?.inMilliseconds.toDouble() ?? 0).clamp(0.0, max);
    final playing = player.status == MediaStatus.playing;
    return IonCard(
      blur: true,
      padding: const EdgeInsets.fromLTRB(IonixSpace.sm, IonixSpace.sm, IonixSpace.sm, IonixSpace.md),
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Slider(value: canSeek ? value : 0, max: canSeek ? max : 1, onChanged: canSeek ? onSeekChanged : null, onChangeEnd: canSeek ? onSeekEnd : null),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: IonixSpace.lg),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_format(Duration(milliseconds: value.round())), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.dim)),
              Text(length == null ? "" : _format(length), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.dim)),
            ],
          ),
        ),
        const SizedBox(height: IonixSpace.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(iconSize: 36, tooltip: "Previous", icon: const Icon(Icons.skip_previous_rounded), onPressed: player.canPrevious ? () => onControl(MediaAction.previous) : null),
            const SizedBox(width: IonixSpace.md),
            Container(
              decoration: BoxDecoration(color: t.accentBright, shape: BoxShape.circle),
              child: IconButton(
                iconSize: 40,
                tooltip: playing ? "Pause" : "Play",
                color: t.onAccent,
                padding: const EdgeInsets.all(IonixSpace.md),
                icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: t.onAccent),
                onPressed: (playing ? player.canPause : player.canPlay) ? () => onControl(MediaAction.playPause) : null,
              ),
            ),
            const SizedBox(width: IonixSpace.md),
            IconButton(iconSize: 36, tooltip: "Next", icon: const Icon(Icons.skip_next_rounded), onPressed: player.canNext ? () => onControl(MediaAction.next) : null),
          ],
        ),
        const SizedBox(height: IonixSpace.md),
        volume,
      ],
    ));
  }
}
