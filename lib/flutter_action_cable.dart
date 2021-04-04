library flutter_action_cable;

import 'dart:collection';
import 'dart:convert';

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

  WebSocketChannel _webSocketChannel;

  Set<ChannelSubscription> _subscriptions;

  ActionCable(Uri url) : this._url = url {
    _connect();
    _subscriptions = {};
  }

  void subscribe(ChannelSubscription subscription) {
    subscription._consumer = this;
    _subscriptions.add(subscription);
    sendCommand(subscription, "subscribe");
  }

  void remove(ChannelSubscription subscription) {
    forget(subscription);
    if (findAll(subscription.identifier).isNotEmpty) {
      sendCommand(subscription, "unsubscribe");
    }
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
  }

  List<ChannelSubscription> findAll(String identifier) {
    identifier = _parseChannelId(identifier);
    return _subscriptions.where((s) => s.identifier == identifier).toList();
  }

  void reload() {
    _subscriptions
        .map((subscription) => sendCommand(subscription, "subscribe"));
  }

  void notifyAll(String callbackName, [Map args]) {
    for (var subscription in _subscriptions) {
      subscription._dispatch(callbackName, args);
    }
  }

  void sendCommand(ChannelSubscription subscription, String command) {
    send({
      'command': command,
      'identifier': subscription.identifier,
    });
  }

  void _onDone() {
    return notifyAll("disconnected");
  }

  void _onEvent(event) {
    var data = json.decode(event);
    var identifier = data['identifier'];
    var message = data['message'];
    var reason = data['reason'];
    var type = data['type'];

    switch (type) {
      case MessageTypes.welcome:
        reload();
        break;
      case MessageTypes.disconnect:
        print("Disconnecting. Reason: $reason");
        _webSocketChannel.sink.close();
        break;
      case MessageTypes.ping:
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

  void send(Map<String, dynamic> data) {
    return _webSocketChannel.sink.add(json.encode(data));
  }

  void dispose() {
    _webSocketChannel.sink.close();
  }

  void _connect() {
    _webSocketChannel = WebSocketChannel.connect(_url)
      ..stream.listen(_onEvent, onDone: _onDone);
  }
}

abstract class ChannelSubscription {
  ActionCable _consumer;
  String identifier;

  bool _connected;

  ChannelSubscription([Map params]) {
    identifier = _encodeChannelId(channelName, params);
  }

  void perform(String action, Map data) {
    data['action'] ??= action;

    send(data);
  }

  void send(data) {
    assert(_connected);

    _consumer.send({
      'command': "message",
      "identifier": identifier,
      'data': json.encode(data),
    });
  }

  void unsubscribe() {
    _consumer.remove(this);
  }

  void _dispatch(String callbackName, [Map params]) {
    if (callbackName == 'connected')
      connected(params);
    else if (callbackName == 'disconnected')
      disconnected(params);
    else
      onAction(callbackName, params);
  }

  String get channelName;

  void onAction(String action, Map params);

  @mustCallSuper
  void connected(Map params) {
    _connected = true;
  }

  @mustCallSuper
  void disconnected(Map params) {
    _connected = false;
  }
}

String _encodeChannelId(String channelName, Map channelParams) {
  Map channelId = channelParams == null ? {} : Map.from(channelParams);
  channelId['channel'] ??= channelName;

  final orderedMap = SplayTreeMap.from(channelId);
  return jsonEncode(orderedMap);
}

String _parseChannelId(String channelId) {
  return jsonEncode(SplayTreeMap.from(jsonDecode(channelId)));
}
