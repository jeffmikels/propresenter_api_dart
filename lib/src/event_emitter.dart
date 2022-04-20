import 'dart:async';

/// [EventEmitter]s provide two ways for an object to listen to changes.
/// Either by providing a callback, or by listening to an event stream.
///
/// Listening to the [eventStream] allows the use of [StreamBuilder] widgets
/// in Flutter
mixin EventEmitter {
  Map<String, List<void Function()>> callbacks = {};
  StreamController<String> eventStream = StreamController.broadcast();

  /// listen to an event on this [EventEmitter] as a stream. A True value
  /// will be emitted whenever the event by this name is emitted.
  Stream<bool> listen(String event) {
    return eventStream.stream.where((e) => e == event).map<bool>((event) => true);
  }

  EventObserver on(String event, void Function() callback) {
    if (!callbacks.containsKey(event)) callbacks[event] = [];
    callbacks[event]!.add(callback);
    return EventObserver(() => callbacks[event]?.remove(callback));
  }

  void emit(String event) {
    eventStream.add(event);
    if (callbacks.containsKey(event)) {
      for (var callback in callbacks[event]!) {
        callback();
      }
    }
  }
}

/// Allow a listener to cancel a callback registered with an [EventEmitter]
class EventObserver {
  void Function() canceler;
  EventObserver(this.canceler);

  void cancel() => canceler();
}
