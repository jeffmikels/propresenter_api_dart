import 'dart:async';

import './propresenter_api_base.dart';
import './ws.dart';
import './helpers.dart';

/// listens to ProPresenter as a stage display client.
///
/// Unlike the [ProRemoteClient], this class has no need
/// to access anything from the parent propresenter class.
///
/// The following streams are emitted from this class:
///
/// - [timerStream] -- for updated clocks/timers
/// - [sysStream] -- for updated system time
/// - [slideStream] -- for updated slide data (current, next, text, notes)
/// - [messageStream] -- for updated stage display messages
class ProSDClient extends ProConnectedComponent {
  ProSettings settings;

  String get ip => settings.ip;
  int get port => settings.port;
  ProVersion get version => settings.version;
  String? get password => settings.sdPass;

  bool active = false;

  String message = '';
  TimeOfDay systemTime = TimeOfDay.now();
  Map<String, ProTimer> timers = {};
  Map<String, ProSDSlide> seenSlides = {};

  // it's useful to remember the "last" slide so that widgets can animate transitions
  ProSDSlide last;
  ProSDSlide current;
  ProSDSlide next;

  List<ProSDLayout> layouts = [];

  WS ws = WS('sdSocket');
  StreamSubscription? socketListener;
  StreamSubscription? socketStatusListener;

  StreamController _timerStreamController = StreamController.broadcast();
  StreamController _sysStreamController = StreamController.broadcast();
  StreamController _slideStreamController = StreamController.broadcast();
  StreamController<String> _messageStreamController = StreamController.broadcast();

  Stream get timerStream => _timerStreamController.stream;
  Stream get sysStream => _sysStreamController.stream;
  Stream get slideStream => _slideStreamController.stream;
  Stream<String> get messageStream => _messageStreamController.stream;

  Map get statusMap => {
        'system_time': systemTime,
        'timers': timers,
        'slides': {'current': current, 'next': next},
        'connected': connected,
        'active': active,
        'message': message,
      };

  ProSDClient(this.settings)
      : last = ProSDSlide(settings),
        current = ProSDSlide(settings),
        next = ProSDSlide(settings) {
    _timerStreamController = StreamController.broadcast();
    _sysStreamController = StreamController.broadcast();
    _slideStreamController = StreamController.broadcast();
    _messageStreamController = StreamController.broadcast();
    timers = {};
    layouts = [];
    message = '';
  }

  void destroy() {
    _timerStreamController.close();
    _sysStreamController.close();
    _slideStreamController.close();
    _messageStreamController.close();
    socketStatusListener?.cancel();
    socketListener?.cancel();
    ws.dispose();
  }

  Future disconnect() async {
    status = ProConnectionStatus.disconnected;
    await socketStatusListener?.cancel();
    await socketListener?.cancel();
    await ws.dispose();
  }

  Future<ProConnectionStatus> connect() async {
    // destroy the socket and the listeners if they exist
    disconnect();

    if (ip.isEmpty || port == 0) return ProConnectionStatus.failed;

    status = ProConnectionStatus.connecting;

    ws = WS('sdSocket');
    socketListener = ws.messages.listen((msg) => messageHandler(msg.data));
    socketStatusListener = ws.connectionStatus.listen((bool b) {
      status = b ? ProConnectionStatus.connected : ProConnectionStatus.failed;
    });

    // connect and then immediately send a first message
    ws.connect(
      'ws://$ip:$port/stagedisplay',
      usePing: false,
      firstMessage: WSMessage(data: {
        'pwd': password,
        'ptl': version == ProVersion.seven ? PRO7_SD_PROTOCOL : PRO6_SD_PROTOCOL,
        'acn': "ath",
      }),
    );

    return delayedConnectionCheck();
  }

  void messageHandler(Map<String, dynamic> data) {
    // update the connection status if needed
    status = ProConnectionStatus.connected;

    var newdata = {}; // for debug purposes really
    switch (data['acn']) {
      case 'asl':
        // all stage layouts
        layouts.clear();
        var index = 0;
        for (var layout in data['ary']) {
          // add layout data to layouts array
          var l = ProSDLayout.fromMap(index, layout);
          layouts.add(l);
          index++;
          messageHandler(layout);
        }
        break;
      case 'sl':
        // single stage layout
        // we only care about the slides and timers
        // we don't care about layout or colors
        for (var frame in data['fme']) {
          if (frame['typ'] == 7) {
            var uid = frame['uid'];
            if (!timers.containsKey(uid)) timers[uid] = ProTimer.fromMap(data: frame);
            if (frame['nme'].isNotEmpty) timers[uid]?.name = frame['nme'];
          }
        }
        break;
      case "ath":
        //{"acn":"ath","ath":true/false,"err":""}
        if (data['ath']) {
          print("ProPresenter Listener is Connected");
          active = true;
          status = ProConnectionStatus.connected;
          newdata = {'type': "authentication", 'data': true};
        } else {
          status = ProConnectionStatus.failed;
          active = false;
          newdata = {'type': "authentication", 'data': false};
        }
        getAllLayouts();
        break;
      case 'vid':
        if (!data['txt'].contains('--')) {
          timers['vid'] = ProTimer.fromMap(data: data);
          newdata = {'type': "timer", data: timers['vid']};
          _timerStreamController.add(timers['vid']);
        }
        break;
      case "tmr":
        // { "acn": "tmr", "uid": uuid, "txt": "HH:MM:SS"}
        if (!data['txt'].contains('--')) {
          var uid = data['uid'];
          if (!timers.containsKey(uid)) {
            timers[uid] = ProTimer.fromMap(data: data);
          } else {
            timers[uid]?.text = data['txt'];
          }
          newdata = {'type': "timer", data: timers[uid]};
          _timerStreamController.add(timers[uid]);
        }
        break;
      case 'msg':
        var txt = data['txt'];
        message = txt;
        _messageStreamController.add(message);
        break;
      case "sys":
        // Pro6 sends this
        // { "acn": "sys", "txt": " 11:17 AM" }

        // Pro7 sends this
        // { "acn": "sys", "txt": "1626208236" }
        var txt = data['txt'];

        if (settings.is7) {
          systemTime = TimeOfDay.fromTimestamp((int.tryParse(txt) ?? 0) * 1000);
        } else {
          systemTime = TimeOfDay.fromTimestring(txt);
        }
        newdata = {'type': "systime", 'data': systemTime};
        // _sysStreamController.add(systemTime);
        _timerStreamController.add('update');
        break;
      case "fv":
        // we expect a list of 4 items in the 'ary' field identified by their 'acn' field
        // cs: current slide
        // csn: current slide notes
        // ns: next slide
        // nsn: next slide notes
        var newCurrent = ProSDSlide(settings);
        var newNext = ProSDSlide(settings);
        for (var blob in data['ary']) {
          switch (blob['acn']) {
            case "cs":
              newCurrent.uid = blob['uid'];
              newCurrent.text = blob['txt'];
              break;
            case "csn":
              newCurrent.notes = blob['txt'];
              break;
            case "ns":
              newNext.uid = blob['uid'];
              newNext.text = blob['txt'];
              break;
            case "nsn":
              newNext.notes = blob['txt'];
              break;
          }
        }

        // save these new slides into the slide memory bank
        if (!seenSlides.containsKey(newCurrent.uid)) seenSlides[newCurrent.uid] = newCurrent;
        if (!seenSlides.containsKey(newNext.uid)) seenSlides[newNext.uid] = newNext;

        // merge new data with existing data
        current = seenSlides[newCurrent.uid]!
          ..text = newCurrent.text
          ..notes = newCurrent.notes;
        next = seenSlides[newNext.uid]!
          ..text = newNext.text
          ..notes = newNext.notes;

        newdata = {
          'type': "slides",
          'data': {'current': current, 'next': next}
        };
        _slideStreamController.add({'current': current, 'next': next});
    }
    print(newdata);
    emit(data['acn']);
    notify();
  }

  void getAllLayouts() {
    var msg = WSMessage(data: {"acn": "asl"});
    send(msg);
  }

  void send(WSMessage message) async {
    if (disconnected) return;
    await connect();
    if (disconnected) return;
    ws.send(message);
  }
}

/// the SD API only sends a limited amount of slide data
class ProSDSlide {
  // needed for determining what kind of images to load
  ProSettings settings;
  late final ProSlideImage image;

  late final String _uid;
  String get uid => _uid;
  set uid(String u) {
    _uid = u;
    image = ProSlideImage.fromUrl(sdImageUrl);
  }

  String notes = '';
  String text = '';
  String get baseUrl => 'http://${settings.ip}:${settings.port}';
  String get sdImageUrl => '$baseUrl/stage/image/$uid';
  String get sdImageBasename => '$uid.jpg';

  /// stage display api sends slide data in multiple separate
  /// objects. One will send uid and text, but another will send
  /// the notes data. Since we don't know which comes firest, we
  /// use an empty constructor, and assign the values later.
  ProSDSlide(this.settings);
}

/// [ProSDLayout] describes a Stage Display layout
class ProSDLayout {
  int id;
  String uid = '';
  String name = '';

  ProSDLayout({required this.id, this.uid = '', this.name = ''});
  ProSDLayout.fromMap(this.id, Map<String, dynamic> data) {
    uid = data['uid'] ?? '';
    name = data['nme'] ?? '';
  }
}
