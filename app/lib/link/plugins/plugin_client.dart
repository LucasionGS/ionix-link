import "dart:async";

import "package:flutter/foundation.dart";

import "../connection/link_connection.dart";
import "../models/plugin_info.dart";
import "../protocol/errors.dart";
import "../protocol/message.dart";

/// Base of every typed plugin client. One instance per plugin lives for the app's lifetime (in [Link]); the session
/// attaches it to each new connection on `ready` and detaches it on close, so UI listeners never re-subscribe.
///
/// A subclass sets [name], [version], [localCaps], registers its request handlers and push listeners in [onAttach] (and uses [request]/[send]),
/// and clears connection-bound state in [onDetach]. Listeners subscribed in [onAttach] are cancelled by the base
/// class on detach when added through [listen].
abstract class PluginClient {
  final ValueNotifier<PluginInfo?> _remote = ValueNotifier(null);
  LinkConnection? _connection;
  final List<StreamSubscription<LinkMessage>> _subscriptions = [];
  final List<String> _handled = [];

  /// Plugin name, one of [LinkPlugins].
  String get name;

  /// Plugin version this app speaks.
  int get version => 1;

  /// Caps this phone supports, sent in `hello.plugins`.
  List<String> get localCaps => const [];

  /// The descriptor sent in `hello`.
  PluginInfo get localInfo => PluginInfo(name: name, version: version, caps: localCaps);

  /// The negotiated descriptor (daemon caps) while attached and negotiated, else null.
  ValueListenable<PluginInfo?> get remote => _remote;

  /// Whether the plugin is negotiated on the current connection.
  bool get isAvailable => remote.value != null;

  /// Whether the desktop advertised [cap] for this plugin.
  bool hasCap(String cap) => remote.value?.has(cap) ?? false;

  /// The connection while attached, else null.
  @protected
  LinkConnection? get connection => _connection;

  /// Called by [LinkSession] on `ready`. [info] is null when the desktop did not negotiate this plugin; the client
  /// then stays unavailable and [onAttach] is not called.
  void attach(LinkConnection connection, PluginInfo? info) {
    if (_connection != null) detach();
    if (info == null) return;
    _connection = connection;
    _remote.value = info;
    try {
      onAttach(connection, info);
    } catch (error, stack) {
      debugPrint("ionix-link: $name failed to attach: $error\n$stack");
    }
  }

  /// Called by [LinkSession] when the connection closes.
  void detach() {
    final connection = _connection;
    if (connection == null) return;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    for (final type in _handled) {
      connection.removeRequestHandler(type);
    }
    _handled.clear();
    _connection = null;
    _remote.value = null;
    try {
      onDetach();
    } catch (error, stack) {
      debugPrint("ionix-link: $name failed to detach: $error\n$stack");
    }
  }

  /// Subclass hook: the plugin became available on [connection].
  @protected
  void onAttach(LinkConnection connection, PluginInfo info);

  /// Subclass hook: the connection is gone. Clear state that is only valid while connected.
  @protected
  void onDetach();

  /// Listen to pushes of [type] on the attached connection; cancelled automatically on [detach].
  @protected
  void listen(String type, void Function(LinkMessage message) onMessage) {
    final connection = _connection;
    if (connection == null) return;
    _subscriptions.add(connection.messages(type).listen((message) {
      try {
        onMessage(message);
      } on LinkException catch (error) {
        debugPrint("ionix-link: ignoring a malformed $type: ${error.message}");
      }
    }));
  }

  /// Answer incoming requests of [type] on the attached connection; removed automatically on [detach].
  @protected
  void handle(String type, LinkRequestHandler handler) {
    final connection = _connection;
    if (connection == null) return;
    connection.onRequest(type, handler);
    _handled.add(type);
  }

  /// Send a request on the attached connection and return the reply body.
  /// @throws LinkPluginUnavailableException when not available; otherwise as [LinkConnection.request].
  @protected
  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic> body = const {}, Duration? timeout, Uint8List? data]) async {
    return (await requestMessage(type, body, timeout, data)).body;
  }

  /// Like [request], but returns the whole reply, for replies that carry binary data.
  @protected
  Future<LinkMessage> requestMessage(String type, [Map<String, dynamic> body = const {}, Duration? timeout, Uint8List? data]) {
    final connection = _connection;
    if (connection == null || !isAvailable) return Future.error(LinkPluginUnavailableException(name));
    return connection.request(type, body, timeout, data);
  }

  /// Send a push on the attached connection.
  /// @throws LinkPluginUnavailableException when not available.
  @protected
  void send(String type, [Map<String, dynamic> body = const {}]) {
    final connection = _connection;
    if (connection == null || !isAvailable) throw LinkPluginUnavailableException(name);
    connection.send(type, body);
  }

  /// Run [future] without anyone awaiting it (a refresh started on attach): a failure is logged, never uncaught.
  @protected
  void runQuietly(Future<Object?> future, String what) {
    future.then((_) {}, onError: (Object error) {
      if (error is LinkException) {
        debugPrint("ionix-link: $name $what failed: ${error.message}");
      }
      else {
        debugPrint("ionix-link: $name $what failed: $error");
      }
    });
  }
}
