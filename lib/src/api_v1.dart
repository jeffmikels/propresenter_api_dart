import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'helpers.dart';
import 'event_emitter.dart';
import 'propresenter_api_base.dart';

import 'api_v1_generated.dart';

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
    ProApiSubbable.systemTime,

    ProApiSubbable.videoCountdown,
  ];

  /// `audio/playlist/{id}/updates`
  static String audioPlaylistUpdates(String playlistId) => 'audio/playlist/$playlistId/updates';

  /// - `library/{id}`
  static String libraryUpdates(String libraryId) => 'library/$libraryId';

  /// - `media/playlist/{id}/updates`
  static String mediaPlaylistUpdates(String playlistId) => 'media/playlist/$playlistId/updates';

  /// - `transport/{layer}/time`
  static String transportTime(String layerId) => 'transport/$layerId/time';

  /// - `transport/{layer}/current`
  static String transportCurrent(String layerId) => 'transport/$layerId/current';
}

/// This class gives full access to the completely new ProPresenter API available in 7.9+
/// This API uses basic HTTP clients. For normal commands, a standard request/response method
/// is employed, but the API also allows for "subscriptions" to certain events which will result
/// in a persistent-ly open HTTP client that receives streamed JSON data in `chunks`.
class ProApiClient with EventEmitter {
  bool subscribed = false;
  ProApiWrapper api;
  ProSettings settings;
  ProState state = ProState();
  ProApiClient(this.settings) : api = ProApiWrapper(settings.host, settings.port);

  /// will subscribe to chunked updates using the /status endpoint.
  ///
  /// To make things easier, the available and working endpoints are stored
  /// as static constants in the [ProApiSubbable] class.
  ///
  /// Note: these endpoints do not work in 7.9 despite the claims in the documentation:
  /// - `playlist/current`
  /// - `announcement/active/timeline`
  ///
  /// Note also: Other endpoints are supported but they require id values.
  Future<bool> subscribeMulti(List<String> subs) async {
    emit('subscribing', subs);

    var s = await api.statusUpdatesGet(subs);
    if (s == null) return false;
    s.listen((obj) {
      var data = (obj as Map<String, dynamic>);

      // emit the raw data identified by the endpoint/url
      var url = data['url'] as String;
      emit(url, data);

      // parse into the ProState
      state.handleData(data);
    }).onDone(() {
      print('subscription ended');
      emit('unsubscribed', 'subscribeAll');
      subscribed = false;
    });
    emit('subscribed', 'subscribeAll');
    subscribed = true;
    return true;
  }

  /// will automatically call [subscribeMulti] with all available endpoints
  /// except for the endpoints that require specific ids:
  /// - `audio/playlist/{id}/updates`
  /// - `library/{id}`
  /// - `media/playlist/{id}/updates`
  /// - `transport/{layer}/time`
  /// - `transport/{layer}/current`
  Future<bool> subscribeAll() async {
    return subscribeMulti(ProApiSubbable.all);
  }
}
