import 'dart:convert';

/// simplified implementation of the Color class from Flutter's dart:ui package
/// We use it to compute the luminance of an image
class Color {
  final int value; // should be a 32 bit integer 0xAABBCCDD alpha, red, green, blue
  const Color(int value) : value = value & 0xFFFFFFFF;
  factory Color.fromARGB(int a, int r, int g, int b) {
    var c = b;
    c |= g << 8;
    c |= r << 16;
    c |= a << 24;
    return Color(c);
  }
}

Map<Color, double> computedLuminance = {};

/// [DayPeriod] duplicates item from Flutter's material library
enum DayPeriod { am, pm }

/// [TimeOfDay] duplicates class from Flutter's material library
class TimeOfDay {
  // always in 24 hour time, 0-23
  final int hour;
  final int minute;
  final int second;

  static const int hoursPerPeriod = 12;

  String _maybePad(int val) => val < 10 ? '0$val' : val.toString();

  /// Whether this time of day is before or after noon.
  DayPeriod get period => hour < hoursPerPeriod ? DayPeriod.am : DayPeriod.pm;
  int get periodOffset => period == DayPeriod.am ? 0 : hoursPerPeriod;
  int get hourOfPeriod => hour == 0 || hour == 12 ? 12 : hour - periodOffset;
  String get ampm => period == DayPeriod.am ? 'am' : 'pm';

  String get _as24HourWithSeconds => '${_maybePad(hour)}:${_maybePad(minute)}:${_maybePad(second)}';
  String get as24Hour => second > 0 ? _as24HourWithSeconds : '${_maybePad(hour)}:${_maybePad(minute)}';
  String get _as12HourWithSeconds => '$hourOfPeriod:${_maybePad(minute)}:${_maybePad(second)}$ampm';
  String get as12Hour => second > 0 ? _as12HourWithSeconds : '$hourOfPeriod:${_maybePad(minute)}$ampm';

  int get secondsFromMidnight => (hour * 60 + minute) * 60 + second;

  /// [hour] must be between 0 and 23, inclusive.
  /// [minute] and [second] must be between 0 and 59, inclusive.
  const TimeOfDay({
    this.hour = 0,
    this.minute = 0,
    this.second = 0,
  });

  TimeOfDay.fromDateTime(DateTime d, {includeSeconds = false})
      : hour = d.hour,
        minute = d.minute,
        second = includeSeconds ? d.second : 0;

  factory TimeOfDay.now() {
    return TimeOfDay.fromDateTime(DateTime.now());
  }

  factory TimeOfDay.fromTimestring(String timestring) {
    var pattern = RegExp(r'\s*(\d+):(\d+)\s*([AP]M)');
    var match = pattern.firstMatch(timestring);
    if (match == null) return TimeOfDay();
    var hours = int.parse(match.group(1) ?? '');
    var minutes = int.parse(match.group(2) ?? '');
    var ampm = match.group(3);
    if (ampm == "PM") hours += 12;
    return TimeOfDay(hour: hours, minute: minutes);
  }

  factory TimeOfDay.fromTimestamp(int millis, {includeSeconds = false}) {
    var time = DateTime.fromMillisecondsSinceEpoch(millis);
    return TimeOfDay.fromDateTime(time, includeSeconds: includeSeconds);
  }
}

String enumValueToString(var e) {
  return e.toString().split('.').last;
}

T enumValueFromString<T>(String s, List<T> values) =>
    values.firstWhere((v) => s.toLowerCase() == enumValueToString(v).toLowerCase());

String basename(String p) {
  return p.split('/').last;
}

int hms2secs(String hms) {
  var a = hms.split(":").map((e) => int.tryParse(e) ?? 0).toList(); // split it at the colons
  var seconds = a[0] * 60 * 60 + a[1] * 60 + a[2];
  return seconds;
}

int timestring2secs(String timestring) {
  var tod = TimeOfDay.fromTimestring(timestring);
  return tod.secondsFromMidnight;
}

// String tod2timestring(TimeOfDay tod) {
//   if (tod == null) return '12:00 am';
//   var hour = tod.hourOfPeriod;
//   if (hour == 0) hour = 12;
//   var ampm = tod.period == DayPeriod.am ? 'am' : 'pm';
//   var minute = tod.minute.toString().padLeft(2, '0');
//   return '$hour:$minute $ampm';
// }

void debug(Object obj) {
  var converter = JsonEncoder.withIndent('  ').convert;
  if (obj is String) {
    print('DEBUG: $obj');
  } else {
    print('DEBUG:');
    print(converter(obj));
  }
}
