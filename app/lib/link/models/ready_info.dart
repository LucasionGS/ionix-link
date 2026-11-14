import "../protocol/json_read.dart";
import "plugin_info.dart";

/// The body of `ready`: what the desktop agreed to on this connection.
class ReadyInfo {
  ReadyInfo({
    required this.protocol,
    required this.hostId,
    required this.hostName,
    required this.daemonVersion,
    required this.plugins,
  });

  /// Protocol version chosen for the connection.
  final int protocol;

  /// Host id, hex32.
  final String hostId;

  /// Host name.
  final String hostName;

  /// The daemon's version string.
  final String daemonVersion;

  /// Negotiated plugins, with the **daemon's** caps.
  final List<PluginInfo> plugins;

  /// The negotiated descriptor of [name], or null if not negotiated.
  PluginInfo? plugin(String name) {
    for (final info in plugins) {
      if (info.name == name) return info;
    }
    return null;
  }

  /// Throws [LinkFormatException] on a missing or mistyped field.
  static ReadyInfo fromJson(Map<String, dynamic> json) {
    return ReadyInfo(
      protocol: JsonRead.integer(json, "protocol"),
      hostId: JsonRead.string(json, "hostId").toLowerCase(),
      hostName: JsonRead.string(json, "hostName"),
      daemonVersion: JsonRead.optString(json, "daemonVersion") ?? "",
      plugins: List.unmodifiable(JsonRead.objects(json, "plugins", PluginInfo.fromJson)),
    );
  }
}
