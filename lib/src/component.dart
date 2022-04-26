import 'dart:async';

import 'package:propresenter_api/propresenter_api.dart';
import 'package:propresenter_api/src/event_emitter.dart';

enum ProConnectionStatus { disconnected, connecting, connected, failed }

/// this class manages a number of data streams for ProPresenter clients.
///
/// Available Streams:
/// [connectionStatus]
/// [updates]
///
/// It also emits the following events by default:
///
/// connected, connecting, disconnected, failed, update
///
/// Child classes may emit custom events with the [notify] function.
class ProConnectedComponent with ProEventEmitter {
  bool destroyed = false;
  bool get connected => status == ProConnectionStatus.connected;
  bool get connecting => status == ProConnectionStatus.connecting;
  bool get disconnected => status == ProConnectionStatus.disconnected;
  bool get failed => status == ProConnectionStatus.failed;

  ProConnectionStatus _status = ProConnectionStatus.disconnected;
  ProConnectionStatus get status => _status;
  set status(ProConnectionStatus newStatus) {
    if (_status == newStatus) return;

    _status = newStatus;
    if (_connectionStatusController.hasListener == true) _connectionStatusController.add(_status);
    switch (_status) {
      case ProConnectionStatus.connected:
        emit('connected');
        break;
      case ProConnectionStatus.connecting:
        emit('connecting');
        break;
      case ProConnectionStatus.disconnected:
        emit('disconnected');
        break;
      case ProConnectionStatus.failed:
        emit('failed');
        break;
    }
  }

  final StreamController<String> _updateController = StreamController.broadcast();
  Stream<String> get updates => _updateController.stream;

  final StreamController<ProConnectionStatus> _connectionStatusController = StreamController.broadcast();
  Stream<ProConnectionStatus> get connectionStatus => _connectionStatusController.stream;

  void notify([String eventName = 'update']) {
    emit(eventName);
    _updateController.add(eventName);
  }

  /// returns a future that completes after two seconds
  /// with the connection status
  Future<ProConnectionStatus> delayedConnectionCheck() {
    var completer = Completer<ProConnectionStatus>();
    // wait a bit to see if we are actually connected or not
    Timer(Duration(seconds: 2), () {
      if (connected == false) {
        status = ProConnectionStatus.failed;
        completer.complete(status);
      } else {
        status = ProConnectionStatus.connected;
        completer.complete(status);
      }
    });
    return completer.future;
  }

  // /// Future allows child classes to use a Future for connections
  // FutureOr connect() async {
  //   if (_connectionStatusController.hasListener != true) _connectionStatusController = StreamController.broadcast();
  //   if (_updateController.hasListener != true) _updateController = StreamController.broadcast();

  //   status = ProConnectionStatus.connecting;

  //   Timer(Duration(seconds: 1), () {
  //     if (status == ProConnectionStatus.connecting) status = ProConnectionStatus.failed;
  //   });
  // }

  // void disconnect() {
  //   status = ProConnectionStatus.disconnected;
  // }

  // void destroy() {
  //   destroyed = true;
  //   status = ProConnectionStatus.disconnected;
  //   _updateController.close();
  //   _connectionStatusController.close();
  // }
}
