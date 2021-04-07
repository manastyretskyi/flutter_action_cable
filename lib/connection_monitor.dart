import 'dart:async';

import 'package:flutter_action_cable/flutter_action_cable.dart';

int secondsSince(DateTime time) {
  return DateTime.now().difference(time).inSeconds;
}

class ConnectionMonitor {
  final ActionCable connection;
  int reconnectAttempts = 0;
  DateTime startedAt;
  DateTime stoppedAt;
  DateTime disconnectedAt;
  DateTime pingedAt;
  Timer pollTimer;
  static int staleThreshold = 6;

  ConnectionMonitor(this.connection);

  void start() {
    if (!isRunning) {
      this.startedAt = DateTime.now();
      stoppedAt = null;
      startPolling();
    }
  }

  void stop() {
    if (isRunning) {
      stoppedAt = DateTime.now();
      stopPolling();
    }
  }

  bool get isRunning {
    return startedAt != null && stoppedAt == null;
  }

  void recordPing() {
    pingedAt = DateTime.now();
  }

  void recordConnect() {
    reconnectAttempts = 0;
    recordPing();
    disconnectedAt = null;
  }

  void recordDisconnect() {
    disconnectedAt = DateTime.now();
  }

  void startPolling() {
    stopPolling();
    poll();
  }

  void stopPolling() {
    pollTimer?.cancel();
  }

  void poll() {
    pollTimer = Timer(getPollInterval, () {
      reconnectIfStale();
      poll();
    });
  }

  Duration get getPollInterval {
    var duration = 1 * reconnectAttempts;
    duration = duration > 30 ? 30 : duration;
    duration = duration <= 0 ? 1 : duration;

    return Duration(seconds: duration);
  }

  void reconnectIfStale() {
    if (connectionIsStale) {
      reconnectAttempts++;

      if (!disconnectedRecently) {
        connection.reopen();
      }
    }
  }

  bool get connectionIsStale {
    return secondsSince(pingedAt ?? startedAt) > staleThreshold;
  }

  bool get disconnectedRecently {
    return disconnectedAt != null &&
        (secondsSince(disconnectedAt) < staleThreshold);
  }

  void dispose() {
    stopPolling();
  }
}
