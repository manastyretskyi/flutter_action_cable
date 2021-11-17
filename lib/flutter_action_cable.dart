library flutter_action_cable;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_action_cable/connection_monitor.dart';
import 'package:meta/meta.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class MessageTypes {
  static const String welcome = "welcome";
  static const String disconnect = "disconnect";
  static const String ping = "ping";
  static const String confirmation = "confirm_subscription";
  static const String rejection = "reject_subscription";
}

class ActionCable {
  final Uri _url;

  late WebSocketChannel _webSocketChannel;

  late ConnectionMonitor _monitor;
  Set<ChannelSubscription> _subscriptions = {};
  bool _connected = false;
  Completer? _connectionCompleter;

  ActionCable(Uri url) : this._url = url {
    _monitor = ConnectionMonitor(this);
  }

  bool get connected => _connected;

  void subscribe(ChannelSubscription subscription) {
    subscription._consumer = this;
    if (_subscriptions.length == 0) open();

    _subscriptions.add(subscription);
    sendCommand(subscription, "subscribe");
  }

  void remove(ChannelSubscription subscription) {
    forget(subscription);
    if (findAll(subscription.identifier).isNotEmpty) {
      sendCommand(subscription, "unsubscribe");
    }
  }

  void open() {
    if (!connected) {
      _connect();
      _monitor.start();
    }
  }

  void close({allowReconect = true}) {
    if (!allowReconect) _monitor.stop();
    if (connected) {
      _webSocketChannel.sink.close();

      _monitor.start();
    }
  }

  void reopen() {
    if (connected) {
      close();
    } else {
      open();
    }
  }

  Future<void> ensureConnected() async {
    _connectionCompleter ??= Completer();

    await _connectionCompleter!.future;
  }

  List<ChannelSubscription> reject(identifier) {
    return findAll(identifier).map<ChannelSubscription>((subscription) {
      forget(subscription);
      subscription._dispatch("rejected");
      return subscription;
    }).toList();
  }

  void forget(subscription) {
    _subscriptions.remove(subscription);
    if (_subscriptions.length == 0) close(allowReconect: false);
  }

  List<ChannelSubscription> findAll(String identifier) {
    identifier = _parseChannelId(identifier);
    return _subscriptions.where((s) => s.identifier == identifier).toList();
  }

  void reload() {
    _subscriptions
        .map((subscription) => sendCommand(subscription, "subscribe"));
  }

  void notifyAll(String callbackName, [Map? args]) {
    for (var subscription in _subscriptions) {
      subscription._dispatch(callbackName, args);
    }
  }

  Future<void> sendCommand(
      ChannelSubscription subscription, String command) async {
    await send({
      'command': command,
      'identifier': subscription.identifier,
    });
  }

  void _onDone() {
    _connected = false;
    _monitor.recordDisconnect();
    _connectionCompleter = null;
    return notifyAll("disconnected");
  }

  void _onEvent(event) {
    var data = json.decode(event);
    var identifier = data['identifier'];
    var message = data['message'];
    var reason = data['reason'];
    var type = data['type'];
    var reconnect = data['reconnect'];

    switch (type) {
      case MessageTypes.welcome:
        _monitor.recordConnect();
        _connectionCompleter?.complete(true);
        reload();
        break;
      case MessageTypes.disconnect:
        print("Disconnecting. Reason: $reason");
        close(allowReconect: reconnect);
        break;
      case MessageTypes.ping:
        _monitor.recordPing();
        break;
      case MessageTypes.confirmation:
        for (var subscription in findAll(identifier)) {
          subscription._dispatch("connected");
        }
        break;
      case MessageTypes.rejection:
        reject(identifier);
        break;
      default:
        for (var subscription in findAll(identifier)) {
          subscription._dispatch("received", message);
        }
    }
  }

  Future<void> send(Map<String, dynamic> data) async {
    await ensureConnected();

    _webSocketChannel.sink.add(json.encode(data));
  }

  void dispose() {
    _webSocketChannel.sink.close();
    _monitor.dispose();
  }

  void _connect() {
    _webSocketChannel = WebSocketChannel.connect(_url)
      ..stream.listen(_onEvent, onDone: _onDone);
    _connected = true;
  }
}

abstract class ChannelSubscription {
  late ActionCable _consumer;
  late String identifier;

  bool? _connected;

  ChannelSubscription([Map? params]) {
    identifier = _encodeChannelId(channelName, params);
  }

  Future<void> perform(String action, Map data) async {
    data['action'] ??= action;

    await send(data);
  }

  Future<void> send(data) async {
    await _consumer.send({
      'command': "message",
      "identifier": identifier,
      'data': json.encode(data),
    });
  }

  void unsubscribe() {
    _consumer.remove(this);
  }

  void _dispatch(String callbackName, [Map? params]) {
    if (callbackName == 'connected')
      connected(params);
    else if (callbackName == 'disconnected')
      disconnected(params);
    else
      onAction(callbackName, params ?? {});
  }

  String get channelName;

  void onAction(String action, Map params);

  @mustCallSuper
  void connected(Map? params) {
    _connected = true;
  }

  @mustCallSuper
  void disconnected(Map? params) {
    _connected = false;
  }
}

String _encodeChannelId(String channelName, Map? channelParams) {
  Map channelId = channelParams == null ? {} : Map.from(channelParams);
  channelId['channel'] ??= channelName;

  final orderedMap = SplayTreeMap.from(channelId);
  return jsonEncode(orderedMap);
}

String _parseChannelId(String channelId) {
  return jsonEncode(SplayTreeMap.from(jsonDecode(channelId)));
}
