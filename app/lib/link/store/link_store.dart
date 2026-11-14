import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:path_provider/path_provider.dart";

import "../models/device_identity.dart";
import "../models/link_theme.dart";
import "../models/paired_host.dart";
import "../protocol/errors.dart";
import "../protocol/link_crypto.dart";

/// Persistent link state. Keys go to `flutter_secure_storage` (Android Keystore), one entry per host named
/// `ionix-link.key.<hostId>`; everything else goes to `link.json` in the app support directory (`path_provider`):
///
/// ```json
/// { "version": 1, "deviceId": "<hex32>", "deviceName": "Pixel 8"?, "currentHost": "<hostId>"?, "hosts": [PairedHost],
///   "themes": { "<hostId>": Theme }, "wallpapers": { "<hostId>": "<hash>" } }
/// ```
///
/// A fetched wallpaper is kept next to it as `wallpaper-<hostId>.jpg`. Writes are atomic (temp file + rename) and run
/// one at a time. Only [Link] and [LinkPairing]/[LinkSession] write to it.
class LinkStore {
  LinkStore._(this.directory, this._keys, this._data);

  /// Current `link.json` format.
  static const int fileVersion = 1;

  /// The directory holding `link.json` and the wallpaper files.
  final String directory;

  final LinkKeyStore _keys;
  final Map<String, dynamic> _data;
  final ValueNotifier<List<PairedHost>> _hosts = ValueNotifier(const []);
  Future<void> _writing = Future.value();

  /// Open the store, creating `link.json` and a device id on first run.
  /// @param directory Overrides the app support directory (tests, the Linux build).
  /// @param keys Overrides where device keys are kept (default [SecureKeyStore]); tests pass a [MemoryKeyStore].
  static Future<LinkStore> open({String? directory, LinkKeyStore? keys}) async {
    final String path;
    try {
      path = directory ?? (await getApplicationSupportDirectory()).path;
      await Directory(path).create(recursive: true);
    } catch (error) {
      throw LinkException("Could not open the app's storage directory: $error");
    }
    final file = File("$path/link.json");
    Map<String, dynamic> data = {};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) throw const FormatException("not an object");
        data = decoded;
      } catch (error) {
        // A damaged file is kept for inspection; the phone then starts over and must pair again.
        final aside = "${file.path}.damaged-${DateTime.now().millisecondsSinceEpoch}";
        debugPrint("ionix-link: link.json is unreadable ($error), moved to $aside");
        await file.rename(aside).catchError((_) => file);
        data = {};
      }
    }
    final store = LinkStore._(path, keys ?? SecureKeyStore(), data);
    store._load();
    if (data["deviceId"] is! String || !LinkCrypto.isHex(data["deviceId"] as String, 16)) {
      data["deviceId"] = LinkCrypto.randomId();
      data["version"] = fileVersion;
      await store._save();
    }
    return store;
  }

  void _load() {
    final hosts = <PairedHost>[];
    final entries = _data["hosts"];
    if (entries is List) {
      for (final entry in entries) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          hosts.add(PairedHost.fromJson(entry));
        } on LinkException catch (error) {
          debugPrint("ionix-link: skipping a stored host: ${error.message}");
        }
      }
    }
    _hosts.value = List.unmodifiable(hosts);
    if (_data["themes"] is! Map<String, dynamic>) _data["themes"] = <String, dynamic>{};
    if (_data["wallpapers"] is! Map<String, dynamic>) _data["wallpapers"] = <String, dynamic>{};
  }

  /// This install's device id, hex32. Made once by [open] with [LinkCrypto.randomId].
  String get deviceId => _data["deviceId"] as String;

  /// The phone name the user chose in settings, or null to use the platform's.
  String? get deviceName {
    final name = _data["deviceName"];
    return name is String && name.trim().isNotEmpty ? name : null;
  }

  /// Set or clear (null) the chosen phone name.
  Future<void> setDeviceName(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      _data.remove("deviceName");
    }
    else {
      _data["deviceName"] = trimmed;
    }
    return _save();
  }

  /// Build the identity sent to desktops from [deviceId], the chosen name (else [platformName]) and [model].
  DeviceIdentity identity({required String platformName, required String model}) {
    var name = deviceName ?? platformName.trim();
    if (name.isEmpty) name = model.trim();
    if (name.isEmpty) name = "Phone";
    return DeviceIdentity(id: deviceId, name: name, model: model);
  }

  /// Paired hosts, in pairing order. Updates on every change.
  ValueListenable<List<PairedHost>> get hosts => _hosts;

  /// The host with [hostId], or null.
  PairedHost? host(String hostId) {
    final id = hostId.toLowerCase();
    for (final host in _hosts.value) {
      if (host.id == id) return host;
    }
    return null;
  }

  /// Id of the host the app connects to, or null.
  String? get currentHostId {
    final id = _data["currentHost"];
    return id is String && host(id) != null ? id : null;
  }

  /// Set or clear the current host.
  Future<void> setCurrentHostId(String? hostId) {
    if (hostId == null) {
      _data.remove("currentHost");
    }
    else {
      if (host(hostId) == null) throw LinkException("This desktop is not paired.");
      _data["currentHost"] = hostId.toLowerCase();
    }
    return _save();
  }

  /// Add or replace a host and its key (after pairing).
  Future<void> saveHost(PairedHost host, {required String key}) async {
    if (!LinkCrypto.isHex(key, 32)) throw LinkFormatException("The desktop sent a malformed device key.");
    await _keys.write(_keyName(host.id), key.toLowerCase());
    _replaceHost(host, add: true);
    await _save();
  }

  /// Replace a host's stored fields (addresses, lastAddress, lastSeen, name); the key is untouched.
  Future<void> updateHost(PairedHost host) {
    if (!_replaceHost(host, add: false)) return Future.value();
    return _save();
  }

  /// The device key for [hostId], hex64, or null if missing (treat as forgotten).
  Future<String?> keyFor(String hostId) async {
    final key = await _keys.read(_keyName(hostId));
    return key != null && LinkCrypto.isHex(key, 32) ? key.toLowerCase() : null;
  }

  /// Delete a host and its key. Clears [currentHostId] if it was that host.
  Future<void> removeHost(String hostId) async {
    final id = hostId.toLowerCase();
    await _keys.delete(_keyName(id));
    _hosts.value = List.unmodifiable(_hosts.value.where((host) => host.id != id));
    if (_data["currentHost"] == id) _data.remove("currentHost");
    _themes.remove(id);
    _wallpapers.remove(id);
    await _save();
    await _deleteQuietly(_wallpaperFile(id));
  }

  //#region Theme

  Map<String, dynamic> get _themes => _data["themes"] as Map<String, dynamic>;
  Map<String, dynamic> get _wallpapers => _data["wallpapers"] as Map<String, dynamic>;

  /// The last theme [hostId] sent, or null if it never sent one.
  LinkTheme? themeFor(String hostId) {
    final json = _themes[hostId.toLowerCase()];
    return json is Map<String, dynamic> ? LinkTheme.fromJson(json) : null;
  }

  /// Remember [theme] as the last one [hostId] sent. Does nothing for a host that is not paired.
  Future<void> saveTheme(String hostId, LinkTheme theme) {
    final id = hostId.toLowerCase();
    if (host(id) == null) return Future.value();
    _themes[id] = theme.toJson();
    return _save();
  }

  /// The wallpaper hash of the picture stored for [hostId], or null.
  String? wallpaperHashFor(String hostId) {
    final hash = _wallpapers[hostId.toLowerCase()];
    return hash is String ? hash : null;
  }

  /// The wallpaper JPEG stored for [hostId], or null.
  Future<Uint8List?> wallpaperFor(String hostId) async {
    if (wallpaperHashFor(hostId) == null) return null;
    try {
      return await _wallpaperFile(hostId.toLowerCase()).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// Store [bytes] as [hostId]'s wallpaper, identified by the desktop's [hash].
  Future<void> saveWallpaper(String hostId, Uint8List bytes, String hash) async {
    final id = hostId.toLowerCase();
    if (host(id) == null) return;
    final file = _wallpaperFile(id);
    final temp = File("${file.path}.tmp");
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      throw LinkException("Could not save the wallpaper: ${error.message}.");
    }
    _wallpapers[id] = hash;
    await _save();
  }

  File _wallpaperFile(String hostId) => File("$directory/wallpaper-$hostId.jpg");

  //#endregion

  static String _keyName(String hostId) => "ionix-link.key.${hostId.toLowerCase()}";

  /// Put [host] in place of the stored one with the same id, or append it when [add]. Returns whether it changed.
  bool _replaceHost(PairedHost host, {required bool add}) {
    final hosts = [..._hosts.value];
    final index = hosts.indexWhere((stored) => stored.id == host.id);
    if (index >= 0) {
      hosts[index] = host;
    }
    else if (add) {
      hosts.add(host);
    }
    else {
      return false;
    }
    _hosts.value = List.unmodifiable(hosts);
    return true;
  }

  /// Write `link.json` after any write already running, atomically.
  Future<void> _save() {
    _data["version"] = fileVersion;
    _data["hosts"] = [for (final host in _hosts.value) host.toJson()];
    final contents = const JsonEncoder.withIndent("  ").convert(_data);
    final next = _writing.then((_) async {
      final file = File("$directory/link.json");
      final temp = File("${file.path}.tmp");
      try {
        await temp.writeAsString(contents, flush: true);
        await temp.rename(file.path);
      } on FileSystemException catch (error) {
        throw LinkException("Could not save the app's settings: ${error.message}.");
      }
    });
    // A failed write must not block the ones after it; the caller still sees this one fail.
    _writing = next.catchError((_) {});
    return next;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      return;
    }
  }
}

/// Where [LinkStore] keeps device keys.
abstract class LinkKeyStore {
  /// The value stored under [name], or null.
  Future<String?> read(String name);

  /// Store [value] under [name], replacing any earlier one.
  Future<void> write(String name, String value);

  /// Delete [name]; no error when missing.
  Future<void> delete(String name);
}

/// Keys in `flutter_secure_storage`: the Android Keystore, libsecret on Linux.
class SecureKeyStore implements LinkKeyStore {
  SecureKeyStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String name) => _guard("read", () => _storage.read(key: name));

  @override
  Future<void> write(String name, String value) => _guard("save", () => _storage.write(key: name, value: value));

  @override
  Future<void> delete(String name) => _guard("delete", () => _storage.delete(key: name));

  static Future<T> _guard<T>(String verb, Future<T> Function() action) async {
    try {
      return await action();
    } catch (error) {
      throw LinkException("Could not $verb a device key in secure storage: $error");
    }
  }
}

/// Keys in memory only, for tests and scratch runs.
class MemoryKeyStore implements LinkKeyStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String name) async => _values[name];

  @override
  Future<void> write(String name, String value) async => _values[name] = value;

  @override
  Future<void> delete(String name) async => _values.remove(name);
}
