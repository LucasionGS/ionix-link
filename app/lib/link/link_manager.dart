import "dart:async";

import "package:flutter/foundation.dart";

import "connection/discovery.dart";
import "connection/link_connection.dart";
import "connection/link_session.dart";
import "connection/link_status.dart";
import "connection/pairing.dart";
import "models/device_identity.dart";
import "models/discovered_host.dart";
import "models/paired_host.dart";
import "models/pairing_uri.dart";
import "models/link_theme.dart";
import "models/plugin_info.dart";
import "plugins/clipboard_client.dart";
import "plugins/commands_client.dart";
import "plugins/input_client.dart";
import "plugins/media_client.dart";
import "plugins/notifications_client.dart";
import "plugins/plugin_client.dart";
import "plugins/screen_client.dart";
import "plugins/share_client.dart";
import "plugins/status_client.dart";
import "plugins/theme_client.dart";
import "protocol/constants.dart";
import "protocol/errors.dart";
import "store/link_store.dart";

/// The single entry point the UI and platform layers use. Static manager: call [init] once in `main` before
/// `runApp`, then read [connectionStatus], [hosts] and the plugin clients.
///
/// v1 keeps **one** host connected at a time: the current one ([currentHost]). Switching hosts stops the old
/// [LinkSession] and starts a new one. The plugin clients are created once and survive reconnects and host switches,
/// so a widget can listen to `Link.media.players` for its whole life.
class Link {
  Link._();

  /// The app version sent in `hello.appVersion`. Keep in sync with `pubspec.yaml` `version`.
  static const String appVersion = "1.0.0";

  /// Persistent state.
  static late final LinkStore store;

  /// This phone, as the desktop sees it. Replaced by [setDeviceName].
  static DeviceIdentity get identity => _identity;

  static late DeviceIdentity _identity;
  static String _platformName = "";
  static String _model = "";
  static bool _initialized = false;
  static LinkSession? _session;
  static final ValueNotifier<LinkStatus> _status = ValueNotifier(LinkStatus.idleStatus);
  static final ValueNotifier<PairedHost?> _currentHost = ValueNotifier(null);
  static final ValueNotifier<List<PluginInfo>> _plugins = ValueNotifier(const []);

  // Plugin clients
  static final NotificationsClient notifications = NotificationsClient();
  static final MediaClient media = MediaClient();
  static final CommandsClient commands = CommandsClient();
  static final ClipboardClient clipboard = ClipboardClient();
  static final InputClient input = InputClient();
  static final ScreenClient screen = ScreenClient();
  static final StatusClient status = StatusClient();
  static final ShareClient share = ShareClient();

  /// The desktop's theme. Usable before [init] finishes and with nothing paired: it then holds [LinkTheme.ionix].
  static final ThemeClient theme = ThemeClient();

  /// Every plugin client, in the order their descriptors go into `hello`. **A new plugin is added here.**
  static final List<PluginClient> clients = [notifications, media, commands, clipboard, input, screen, status, theme, share];

  /// Load the store, build the identity and, if a current host is stored, start connecting to it.
  /// @param platformName The phone's name from the platform (used unless the user set one).
  /// @param model The phone's model.
  /// @param storeDirectory Overrides the store's directory (tests, Linux).
  /// @param keyStore Overrides where device keys are kept (tests; default secure storage).
  static Future<void> init({required String platformName, required String model, String? storeDirectory, LinkKeyStore? keyStore}) async {
    if (_initialized) throw LinkException("Link.init was called twice.");
    _initialized = true;
    store = await LinkStore.open(directory: storeDirectory, keys: keyStore);
    _platformName = platformName;
    _model = model;
    _identity = store.identity(platformName: platformName, model: model);
    store.hosts.addListener(_onHostsChanged);
    final currentId = store.currentHostId;
    final current = currentId == null ? null : store.host(currentId);
    _currentHost.value = current;
    await theme.useHost(store, current?.id);
    if (current != null) await _startSession(current);
  }

  /// Session status of the current host. [LinkState.idle] when there is none.
  static ValueListenable<LinkStatus> get connectionStatus => _status;

  /// Paired hosts (same as `store.hosts`).
  static ValueListenable<List<PairedHost>> get hosts => store.hosts;

  /// The current host, or null.
  static ValueListenable<PairedHost?> get currentHost => _currentHost;

  /// The live connection while ready, else null. Plugin clients are the normal way in; this is for diagnostics.
  static LinkConnection? get connection => _session?.connection;

  /// Plugins negotiated on the current connection (empty unless ready).
  static ValueListenable<List<PluginInfo>> get plugins => _plugins;

  /// Whether [name] is negotiated on the current connection.
  static bool hasPlugin(String name) => plugins.value.any((p) => p.name == name);

  /// Make [hostId] current and connect to it.
  /// @throws LinkException if [hostId] is not paired.
  static Future<void> selectHost(String hostId) async {
    _requireInit();
    final host = store.host(hostId);
    if (host == null) throw LinkException("This desktop is not paired.");
    await store.setCurrentHostId(host.id);
    final session = _session;
    final state = _status.value.state;
    if (session != null && session.host.id == host.id && state != LinkState.forgotten && state != LinkState.idle) {
      _currentHost.value = host;
      session.retryNow();
      return;
    }
    _currentHost.value = host;
    await theme.useHost(store, host.id);
    await _startSession(host);
  }

  /// Disconnect and clear the current host (it stays paired).
  static Future<void> disconnect() async {
    _requireInit();
    await _stopSession();
    await store.setCurrentHostId(null);
    _currentHost.value = null;
    await theme.useHost(store, null);
  }

  /// Retry the current host now, skipping the backoff (app resumed, pull to refresh).
  static void reconnect() => _session?.retryNow();

  /// Pairing A from a scanned URI; on success the host becomes current and connects.
  static Future<PairedHost> pairWithUri(PairingUri uri) async {
    _requireInit();
    final host = await LinkPairing.withUri(uri, identity, store);
    await selectHost(host.id);
    return host;
  }

  /// Pairing B with a discovered host. The UI shows [CodePairing.code], awaits [CodePairing.result], then calls
  /// [selectHost] with the result's id.
  static Future<CodePairing> pairWithCode(DiscoveredHost host) {
    _requireInit();
    return LinkPairing.withCode(host, identity, store);
  }

  /// Scan the network for desktops (UDP discovery).
  /// @param port The daemons' port; only a desktop that moved it with `IONIX_LINK_PORT` needs another one.
  static Stream<DiscoveredHost> discover({Duration duration = const Duration(seconds: 3), int port = LinkProtocol.defaultPort}) {
    _requireInit();
    return LinkDiscovery.scan(duration: duration, port: port);
  }

  /// Unpair [hostId]: send `pair.unpair` if connected to it, then remove it and its key. If it was current, the
  /// session stops.
  static Future<void> unpair(String hostId) async {
    _requireInit();
    final id = hostId.toLowerCase();
    final session = _session;
    if (session != null && session.host.id == id) {
      final connection = session.connection;
      if (connection != null && connection.isOpen) {
        try {
          connection.send(LinkTypes.pairUnpair);
        } on LinkException catch (error) {
          debugPrint("ionix-link: pair.unpair not sent: ${error.message}");
        }
      }
      // stop() closes gracefully, so the pair.unpair above is written before the socket goes.
      await _stopSession();
    }
    await store.removeHost(id);
  }

  /// Change the phone name sent to desktops (null = the platform's). Takes effect on the next `hello`.
  static Future<void> setDeviceName(String? name) async {
    _requireInit();
    await store.setDeviceName(name);
    _identity = store.identity(platformName: _platformName, model: _model);
  }

  static void _requireInit() {
    if (!_initialized) throw LinkException("Link.init must run before the link layer is used.");
  }

  static Future<void> _startSession(PairedHost host) async {
    await _stopSession();
    final session = LinkSession(
      host: host,
      identity: _identity,
      identityProvider: () => _identity,
      store: store,
      clients: clients,
      appVersion: appVersion,
    );
    _session = session;
    void follow() {
      if (_session != session) return;
      final status = session.status.value;
      _status.value = status;
      _plugins.value = status.isReady ? (session.connection?.ready?.plugins ?? const []) : const [];
    }
    session.status.addListener(follow);
    _sessionListener = (session, follow);
    follow();
    session.start();
  }

  static (LinkSession, VoidCallback)? _sessionListener;

  static Future<void> _stopSession() async {
    final session = _session;
    _session = null;
    final listener = _sessionListener;
    _sessionListener = null;
    if (listener != null) listener.$1.status.removeListener(listener.$2);
    if (session != null) await session.stop();
    _status.value = LinkStatus.idleStatus;
    _plugins.value = const [];
  }

  /// Keep [currentHost] in step with the store: renamed or readdressed hosts, and a host removed by `pair.unpair`.
  static void _onHostsChanged() {
    final current = _currentHost.value;
    if (current == null) return;
    final stored = store.host(current.id);
    if (stored == null) {
      _currentHost.value = null;
      unawaited(theme.useHost(store, null));
      // A session that ended in forgotten keeps its status so the UI can say why; anything else goes idle.
      if (_status.value.state != LinkState.forgotten) unawaited(_stopSession());
      return;
    }
    _currentHost.value = stored;
  }
}
