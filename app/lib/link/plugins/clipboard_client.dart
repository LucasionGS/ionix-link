import "dart:async";
import "dart:convert";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "plugin_client.dart";

/// `clipboard.*`: manual clipboard exchange (`PROTOCOL.md` 8.4). The link layer never touches the phone's clipboard
/// itself; the platform glue writes [received] texts to it.
class ClipboardClient extends PluginClient {
  // Message types
  static const String typePush = "clipboard.push";
  static const String typePull = "clipboard.pull";

  @override
  String get name => LinkPlugins.clipboard;

  final StreamController<String> _received = StreamController.broadcast();

  /// Put [text] on the desktop's clipboard.
  /// @throws LinkFormatException if [text] exceeds [LinkProtocol.maxText] bytes as UTF-8.
  Future<void> push(String text) async {
    if (utf8.encode(text).length > LinkProtocol.maxText) {
      throw LinkFormatException("The text is too long to send; the limit is 512 KiB.");
    }
    final body = await request(typePush, {"text": text});
    if (body["ok"] != true) throw LinkException("The desktop could not set its clipboard.");
  }

  /// Read the desktop's clipboard (`""` if empty or not text).
  Future<String> pull() async {
    final text = (await request(typePull))["text"];
    return text is String ? text : "";
  }

  /// Texts the desktop pushed (`ionix-link send-clipboard`).
  Stream<String> get received => _received.stream;

  @override
  void onAttach(LinkConnection connection, PluginInfo info) {
    listen(typePush, (message) {
      final text = message.body["text"];
      if (text is String) _received.add(text);
    });
  }

  @override
  void onDetach() { }
}
