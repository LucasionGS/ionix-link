/// Protocol constants shared by every part of the link layer. Values are the ones in `PROTOCOL.md`;
/// change both together.
library;

/// Numbers and limits of the wire protocol.
class LinkProtocol {
  LinkProtocol._();

  /// Highest protocol version this app speaks, sent as `hello.protocol`.
  static const int version = 1;

  /// Lowest protocol version this app speaks, sent as `hello.protocolMin`.
  static const int versionMin = 1;

  /// Version of the `ionixlink://pair` URI format this app understands.
  static const int uriVersion = 1;

  /// Default TCP and UDP port of the daemon.
  static const int defaultPort = 47110;

  /// Frame kind byte of a JSON message.
  static const int kindJson = 0;

  /// Frame kind byte of a binary frame (header message plus raw data).
  static const int kindBinary = 1;

  /// Largest frame `length` accepted before `ready`. Unit is bytes.
  static const int maxFrameUnauthenticated = 64 * 1024;

  /// Largest frame `length` accepted after `ready`. Unit is bytes.
  static const int maxFrame = 8 * 1024 * 1024;

  /// Largest JSON message (kind 0 payload or kind 1 header). Unit is bytes.
  static const int maxJson = 1024 * 1024;

  /// Largest clipboard or input text, UTF-8 encoded. Unit is bytes.
  static const int maxText = 512 * 1024;

  /// Largest UDP discovery datagram. Unit is bytes.
  static const int maxDatagram = 1024;

  /// Highest message `id` before the counter wraps back to 1.
  static const int maxId = 2147483647;

  /// Send a `ping` after this long with nothing received.
  static const Duration pingIdle = Duration(seconds: 20);

  /// Close the connection after this long with nothing received.
  static const Duration deadPeer = Duration(seconds: 45);

  /// Default timeout of a request.
  static const Duration requestTimeout = Duration(seconds: 15);

  /// Timeout of `commands.run`.
  static const Duration commandRunTimeout = Duration(seconds: 30);

  /// Timeout of a token `pair.request` (pairing A) and of `pair.confirm` (pairing B): long enough for the desktop
  /// user to answer.
  static const Duration pairTimeout = Duration(seconds: 130);

  /// Timeout of pairing B's `pair.request`, answered at once with `pair.challenge`.
  static const Duration pairCommitTimeout = Duration(seconds: 30);

  /// TCP connect plus TLS handshake timeout, per address.
  static const Duration connectTimeout = Duration(seconds: 3);

  /// How long a discovery scan collects announces.
  static const Duration discoveryScan = Duration(seconds: 3);

  /// Gap between the three discovery query broadcasts.
  static const Duration discoveryRepeat = Duration(milliseconds: 300);

  /// Reconnect delays, in order; the last one repeats.
  static const List<Duration> reconnectBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// Most `input.move` pushes per second; faster moves are coalesced.
  static const int maxMoveRate = 120;
}

/// Core message types (not belonging to a plugin). Plugin types live as constants on each plugin client.
class LinkTypes {
  LinkTypes._();

  // Handshake
  static const String hello = "hello";
  static const String challenge = "challenge";
  static const String auth = "auth";
  static const String ready = "ready";

  // Any time
  static const String error = "error";
  static const String ping = "ping";
  static const String pong = "pong";

  // Pairing
  static const String pairRequest = "pair.request";
  static const String pairChallenge = "pair.challenge";
  static const String pairConfirm = "pair.confirm";
  static const String pairPending = "pair.pending";
  static const String pairAccept = "pair.accept";
  static const String pairReject = "pair.reject";
  static const String pairUnpair = "pair.unpair";
}

/// Plugin names as they appear in `PluginInfo.name`.
class LinkPlugins {
  LinkPlugins._();

  static const String notifications = "notifications";
  static const String media = "media";
  static const String commands = "commands";
  static const String clipboard = "clipboard";
  static const String input = "input";
  static const String screen = "screen";
  static const String status = "status";
  static const String theme = "theme";
  static const String share = "share";
}
