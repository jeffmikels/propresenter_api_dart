import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'dart:typed_data';

/// class to wrap a Websocket Message with a 'message' and 'data'
class WSMessage {
  String message = '';
  dynamic data; // can be a list, a map, or null

  WSMessage({this.message = '', this.data = const {}});

  WSMessage.fromMap(Map<String, dynamic> m) {
    message = m['message'] ?? '';
    data = m['data'];
  }

  WSMessage.fromString(String s) {
    try {
      var tmp = json.decode(s);
      message = tmp['message'] ?? '';
      data = tmp['data'];
    } catch (e) {
      message = s;
      data = null;
    }
  }

  @override
  String toString() {
    return toJsonString();
  }

  String toJsonString() {
    if (message.isNotEmpty) {
      return json.encode({'message': message, 'data': data});
    } else if (data != null) {
      return json.encode(data);
    } else {
      return '';
    }
  }
}

/// wraps a websocket connection
class WS {
  static Map<String, WS> instances = {}; // to track old sockets, we should probably not do this

  String niceName;
  bool disposed = false; // to prevent reuse of this socket
  bool _connected = false;

  String _wsUrl = '';
  WSMessage? _firstMessage; // first message to send on connection, remember this for automatic reconnections

  WebSocket? _socket;

  bool _usePing = true;
  Timer? _heartBeatTimer;
  StreamSubscription? _wsMessageListener;

  /// streams to communicate to clients of this WS connection
  final StreamController<WSMessage> _outputController = StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get messages => _outputController.stream;

  final StreamController<bool> _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;
  bool get connected => _connected;
  set connected(bool b) {
    if (b != _connected) {
      _connected = b;
      _connectionStatusController.add(b);
    }
  }

  WS(this.niceName) {
    connected = false;
    registerInstance(niceName, this);
  }

  static Future<void> registerInstance(niceName, newInstance) async {
    await WS.instances[niceName]?.dispose();
    WS.instances[niceName] = newInstance;
  }

  // command to connect to a websocket url
  void connect(String url, {WSMessage? firstMessage, bool usePing: true}) {
    _wsUrl = url;
    _firstMessage = firstMessage;
    _usePing = usePing;
    _socketStart();
  }

  // starts a listener on this websocket url
  // StreamSubscription<WSMessage> listen(Function(WSMessage) onData) {
  //   return messages.listen(onData);
  // }

  Future<void> dispose() async {
    disposed = true;
    _heartBeatTimer?.cancel();

    await Future.wait([_outputController.close(), _connectionStatusController.close()]);
    await _wsMessageListener?.cancel();
    await _socket?.close(4999, 'self');

    _socket = null;
    WS.instances.remove(niceName);
  }

  void send(WSMessage message) {
    var msg = message.toJsonString();
    print('WS $niceName: sending websocket message');
    print(msg);
    if (_socket?.readyState == WebSocket.open) {
      _socket?.add(msg);
    } else {
      _heartBeat();
    }
  }

  /// we do this manually here because the dart:io
  /// WebSocket.connect() sends headers as lowercase
  /// but some versions of propresenter need headers to be camelCase
  Future<WebSocket> buildWebSocket(server) async {
    Uri uri = Uri.parse(server);
    uri = Uri(
        scheme: uri.scheme == "wss" ? "https" : "http",
        userInfo: uri.userInfo,
        host: uri.host,
        port: uri.port,
        path: uri.path,
        query: uri.query,
        fragment: uri.fragment);

    Uint8List nonceData = Uint8List(16);
    Random random = Random();
    for (int i = 0; i < 16; i++) {
      nonceData[i] = random.nextInt(256);
    }
    var nonce = base64.encode(nonceData);

    var _httpClient = HttpClient();
    return _httpClient.openUrl("GET", uri).then((request) {
      // Setup the initial handshake.
      request.headers.add("Connection", 'Upgrade', preserveHeaderCase: true);
      request.headers.add("Upgrade", "websocket", preserveHeaderCase: true);
      request.headers.add("Sec-WebSocket-Key", nonce, preserveHeaderCase: true);
      request.headers.add("Sec-WebSocket-Version", "13", preserveHeaderCase: true);

      return request.close();
    }).then((response) {
      print(response);
      return response
          .detachSocket()
          .then<WebSocket>((socket) => WebSocket.fromUpgradedSocket(socket, serverSide: false));
    });
  }

  void _heartBeat() {
    _heartBeatTimer?.cancel(); // only one heartbeat timer at a time
    _heartBeatTimer = Timer(Duration(seconds: 3), _heartBeat);
    if (_socket == null || _socket?.readyState == WebSocket.closed) {
      connected = false;
      _socketStart(fromHeartBeat: true);
    }
  }

  void _socketStart({
    int retrySeconds = 2,
    bool fromHeartBeat = false,
    bool isAutoReconnect = false,
  }) async {
    _heartBeatTimer?.cancel();

    // we only want one socket instance, so we close the previous one
    await _socket?.close(4999, 'self');

    if (disposed) {
      print('ERROR: Websocket $niceName was disposed... not starting it again');
      return;
    }

    print('WS $niceName: attempting to connect websocket: $_wsUrl');
    try {
      // we cannot use this simple function anymore because Pro7
      // expects the headers to be CamelCase, and this function by
      // default converts all headers to lowercase. :-(
      // _socket = await WebSocket.connect(_wsUrl);

      _socket = await buildWebSocket(_wsUrl);
      connected = true;
      _heartBeat();
    } catch (e) {
      print(e);
      connected = false;
      var nextRetry = retrySeconds + 2;
      if (nextRetry > 60) {
        print('ERROR: $niceName connection kept failing. I will not try again.');
        return;
      }
      print('WS $niceName: connection failed, trying again in $nextRetry seconds: $_wsUrl');
      Timer(
        Duration(seconds: retrySeconds),
        () => _socketStart(retrySeconds: nextRetry),
      );
      return;
    }

    print('WS $niceName: Socket Created.');

    // if we make it here, the socket was created successfully
    if (_usePing) _socket?.pingInterval = Duration(seconds: 5);

    // start / restart the listener
    await _wsMessageListener?.cancel();
    _wsMessageListener = _socket?.listen(
      handler,
      onDone: () {
        _heartBeatTimer?.cancel();
        retrySeconds = 2;
        connected = false;

        if (_socket?.closeReason == 'self') {
          print('WS $niceName: I closed my websocket connection.');
          return;
        }

        print(_socket?.closeReason);
        print(_socket?.closeCode);
        print('WS $niceName: WEBSOCKET CONNECTION WAS CLOSED EXTERNALLY. TRYING AGAIN IN 2 SECONDS.');
        Timer(Duration(seconds: 2), () {
          _socketStart(isAutoReconnect: true);
        });
      },
      cancelOnError: false,
    );

    // send our first message
    if (_firstMessage != null) {
      send(_firstMessage!);
    }
  }

  void handler(dynamic data) {
    // print('WS $socketId $niceName: message received.');
    // print(data);
    var message = WSMessage.fromString(data.toString());
    _outputController.add(message);
  }
}
