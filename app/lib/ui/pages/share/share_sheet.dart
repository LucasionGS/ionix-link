import "package:material_ui/material_ui.dart";

import "../../../platform/link_platform.dart";
import "../../theme.dart";
import "../../widgets/ion_card.dart";
import "share_session.dart";

/// Shows the "Send to (desktop)" sheet for [share] over [context]'s navigator: what would be sent and to where, with
/// Send and Cancel. Nothing is sent before Send is tapped, and closing the sheet cancels it. Completes when the sheet
/// is gone. [session] is for the app and the preview, which bring one of their own; it is then not started here.
Future<void> showShareSheet(BuildContext context, IncomingShare share, {ShareSession? session}) async {
  final active = session ?? (ShareSession(share)..start());
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => ShareSheet(session: active),
  );
  active.dispose();
}

/// The content of the share sheet: what is being sent, a progress bar per file, and the buttons the stage calls for.
class ShareSheet extends StatelessWidget {
  const ShareSheet({super.key, required this.session});

  final ShareSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final t = IonixTokens.of(context);
        final text = Theme.of(context).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(IonixSpace.lg, IonixSpace.lg, IonixSpace.lg, IonixSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IonBadge(icon: _stageIcon(session.stage), color: _stageColor(t, session.stage), circle: true),
                    const SizedBox(width: IonixSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Send to ${session.hostName}", style: text.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(_summary(session), style: text.bodyMedium?.copyWith(color: t.dim), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: IonixSpace.lg),
                if (session.isText) _TextPreview(session: session) else _FileList(session: session),
                const SizedBox(height: IonixSpace.lg),
                _StatusLine(session: session),
                const SizedBox(height: IonixSpace.lg),
                _Buttons(session: session),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _summary(ShareSession session) {
    if (session.isText) return _looksLikeLink(session.share.text) ? "A link" : "Some text";
    final count = session.items.length;
    if (count == 1) return _size(session.items.first.size) ?? "1 file";
    return "$count files";
  }

  static bool _looksLikeLink(String? text) {
    final s = text?.trim() ?? "";
    return !s.contains(RegExp(r"\s")) && (s.startsWith("http://") || s.startsWith("https://"));
  }

  static IconData _stageIcon(ShareStage stage) {
    return switch (stage) {
      ShareStage.confirm => Icons.send_rounded,
      ShareStage.waiting => Icons.sync_rounded,
      ShareStage.noHost => Icons.link_off_rounded,
      ShareStage.unsupported => Icons.block_rounded,
      ShareStage.sending => Icons.upload_rounded,
      ShareStage.done => Icons.check_rounded,
      ShareStage.failed => Icons.error_outline_rounded,
      ShareStage.cancelled => Icons.close_rounded,
    };
  }

  static Color? _stageColor(IonixTokens t, ShareStage stage) {
    return switch (stage) {
      ShareStage.done => t.green,
      ShareStage.failed || ShareStage.unsupported || ShareStage.noHost => t.red,
      _ => null,
    };
  }
}

/// "12.3 MB" for a byte count, null when unknown.
String? _size(int bytes) {
  if (bytes < 0) return null;
  if (bytes < 1024) return "$bytes B";
  if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(0)} KB";
  if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB";
  return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.session});

  final ShareSession session;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final subject = session.share.subject;
    final link = ShareSheet._looksLikeLink(session.share.text);
    return IonCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(link ? Icons.link_rounded : Icons.notes_rounded, size: 22, color: t.accentLight),
          const SizedBox(width: IonixSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subject != null && subject.trim().isNotEmpty) ...[
                  Text(subject.trim(), style: text.titleSmall?.copyWith(color: t.textBright), maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: IonixSpace.xs),
                ],
                Text(session.share.text?.trim() ?? "", style: text.bodyMedium?.copyWith(color: link ? t.accentLight : t.text),
                    maxLines: link ? 3 : 5, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({required this.session});

  final ShareSession session;

  @override
  Widget build(BuildContext context) {
    final items = session.items;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
      child: IonCard(
        padding: const EdgeInsets.symmetric(horizontal: IonixSpace.lg, vertical: IonixSpace.sm),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: items.length,
          separatorBuilder: (context, _) => const SizedBox(height: IonixSpace.sm),
          itemBuilder: (context, index) => _FileRow(item: items[index]),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.item});

  final ShareItem item;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final status = item.status;
    final size = _size(item.size);
    final detail = switch (status) {
      ShareItemStatus.queued => size ?? "Size unknown",
      ShareItemStatus.preparing => "Reading…",
      ShareItemStatus.sending => "${_size(item.sent) ?? "0 B"}${size == null ? "" : " of $size"}",
      ShareItemStatus.done => "Sent${size == null ? "" : ", $size"}",
      ShareItemStatus.failed => item.error ?? "Failed",
      ShareItemStatus.cancelled => "Cancelled",
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: IonixSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_fileIcon(item.file.mime), size: 22, color: t.accentLight),
              const SizedBox(width: IonixSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.file.name, style: text.bodyLarge?.copyWith(color: t.textBright), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(detail, style: text.bodySmall?.copyWith(color: status == ShareItemStatus.failed ? t.red : t.dim), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: IonixSpace.sm),
              if (status == ShareItemStatus.done) Icon(Icons.check_circle_rounded, size: 20, color: t.green),
              if (status == ShareItemStatus.failed) Icon(Icons.error_rounded, size: 20, color: t.red),
            ],
          ),
          if (status == ShareItemStatus.sending || status == ShareItemStatus.preparing) ...[
            const SizedBox(height: IonixSpace.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: status == ShareItemStatus.sending ? item.fraction : null, minHeight: 6),
            ),
          ],
        ],
      ),
    );
  }

  static IconData _fileIcon(String? mime) {
    if (mime == null) return Icons.insert_drive_file_outlined;
    if (mime.startsWith("image/")) return Icons.image_outlined;
    if (mime.startsWith("video/")) return Icons.movie_outlined;
    if (mime.startsWith("audio/")) return Icons.audiotrack_outlined;
    if (mime.startsWith("text/")) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.session});

  final ShareSession session;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    switch (session.stage) {
      case ShareStage.confirm:
        final where = session.hostName;
        final what = session.isText
            ? (ShareSheet._looksLikeLink(session.share.text) ? "Opens in the browser on $where." : "Goes to the clipboard on $where.")
            : (session.items.length == 1 ? "Saved to the download folder on $where." : "All are saved to the download folder on $where.");
        return Text("$what Nothing is sent until you tap Send.", style: text.bodyMedium?.copyWith(color: t.dim));
      case ShareStage.waiting:
        return Row(
          children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4)),
            const SizedBox(width: IonixSpace.md),
            Expanded(child: Text("Connecting to ${session.hostName}…", style: text.bodyMedium)),
          ],
        );
      case ShareStage.sending:
        final fraction = session.fraction;
        return session.isText
            ? Row(
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4)),
                  const SizedBox(width: IonixSpace.md),
                  Text("Sending…", style: text.bodyMedium),
                ],
              )
            : Text(fraction == null ? "Sending…" : "Sending… ${(fraction * 100).floor()}%", style: text.bodyMedium);
      case ShareStage.done:
        return Text(session.message ?? "Sent.", style: text.bodyMedium?.copyWith(color: t.green));
      case ShareStage.failed:
      case ShareStage.unsupported:
      case ShareStage.noHost:
        // A file's own error already shows in its row; the line below the list only says that something is left.
        final shown = session.items.any((item) => item.error != null && item.error == session.message);
        return Text(shown ? "Some files did not arrive." : session.message ?? "Something went wrong.", style: text.bodyMedium?.copyWith(color: t.red));
      case ShareStage.cancelled:
        return Text(session.message ?? "Cancelled.", style: text.bodyMedium?.copyWith(color: t.dim));
    }
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons({required this.session});

  final ShareSession session;

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    switch (session.stage) {
      case ShareStage.confirm:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () { session.cancel(); close(); }, child: const Text("Cancel")),
            const SizedBox(width: IonixSpace.sm),
            FilledButton.icon(onPressed: session.send, icon: const Icon(Icons.send_rounded, size: 18), label: const Text("Send")),
          ],
        );
      case ShareStage.waiting:
      case ShareStage.sending:
        return Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () { session.cancel(); close(); }, child: const Text("Cancel")));
      case ShareStage.failed:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: close, child: const Text("Close")),
            const SizedBox(width: IonixSpace.sm),
            FilledButton(onPressed: session.retry, child: const Text("Try again")),
          ],
        );
      case ShareStage.noHost:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: close, child: const Text("Close")),
            const SizedBox(width: IonixSpace.sm),
            FilledButton(onPressed: close, child: const Text("Pair")),
          ],
        );
      case ShareStage.unsupported:
      case ShareStage.cancelled:
        return Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: close, child: const Text("Close")));
      case ShareStage.done:
        return Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: close, child: const Text("Done")));
    }
  }
}
