import 'dart:async';

/// [EventEmitter]s provide two ways for an object to listen to changes.
/// Either by providing a callback, or by listening to an event stream.
///
/// Listening to the [eventStream] allows the use of [StreamBuilder] widgets
/// in Flutter
class EventEmitter<T extends Object> {
  Map<String, List<void Function(Event<T> event)>> callbacks = {};
  StreamController<Event<T>> eventStream = StreamController.broadcast();

  /// listen to an event on this [EventEmitter] as a stream. A True value
  /// will be emitted whenever the event by this name is emitted.
  ///
  /// Use the special `event` name of 'all' to subscribe to all events.
  Stream<Event> listen(String event) {
    return eventStream.stream.where((e) => e.name == event); //.map<bool>((event) => true);
  }

  /// set a callback for events of this type.
  ///
  /// Use the special `event` name of 'all' to fire this callback on all events.
  EventObserver on(String event, void Function(Event<T> event) callback) {
    if (!callbacks.containsKey(event)) callbacks[event] = [];
    callbacks[event]!.add(callback);
    return EventObserver(() => callbacks[event]?.remove(callback));
  }

  /// emit will always emit twice... first, by the name of the event
  /// submitted, and secondly, by the name of the special event 'all'
  void emit(String event, [T? data]) {
    for (var name in [event, 'all']) {
      var e = Event(name, data);
      eventStream.add(e);
      if (callbacks.containsKey(name)) {
        for (var callback in callbacks[name]!) {
          callback(e);
        }
      }
    }
  }
}

class Event<T extends Object> {
  String name = '';
  T? data;
  Event(this.name, [this.data]);

  toJson() => {
        'name': name,
        'data': data,
      };
}

/// Allow a listener to cancel a callback registered with an [EventEmitter]
class EventObserver {
  void Function() canceler;
  EventObserver(this.canceler);

  void cancel() => canceler();
}
