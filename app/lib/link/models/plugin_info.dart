import "../protocol/errors.dart";
import "../protocol/json_read.dart";

/// One entry of `hello.plugins` / `ready.plugins`: `{ name, version, caps }`.
class PluginInfo {
  /// Create a plugin descriptor. Throws [LinkFormatException] if [name] is empty or [version] < 1.
  PluginInfo({required this.name, required this.version, List<String> caps = const []}) : caps = List.unmodifiable(caps) {
    if (name.isEmpty) throw LinkFormatException("A plugin needs a name.");
    if (version < 1) throw LinkFormatException("Plugin $name has version $version; versions start at 1.");
  }

  /// Plugin name, one of [LinkPlugins].
  final String name;

  /// Plugin version.
  final int version;

  /// Capabilities the side that sent this descriptor supports.
  final List<String> caps;

  /// Whether [cap] is in [caps].
  bool has(String cap) => caps.contains(cap);

  Map<String, dynamic> toJson() => {"name": name, "version": version, "caps": caps};

  static PluginInfo fromJson(Map<String, dynamic> json) {
    return PluginInfo(
      name: JsonRead.string(json, "name"),
      version: JsonRead.integer(json, "version"),
      caps: [
        for (final cap in JsonRead.optList(json, "caps") ?? const [])
          if (cap is String) cap,
      ],
    );
  }

  @override
  String toString() => "PluginInfo($name v$version ${caps.join(",")})";
}
