import 'dart:async';
import 'dart:convert';

import 'helpers.dart';
import 'event_emitter.dart';
import 'propresenter_api_base.dart';

import 'api_v1_generated.dart';

/// this class stores the string constants representing
/// ProPresenter endpoints that can be subscribed to
/// using the `/status/updates` endpoint
abstract class ProApiSubbable {
  static const captureStatus = 'capture/status';
  static const layersStatus = 'status/layers';
  static const currentLook = 'look/current';

  static const slideStatus = 'status/slide';
  static const currentSlideIndex = 'presentation/slide_index';
  static const currentPresentation = 'presentation/current';
  static const activePresentationTimeline = 'presentation/active/timeline';
  static const focusedPresentationTimeline = 'presentation/focused/timeline';

  static const messages = 'messages';
  static const screens = 'status/screens';

  static const stageMessage = 'stage/message';
  static const stageScreens = 'status/stage_screens';
  static const audienceScreens = 'status/audience_screens';

  static const allTimers = 'timers';
  static const currentTimers = 'timers/current';
  static const systemTime = 'timer/system_time';

  static const videoCountdown = 'timer/video_countdown';

  /// Advertised to work but does not in 7.9
  static const currentPlaylist = 'playlist/current';

  /// Advertised to work but does not in 7.9
  static const activeAnnouncementTimeline = 'announcement/active/timeline';

  static const List<String> all = [
    // ProApiSubbable.currentPlaylist,
    // ProApiSubbable.activeAnnouncementTimeline,

    ProApiSubbable.captureStatus,
    ProApiSubbable.layersStatus,
    ProApiSubbable.currentLook,

    ProApiSubbable.slideStatus,
    ProApiSubbable.currentSlideIndex,
    ProApiSubbable.currentPresentation,
    ProApiSubbable.activePresentationTimeline,
    ProApiSubbable.focusedPresentationTimeline,

    ProApiSubbable.messages,
    ProApiSubbable.screens,

    ProApiSubbable.stageMessage,
    ProApiSubbable.stageScreens,
    ProApiSubbable.audienceScreens,

    ProApiSubbable.allTimers,
    ProApiSubbable.currentTimers,

    /// reports an update every second
    ProApiSubbable.systemTime,

    /// reports an update every second even if no change
    ProApiSubbable.videoCountdown,
  ];

  /// - `library/{id}`
  static String libraryUpdates(String libraryId) => 'library/$libraryId';

  /// - `media/playlist/{id}/updates`
  static String mediaPlaylistUpdates(String playlistId) => 'media/playlist/$playlistId/updates';

  /// `audio/playlist/{id}/updates`
  static String audioPlaylistUpdates(String playlistId) => 'audio/playlist/$playlistId/updates';

  /// - `transport/{layer}/time`
  static String transportTime(String layerId) => 'transport/$layerId/time';

  /// - `transport/{layer}/current`
  static String transportCurrent(String layerId) => 'transport/$layerId/current';
}

/// This class gives full access to the completely new ProPresenter API available in 7.9+
/// This API uses basic HTTP clients. For normal commands, a standard request/response method
/// is employed, but the API also allows for "subscriptions" to certain events which will result
/// in a persistent HTTP connection that receives streamed JSON data in `chunks`.
///
/// The generated code in [ProApiGeneratedWrapper] wraps those commands and returns responses of the
/// correct type either `Future<Map<String, dynamic>>` or `Future<Uint8List>` when not using the
/// "subscription" methods or streamed responses when using the "subscription" methods.
///
/// This class further wraps those functions to make using those methods more convenient. In particular,
/// this class allows easy subscriptions, will maintain an internal `state` object to track the
/// current state of the ProPresenter instance, and will reduce complexity when calling endpoints
/// that accept large blocks of data.
class ProApiClient with EventEmitter {
  final ProApiGeneratedWrapper api;
  ProSettings settings;
  ProState state = ProState();

  Set<String> statusSubscriptions = {};
  Map<String, StreamSubscription> updateListeners = {};

  /// Creates new [ProApiClient] instance.
  ProApiClient(this.settings)
      : api = ProApiGeneratedWrapper(settings.host, settings.port),
        assert(settings.version.index >= ProVersion.seven9.index);

  /// will subscribe to chunked updates using the /status endpoint.
  ///
  /// To make things easier, the available and working endpoints are stored
  /// as static constants in the [ProApiSubbable] class.
  ///
  /// Note: in 7.9, these endpoints do not work in this call despite the claims in the documentation:
  /// - `playlist/current`
  /// - `announcement/active/timeline`
  ///
  /// Note also: Other endpoints are supported but they require id values. See the
  /// static class methods on [ProApiSubbable] for endpoint generators.
  Future<bool> subscribeMulti(List<String> subs) async {
    emit('subscribing', subs);

    var s = await api.statusUpdatesGet(subs);
    if (s == null) return false;

    var streamListener = s.listen((obj) {
      // emit the raw data identified by the endpoint/url
      var url = obj['url'] as String;
      emit(url, obj);

      // parse into the ProState
      state.handleData(obj);
    });

    streamListener.onDone(() {
      for (var endpoint in subs) {
        emit('unsubscribed', endpoint);
      }
      updateListeners.removeWhere((key, value) => value == streamListener);
    });

    for (var endpoint in subs) {
      // cancel all previous streamListeners on this endpoint
      await updateListeners[endpoint]?.cancel();
      updateListeners[endpoint] = streamListener;
      emit('subscribed', endpoint);
    }
    return true;
  }

  /// will automatically call [subscribeMulti] with all available endpoints
  /// except for the endpoints that require specific ids:
  /// - `audio/playlist/{id}/updates`
  /// - `library/{id}`
  /// - `media/playlist/{id}/updates`
  /// - `transport/{layer}/time`
  /// - `transport/{layer}/current`
  Future<bool> subscribeAll({withoutSysTime = false, withoutVideoCountdown = false}) async {
    var subs = [...ProApiSubbable.all];
    if (withoutSysTime) subs.remove(ProApiSubbable.systemTime);
    if (withoutVideoCountdown) subs.remove(ProApiSubbable.videoCountdown);
    return subscribeMulti(subs);
  }
}
