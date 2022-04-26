import 'dart:async';

/// [ProEventEmitter]s provide two ways for an object to listen to changes.
/// Either by providing a callback, or by listening to an event stream.
///
/// Listening to the [eventStream] allows the use of [StreamBuilder] widgets
/// in Flutter
class ProEventEmitter<T extends Object> {
  bool _disposed = false;
  Map<String, List<void Function(ProEvent<T> event)>> callbacks = {};
  StreamController<ProEvent<T>> eventStream = StreamController.broadcast();

  /// listen to an event on this [ProEventEmitter] as a stream. An [ProEvent]
  /// will be emitted whenever the event by this name is emitted.
  ///
  /// Use the special `event` name of 'all' to subscribe to all events.
  Stream<ProEvent> stream(String event) {
    return eventStream.stream.where((e) => e.name == event); //.map<bool>((event) => true);
  }

  /// set a callback for events of this type.
  ///
  /// REMEMBER TO DISPOSE INSTANCES OF THIS CLASS OR CANCEL THESE CALLBACKS
  /// i.e. call [EventEmitter.dispose]
  ///
  /// Use the special `event` name of 'all' to fire this callback on all events.
  ProEventObserver on(String event, void Function(ProEvent<T> event) callback) {
    if (!callbacks.containsKey(event)) callbacks[event] = [];
    callbacks[event]!.add(callback);
    return ProEventObserver(() => callbacks[event]?.remove(callback));
  }

  /// emit will always emit twice... first, by the name of the event
  /// submitted, and secondly, by the name of the special event 'all'
  void emit(String event, [T? data]) {
    if (_disposed) return;
    for (var name in [event, 'all']) {
      var e = ProEvent(name, data);
      eventStream.add(e);
      if (callbacks.containsKey(name)) {
        for (var callback in callbacks[name]!) {
          callback(e);
        }
      }
    }
  }

  void clear() {
    callbacks.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}

class ProEvent<T extends Object> {
  String name = '';
  T? data;
  ProEvent(this.name, [this.data]);

  toJson() => {
        'name': name,
        'data': data,
      };
}

/// Allow a listener to cancel a callback registered with an [ProEventEmitter]
class ProEventObserver {
  void Function() _canceler;
  ProEventObserver(this._canceler);

  void cancel() => _canceler();
}
