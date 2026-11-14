import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "../protocol/json_read.dart";
import "plugin_client.dart";

/// `commands.*`: run a desktop command by id (`PROTOCOL.md` 8.3). The phone can never send a shell string.
class CommandsClient extends PluginClient {
  // Message types
  static const String typeList = "commands.list";
  static const String typeRun = "commands.run";
  static const String typeChanged = "commands.changed";

  @override
  String get name => LinkPlugins.commands;

  final ValueNotifier<List<LinkCommand>> _commands = ValueNotifier(const []);

  /// The desktop's commands, fetched on attach and on `commands.changed`. Empty while detached.
  ValueListenable<List<LinkCommand>> get commands => _commands;

  /// Re-fetch [commands].
  Future<List<LinkCommand>> refresh() async {
    final body = await request(typeList);
    final commands = List<LinkCommand>.unmodifiable(JsonRead.objects(body, "commands", LinkCommand.fromJson));
    if (isAvailable) _commands.value = commands;
    return commands;
  }

  /// Run command [id]. The UI asks first when [LinkCommand.confirm] is set; this method never asks.
  /// @throws LinkRemoteException with `not_found` for an unknown id.
  Future<CommandResult> run(String id) async {
    return CommandResult.fromJson(await request(typeRun, {"id": id}, LinkProtocol.commandRunTimeout));
  }

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    listen(typeChanged, (_) => runQuietly(refresh(), "refresh"));
    runQuietly(refresh(), "list");
  }

  @override
  void onDetach() {
    _commands.value = const [];
  }
}

/// The `Command` object of `PROTOCOL.md` 8.3.
class LinkCommand {
  LinkCommand({required this.id, required this.title, required this.icon, required this.confirm, this.group});

  /// Icon names the desktop may send; the UI maps each to a Material icon and anything else to `terminal`.
  static const List<String> knownIcons = [
    "lock", "bedtime", "logout", "restart", "power", "terminal", "play", "screen",
    "volume", "wifi", "bolt", "star", "apps", "code", "folder",
  ];

  final String id;
  final String title;

  /// One of [knownIcons], or something the UI does not know.
  final String icon;

  /// Ask before running.
  final bool confirm;

  /// Section heading; null = "Commands".
  final String? group;

  /// Throws [LinkFormatException] on a missing `id`.
  static LinkCommand fromJson(Map<String, dynamic> json) {
    final id = JsonRead.string(json, "id");
    if (id.isEmpty) throw LinkFormatException("A command needs an id.");
    final title = JsonRead.optString(json, "title");
    final group = JsonRead.optString(json, "group");
    return LinkCommand(
      id: id,
      title: title == null || title.isEmpty ? id : title,
      icon: JsonRead.optString(json, "icon") ?? "terminal",
      confirm: JsonRead.optBool(json, "confirm") ?? false,
      group: group == null || group.isEmpty ? null : group,
    );
  }
}

/// The reply of `commands.run`.
class CommandResult {
  const CommandResult({required this.ok, this.exitCode, required this.detached, this.output});

  /// Exit status 0, or still running.
  final bool ok;

  /// Exit status; null while still running.
  final int? exitCode;

  /// Still running after its timeout and left running.
  final bool detached;

  /// Tail of the output, only for commands that share it.
  final String? output;

  static CommandResult fromJson(Map<String, dynamic> json) {
    return CommandResult(
      ok: JsonRead.optBool(json, "ok") ?? false,
      exitCode: JsonRead.optInt(json, "exitCode"),
      detached: JsonRead.optBool(json, "detached") ?? false,
      output: JsonRead.optString(json, "output"),
    );
  }
}
