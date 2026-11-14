import "dart:async";
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/constants.dart";
import "../protocol/errors.dart";
import "plugin_client.dart";

/// What the desktop did with shared text.
enum ShareAction {
  /// It was a lone link and is now open in the desktop's browser.
  opened,

  /// It is on the desktop's clipboard.
  copied,
}

/// How far a file upload is.
class ShareProgress {
  const ShareProgress({required this.sent, required this.total});

  /// Bytes the desktop has confirmed.
  final int sent;

  /// Size of the file.
  final int total;

  /// 0..1, 1 for an empty file.
  double get fraction => total <= 0 ? 1 : (sent / total).clamp(0.0, 1.0);
}

/// Where the desktop saved a file.
class ShareReceipt {
  const ShareReceipt({required this.path, required this.name});

  /// Full path on the desktop.
  final String path;

  /// Final file name there (it differs from the one sent when the name was taken or unsafe).
  final String name;
}

/// The upload was cancelled on this side.
class ShareCancelledException extends LinkException {
  ShareCancelledException() : super("Cancelled.");
}

/// One file on its way to the desktop. [done] completes with where it landed, or with a [LinkException].
class ShareUpload {
  ShareUpload._(this._client, this.path, this.name, this.size, this.mime, String? sha256) : _sha256 = sha256 {
    // A failure nobody awaits (the sheet was closed) must not surface as an unhandled error.
    _done.future.then((_) {}, onError: (Object _) {});
    unawaited(_run());
  }

  final ShareClient _client;

  /// Local file being sent.
  final String path;

  /// Name offered to the desktop.
  final String name;

  /// Bytes in the file.
  final int size;
  final String? mime;
  String? _sha256;
  bool _cancelled = false;
  String? _transfer;
  final ValueNotifier<ShareProgress> _progress = ValueNotifier(const ShareProgress(sent: 0, total: 0));
  final Completer<ShareReceipt> _done = Completer();

  /// Progress, from 0 bytes up to [size].
  ValueListenable<ShareProgress> get progress => _progress;

  /// Completes when the desktop has verified and saved the file.
  Future<ShareReceipt> get done => _done.future;

  /// Stop sending. The desktop deletes what it has; [done] fails with [ShareCancelledException].
  void cancel() {
    if (_cancelled || _done.isCompleted) return;
    _cancelled = true;
  }

  Future<void> _run() async {
    _progress.value = ShareProgress(sent: 0, total: size);
    RandomAccessFile? file;
    try {
      _sha256 ??= (await sha256.bind(File(path).openRead()).first).toString();
      if (_cancelled) throw ShareCancelledException();
      final begin = await _client._call(ShareClient.typeBegin, {"name": name, "size": size, if (mime != null) "mime": mime}, const Duration(seconds: 30));
      final transfer = begin["transfer"];
      if (transfer is! String) throw LinkProtocolException("The desktop accepted $name without a transfer id.");
      _transfer = transfer;
      file = await File(path).open();
      var offset = 0;
      while (offset < size) {
        if (_cancelled) throw ShareCancelledException();
        final chunk = await file.read(size - offset < ShareClient.chunkSize ? size - offset : ShareClient.chunkSize);
        if (chunk.isEmpty) throw LinkException("$name changed while it was being sent.");
        final reply = await _client._call(ShareClient.typeChunk, {"transfer": transfer, "offset": offset}, const Duration(seconds: 30), chunk);
        offset += chunk.length;
        final received = reply["received"];
        _progress.value = ShareProgress(sent: received is int ? received : offset, total: size);
      }
      if (_cancelled) throw ShareCancelledException();
      final end = await _client._call(ShareClient.typeEnd, {"transfer": transfer, "sha256": _sha256}, const Duration(seconds: 60));
      _progress.value = ShareProgress(sent: size, total: size);
      _done.complete(ShareReceipt(path: end["path"] is String ? end["path"] as String : "", name: end["name"] is String ? end["name"] as String : name));
    } on Object catch (error) {
      if (_transfer != null) _client._abandon(_transfer!);
      _done.completeError(error is LinkException ? error : LinkException("Sending $name failed: $error"));
    } finally {
      await file?.close();
    }
  }
}

/// `share.*`: send text, links and files from this phone to the desktop (`PROTOCOL.md` 8.9). Receiving the share
/// intent from Android is the platform layer's job; this client only speaks to the desktop.
class ShareClient extends PluginClient {
  // Message types
  static const String typeText = "share.text";
  static const String typeBegin = "share.begin";
  static const String typeChunk = "share.chunk";
  static const String typeEnd = "share.end";
  static const String typeCancel = "share.cancel";

  /// Bytes of file data in one `share.chunk` (the protocol allows 1 MiB).
  static const int chunkSize = 512 * 1024;

  @override
  String get name => LinkPlugins.share;

  /// Whether the desktop can take shared text.
  bool get canText => hasCap("text");

  /// Whether the desktop can take shared files.
  bool get canFiles => hasCap("files");

  /// Send [text] (and the app's [subject], if it gave one). A lone web link is opened on the desktop, anything else
  /// lands on its clipboard.
  /// @throws LinkFormatException if [text] is over 512 KiB as UTF-8.
  Future<ShareAction> sendText(String text, {String? subject}) async {
    if (utf8.encode(text).length > LinkProtocol.maxText) {
      throw LinkFormatException("The text is too long to share; the limit is 512 KiB.");
    }
    final body = await request(typeText, {"text": text, if (subject != null && subject.isNotEmpty) "subject": subject});
    return body["action"] == "opened" ? ShareAction.opened : ShareAction.copied;
  }

  /// Start sending the file at [path] as [name]. [sha256] is the file's hex digest when the platform already computed it
  /// (it is worked out here otherwise). One file per connection at a time: wait for [ShareUpload.done] before the next.
  ShareUpload sendFile({required String path, required String name, required int size, String? mime, String? sha256}) {
    return ShareUpload._(this, path, name, size, mime, sha256);
  }

  // The uploads are separate objects in this library, so they cannot call the protected request().
  Future<Map<String, dynamic>> _call(String type, Map<String, dynamic> body, Duration timeout, [Uint8List? data]) => request(type, body, timeout, data);

  void _abandon(String transfer) {
    if (!isAvailable) return;
    runQuietly(request(typeCancel, {"transfer": transfer}), "cancel");
  }

  @override
  void onAttach(LinkConnection connection, PluginInfo info) { }

  @override
  void onDetach() { }
}
