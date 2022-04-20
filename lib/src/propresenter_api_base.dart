import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:image/image.dart' as imglib;

import 'cache.dart';
import 'event_emitter.dart';

import 'helpers.dart';

import 'api_v1.dart';
import 'sd.dart';
import 'remote.dart';
import 'component.dart';

export 'api_v1.dart';
export 'sd.dart';
export 'remote.dart';
export 'component.dart';

// TODO: ProPresenter messages are often inconsistent with their types
// doublecheck this throughout
// also fix the image reloading that happens on android when a new presentation is loaded
// if we have an image, only replace it with one of the same quality or better

const PRO6_SD_PROTOCOL = 610;
const PRO6_CONTROL_PROTOCOL = 600;

const PRO7_SD_PROTOCOL = 610;
const PRO7_CONTROL_PROTOCOL = 701;

enum ConnectionStatus { disconnected, connecting, connected, failed }
enum ProVersion { six, seven, seven8, seven9 }

/// [ProSettings] contains all the data needed to connect to a ProPresenter instance
/// over one or more of the API methods.
class ProSettings {
  ProVersion version = ProVersion.seven9;
  String ip;
  int port;

  String? remotePass;
  String? sdPass;

  bool get is7 => version.index >= ProVersion.seven.index;
  bool get hasNetworkLink => version.index >= ProVersion.seven8.index;
  bool get hasAPI => version.index >= ProVersion.seven9.index;

  ProSettings({this.version = ProVersion.seven9, required this.ip, required this.port, this.remotePass, this.sdPass});
}

/// contains all the data exposed by the various API methods
///
/// Will emit the following events:
///
/// - update (for all updates)
/// - presentation (includes slide updates)
/// - clock
/// - message
/// - playlist
/// - library
/// - audio
class ProState with EventEmitter {
  bool audioIsPlaying = false;

  List<ProClock> clocks = [];
  List<ProMessage> messages = [];
  List<ProPlaylist> playlists = [];
  List<ProPlaylist> audioPlaylists = [];

  // TODO: pro7 has multiple libraries
  List<ProLibraryItem> library = [];

  // mappings to make things easier to find
  Map<String, ProPlaylist> playlistsByPath = {};
  Map<String, ProPlaylist> audioPlaylistsByPath = {};
  Map<String, ProPresentation> presentationsByPath = {};
  Map<String, ProPlaylistItem> playlistItemsByName = {};
  Map<String, ProPlaylistItem> audioPlaylistItemsByName = {};
  Map<String, ProClock> clocksById = {};

  /// when it comes to paths, we want to keep all possible paths to things
  /// In ProPresenter, a path can be 0:0.0 (first playlist, first playlist item, first slide)
  /// Or a path can be a full path name to a presentation.
  String? _currentPlaylistPath;
  String? _currentAudioPlaylistPath;
  String? _currentPresentationPath;
  String? _currentAudioPath;

  int? _currentSlideIndex;

  String? stageMessage;

  // getters
  String? get currentPlaylistPath => _currentPlaylistPath;
  String? get currentAudioPlaylistPath => _currentAudioPlaylistPath;
  String? get currentPresentationPath => _currentPresentationPath;
  String? get currentAudioPath => _currentAudioPath;
  int? get currentSlideIndex => _currentSlideIndex;
  ProPlaylist? get currentPlaylist => _currentPlaylistPath == null ? null : playlistsByPath[_currentPlaylistPath];
  ProPlaylist? get currentAudioPlaylist =>
      _currentAudioPlaylistPath == null ? null : audioPlaylistsByPath[_currentAudioPlaylistPath];
  ProPresentation? get currentPresentation =>
      _currentPresentationPath == null ? null : presentationsByPath[_currentPresentationPath];

  // information on the currently showing slides
  ProSlide? get currentSlide =>
      _currentSlideIndex == null ? null : currentPresentation?.slideAt(_currentSlideIndex! + 1);
  ProSlide? get nextSlide => _currentSlideIndex == null ? null : currentPresentation?.slideAt(_currentSlideIndex! + 1);
  bool get showingFirstSlide => currentSlide == currentPresentation?.slides.first;
  bool get showingLastSlide => currentSlide == currentPresentation?.slides.last;

  // setters that will emit events
  set currentPresentation(ProPresentation? p) {
    if (p == null) _currentPresentationPath = null;
    if (p!.presentationPath.isEmpty) return;

    if (presentationsByPath.containsKey(p.presentationPath)) {
      presentationsByPath[p.presentationPath]!.mergePresentation(p);
    } else {
      presentationsByPath[p.presentationPath] = p;
    }

    _currentPresentationPath = p.presentationPath;
    updateWith('presentation');
  }

  set currentPresentationPath(String? p) {
    if (p == _currentPresentationPath) return;
    _currentPresentationPath = p;
    updateWith('presentation');
  }

  set currentSlideIndex(int? i) {
    if (i == _currentSlideIndex) return;
    _currentSlideIndex = i;
    updateWith('presentation');
  }

  set currentAudioPath(String? p) {
    if (p == _currentAudioPath) return;
    _currentAudioPath = p;
    updateWith('audio');
  }

  /// emits an event by name and an 'update' event
  void updateWith(String s) {
    emit(s);
    emit('update');
  }
}

// represents the data reported from an mDNS query
class ProInstance {
  final String name;
  final String ip;
  final int port;
  final ProVersion version;

  int get versionNumber => version.index + 6;
  String get id => "$ip:$port (Pro $versionNumber)";

  @override
  operator ==(other) => other is ProInstance && other.id == id;

  @override
  int get hashCode => id.hashCode;

  // FUNCTIONS FOR mDNS auto discovery
  static Future<List<Map<String, dynamic>>> _getRecords(MDnsClient client, String name) async {
    print('Searching for ptr, srv, ip records using name: $name');
    List<Map<String, dynamic>> retval = [];

    // get all the relevant ptr instances
    await for (final PtrResourceRecord ptr
        in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(name), timeout: Duration(seconds: 1))) {
      // Use the domainName from the PTR record to get the SRV record,
      // which will have the port and local hostname.
      // Note that duplicate messages may come through, especially if any
      // other mDNS queries are running elsewhere on the machine.
      var record = <String, dynamic>{'ptr': ptr};

      // for each domain name, we want the server and the ip address
      var srv = await client
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName), timeout: Duration(seconds: 1))
          .first;
      final String bundleId = ptr.domainName; //.substring(0, ptr.domainName.indexOf('@'));
      print('mDNS server found at ${srv.target}:${srv.port} for "$bundleId".');

      var ip = await client
          .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: Duration(seconds: 1))
          .first;
      print('mDNS server found at ${srv.target}:${srv.port} for "$bundleId".');

      record['srv'] = srv;
      record['ip'] = ip;
      retval.add(record);

      // await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
      //     ResourceRecordQuery.service(ptr.domainName),
      //     timeout: Duration(seconds: 1))) {
      //   // Domain name will be something like "io.flutter.example@some-iphone.local._dartobservatory._tcp.local"
      //   final String bundleId = ptr.domainName; //.substring(0, ptr.domainName.indexOf('@'));
      //   print('mDNS server found at ${srv.target}:${srv.port} for "$bundleId".');
      //   record['srv'] = srv;
      // }
    }
    return retval;
  }

  static Stream<Map<String, dynamic>> _getRecordStream(MDnsClient client, String name) {
    print('Searching for ptr, srv, ip records using name: $name');

    StreamSubscription? ptrsub;
    StreamSubscription? srvsub;
    StreamSubscription? ipsub;

    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>(
      onCancel: () {
        ipsub?.cancel();
        srvsub?.cancel();
        ptrsub?.cancel();
        controller.close();
        client.stop();
      },
    );

    // start client lookup
    var srvPtr = ResourceRecordQuery.serverPointer(name);
    ptrsub = client.lookup<PtrResourceRecord>(srvPtr, timeout: Duration(seconds: 2)).listen(
      (ptr) {
        // Use the domainName from the PTR record to get the SRV record,
        // which will have the port and local hostname.
        // Note that duplicate messages may come through, especially if any
        // other mDNS queries are running elsewhere on the machine.
        // for each domain name, we want the server and the ip address
        var domainService = ResourceRecordQuery.service(ptr.domainName);
        srvsub = client.lookup<SrvResourceRecord>(domainService, timeout: Duration(seconds: 2)).listen(
          (srv) {
            print('mDNS server found at ${srv.target}:${srv.port} for "${ptr.domainName}".');
            ipsub = client
                .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target),
                    timeout: Duration(seconds: 2))
                .listen(
              (ip) {
                if (!controller.isClosed) {
                  controller.add(
                    <String, dynamic>{
                      'ptr': ptr,
                      'srv': srv,
                      'ip': ip,
                    },
                  );
                }
              },
            );
          },
        );
      },
    );
    return controller.stream;
  }

  static Future<Stream<ProInstance>> discover({Duration timeout: const Duration(seconds: 5)}) async {
    print('discover');

    List<StreamSubscription> subs = [];
    MDnsClient? client;

    final controller = StreamController<ProInstance>();
    controller.onCancel = () {
      for (var sub in subs) {
        sub.cancel();
      }
      controller.close();
      client?.stop();
    };

    // this longer installation allows us to set reusePort to false which if not set
    // causes weird errors on Android for some reason
    client =
        MDnsClient(rawDatagramSocketFactory: (dynamic host, int port, {bool? reuseAddress, bool? reusePort, int? ttl}) {
      return RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl ?? 1);
    });
    await client.start();
    var pro6name = '_pro6proremote._tcp.local';
    var pro7name = '_pro7proremote._tcp.local';

    for (var name in [pro6name, pro7name]) {
      print(name);
      var version = name == pro6name ? ProVersion.six : ProVersion.seven;

      subs.add(_getRecordStream(client, name).listen((record) {
        var srv = record['srv'] as SrvResourceRecord;
        var ip = record['ip'] as IPAddressResourceRecord;
        // var ptr = record['ptr'] as PtrResourceRecord;
        var instance = ProInstance(srv.target, ip.address.address, srv.port, version);
        if (!controller.isClosed) controller.add(instance);
      }));
    }
    Future.delayed(timeout).then((_) {
      for (var sub in subs) {
        sub.cancel();
      }
      client?.stop();
      controller.close();
    });
    return controller.stream;
  }

  ProInstance(this.name, this.ip, this.port, this.version);
}

/// the [ProLegacyClient] class wraps and combines the two Websocket APIs
class ProLegacyClient extends ProConnectedComponent {
  late ProSDClient? sd;
  late ProRemoteClient? remote;

  ProSettings settings;
  ProState data = ProState();

  StreamSubscription? _sdConnectionListener;
  StreamSubscription? _remoteConnectionListener;

  @override
  bool get connected => sd?.connected == true && remote?.connected == true;

  String get imageBaseUrl => 'http://${settings.ip}:${settings.port}';

  ProLegacyClient(this.settings);

  void connectionHandler(ProConnectionStatus s) {
    status = s;
  }

  Future connect() async {
    await disconnect();
    if (settings.remotePass != null) {
      // PRO PRESENTER REMOTE CLIENT
      remote = ProRemoteClient(this, settings);
      _remoteConnectionListener = remote!.connectionStatus.listen(connectionHandler);
    }

    // PRO PRESENTER STAGE DISPLAY CLIENT
    if (settings.sdPass != null) {
      sd = ProSDClient(settings);
      _sdConnectionListener = sd!.connectionStatus.listen(connectionHandler);
    }
    var futures = [sd?.connect(), remote?.connect()];

    // unwrap and wait for the futures to complete
    return Future.wait(futures.where((e) => e != null).map((e) => e!));
  }

  Future disconnect() async {
    await sd?.disconnect();
    await remote?.disconnect();
    await _remoteConnectionListener?.cancel();
    await _sdConnectionListener?.cancel();
  }
}

/// Represents the data used for a slide image that may come from
/// a url or a B64 encoded String. The SD api passes a UID with a slide
/// that can be used to generate a url to a full resolution version
/// of the slide image. The Remote api passes the slide data as a
/// Base 64 encoded string
class ProSlideImage {
  List<int> slideImageBytes = [];

  // requested slide quality is stored so we can compare quality values
  int quality = 0;

  final StreamController<List<int>> _sc = StreamController();

  /// Will return a stream of bytes representing JPG encoded image of this slide.
  /// The first set of bytes will be the image from local cache if it exists, and
  /// when the network request returns, it will be sent as a second set of bytes.
  /// ProPresenter version 6 yields JPG bytes, but 7+ yields TIFF encoded images
  /// that we transcode to JPG in memory.
  Stream<List<int>> get stream => _sc.stream;

  /// Use this Constructor when you have the UID / URL of a slide image.
  /// This is sent with the Stage Display protocol.
  ProSlideImage.fromUrl(String url, {version = ProVersion.six}) {
    Cache.getBytesCachedFirst(Uri.parse(url)).map((List<int> bytes) {
      late imglib.Decoder decoder;
      if (version.index > ProVersion.six.index) {
        decoder = imglib.TiffDecoder();
      } else {
        decoder = imglib.JpegDecoder();
      }
      var decoded = decoder.decodeImage(bytes);
      if (decoded != null) {
        slideImageBytes = imglib.encodeJpg(decoded, quality: 70);
        quality = decoded.width;
      } else {
        return bytes;
      }
      return slideImageBytes;
    }).pipe(_sc);
  }

  /// Use this constructor when you have the Base 64 encoded slide image.
  /// This is sent with the Remote Control protocol
  ProSlideImage.fromBase64(String encoded, this.quality) {
    updateImage(encoded, quality: quality);
  }

  // decoding large images is expensive, keep this async
  void updateImage(String slideImageEncoded, {int? quality}) async {
    if (slideImageEncoded.isNotEmpty) slideImageBytes = base64Decode(slideImageEncoded);
    if (slideImageBytes.isNotEmpty) {
      // compute the quality value if needed
      if (quality == null) {
        var decoder = imglib.JpegDecoder();
        var decoded = decoder.decodeImage(slideImageBytes);
        if (decoded != null) {
          quality = decoded.width;
        }
      } else {
        this.quality = quality;
      }
      _sc.add(slideImageBytes);
    }
  }
}

/// The Stage Display protocol is different enough, that it maintains its own
/// [ProSDSlide] class.
class ProSlide {
  // metadata related to class objects
  ProSlideGroup group;
  ProPresentation get presentation => group.presentation;
  late ProSlideImage image;

  // ProPresenter Slide Metadata
  bool slideEnabled = true;
  int slideAttachmentMask = 0;
  String slideNotes = '';
  String slideText = '';
  int slideIndex = 0;
  int slideTransitionType = 0;
  String slideLabel = '';

  Color slideColor = Color(0);
  double slideColorBrightness = 0;

  String get id => '${presentation.presentationPath}:$slideIndex';
  bool get showing => presentation.parent.currentSlide?.id == id;

  ProSlide.fromMap(this.group, Map data, {int imageQuality = -1})
      : image = ProSlideImage.fromBase64(data['slideImage'] ?? '', -1) {
    slideEnabled = data['slideEnabled'] ?? true;
    slideAttachmentMask = data['slideAttachmentMask'] ?? 0;
    slideNotes = data['slideNotes'] ?? '';
    slideText = data['slideText'] ?? '';
    slideIndex = int.tryParse(data['slideIndex']?.toString() ?? '0') ?? 0;
    slideTransitionType = data['slideTransitionType'] ?? 0;
    slideLabel = data['slideLabel'] ?? '';
    double avgColor = 0;
    List<int> colorData = (data['slideColor'] ?? '0 0 0 1').split(' ').map((e) {
      var val = ((double.tryParse(e) ?? 0) * 255).floor();
      avgColor += val;
      return val;
    }).toList();
    avgColor /= 4;
    slideColor = Color.fromARGB(colorData[3], colorData[0], colorData[1], colorData[2]);
    slideColorBrightness = avgColor < 128 ? 0 : 1;

    image = ProSlideImage.fromBase64(data['slideImage'] ?? '', imageQuality);
  }
}

class ProSlideGroup {
  String groupName = '';
  Color groupColor = Color(0);
  double groupColorBrightness = 0;
  ProPresentation presentation;

  List<ProSlide> groupSlides = [];
  ProSlideGroup.fromMap(this.presentation, Map data) {
    groupName = data['groupName'] ?? '';

    double avgColor = 0;
    List<int> colorData = (data['groupColor'] ?? '0 0 0 1').split(' ').map((e) {
      var val = ((double.tryParse(e) ?? 0) * 255).floor();
      avgColor += val;
      return val;
    }).toList();
    avgColor /= 4;
    groupColor = Color.fromARGB(colorData[3], colorData[0], colorData[1], colorData[2]);
    groupColorBrightness = avgColor < 128 ? 0 : 1;

    groupSlides = [];
    for (var s in data['groupSlides']) {
      var slide = ProSlide.fromMap(this, s);
      slide.group = this;
      groupSlides.add(slide);
    }
  }
}

class ProPresentation {
  ProRemoteClient parent;
  String presentationName = '';
  String presentationPath = '';
  List<ProSlideGroup> presentationSlideGroups = [];
  List<ProSlide> slides = [];

  int slideQuality = -1;
  int lastQuality = -1;

  ProPresentation(
    this.parent, {
    this.presentationName = '',
    this.presentationPath = '',
    this.slideQuality = 0,
  });

  ProPresentation.fromMap(this.parent, Map data)
      : slideQuality = data['presentationSlideQuality'] ?? 0,
        presentationName = data['presentationName'] ?? '',
        presentationPath = data['presentationPath'] ?? '' {
    // handle slide groups
    presentationSlideGroups = [];
    for (var item in data['presentationSlideGroups'] ?? []) {
      var sg = ProSlideGroup.fromMap(this, item);
      presentationSlideGroups.add(sg);
    }
    reComputeSlides();
  }

  void mergePresentation(ProPresentation other) {
    presentationName = other.presentationName.isNotEmpty ? other.presentationName : presentationName;
    presentationPath = other.presentationPath.isNotEmpty ? other.presentationPath : presentationPath;
    presentationSlideGroups = other.presentationSlideGroups;
    slideQuality = other.slideQuality;

    // reconnect slides and slide groups to this presentation
    for (var slideGroup in presentationSlideGroups) {
      slideGroup.presentation = this;
      for (var slide in slideGroup.groupSlides) {
        slide.group = slideGroup;
      }
    }

    reComputeSlides();
  }

  ProSlide? slideAt(int i) {
    if (slides.length <= i) {
      return null;
    } else {
      return slides[(i + slides.length) % slides.length];
    }
  }

  void reComputeSlides() {
    slides.clear();

    // fix the slideIndex also
    var index = 0;
    for (var sg in presentationSlideGroups) {
      for (var s in sg.groupSlides) {
        s.slideIndex = index;
        slides.add(s);
        index++;
      }
    }
  }
}

class ProPlaylistItem {
  ProLegacyClient pro;
  String playlistItemName;
  String playlistItemLocation;
  String playlistItemType;
  String get playlistItemTypeString => playlistItemType == 'playlistItemTypeAudio' ? 'audio' : 'presentation';
  List<ProPlaylistItem> playlist = [];

  ProPlaylistItem.fromMap(this.pro, Map data)
      : playlistItemName = data['playlistItemName'] ?? '',
        playlistItemLocation = data['playlistItemLocation'] ?? '',
        playlistItemType = data['playlistItemType'] ?? '';
}

class ProPlaylist {
  // case "playlistTypePlaylist"
  // case "playlistTypeGroup"
  ProLegacyClient pro;
  String playlistName = '';
  String playlistType = '';
  String playlistLocation = '';
  List playlist = [];

  ProPlaylist.fromMap(this.pro, Map data) {
    playlistType = data['playlistType'];
    playlistName = data['playlistName'];
    playlistLocation = data['playlistLocation'];
    playlist = [];
    for (var item in data['playlist']) {
      var p;
      if (playlistType == 'playlistTypePlaylist') {
        p = ProPlaylistItem.fromMap(pro, item);
      } else {
        p = ProPlaylist.fromMap(pro, item);
      }
      playlist.add(p);
    }
  }
}

class ProLibraryItem {
  ProLegacyClient parent;
  String path = '';
  String name = '';
  ProLibraryItem(this.parent, {required this.path}) {
    name = path.split('/').last.replaceAll('.pro6', '');
  }
}

/// ProPresenter 7+ has the idea of multiple libraries
class ProLibrary {
  ProLegacyClient parent;
  String path = '';
  String name = '';
  List<ProLibraryItem> items = [];

  ProLibrary(this.parent, {required this.path, required this.name});
}

/// can be `countdown`, `countto`, or `elapsed`
enum ProClockType { countdown, countto, elapsed }

/// a [ProClock] is the version of a clock reported by the Remote Control API
class ProClock with EventEmitter {
  ProLegacyClient? parent;

  late int id; // just refers to the order in which ProPresenter reports the clocks
  String _name = '';
  String _duration = ''; // for countto, this is the target time of day
  bool _isPM = false;
  String _end = ''; // when set to --:--:-- clock has no specified end time
  ProClockType _type = ProClockType.elapsed;
  bool _running = false;
  bool _overrun = false;
  String _current = '';

  /// a `timer` is the version of a clock reported by the Stage Display API
  ProTimer? get timer {
    try {
      return parent?.sd?.timers.values.firstWhere((t) => t.name == name);
    } on StateError catch (_) {
      return null;
    }
  }

  final StreamController<bool> _updateController = StreamController.broadcast();
  Stream<bool> get updates => _updateController.stream;

  // main getters/setters
  String get name => _name;
  set name(String s) {
    _name = s;
    notify();
  }

  String get duration => _duration;
  set duration(String s) {
    _duration = s.split('.').first;
    notify();
  }

  bool get isPM => _isPM;
  set isPM(bool b) {
    _isPM = b;
    notify();
  }

  String get end => _end;
  set end(String s) {
    _end = s;
    notify();
  }

  String get current => _current;
  set current(String s) {
    _current = s.split('.').first;
    notify();
  }

  bool get running => _running;
  set running(bool b) {
    _running = b;
    notify();
  }

  bool get overrun => _overrun;
  set overrun(bool b) {
    _overrun = b;
    notify();
  }

  ProClockType get type => _type;
  set type(ProClockType type) {
    _type = type;
    notify();
  }

  String get typeString {
    switch (type) {
      case ProClockType.countdown:
        return 'Countdown';
      case ProClockType.countto:
        return 'Countdown To';
      case ProClockType.elapsed:
        return 'Elapsed';
      default:
        return '';
    }
  }

  String get description {
    switch (type) {
      case ProClockType.countdown:
        return 'Countdown Duration: $duration';
      case ProClockType.countto:
        return 'Countdown to $duration${isPM ? 'pm' : 'am'}';
      case ProClockType.elapsed:
        return 'Elapsed time';
      default:
        return '';
    }
  }

  ProClock({this.parent});

  // clocks with type 0 count from "duration" down toward zero (or negative if overrun)
  // clocks with type 1 count from now to a specific time of day
  // clocks with type 2 count elapsed time from start until now
  // the remote api offers different data fields from the stage display
  ProClock.fromMap({this.parent, required Map<String, dynamic> data}) {
    _type = ProClockType.values[data['clockType'] ?? 0];
    _name = data['clockName'] ?? '';
    _current = data['clockTime'] ?? '--:--:--';
    _running = data['clockState'] ?? false;
    _overrun = data['clockOverrun'] ?? false;
    _isPM = data['clockIsPM'] == 1;
    _duration = data['clockDuration'] ?? '--:--:--';
    _duration = _duration.split('.').first; // Pro7 now sends clock data with fractional seconds.
    _end = data['clockEndTime'] ?? '--:--:--';
  }

  void notify() {
    emit('update');
    _updateController.add(true);
  }
}

/// the remote api sends "Clocks" but the Stage Display sends "Timers"
class ProTimer {
  ProLegacyClient? parent;
  late String name;
  late String uid;
  late String text;
  late Duration duration;

  ProClock? get clock {
    try {
      return parent?.remote?.clocks.firstWhere((c) => c.name == name);
    } on StateError {
      return null;
    }
  }

  // the remote api offers different data fields from the stage display
  ProTimer.fromMap({this.parent, required Map<String, dynamic> data}) {
    name = data['nme'] ?? '';
    uid = data['uid'] ?? '';
    text = data['txt'] ?? '00:00:00';
    duration = Duration(seconds: hms2secs(text));
  }
}

class ProMessage {
  int id;
  List<String> components = [];
  List<String> keys = [];
  Map<String, String> mapping = {};
  String title = '';
  bool showing = false;

  /// ProMessages can be sent with replacement text mappings
  /// this will display a "sample" based on those replacements.
  String get sample {
    var s = components.join('');
    if (mapping.isNotEmpty) {
      for (var k in keys) {
        var search = '\${$k}';
        var replace = mapping[k] ?? '';
        if (replace.isNotEmpty) s = s.replaceAll(search, replace);
      }
    }
    return s;
  }

  ProMessage.fromMap(this.id, Map<String, dynamic> data) {
    var re = RegExp(r'\${(.*?)}');
    keys = [];
    components = [];
    mapping = {};
    showing = false;
    title = data['messageTitle'] ?? '';
    for (var c in data['messageComponents']) {
      var m = re.firstMatch(c);
      if (m == null) {
        components.add(c);
      } else {
        components.add(c);
        var key = m.group(1)!;
        keys.add(key);
        mapping[key] = '';
      }
    }
  }
}
