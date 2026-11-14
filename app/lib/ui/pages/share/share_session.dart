import "dart:async";

import "package:flutter/foundation.dart";

import "../../../link/link.dart";
import "../../../platform/link_platform.dart";
import "../../sources.dart";

/// Where a share is.
enum ShareStage {
  /// Showing what would be sent, and to which desktop; nothing goes out until [ShareSession.send]. Any app can hand
  /// this one a share, so the tap on Send is the user's consent.
  confirm,

  /// Waiting for the connection to the desktop.
  waiting,

  /// Nothing is paired, so there is nowhere to send to.
  noHost,

  /// The desktop is there but cannot take this (old daemon, no writable download folder).
  unsupported,

  /// Text or files are on their way.
  sending,

  /// Everything arrived.
  done,

  /// Something did not arrive; [ShareSession.retry] tries the rest again.
  failed,

  /// The user stopped it.
  cancelled,
}

/// Where one file of a share is.
enum ShareItemStatus { queued, preparing, sending, done, failed, cancelled }

/// One shared file and how far it has got.
class ShareItem {
  ShareItem(this.file);

  final SharedFile file;
  ShareItemStatus status = ShareItemStatus.queued;
  String? error;
  StagedFile? staged;
  ShareUpload? upload;
  ShareReceipt? receipt;

  /// Real size once copied, else what the sharing app said (-1 when it did not).
  int get size => staged?.size ?? file.size;

  /// Bytes the desktop has confirmed so far (kept up to date by the session while the file is sending).
  int sentBytes = 0;

  /// Bytes the desktop confirmed.
  int get sent => status == ShareItemStatus.done ? size : sentBytes;

  /// 0..1 while sending, null when it cannot be told yet.
  double? get fraction {
    if (status == ShareItemStatus.done) return 1;
    if (status != ShareItemStatus.sending || size <= 0) return null;
    return (sentBytes / size).clamp(0.0, 1.0);
  }
}

/// Everything about sending one [IncomingShare] to the current desktop: waits for the user to confirm, then for the
/// connection, sends the text or the files one after the other, and tells the sheet what to show. Nothing here is
/// widget code.
class ShareSession extends ChangeNotifier {
  ShareSession(this.share, {ShareSource? source, this.connectTimeout = const Duration(seconds: 45)})
    : _source = source ?? UiSources.share,
      items = [for (final file in share.files) ShareItem(file)];

  /// A session frozen in [stage], for the headless preview of every sheet state; it never talks to the link.
  ShareSession.preview(this.share, {required ShareStage stage, String? message, ShareAction? textAction, this.items = const []})
    : _source = UiSources.share,
      connectTimeout = Duration.zero {
    _stage = stage;
    _message = message;
    _textAction = textAction;
  }

  final IncomingShare share;
  final ShareSource _source;

  /// How long to wait for the desktop to be reachable before giving up.
  final Duration connectTimeout;

  /// The files, in order. Empty for a text share.
  final List<ShareItem> items;

  ShareStage _stage = ShareStage.confirm;
  String? _message;
  ShareAction? _textAction;
  bool _cancelled = false;
  bool _disposed = false;
  Completer<void>? _wake;

  ShareStage get stage => _stage;

  /// A sentence for the sheet: why it failed, or what happened on the desktop.
  String? get message => _message;

  /// What the desktop did with shared text, once it has.
  ShareAction? get textAction => _textAction;

  bool get isText => share.files.isEmpty;

  /// Whether it is still going to do something, or waiting for the user to decide.
  bool get isActive => _stage == ShareStage.confirm || _stage == ShareStage.waiting || _stage == ShareStage.sending;

  /// The desktop's name, or "your desktop" before one is known.
  String get hostName {
    final status = _source.status.value;
    final hosts = _source.hosts.value;
    return status.host?.name ?? (hosts.isEmpty ? "your desktop" : hosts.first.name);
  }

  /// Bytes confirmed over bytes to send, across all files; null for text or while sizes are unknown.
  double? get fraction {
    var total = 0;
    var sent = 0;
    for (final item in items) {
      if (item.size < 0) return null;
      total += item.size;
      sent += item.sent;
    }
    return total == 0 ? null : sent / total;
  }

  /// Show the share for confirmation ([ShareStage.confirm]), or [ShareStage.noHost] when there is nowhere to send it.
  /// Only connects, so that [send] is quick; nothing of the share leaves the phone here.
  void start() {
    if (_source.hosts.value.isEmpty) {
      _finish(ShareStage.noHost, "No desktop is paired yet. Pair one, then share again.");
      return;
    }
    _setStage(ShareStage.confirm);
    if (!_source.status.value.isReady) _source.reconnect();
  }

  /// The user tapped Send. Completes when the share has finished, failed or been cancelled.
  Future<void> send() async {
    if (_stage != ShareStage.confirm) return;
    await _run();
  }

  Future<void> _run() async {
    _cancelled = false;
    if (_source.hosts.value.isEmpty) {
      _finish(ShareStage.noHost, "No desktop is paired yet. Pair one, then share again.");
      return;
    }
    _setStage(ShareStage.waiting);
    if (!await _waitUntilReady()) return;
    if (share.files.isEmpty) {
      await _sendText();
    }
    else {
      await _sendFiles();
    }
  }

  /// Send what has not arrived yet. The user asked for it again, so there is no second confirmation.
  Future<void> retry() {
    for (final item in items) {
      if (item.status == ShareItemStatus.failed || item.status == ShareItemStatus.cancelled) {
        item.status = ShareItemStatus.queued;
        item.error = null;
        item.upload = null;
      }
    }
    return _run();
  }

  /// Stop sending. The desktop deletes the part of a file it already has.
  void cancel() {
    if (!isActive) return;
    _cancelled = true;
    for (final item in items) {
      item.upload?.cancel();
      if (item.status == ShareItemStatus.queued || item.status == ShareItemStatus.preparing) item.status = ShareItemStatus.cancelled;
    }
    _wake?.complete();
    _finish(ShareStage.cancelled, "Cancelled.");
  }

  @override
  void dispose() {
    _disposed = true;
    if (isActive) cancel();
    _source.status.removeListener(_check);
    _source.plugin.removeListener(_check);
    unawaited(_source.clearStaged().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _setStage(ShareStage stage, [String? message]) {
    _stage = stage;
    _message = message;
    notifyListeners();
  }

  void _finish(ShareStage stage, String message) => _setStage(stage, message);

  void _check() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Waits for a ready connection with the share plugin negotiated. False when it gave up (the stage says why).
  Future<bool> _waitUntilReady() async {
    final deadline = DateTime.now().add(connectTimeout);
    _source.status.addListener(_check);
    _source.plugin.addListener(_check);
    try {
      if (!_source.status.value.isReady) _source.reconnect();
      while (!_cancelled) {
        final status = _source.status.value;
        if (status.state == LinkState.forgotten) {
          _finish(ShareStage.failed, "$hostName no longer knows this phone. Pair it again, then share again.");
          return false;
        }
        if (status.isReady && _source.plugin.value != null) return true;
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) {
          if (status.isReady) {
            _finish(ShareStage.unsupported, "$hostName cannot receive shares. Update Ionix Link on it.");
          }
          else {
            _finish(ShareStage.failed, "Could not reach $hostName. Is it on and on the same network?");
          }
          return false;
        }
        _wake = Completer<void>();
        await _wake!.future.timeout(left > const Duration(seconds: 1) ? const Duration(seconds: 1) : left, onTimeout: () {});
      }
      return false;
    } finally {
      _source.status.removeListener(_check);
      _source.plugin.removeListener(_check);
      _wake = null;
    }
  }

  Future<void> _sendText() async {
    if (!_source.canText) {
      _finish(ShareStage.unsupported, "$hostName can neither open links nor copy text. Install wl-clipboard there.");
      return;
    }
    _setStage(ShareStage.sending);
    try {
      _textAction = await _source.sendText(share.text ?? "", subject: share.subject);
      if (_cancelled) return;
      _finish(ShareStage.done, _textAction == ShareAction.opened ? "Opened on $hostName." : "Copied to the clipboard on $hostName.");
    } on LinkException catch (error) {
      if (!_cancelled) _finish(ShareStage.failed, error.message);
    }
  }

  Future<void> _sendFiles() async {
    if (!_source.canFiles) {
      _finish(ShareStage.unsupported, "$hostName cannot take files: its download folder is missing or not writable.");
      return;
    }
    _setStage(ShareStage.sending);
    for (final item in items) {
      if (_cancelled) return;
      if (item.status == ShareItemStatus.done) continue;
      await _sendItem(item);
      if (_cancelled) return;
      // A dropped connection fails the rest the same way; wait for it to come back on retry instead.
      if (item.status == ShareItemStatus.failed && !_source.status.value.isReady) break;
    }
    if (_cancelled) return;
    final failed = items.where((item) => item.status != ShareItemStatus.done).toList();
    if (failed.isEmpty) {
      final folder = _folderOf(items.first.receipt?.path);
      _finish(ShareStage.done, folder == null ? "Sent to $hostName." : "Saved to $folder on $hostName.");
    }
    else {
      _finish(ShareStage.failed, failed.firstWhere((item) => item.error != null, orElse: () => failed.first).error ?? "Some files did not arrive.");
    }
  }

  Future<void> _sendItem(ShareItem item) async {
    item.status = ShareItemStatus.preparing;
    notifyListeners();
    try {
      item.staged ??= await _source.stage(item.file);
    } on Object catch (error) {
      item.status = ShareItemStatus.failed;
      item.error = "Could not read ${item.file.name}: ${error is LinkException ? error.message : "the app that shared it no longer provides it"}.";
      notifyListeners();
      return;
    }
    if (_cancelled) return;
    final upload = _source.sendFile(item.staged!, item.file);
    item.upload = upload;
    item.status = ShareItemStatus.sending;
    void follow() {
      item.sentBytes = upload.progress.value.sent;
      notifyListeners();
    }
    upload.progress.addListener(follow);
    notifyListeners();
    try {
      item.receipt = await upload.done;
      item.status = ShareItemStatus.done;
    } on ShareCancelledException {
      item.status = ShareItemStatus.cancelled;
    } on LinkException catch (error) {
      item.status = ShareItemStatus.failed;
      item.error = error.message;
    } finally {
      upload.progress.removeListener(follow);
      notifyListeners();
    }
  }

  static String? _folderOf(String? path) {
    if (path == null || path.isEmpty) return null;
    final slash = path.lastIndexOf("/");
    if (slash <= 0) return null;
    final folder = path.substring(0, slash);
    final home = folder.lastIndexOf("/");
    return home >= 0 ? folder.substring(home + 1) : folder;
  }
}
