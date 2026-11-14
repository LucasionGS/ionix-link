// End-to-end run of the link layer over real TLS on localhost, against the fake daemon in test/support/ (the real
// bin/ionix-link cannot answer the debug.* hooks this needs). Skipped unless IONIX_LINK_E2E_DIR is set. To run it:
//
//   python3 test/support/fake_daemon.py /tmp/ionix-link-e2e 47999 &
//   IONIX_LINK_E2E_DIR=/tmp/ionix-link-e2e flutter test test/link_e2e_test.dart
//
// Use a fresh state directory and a free port each time, and stop the daemon afterwards. It also binds 127.0.0.2
// (an imposter with another certificate), so it needs Linux's whole 127.0.0.0/8 loopback.

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";
import "package:ionix_link/link/connection/discovery.dart";
import "package:ionix_link/link/connection/pairing.dart";
import "package:ionix_link/link/link.dart";
import "package:ionix_link/link/protocol/link_crypto.dart";

final String? stateDir = Platform.environment["IONIX_LINK_E2E_DIR"];

/// Wait until [listenable]'s value satisfies [test], or fail after [timeout].
Future<T> waitFor<T>(ValueListenable<T> listenable, bool Function(T value) test, {Duration timeout = const Duration(seconds: 10), String? what}) {
  if (test(listenable.value)) return Future.value(listenable.value);
  final completer = Completer<T>();
  void check() {
    if (!completer.isCompleted && test(listenable.value)) completer.complete(listenable.value);
  }
  listenable.addListener(check);
  return completer.future.timeout(timeout, onTimeout: () => throw TimeoutException("Waiting for ${what ?? "a value"}; last: ${listenable.value}")).whenComplete(() => listenable.removeListener(check));
}

Future<LinkStatus> waitState(LinkState state, {Duration timeout = const Duration(seconds: 10)}) =>
    waitFor(Link.connectionStatus, (status) => status.state == state, timeout: timeout, what: state.name);

Future<Map<String, dynamic>> debug(String type, [Map<String, dynamic> body = const {}]) async =>
    (await Link.connection!.request(type, body)).body;

void main() {
  final skip = stateDir == null ? "IONIX_LINK_E2E_DIR is not set" : null;
  late Map<String, dynamic> info;
  late String storeDir;
  final keys = MemoryKeyStore();

  setUpAll(() async {
    if (stateDir == null) return;
    info = jsonDecode(await File("$stateDir/info.json").readAsString()) as Map<String, dynamic>;
    storeDir = (await Directory.systemTemp.createTemp("ionix-link-e2e-")).path;
    LinkDiscovery.broadcastAddress = "127.0.0.1";
    await Link.init(platformName: "Test phone", model: "Pixel Test", storeDirectory: storeDir, keyStore: keys);
  });

  tearDownAll(() async {
    if (stateDir == null) return;
    await Link.disconnect();
    await Directory(storeDir).delete(recursive: true);
  });

  test("theme is the base one before anything is paired", () {
    expect(Link.theme.theme.value, LinkTheme.ionix);
    expect(Link.connectionStatus.value.state, LinkState.idle);
  }, skip: skip);

  test("a wrong pin is refused as a certificate change", () async {
    await expectLater(
      LinkConnection.open("127.0.0.1", info["port"] as int, pin: "00" * 32),
      throwsA(isA<LinkCertificateException>().having((error) => error.actual, "actual", info["fingerprint"])),
    );
  }, skip: skip);

  test("pairing A over the QR URI, then ready with pushed state", () async {
    final uri = PairingUri.parse(info["uri"] as String);
    final watch = Stopwatch()..start();
    final host = await Link.pairWithUri(uri);
    debugPrint("pair A took ${watch.elapsedMilliseconds} ms (one address unreachable)");
    expect(host.id, info["hostId"]);
    expect(host.lastAddress, "127.0.0.1");
    expect(await keys.read("ionix-link.key.${host.id}"), hasLength(64));
    final status = await waitState(LinkState.ready);
    expect(status.address, "127.0.0.1");
    expect(Link.plugins.value.map((plugin) => plugin.name), containsAll(["media", "commands", "screen", "theme", "status"]));
    await waitFor(Link.status.host, (host) => host != null, what: "status.host");
    expect(Link.status.host.value!.hostName, "fakeix");
    await waitFor(Link.media.players, (players) => players.isNotEmpty, what: "media.players");
    expect(Link.media.active!.identity, "Spotify");
    await waitFor(Link.media.volume, (volume) => volume != null, what: "media.volume");
    expect(Link.media.volume.value!.volume, 0.5);
    // Cover art: fetched once through media.art, then served from the cache.
    final cover = await Link.media.art(Link.media.active!);
    expect(cover?.first, 0xff);
    expect(await Link.media.art(Link.media.active!), same(cover));
    await waitFor(Link.commands.commands, (commands) => commands.isNotEmpty, what: "commands.list");
    expect(Link.commands.commands.value.single.group, "Tests");
    await waitFor(Link.notifications.active, (list) => list.isNotEmpty, what: "notifications.list");
  }, skip: skip);

  test("a used token is rejected", () async {
    await expectLater(
      LinkPairing.withUri(PairingUri.parse(info["uri"] as String), Link.identity, Link.store),
      throwsA(isA<LinkPairingException>().having((error) => error.reason, "reason", "token_invalid")),
    );
  }, skip: skip);

  test("requests, errors and keepalive ping", () async {
    final result = await Link.commands.run("hello");
    expect(result.ok, isTrue);
    expect(result.exitCode, 0);
    await expectLater(Link.commands.run("nope"), throwsA(isA<LinkRemoteException>().having((error) => error.code, "code", LinkErrorCode.notFound)));
    expect(await Link.clipboard.pull(), "from desktop");
    await Link.clipboard.push("from phone");
    expect((await Link.connection!.request("ping")).type, "pong");
    await expectLater(Link.connection!.request("bogus.verb"), throwsA(isA<LinkRemoteException>()));
    Link.status.setBattery(const BatteryState(level: 42, charging: true));
    final stats = await debug("debug.stats");
    expect(stats["clipboard"], "from phone");
    expect(stats["battery"], {"level": 42, "charging": true});
  }, skip: skip);

  test("pointer moves are coalesced, buttons keep their place", () async {
    for (var i = 0; i < 1000; i++) {
      Link.input.move(1, -1);
    }
    Link.input.click();
    // 300 moves spread over ~0.6 s, as a finger would.
    for (var i = 0; i < 300; i++) {
      Link.input.move(0.5, 0);
      if (i % 10 == 0) await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final stats = await debug("debug.stats");
    debugPrint("input: ${stats["moves"]} move pushes for 1300 move() calls; buttons ${stats["buttons"]}");
    expect(stats["dx"], 1150);
    expect(stats["dy"], -1000);
    expect(stats["moves"], lessThan(100));
    final button = (stats["buttons"] as List).single as List;
    expect(button.sublist(0, 2), ["left", "click"]);
  }, skip: skip);

  test("screen frames flow one at a time with acks", () async {
    final outputs = await Link.screen.outputs();
    expect(outputs.single.name, "HEADLESS-1");
    final seen = <int>[];
    final subscription = Link.screen.frames.listen((frame) {
      seen.add(frame.seq);
      expect(frame.bytes, [0xff, 0xd8, frame.seq, 0xff, 0xd9]);
      Link.screen.ack(frame.seq);
    });
    final stream = await Link.screen.start("HEADLESS-1", scale: 0.5);
    expect(stream.width, 960);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await subscription.cancel();
    await Link.screen.stop();
    expect(seen, [1, 2, 3]);
    expect((await debug("debug.stats"))["acks"], [1, 2, 3]);
  }, skip: skip);

  test("the desktop's theme and wallpaper arrive, change, and persist", () async {
    final hostId = info["hostId"] as String;
    await waitFor(Link.theme.theme, (theme) => theme.name == "fakeix", what: "theme.changed");
    expect(Link.theme.theme.value.colors.bgDeep, 0xFF101018);
    expect(Link.theme.theme.value.colors.text, LinkColors.ionix.text);
    final wallpaper = await waitFor(Link.theme.wallpaper, (bytes) => bytes != null && bytes.length > 65536, what: "wallpaper");
    expect(wallpaper!.first, 0xff);

    await debug("debug.theme", {"accent": "#00ff00"});
    await waitFor(Link.theme.theme, (theme) => theme.colors.accent == 0xFF00FF00, what: "accent change");
    await waitFor(Link.theme.wallpaper, (bytes) => bytes != null && utf8.decode(bytes.sublist(bytes.length - 7), allowMalformed: true) == "#00ff00", what: "new wallpaper");
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // A restarted app: a fresh store on the same directory and a fresh client see the same theme and wallpaper.
    final reopened = await LinkStore.open(directory: storeDir, keys: keys);
    expect(reopened.themeFor(hostId), Link.theme.theme.value);
    final fresh = ThemeClient();
    await fresh.useHost(reopened, hostId);
    expect(fresh.theme.value.colors.accent, 0xFF00FF00);
    expect(fresh.wallpaper.value, Link.theme.wallpaper.value);
    final none = ThemeClient();
    await none.useHost(reopened, null);
    expect(none.theme.value, LinkTheme.ionix);
  }, skip: skip);

  test("the phone answers a ring request", () async {
    final rings = Link.status.ringRequests.listen((_) {});
    await debug("debug.ring");
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await debug("debug.stats"))["ring"], {"ok": true});
    await rings.cancel();
  }, skip: skip);

  test("a dropped connection reconnects with auth", () async {
    final before = Link.connection;
    final hellos = (await debug("debug.stats"))["hellos"] as int;
    await debug("debug.drop");
    await waitFor(Link.connectionStatus, (status) => status.state != LinkState.ready, what: "drop");
    expect(Link.media.players.value, isEmpty);
    await waitState(LinkState.ready, timeout: const Duration(seconds: 6));
    expect(identical(Link.connection, before), isFalse);
    expect((await debug("debug.stats"))["hellos"], hellos + 1);
    await waitFor(Link.media.players, (players) => players.isNotEmpty, what: "players again");
  }, skip: skip);

  test("a graceful close without an error is noticed (TLS close_notify, then FIN)", () async {
    final watch = Stopwatch()..start();
    await debug("debug.close");
    await waitFor(Link.connectionStatus, (status) => status.state != LinkState.ready, what: "close");
    debugPrint("graceful close noticed after ${watch.elapsedMilliseconds} ms");
    await waitState(LinkState.ready, timeout: const Duration(seconds: 6));
  }, skip: skip);

  test("an unreachable stored address falls back to a UDP refind", () async {
    final stored = Link.store.host(info["hostId"] as String)!;
    await Link.store.updateHost(PairedHost(
      id: stored.id,
      name: stored.name,
      fingerprint: stored.fingerprint,
      port: stored.port,
      addresses: ["127.0.0.4"],
      pairedAt: stored.pairedAt,
    ));
    await debug("debug.drop");
    await waitFor(Link.connectionStatus, (status) => status.state != LinkState.ready, what: "drop");
    await waitState(LinkState.ready, timeout: const Duration(seconds: 8));
    final updated = Link.store.host(stored.id)!;
    expect(updated.lastAddress, "127.0.0.1");
    expect(updated.addresses.first, "127.0.0.1");
  }, skip: skip);

  test("a device the desktop forgot is reported at the next hello and not retried", () async {
    await debug("debug.forget");
    final status = await waitState(LinkState.forgotten, timeout: const Duration(seconds: 8));
    expect(status.error, isA<LinkAuthException>().having((error) => error.code, "code", LinkErrorCode.unknownDevice));
  }, skip: skip);

  test("pairing B is refused while the desktop has no pairing window", () async {
    final found = await Link.discover(port: info["port"] as int).toList();
    await File("$stateDir/window-closed").writeAsString("");
    try {
      final pairing = await Link.pairWithCode(found.single);
      await expectLater(pairing.result, throwsA(isA<LinkPairingException>().having((error) => error.isNotOpen, "isNotOpen", isTrue)));
      expect(pairing.code, isNull);
    } finally {
      await File("$stateDir/window-closed").delete();
    }
  }, skip: skip);

  test("pairing B: discovery, commit, challenge, code, accept", () async {
    final found = await Link.discover(port: info["port"] as int).toList();
    expect(found.single.id, info["hostId"]);
    expect(found.single.isCompatible, isTrue);
    final steps = <String>[];
    final pairing = await Link.pairWithCode(found.single);
    pairing.step.addListener(() => steps.add(pairing.step.value.name));
    expect(pairing.code, isNull);
    final host = await pairing.result.timeout(const Duration(seconds: 5));
    expect(steps, ["confirming", "pending"]);
    expect(pairing.isPending, isTrue);
    expect(pairing.displayCode, "${pairing.code!.substring(0, 3)} ${pairing.code!.substring(3)}");
    expect(pairing.code, await File("$stateDir/code.txt").readAsString());
    expect(pairing.fingerprint, info["fingerprint"]);
    await Link.selectHost(host.id);
    await waitState(LinkState.ready);
  }, skip: skip);

  test("a wrong key forgets the host; a certificate other than the pinned one only warns and retries", () async {
    final hostId = info["hostId"] as String;
    final good = (await Link.store.keyFor(hostId))!;
    final host = Link.store.host(hostId)!;
    await Link.disconnect();
    await Link.store.saveHost(host, key: LinkCrypto.toHex(LinkCrypto.randomBytes(32)));
    await Link.selectHost(hostId);
    final status = await waitState(LinkState.forgotten);
    expect(status.error, isA<LinkAuthException>().having((error) => error.code, "code", LinkErrorCode.authFailed));

    await Link.disconnect();
    final imposter = PairedHost(
      id: host.id,
      name: host.name,
      fingerprint: "ab" * 32,
      port: host.port,
      addresses: host.addresses,
      pairedAt: host.pairedAt,
    );
    await Link.store.saveHost(imposter, key: good);
    await Link.selectHost(hostId);
    final changed = await waitFor(Link.connectionStatus, (status) => status.state == LinkState.retrying && status.warning != null, what: "retrying with a warning");
    expect(changed.warning, contains("different certificate"));
    expect(Link.store.host(hostId), isNotNull);

    await Link.disconnect();
    await Link.store.saveHost(host, key: good);
    await Link.selectHost(hostId);
    await waitState(LinkState.ready);
  }, skip: skip);

  test("discovery queries carry nothing about the phone", () async {
    final queries = (await debug("debug.stats"))["queries"] as List;
    expect(queries, isNotEmpty);
    for (final query in queries.cast<Map<String, dynamic>>()) {
      expect(query.keys.toSet(), anyOf({"ionixlink", "type"}, {"ionixlink", "type", "want"}));
    }
  }, skip: skip);

  /// Store [addresses] (and no last address) for the paired host, then drop the connection so the session reconnects.
  Future<void> reconnectVia(List<String> addresses) async {
    final stored = Link.store.host(info["hostId"] as String)!;
    await Link.store.updateHost(PairedHost(
      id: stored.id,
      name: stored.name,
      fingerprint: stored.fingerprint,
      port: stored.port,
      addresses: addresses,
      pairedAt: stored.pairedAt,
    ));
    await debug("debug.drop");
    await waitFor(Link.connectionStatus, (status) => status.state != LinkState.ready, what: "drop");
  }

  test("a wrong certificate at one stored address is skipped while another one works", () async {
    await reconnectVia(["127.0.0.2", "127.0.0.1"]);
    final status = await waitState(LinkState.ready, timeout: const Duration(seconds: 6));
    expect(status.address, "127.0.0.1");
    expect(Link.store.host(info["hostId"] as String)!.addresses.first, "127.0.0.1");
  }, skip: skip);

  test("only a wrong certificate at the stored address: skipped, refound by UDP, warned about", () async {
    await reconnectVia(["127.0.0.2"]);
    final status = await waitState(LinkState.ready, timeout: const Duration(seconds: 8));
    expect(status.address, "127.0.0.1");
    expect(status.warning, contains("127.0.0.2"));
  }, skip: skip);

  test("a forged refind announce is ignored, the real one still wins", () async {
    await File("$stateDir/forge-announce").writeAsString("");
    try {
      await reconnectVia(["127.0.0.4"]);
      final status = await waitState(LinkState.ready, timeout: const Duration(seconds: 8));
      expect(status.warning, contains("different certificate"));
    } finally {
      await File("$stateDir/forge-announce").delete();
    }
  }, skip: skip);

  test("only forged announces: the host is not forgotten, the session keeps trying", () async {
    await File("$stateDir/forge-only").writeAsString("");
    try {
      await reconnectVia(["127.0.0.4"]);
      final status = await waitFor(Link.connectionStatus, (status) => status.state == LinkState.retrying && status.warning != null, timeout: const Duration(seconds: 8), what: "retrying with a warning");
      expect(status.warning, contains("different certificate"));
      expect(Link.store.host(info["hostId"] as String), isNotNull);
    } finally {
      await File("$stateDir/forge-only").delete();
    }
    Link.reconnect();
    await waitState(LinkState.ready, timeout: const Duration(seconds: 8));
  }, skip: skip);

  test("stored addresses are capped to the most recent ones", () async {
    final stored = Link.store.host(info["hostId"] as String)!;
    final many = PairedHost(
      id: stored.id,
      name: stored.name,
      fingerprint: stored.fingerprint,
      port: stored.port,
      addresses: ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"],
      pairedAt: stored.pairedAt,
    );
    expect(many.addresses, hasLength(PairedHost.maxAddresses));
  }, skip: skip);

  test("pair.unpair from the desktop removes the host", () async {
    await debug("debug.unpair");
    final status = await waitState(LinkState.forgotten);
    expect(status.error!.message, contains("Unpaired by fakeix"));
    await waitFor(Link.hosts, (hosts) => hosts.isEmpty, what: "host removed");
    expect(Link.currentHost.value, isNull);
    expect(await keys.read("ionix-link.key.${info["hostId"]}"), isNull);
    expect(Link.theme.theme.value, LinkTheme.ionix);
  }, skip: skip);
}
