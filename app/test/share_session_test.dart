// The share sheet's session sends nothing until the user taps Send: any app on the phone can hand Ionix Link a share
// (the activity is exported), so the tap is the consent (PROTOCOL.md §8.9).

import "package:flutter_test/flutter_test.dart";
import "package:ionix_link/link/link.dart";
import "package:ionix_link/platform/link_platform.dart";
import "package:ionix_link/ui/pages/share/share_session.dart";
import "package:ionix_link/ui/preview/fakes.dart";

/// Counts what would have left the phone.
class _CountingShareSource extends FakeShareSource {
  _CountingShareSource({super.paired});

  final List<String> texts = [];

  @override
  Future<ShareAction> sendText(String text, {String? subject}) async {
    texts.add(text);
    return ShareAction.opened;
  }
}

void main() {
  const link = IncomingShare(text: "https://example.com/page", subject: "A page");

  test("a share waits for Send, then sends once", () async {
    final source = _CountingShareSource();
    final session = ShareSession(link, source: source)..start();
    expect(session.stage, ShareStage.confirm);
    expect(session.isActive, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(source.texts, isEmpty);
    await session.send();
    expect(source.texts, ["https://example.com/page"]);
    expect(session.stage, ShareStage.done);
    expect(session.textAction, ShareAction.opened);
    await session.send();
    expect(source.texts, hasLength(1));
    session.dispose();
  });

  test("Cancel or closing the sheet before Send sends nothing", () async {
    final source = _CountingShareSource();
    final session = ShareSession(link, source: source)..start();
    session.cancel();
    expect(session.stage, ShareStage.cancelled);
    await session.send();
    expect(source.texts, isEmpty);
    session.dispose();

    final dismissed = ShareSession(link, source: source)..start();
    dismissed.dispose();
    expect(source.texts, isEmpty);
  });

  test("with nothing paired the sheet says so instead of asking", () {
    final session = ShareSession(link, source: _CountingShareSource(paired: false))..start();
    expect(session.stage, ShareStage.noHost);
    expect(session.isActive, isFalse);
    session.dispose();
  });
}
