import "dart:typed_data";

import "constants.dart";
import "errors.dart";

/// One protocol message: `{ type, id?, re?, body }`, plus the raw data of a binary (kind 1) frame.
class LinkMessage {
  /// Create a message. Throws [LinkFormatException] if [type] is empty or [id]/[re] are out of range.
  LinkMessage(this.type, {this.id, this.re, Map<String, dynamic>? body, this.data})
    : body = body ?? const {} {
    if (type.isEmpty) throw LinkFormatException("A message needs a type.");
    if (id != null && (id! < 1 || id! > LinkProtocol.maxId)) {
      throw LinkFormatException("Message id $id is outside 1..${LinkProtocol.maxId}.");
    }
    if (re != null && (re! < 1 || re! > LinkProtocol.maxId)) {
      throw LinkFormatException("Message re $re is outside 1..${LinkProtocol.maxId}.");
    }
    if (id != null && re != null) throw LinkFormatException("A message cannot be both a request and a reply.");
  }

  /// `<plugin>.<verb>` or a core type from [LinkTypes].
  final String type;

  /// Set on a request; the sender expects exactly one reply.
  final int? id;

  /// Set on a reply: the `id` it answers.
  final int? re;

  /// The message body. Never null; `{}` when empty.
  final Map<String, dynamic> body;

  /// Raw data when the message travelled in a binary frame, else null.
  final Uint8List? data;

  /// Whether this is a request (has an [id]).
  bool get isRequest => id != null;

  /// Whether this is a reply (has a [re]).
  bool get isReply => re != null;

  /// Whether this is a push (neither [id] nor [re]).
  bool get isPush => id == null && re == null;

  /// Whether this is an `error` message.
  bool get isError => type == "error";

  /// The message object as sent on the wire (without [data]).
  Map<String, dynamic> toJson() {
    return {
      "type": type,
      if (id != null) "id": id,
      if (re != null) "re": re,
      "body": body,
    };
  }

  /// Parse a message object. Throws [LinkProtocolException] (`bad_message`) on a missing `type` or wrong field types.
  static LinkMessage fromJson(Map<String, dynamic> json, {Uint8List? data}) {
    final type = json["type"];
    final id = json["id"];
    final re = json["re"];
    final body = json["body"];
    if (type is! String || type.isEmpty) throw LinkProtocolException("A message arrived without a type.");
    if (id != null && id is! int) throw LinkProtocolException("The id of a $type message is not an integer.");
    if (re != null && re is! int) throw LinkProtocolException("The re of a $type message is not an integer.");
    if (body != null && body is! Map<String, dynamic>) {
      throw LinkProtocolException("The body of a $type message is not an object.");
    }
    try {
      return LinkMessage(type, id: id as int?, re: re as int?, body: body as Map<String, dynamic>?, data: data);
    } on LinkFormatException catch (error) {
      throw LinkProtocolException(error.message);
    }
  }

  @override
  String toString() => "LinkMessage($type, id: $id, re: $re)";
}
