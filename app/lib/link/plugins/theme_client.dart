
import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/link_theme.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/link_crypto.dart";
import "../store/link_store.dart";
import "plugin_client.dart";

/// `theme.*`: the desktop's active theme and wallpaper (`PROTOCOL.md` 8.8).
///
/// Unlike the other clients this one has a value before any connection: [theme] starts at the theme the current host
/// sent last (kept by [LinkStore]), else [LinkTheme.ionix], so the app wears the desktop's colours while offline and
/// with nothing paired. [Link] points it at the current host with [useHost].
class ThemeClient extends PluginClient {
  // Message types
  static const String typeChanged = "theme.changed";
  static const String typeGet = "theme.get";
  static const String typeWallpaper = "theme.wallpaper";

  /// Daemon cap: it can send its wallpaper.
  static const String capWallpaper = "wallpaper";

  /// Smallest and largest `maxSize` the desktop accepts for [fetchWallpaper], px.
  static const int minWallpaperSize = 256;
  static const int maxWallpaperSize = 2048;

  @override
  String get name => LinkPlugins.theme;

  final ValueNotifier<LinkTheme> _theme = ValueNotifier(LinkTheme.ionix);
  final ValueNotifier<Uint8List?> _wallpaper = ValueNotifier(null);
  LinkStore? _store;
  String? _hostId;
  String? _fetchingHash;

  /// The theme to wear. Never null: [LinkTheme.ionix] until a desktop has sent one.
  ValueListenable<LinkTheme> get theme => _theme;

  /// The desktop's wallpaper as JPEG bytes (cached, so also offline), or null when none was ever fetched.
  ValueListenable<Uint8List?> get wallpaper => _wallpaper;

  /// Show the stored theme and wallpaper of [hostId] (null: no current host, so [LinkTheme.ionix] and no wallpaper),
  /// and persist later changes for it. Called by [Link] at startup and on every host change.
  Future<void> useHost(LinkStore store, String? hostId) async {
    _store = store;
    _hostId = hostId?.toLowerCase();
    _theme.value = hostId == null ? LinkTheme.ionix : (store.themeFor(hostId) ?? LinkTheme.ionix);
    final bytes = hostId == null ? null : await store.wallpaperFor(hostId);
    if (_hostId == hostId?.toLowerCase()) _wallpaper.value = bytes;
  }

  /// Ask the desktop for its theme again.
  Future<LinkTheme> refresh() async => _apply(LinkTheme.fromJson(await request(typeGet)));

  /// Fetch the desktop's wallpaper, scaled to [maxSize] px on its longest edge (clamped to 256..2048), store it and
  /// publish it on [wallpaper]. Returns null when the desktop lacks [capWallpaper]. Called by itself whenever the
  /// theme's wallpaper hash changes.
  Future<Uint8List?> fetchWallpaper({int maxSize = 1080}) async {
    if (!isAvailable || !hasCap(capWallpaper)) return null;
    final reply = await requestMessage(typeWallpaper, {"maxSize": maxSize.clamp(minWallpaperSize, maxWallpaperSize)});
    final data = reply.data;
    if (data == null || data.isEmpty) throw LinkProtocolException("The desktop's wallpaper reply carried no image.");
    final hash = reply.body["wallpaper"];
    _wallpaper.value = data;
    final store = _store;
    final hostId = _hostId;
    if (store != null && hostId != null) {
      try {
        await store.saveWallpaper(hostId, data, hash is String && hash.isNotEmpty ? hash : LinkCrypto.toHex(LinkCrypto.sha256(data)));
      } on LinkException catch (error) {
        debugPrint("ionix-link: wallpaper not cached: ${error.message}");
      }
    }
    return data;
  }

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    final readyHost = connection.ready?.hostId;
    if (readyHost != null) _hostId = readyHost;
    listen(typeChanged, (message) => _apply(LinkTheme.fromJson(message.body)));
  }

  /// The theme stays as it was: it is what the app wears offline.
  @override
  void onDetach() {
    _fetchingHash = null;
  }

  LinkTheme _apply(LinkTheme theme) {
    final store = _store;
    final hostId = _hostId;
    if (theme != _theme.value) {
      _theme.value = theme;
      if (store != null && hostId != null) runQuietly(store.saveTheme(hostId, theme), "theme save");
    }
    final hash = theme.wallpaper;
    if (hash != null && hasCap(capWallpaper) && hash != _fetchingHash && (hostId == null || store?.wallpaperHashFor(hostId) != hash)) {
      _fetchingHash = hash;
      runQuietly(fetchWallpaper().whenComplete(() {
        if (_fetchingHash == hash) _fetchingHash = null;
      }), "wallpaper fetch");
    }
    return theme;
  }
}
