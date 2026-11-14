import "dart:async";

import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "plugin_client.dart";

/// `media.*`: the desktop's MPRIS players and default-sink volume (`PROTOCOL.md` 8.2).
class MediaClient extends PluginClient {
  // Message types
  static const String typePlayers = "media.players";
  static const String typeControl = "media.control";
  static const String typeSeek = "media.seek";
  static const String typeVolume = "media.volume";
  static const String typeSetVolume = "media.setVolume";
  static const String typeArt = "media.art";

  /// Daemon cap: players (playerctl).
  static const String capPlayers = "players";

  /// Daemon cap: volume (wpctl).
  static const String capVolume = "volume";

  /// Daemon cap: cover art (`media.art`).
  static const String capArt = "art";

  /// Longest edge, px, of the covers [art] asks for: the media page shows them at up to 220 dp.
  static const int artSize = 512;

  /// Covers kept in memory, by `artUrl`.
  static const int _artCacheSize = 12;

  @override
  String get name => LinkPlugins.media;

  final ValueNotifier<List<MediaPlayer>> _players = ValueNotifier(const []);
  final ValueNotifier<String?> _activePlayer = ValueNotifier(null);
  final ValueNotifier<VolumeState?> _volume = ValueNotifier(null);

  // artUrl → JPEG, least recently used first; null = the desktop could not send that cover, so it is not asked again
  // until the next connection.
  final Map<String, Uint8List?> _art = {};
  final Map<String, Future<Uint8List?>> _artLoading = {};

  /// All players, as last pushed. Empty while detached.
  ValueListenable<List<MediaPlayer>> get players => _players;

  /// Name of the desktop's default player, or null.
  ValueListenable<String?> get activePlayer => _activePlayer;

  /// The [MediaPlayer] named by [activePlayer], or the first one, or null.
  MediaPlayer? get active {
    final players = _players.value;
    for (final player in players) {
      if (player.name == _activePlayer.value) return player;
    }
    return players.isEmpty ? null : players.first;
  }

  /// Default sink volume, null while detached or without [capVolume].
  ValueListenable<VolumeState?> get volume => _volume;

  /// Re-request players and volume.
  Future<void> refresh() async {
    await Future.wait([
      if (hasCap(capPlayers)) request(typePlayers).then(_applyPlayers),
      if (hasCap(capVolume)) request(typeVolume).then(_applyVolume),
    ]);
  }

  /// Send a transport command to [player] (default: the desktop's active one).
  Future<void> control(MediaAction action, {String? player}) async {
    final body = await request(typeControl, {"action": action.wire, "player": ?player});
    if (body["ok"] != true) throw LinkException("The player did not accept ${action.wire}.");
  }

  /// Seek [player] to an absolute [position].
  Future<void> seek(Duration position, {String? player}) async {
    final body = await request(typeSeek, {"position": position.inMilliseconds < 0 ? 0 : position.inMilliseconds, "player": ?player});
    if (body["ok"] != true) throw LinkException("The player cannot seek right now.");
  }

  /// Set the volume (0..1, values up to 1.5 accepted). Returns the new state.
  Future<VolumeState> setVolume(double volume) async {
    return _applyVolume(await request(typeSetVolume, {"volume": volume.isNaN ? 0.0 : volume.clamp(0.0, maxVolume)}));
  }

  /// Highest volume [setVolume] sends (150 %).
  static const double maxVolume = 1.5;

  /// The cover of [player]'s current track as JPEG bytes, or null when it has none, the desktop cannot send covers, or
  /// fetching it failed. Cached per `artUrl`, and one request at a time per cover.
  Future<Uint8List?> art(MediaPlayer player) {
    final url = player.artUrl;
    if (url == null || !isAvailable || !hasCap(capArt)) return Future.value(null);
    if (_art.containsKey(url)) {
      final bytes = _art.remove(url);
      _art[url] = bytes;
      return Future.value(bytes);
    }
    // A block body: `=> _artLoading.remove(url)` would hand whenComplete this very future to wait on, forever.
    return _artLoading[url] ??= _fetchArt(player.name, url).whenComplete(() {
      _artLoading.remove(url);
    });
  }

  Future<Uint8List?> _fetchArt(String player, String url) async {
    Uint8List? bytes;
    try {
      final reply = await requestMessage(typeArt, {"player": player, "maxSize": artSize});
      // The track may have changed while the desktop fetched; a cover for another URL is not this one.
      if (reply.body["artUrl"] == url && reply.data != null && reply.data!.isNotEmpty) bytes = reply.data;
    } on LinkException catch (error) {
      debugPrint("ionix-link: no cover for $url: ${error.message}");
    }
    if (!isAvailable) return bytes;
    _art[url] = bytes;
    while (_art.length > _artCacheSize) {
      _art.remove(_art.keys.first);
    }
    return bytes;
  }

  /// Mute or unmute. Returns the new state.
  Future<VolumeState> setMuted(bool muted) async {
    return _applyVolume(await request(typeSetVolume, {"muted": muted}));
  }

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    // The desktop pushes both right after ready, so there is nothing to ask for here.
    listen(typePlayers, (message) => _applyPlayers(message.body));
    listen(typeVolume, (message) => _applyVolume(message.body));
  }

  @override
  void onDetach() {
    _players.value = const [];
    _activePlayer.value = null;
    _volume.value = null;
    // Covers that failed may work on the next connection; the ones that arrived stay.
    _art.removeWhere((_, bytes) => bytes == null);
  }

  void _applyPlayers(Map<String, dynamic> body) {
    if (!isAvailable) return;
    _players.value = List.unmodifiable(JsonRead.objects(body, "players", MediaPlayer.fromJson));
    _activePlayer.value = JsonRead.optString(body, "active");
  }

  VolumeState _applyVolume(Map<String, dynamic> body) {
    final volume = VolumeState.fromJson(body);
    if (isAvailable) _volume.value = volume;
    return volume;
  }
}

/// `media.control` actions; [wire] is the value sent.
enum MediaAction {
  play("play"),
  pause("pause"),
  playPause("playPause"),
  next("next"),
  previous("previous"),
  stop("stop");

  const MediaAction(this.wire);

  final String wire;
}

/// Player status.
enum MediaStatus {
  playing,
  paused,
  stopped;

  /// Parse the wire value; unknown → [stopped].
  static MediaStatus fromWire(String? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return stopped;
  }
}

/// The `Player` object of `PROTOCOL.md` 8.2.
class MediaPlayer {
  MediaPlayer({
    required this.name,
    required this.identity,
    required this.status,
    required this.title,
    required this.artist,
    required this.album,
    this.length,
    this.position,
    required this.positionTime,
    required this.canSeek,
    required this.canNext,
    required this.canPrevious,
    required this.canPlay,
    required this.canPause,
    this.artUrl,
  });

  /// playerctl instance name; the handle for commands.
  final String name;

  /// Display name.
  final String identity;

  final MediaStatus status;
  final String title;
  final String artist;
  final String album;

  /// Track length, null when unknown.
  final Duration? length;

  /// Position when sampled, null when unknown.
  final Duration? position;

  /// When [position] was sampled.
  final DateTime positionTime;

  final bool canSeek;
  final bool canNext;
  final bool canPrevious;
  final bool canPlay;
  final bool canPause;

  /// `mpris:artUrl` as given. The phone never fetches it itself: [MediaClient.art] asks the desktop.
  final String? artUrl;

  /// Position extrapolated to [now] while playing, capped at [length]; [position] otherwise.
  Duration? positionAt(DateTime now) {
    final sampled = position;
    if (sampled == null || status != MediaStatus.playing) return sampled;
    final elapsed = now.difference(positionTime);
    var extrapolated = sampled + (elapsed.isNegative ? Duration.zero : elapsed);
    final total = length;
    if (total != null && extrapolated > total) extrapolated = total;
    return extrapolated;
  }

  /// Throws [LinkFormatException] on a missing `name`.
  static MediaPlayer fromJson(Map<String, dynamic> json) {
    final name = JsonRead.string(json, "name");
    final identity = JsonRead.optString(json, "identity");
    final length = JsonRead.optInt(json, "length");
    final position = JsonRead.optInt(json, "position");
    final positionTime = JsonRead.optInt(json, "positionTime");
    final artUrl = JsonRead.optString(json, "artUrl");
    return MediaPlayer(
      name: name,
      identity: identity == null || identity.isEmpty ? name : identity,
      status: MediaStatus.fromWire(JsonRead.optString(json, "status")),
      title: JsonRead.optString(json, "title") ?? "",
      artist: JsonRead.optString(json, "artist") ?? "",
      album: JsonRead.optString(json, "album") ?? "",
      length: length == null || length <= 0 ? null : Duration(milliseconds: length),
      position: position == null ? null : Duration(milliseconds: position < 0 ? 0 : position),
      positionTime: positionTime == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(positionTime),
      canSeek: JsonRead.optBool(json, "canSeek") ?? false,
      canNext: JsonRead.optBool(json, "canNext") ?? false,
      canPrevious: JsonRead.optBool(json, "canPrevious") ?? false,
      canPlay: JsonRead.optBool(json, "canPlay") ?? false,
      canPause: JsonRead.optBool(json, "canPause") ?? false,
      artUrl: artUrl == null || artUrl.isEmpty ? null : artUrl,
    );
  }
}

/// The `Volume` object of `PROTOCOL.md` 8.2.
class VolumeState {
  const VolumeState({required this.volume, required this.muted});

  /// 0.0 = silent, 1.0 = 100 %.
  final double volume;

  final bool muted;

  /// Throws [LinkFormatException] on a missing `volume`.
  static VolumeState fromJson(Map<String, dynamic> json) {
    return VolumeState(volume: JsonRead.number(json, "volume"), muted: JsonRead.optBool(json, "muted") ?? false);
  }
}
