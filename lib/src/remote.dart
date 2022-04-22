import 'dart:async';

import './propresenter_api_base.dart';
import 'ws.dart';
import 'helpers.dart';

// constants for determining our default desired low quality and high quality images
const SLIDE_LOWQ = 50;
const SLIDE_HIGHQ = 500;

/// the [ProRemoteClient] represents the Remote Control Websocket API.
///
/// The following data streams are exposed:
///
/// - [clockStream]
/// - [messageStream]
/// - [slideUpdates]
/// - [updates] (from the parent class)
///
/// The following events are emitted:
///
/// `clock`, `message`, `slide`, `presentation`, `update`, `action sent`, `action completed`
///
/// Additionally, an event is emitted for every ProPresenter "action"
/// (i.e. `authenticate`, `presentationSlideIndex`, etc.)
class ProRemoteClient extends ProConnectedComponent {
  /// this class might be managed by a parent combined class
  /// by keeping a reference to it here, we can access data
  /// available from the Stage Display Protocol too
  ProLegacyClient parent;

  ProSettings settings;
  String get ip => settings.host;
  int get port => settings.port;
  ProVersion get version => settings.version;
  String? get password => settings.remotePass;

  // variables to manage the websocket connection
  WS ws = WS('controlSocket');
  StreamSubscription? socketListener;
  StreamSubscription? socketConnectionListener;

  // status variables ================================

  /// true when connected and authenticated
  bool controlling = false;
  bool loading = false;

  // variables representing the state of the ProPresenter application
  ProState state = ProState();

  // backwards compatible getters
  bool get audioIsPlaying => state.audioIsPlaying;
  String? get currentAudioPath => state.currentAudioPath;
  String? get currentPresentationPath => state.currentPresentationPath;
  String? get stageMessage => state.stageMessage;

  List<ProLibraryItem> get library => state.library;
  Map<String, ProPresentation> get presentationsByPath => state.presentationsByPath;

  List<ProPlaylist> get playlists => state.playlists;
  Map<String, ProPlaylistItem> get playlistItemsByName => state.playlistItemsByName;

  List<ProPlaylist> get audioPlaylists => state.audioPlaylists;
  Map<String, ProPlaylistItem> get audioPlaylistItemsByName => state.audioPlaylistItemsByName;

  List<ProClock> get clocks => state.clocks;
  List<ProMessage> get messages => state.messages;

  int? get currentSlideIndex => state.currentSlideIndex;

  ProSlide? get currentSlide => state.currentSlide;
  ProSlide? get nextSlide => state.nextSlide;
  bool get showingFirstSlide => state.showingFirstSlide;
  bool get showingLastSlide => state.showingLastSlide;

  // variables to handle the async nature of websocket commands
  String? requestedPresentationPath;
  bool makeRequestedCurrent = false;
  Map<String, Completer> completers = {};

  /// Pro6 sometimes sends the path as a "basename" but Pro7 always sends full pathname
  /// we make sure we always use the full pathname because it is more reliable
  Map<String, String> basename2fullpath = {};

  // remember that the updateStream comes from the "Connected Component" class
  final StreamController _clockStreamController;
  Stream get clockStream => _clockStreamController.stream;

  final StreamController<bool> _messageStreamController;
  Stream<bool> get messageStream => _messageStreamController.stream;

  final StreamController<bool> _slideUpdatesStreamController;
  Stream<bool> get slideUpdates => _slideUpdatesStreamController.stream;

  Map get statusMap => {
        'currentPresentation': currentPresentation,
        'currentSlideIndex': currentSlideIndex,
        'library': library,
        'playlists': playlists,
        'clocks': clocks,
      };

  ProPresentation? get currentPresentation => state.currentPresentation;

  ProRemoteClient(this.parent, this.settings)
      : _messageStreamController = StreamController.broadcast(),
        _slideUpdatesStreamController = StreamController.broadcast(),
        _clockStreamController = StreamController.broadcast() {
    _clockStreamController.onListen = () {
      startSendingClockTimes();
    };
    _clockStreamController.onCancel = () {
      if (!_clockStreamController.hasListener) stopSendingClockTimes();
    };
  }

  void destroy() {
    _clockStreamController.close();
    _messageStreamController.close();
    _slideUpdatesStreamController.close();
    socketListener?.cancel();
    socketConnectionListener?.cancel();
    ws.dispose();
  }

  Future disconnect() async {
    status = ProConnectionStatus.disconnected;
    await socketListener?.cancel();
    await socketConnectionListener?.cancel();
    await ws.dispose();
  }

  Future<ProConnectionStatus> connect() async {
    await disconnect();
    if (ip.isEmpty || port == 0) return ProConnectionStatus.failed;

    ws = WS('controlSocket');
    controlling = false;
    status = ProConnectionStatus.connecting;
    socketListener = ws.messages.listen(handleResponse);
    socketConnectionListener = ws.connectionStatus.listen((bool b) {
      status = b ? ProConnectionStatus.connected : ProConnectionStatus.failed;
      if (b == false) controlling = false;
    });

    ws.connect(
      'ws://$ip:$port/remote',
      usePing: false,
      firstMessage: WSMessage(
        data: {
          'password': password,
          'protocol': version == ProVersion.seven ? PRO7_CONTROL_PROTOCOL : PRO6_CONTROL_PROTOCOL,
          'action': "authenticate",
        },
      ),
    );

    return delayedConnectionCheck();
  }

  /// specify '' for responseAction to ignore propresenter replies
  Future<void> _send(dynamic message, {String? responseAction, bool throwOnTimeout = false}) async {
    if (disconnected) return;
    var realMessage = WSMessage();

    if (message is Map) {
      realMessage.data = message;
    } else if (message is String) {
      realMessage = WSMessage.fromString(message);
    } else if (message is WSMessage) {
      realMessage = message;
    }

    // send the message
    ws.send(realMessage);

    // prepare for responses
    // most responses are the same 'action' as the request
    // but some of them are not, so make sure to set those
    // in the respective functions below
    var action = realMessage.data['action'];
    responseAction ??= action;
    responseAction!;

    if (responseAction != '') {
      // finish previous completers before creating a new one
      completeAction(responseAction);
      var completer = Completer();
      completers[responseAction] = completer;

      // complete anyway after some time
      // Pro7 is MUCH slower, and therefore we give Pro7 extra time
      int timeout = parent.settings.is7 ? 20 : 5;
      Timer(Duration(seconds: timeout), () {
        if (!completer.isCompleted) {
          print('COMMAND TIMEOUT: $action timed out waiting for $responseAction after $timeout seconds');
          if (throwOnTimeout) {
            completer.completeError('Pro Command Timeout: Expected $responseAction from $action');
          } else {
            completer.complete();
          }
        }
      });
      return completer.future;
    }
    return Future.value();
  }

  /// wrapper to send an 'action' to ProPresenter along with arguments
  /// set response action to '' to ignore responses or when no response is expected
  Future act(String action, {Map<String, dynamic> args = const {}, String? responseAction}) async {
    loading = true;
    print('sending $action');
    notify('action sent');
    var result = await _send({"action": action, ...args}, responseAction: responseAction);
    loading = false;
    print('completed $action');
    notify('action completed');
    return result;
  }

  /// The way this system works is that everytime a message is sent to proPresenter
  /// a "completer" is created with the name of the relevant "action"
  /// Then, whenever we get a message from ProPresenter, we "complete" that completer
  /// which allows us to specify "callbacks" for propresenter requests
  void completeAction(String action, [dynamic value]) {
    if (completers.containsKey(action)) {
      if (!completers[action]!.isCompleted) completers[action]?.complete(value); // value might be null
      completers.remove(action);
    }
  }

  void handleResponse(WSMessage message) {
    // don't print every clock update
    if (message.data['action'] != 'clockCurrentTimes') {
      print('Remote Message Handler...');
      print(message.toJsonString());
    }

    // we received data, so mark the connection as connected
    if (!connected) status = ProConnectionStatus.connected;

    // process data for this class instance
    var data = message.data;
    var action = data['action'];
    switch (action) {
      case "authenticate":
        handleAuthenticate(data);
        break;

      // this populates the library with a list of items containing path and name
      case "libraryRequest":
        handleLibraryRequest(data);
        break;

      // this populates the playlist with playlist items
      case "playlistRequestAll":
        handlePlaylistRequestAll(data);
        break;

      // is also the response for presentationRequest
      case "presentationCurrent":
        handlePresentationCurrent(data);
        break;

      case "presentationSlideIndex":
        handlePresentationSlideIndex(data);
        break;

      // returned from triggerSlideIndex
      case "presentationTriggerIndex":
        handlePresentationTriggerIndex(data);
        break;

      case 'clockRequest':
        handleClockRequest(data);
        break;

      case 'clockCurrentTimes':
        handleClockCurrentTimes(data);
        break;

      case 'clockStartStop':
        handleClockStartStop(data);
        break;

      case 'messageRequest':
        handleMessageRequest(data);
        break;

      case 'messageSend':
        handleMessageSend(data);
        break;

      case 'messageHide':
        handleMessageHide(data);
        break;

      case 'audioRequest':
        handleAudioRequest(data);
        break;

      case 'audioCurrentSong':
      case 'audioTriggered':
        handleAudioCurrentSong(data);
        break;

      case 'audioPlayPause':
        handleAudioPlayPause(data);
        break;
      case 'clearText':
      case 'clearProps':
      case 'clearVideo':
      case 'clearAnnouncements':
      case 'clearMessages':
        break;
      default:
        print('$action is not supported yet');
    }

    completeAction(action);
    notify();
    emit(action);
  }

  /* === INDIVIDUAL FUNCTIONS TO HANDLE RESPONSE DATA === */

  void handleLibraryRequest(Map<dynamic, dynamic> data) {
    state.library.clear();
    for (var item in data['library']) {
      var path = item.toString();
      state.library.add(ProLibraryItem(parent, path: path));
    }
    state.library.sort((a, b) => a.name.compareTo(b.name));
  }

  void handlePlaylistRequestAll(Map<dynamic, dynamic> data) {
    state.playlists.clear();
    for (var itemMap in data['playlistAll']) {
      var p = ProPlaylist.fromMap(parent, itemMap);
      state.playlists.add(p);
    }
    state.playlistItemsByName = buildPlaylistItemLocationMap(playlists);
  }

  Map<String, ProPlaylistItem> buildPlaylistItemLocationMap(List playlists) {
    Map<String, ProPlaylistItem> retval = {};
    for (var p in playlists) {
      if (p is ProPlaylistItem) {
        retval[p.playlistItemName] = p;
      } else if (p is ProPlaylist) {
        var map = buildPlaylistItemLocationMap(p.playlist);
        retval.addAll(map);
      }
    }
    return retval;
  }

  void handlePresentationCurrent(Map<dynamic, dynamic> data) {
    // the 'presentation' field never contains the path
    var p = ProPresentation.fromMap(this, data['presentation']);

    // if presentationPath is set, then we have received a `presentationCurrent` response
    // otherwise, we have received a `presentationRequest` response
    if (data.containsKey('presentationPath')) {
      // this was a response to a `presentationCurrent` request
      // the setter will merge with seen presentations if needed
      p.presentationPath = data['presentationPath'];
      state.currentPresentation = p;
    } else {
      // this was a response to a 'presentationRequest' request
      // meaning that we requested it with a path and should have stored that
      if (requestedPresentationPath != null) {
        p.presentationPath = requestedPresentationPath!;
        if (state.presentationsByPath.containsKey(requestedPresentationPath)) {
          state.presentationsByPath[requestedPresentationPath]!.mergePresentation(p);
        } else {
          state.presentationsByPath[requestedPresentationPath!] = p;
        }

        // ProPresenter always returns the location of the current presentation too
        // but it is buried in the 'presentation' response
        var currentPresentationPath = data['presentation']['presentationCurrentLocation'];
        var cp = state.presentationsByPath[currentPresentationPath];
        if (cp != null) {
          state.currentPresentation = cp;
        }
        loading = false;
      }
    }

    // Pro6 sometimes (like with trigger commands) sends only the basename as a partial path
    // so we store a mapping from this basename to the full path
    basename2fullpath[basename(p.presentationPath)] = p.presentationPath;
    _slideUpdatesStreamController.add(true);
    emit('presentation');
    notify();
  }

  // returned from requestCurrentIndex
  // does not include the presentationPath
  void handlePresentationSlideIndex(Map<dynamic, dynamic> data) {
    state.currentSlideIndex = int.tryParse(data['slideIndex'].toString()) ?? 0;
    _slideUpdatesStreamController.add(true);
    emit('presentation');
  }

  // returned from triggerSlideIndex
  void handlePresentationTriggerIndex(Map<dynamic, dynamic> data) {
    var isNew = false;
    var triggeredPath = data['presentationPath'];

    // on Pro6, triggeredPath is just the basename; luckily, we store those :-)
    if (basename2fullpath.containsKey(triggeredPath)) triggeredPath = basename2fullpath[triggeredPath];

    if (triggeredPath != currentPresentationPath) isNew = true;

    state.currentPresentationPath = triggeredPath;
    state.currentSlideIndex = int.tryParse(data['slideIndex'].toString()) ?? 0;

    // we now have enough information to know what the current presentation should be
    // and by this point, we should already have presentation data
    // but we do a doublecheck
    if (isNew || currentPresentation == null || currentPresentation!.slideQuality < SLIDE_HIGHQ) {
      loadPresentation(
        path: triggeredPath,
        quality: SLIDE_HIGHQ,
        doubleLoad: true,
      ).then((_) {
        print('LOADED: presentation $triggeredPath');
        // currentSlide = currentPresentation?.slideAt(currentSlideIndex); // now done with a getter
        // updateController.add(action); // the loadPresentation should trigger updates anyway
      });
    }
    _slideUpdatesStreamController.add(true);
    emit('presentation');
  }

  void handleClockRequest(Map<dynamic, dynamic> data) {
    clocks.clear();
    for (var i = 0; i < data['clockInfo'].length; i++) {
      var ci = data['clockInfo'][i];
      var c = ProClock.fromMap(parent: parent, data: ci);
      c.id = i;
      clocks.add(c);
    }
    _clockStreamController.add(true);
    emit('clock');
  }

  void handleClockCurrentTimes(Map<dynamic, dynamic> data) {
    for (var i = 0; i < (data['clockTimes']! as List).length; i++) {
      String currentTime = data['clockTimes'][i];
      if (i >= clocks.length) break;
      if (clocks[i].current != currentTime) {
        // Pro7 also sends fractional seconds ??
        clocks[i].current = currentTime.split('.').first;
        clocks[i].running = true;
      } else {
        clocks[i].running = false;
      }
      if (clocks[i].current.contains('--')) clocks[i].running = false;
    }
    _clockStreamController.add(true);
    emit('clock');
  }

  void handleClockStartStop(Map<dynamic, dynamic> data) async {
    var id = data['clockIndex'];
    if (id >= clocks.length) await act('clockRequest');
    if (id < clocks.length) {
      var clock = clocks[id];
      clock.current = data['clockTime'];
      clock.running = data['clockState'] == 1;
      _clockStreamController.add(true);
      emit('clock');
    }
  }

  void handleMessageRequest(Map<dynamic, dynamic> data) {
    messages.clear();
    for (var i = 0; i < (data['messages'] as List).length; i++) {
      var mess = data['messages']![i];
      var m = ProMessage.fromMap(i, mess);
      // if the keys contain a clock reference, fix the mapping
      for (var k in m.keys) {
        if (k.contains('H:MM:SS')) {
          var clockName = k.split(':').first;
          for (var c in clocks) {
            if (c.name == clockName) m.mapping[k] = c.duration;
          }
        }
      }
      messages.add(m);
    }
    _messageStreamController.add(true);
    emit('message');
  }

  void handleMessageSend(Map<dynamic, dynamic> data) {
    var id = data['messageIndex'];
    if (id < messages.length) messages[id].showing = true;
    _messageStreamController.add(true);
    emit('message');
  }

  void handleMessageHide(Map<dynamic, dynamic> data) {
    var id = data['messageIndex'];
    if (id < messages.length) messages[id].showing = false;
    _messageStreamController.add(true);
    emit('message');
  }

  void handleAuthenticate(Map<dynamic, dynamic> data) {
    status = (data['authenticated'] == 1) ? ProConnectionStatus.connected : ProConnectionStatus.failed;
    controlling = (data['controller'] == 1) ? true : false;
    if (connected) loadStatus();
    emit('authenticate');
  }

  void handleAudioRequest(Map<dynamic, dynamic> data) {
    audioPlaylists.clear();
    for (var itemMap in data['audioPlaylist']) {
      var p = ProPlaylist.fromMap(parent, itemMap);
      audioPlaylists.add(p);
    }
    state.audioPlaylistItemsByName = buildPlaylistItemLocationMap(audioPlaylists);
    emit('audio');
  }

  void handleAudioPlayPause(Map<dynamic, dynamic> data) {
    state.audioIsPlaying = data['audioPlayPause'] != 'Pause'; // pro7 says Playing while Pro6 says Play
    emit('audio');
  }

  void handleAudioCurrentSong(Map<dynamic, dynamic> data) {
    // the current song shows up with audioName and not a real playlist path
    state.currentAudioPath = audioPlaylistItemsByName[data['audioName']]?.playlistItemLocation;
    emit('audio');
  }

  /* === INDIVIDUAL PROPRESENTER COMMANDS == */

  /// requests all the data we need to get started and waits for
  /// the most important data to arrive
  ///
  /// will be called after authentication message is received
  void loadStatus() async {
    loading = true;
    await getLibrary();
    await getPlaylists();
    await getAudioPlaylists();
    await getCurrentPresentation(quality: SLIDE_HIGHQ, doubleLoad: true);
    await getCurrentSlideIndex();

    // no "await" on these
    getCurrentAudio();
    getMessages();
    getClocks();
    loading = false;
  }

  Future startSendingClockTimes() {
    // ProPresenter doesn't send a response for these commands
    return act('clockStartSendingCurrentTime', responseAction: '');
  }

  Future stopSendingClockTimes() {
    // ProPresenter doesn't send a response for these commands
    return act('clockStopSendingCurrentTime', responseAction: '');
  }

  Future messageToggle(int id) {
    if (id < messages.length) {
      if (messages[id].showing) {
        return messageHide(id);
      } else {
        return messageSend(id);
      }
    }
    return Future.value(false);
  }

  Future messageSend(int id) {
    if (id < messages.length) {
      var message = messages[id];
      var keys = [];
      var values = [];
      message.mapping.forEach((k, v) {
        keys.add(k);
        values.add(v);
      });
      var map = {
        'messageIndex': id,
        'messageKeys': keys,
        'messageValues': values,
      };
      return act('messageSend', args: map);
    }
    return Future.value(false);
  }

  Future messageHide(int id) {
    if (id < messages.length) return act('messageHide', args: {'messageIndex': id});
    return Future.value(false);
  }

  Future getMessages() {
    return act('messageRequest');
  }

  Future getClocks() {
    return act('clockRequest');
  }

  Future clockReset(int id) {
    if (id < clocks.length) return act('clockReset', args: {'clockIndex': id}, responseAction: 'clockResetIndex');
    return Future.value(false);
  }

  Future clockToggle(int id) {
    if (id < clocks.length) return clocks[id].running ? clockStop(id) : clockStart(id);
    return Future.value(false);
  }

  Future clockStart(int id) {
    if (id < clocks.length) return act('clockStart', args: {'clockIndex': id}, responseAction: 'clockTime');
    return Future.value(false);
  }

  Future clockStop(int id) {
    if (id < clocks.length) return act('clockStop', args: {'clockIndex': id}, responseAction: 'clockTime');
    return Future.value(false);
  }

  // {
  //   "action":"clockUpdate",
  //   "clockIndex":"1",
  //   "clockType":"0",
  //   "clockTime":"09:04:00",
  //   "clockOverrun":"false",
  //   "clockIsPM":"1",
  //   "clockName":"Countdown 2",
  //   "clockElapsedTime":"0:02:00"
  // }
  // Clocks are referenced by index. See reply from "clockRequest" action above to learn indexes.
  // Not all parameters are required for each clock type.
  // Countdown clocks only need "clockTime".
  // Elapsed Time Clocks need "clockTime" and optionally will use "clockElapsedTime" if you send it (to set the End Time).
  // You can rename a clock by optionally including the clockName.
  // Type 0 is Countdown
  // Type 1 is CountDown to Time
  // Type 2 is Elapsed Time.
  // Overrun can be modified if you choose to include that as well.
  Future clockUpdate(ProClock clock) {
    var clockData = {
      "clockIndex": clock.id,
      "clockType": clock.type.index,
      "clockTime": clock.duration,
      "clockOverrun": clock.overrun ? 'true' : 'false',
      "clockIsPM": clock.isPM ? '1' : '0',
    };
    return act('clockUpdate', args: clockData);
  }

  Future getLibrary() async {
    return act("libraryRequest");
  }

  Future getPlaylists() async {
    return act("playlistRequestAll");
  }

  /// for better user experience, we implement a doubleload feature
  /// that will first load the presentation using a low quality
  /// and then queue a request for a higher quality version
  Future getCurrentPresentation({int quality = SLIDE_HIGHQ, bool doubleLoad = true}) async {
    if (doubleLoad && quality > SLIDE_LOWQ) {
      await act("presentationCurrent", args: {'presentationSlideQuality': SLIDE_LOWQ});

      // send a second request without waiting for the response
      act("presentationCurrent", args: {'presentationSlideQuality': quality});
      return;
    }
    await act("presentationCurrent", args: {'presentationSlideQuality': quality});
  }

  Future loadPresentation({
    String? path,
    int quality = SLIDE_HIGHQ,
    bool doubleLoad = true,
  }) async {
    if (path == null) return getCurrentPresentation(quality: quality, doubleLoad: doubleLoad);

    // we set this here, because ProPresenter 6 doesn't return
    // the presentationPath if it was in the request.
    // but we need to remember it
    requestedPresentationPath = path;

    var pro6formattedPath = path.replaceAll('/', r'\/');
    var pathToSend = parent.settings.is7 ? path : pro6formattedPath;

    if (doubleLoad && quality > SLIDE_LOWQ) {
      await act('presentationRequest',
          args: {
            'presentationPath': pathToSend,
            'presentationSlideQuality': SLIDE_LOWQ,
          },
          responseAction: 'presentationCurrent');

      // we have to wait this one out because of the need to
      // clear out 'requestedPresentationPath' below
      await act('presentationRequest',
          args: {
            'presentationPath': pathToSend,
            'presentationSlideQuality': quality,
          },
          responseAction: 'presentationCurrent');
    } else {
      await act('presentationRequest',
          args: {
            'presentationPath': pathToSend,
            'presentationSlideQuality': quality,
          },
          responseAction: 'presentationCurrent');
    }

    // we are done with this request, so we clear out the variable
    requestedPresentationPath = null;
    return;
  }

  Future getCurrentSlideIndex() async {
    return act("presentationSlideIndex");
  }

  /// for immediate user feedback, we also update the current presentation
  /// in this function and don't wait for the response from ProPresenter
  Future triggerSlide({ProPresentation? presentation, int index = 0}) async {
    if (!controlling) return false;
    if (presentation == null && currentPresentation == null) return false;
    presentation ??= currentPresentation;
    state.currentPresentation = presentation;
    emit('presentation');

    // pro6 needs the path to be backslash escaped
    String pathToSend =
        parent.settings.is7 ? currentPresentationPath! : currentPresentationPath!.replaceAll('/', r'\/');
    return act("presentationTriggerIndex", args: {
      'slideIndex': parent.settings.is7 ? index.toString() : index,
      'presentationPath': pathToSend,
    });
  }

  // the triggerNext and triggerPrevious commands
  // automatically select the next and previous presentations
  // but don't automatically fire the first slide
  // and therefore, we don't get any data on the next
  // presentation or proof that it has been selected
  // therefore, we manually request data on the next/previous presentations
  Future triggerNext() async {
    if (!controlling) return false;
    if (currentPresentation == null) {
      await getCurrentPresentation();
      return triggerSlide();
    }

    var wasLastSlide = showingLastSlide;
    if (wasLastSlide) {
      loading = true;
      notify();
    }
    return act("presentationTriggerNext", responseAction: 'presentationTriggerIndex');
  }

  Future triggerPrev() async {
    if (!controlling) return false;
    if (currentPresentation == null) {
      await getCurrentPresentation();
      return triggerSlide();
    }

    var wasFirstSlide = showingFirstSlide;
    if (wasFirstSlide) {
      loading = true;
      notify();
    }
    await act("presentationTriggerPrevious", responseAction: 'presentationTriggerIndex');
    // if (wasFirstSlide) {
    //   makeRequestedCurrent = true;
    //   loading = true;
    //   notify();
    //   await loadPreviousPresentation();
    // }
    return true;
  }

  Future<bool> loadNextPresentation() async {
    if (currentPresentation == null) return false;
    // if a presentation is in a playlist, it's path will contain `:`
    var pathParts = currentPresentation!.presentationPath.split(':');
    if (pathParts.length < 2) return false;

    var docNum = int.tryParse(pathParts.removeLast()) ?? 0;
    docNum++;
    pathParts.add(docNum.toString());
    var nextPath = pathParts.join(':');

    await loadPresentation(path: nextPath);
    return true;
  }

  Future<bool> loadPreviousPresentation() async {
    if (currentPresentation == null) return false;

    // if a presentation is in a playlist, it's path will contain `:`
    var pathParts = currentPresentation!.presentationPath.split(':');
    if (pathParts.length < 2) return false;

    var docNum = int.tryParse(pathParts.removeLast()) ?? 0;
    docNum--;
    pathParts.add(docNum.toString());
    var nextPath = pathParts.join(':');
    await loadPresentation(path: nextPath);
    return true;
  }

  Future stageDisplaySendMessage([String? s]) {
    s ??= stageMessage ?? '';
    return act('stageDisplaySendMessage', args: {'stageDisplayMessage': s}, responseAction: '');
  }

  Future stageDisplayHideMessage() {
    return act('stageDisplayHideMessage', responseAction: '');
  }

  Future stageDisplaySelectLayout(int layoutId) async {
    return act('stageDisplaySetIndex', args: {'stageDisplayIndex': layoutId.toString()});
  }

  Future clearAll() async {
    return act('clearAll');
  }

  Future clearProps() async {
    return act('clearProps');
  }

  Future clearAudio() async {
    return act('clearAudio');
  }

  Future clearForeground() async {
    return act('clearText');
  }

  Future clearMessages() async {
    return act('clearMessages');
  }

  Future clearAnnouncements() async {
    return act('clearAnnouncements');
  }

  Future clearBackground() async {
    return act('clearVideo', responseAction: '');
  }

  Future clearTelestrator() async {
    return act('clearTelestrator');
  }

  // AUDIO COMMANDS

  /// get audio library items
  Future getAudioPlaylists() async {
    return act('audioRequest');
  }

  Future getCurrentAudio() async {
    return act('audioCurrentSong');
  }

  Future audioPlayPause() async {
    return act('audioPlayPause');
  }

  Future audioStartCue(String playlistLocation) {
    return act(
      "audioStartCue",
      args: {"audioChildPath": playlistLocation},
      responseAction: 'audioTriggered',
    );
  }

  // Future<bool> next() async {
  //   if (currentPresentation == null) return false;
  //   if (currentSlideIndex == null) return false;
  //   var nextIndex = currentSlideIndex + 1;
  //   return triggerSlide(index: nextIndex);
  // }

  // Future<bool> prev({Function callback}) async {
  //   if (currentPresentation == null) return false;
  //   if (currentSlideIndex == null) return false;
  //   var nextIndex = currentSlideIndex - 1;
  //   if (nextIndex < 0) nextIndex = 0;
  //   return triggerSlide(index: nextIndex);
  // }
}
