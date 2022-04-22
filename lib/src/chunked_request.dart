import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// This class will allow you to make an HTTP request, and it will
/// reply with a stream of data objects
class ChunkedJsonClient {
  static Future<Stream?> request(
    dynamic url, {
    Map<String, dynamic>? params,
    Object? postData,
  }) async {
    late Uri uri;
    if (url is String) {
      uri = Uri.parse(url);
    } else if (url is Uri) {
      uri = url;
    } else {
      uri = Uri();
    }

    if (params != null) {
      uri = Uri(
          scheme: uri.scheme,
          host: uri.host,
          userInfo: uri.userInfo,
          port: uri.port,
          path: uri.path,
          queryParameters: {...uri.queryParameters, ...params});
    }
    var verb = postData == null ? 'GET' : 'POST';
    var r = http.Request(verb, uri);
    r.headers['content-type'] = 'application/json';
    r.body = json.encode(postData);
    var res = await r.send();
    if (res.statusCode > 199 && res.statusCode < 300) {
      var sc = StreamController<Map<String, dynamic>>();
      var accum = '';
      res.stream.listen((e) {
        accum += utf8.decode(e);
        var chunks = accum.split('\r\n\r\n');
        // if the received data ended with \r\n\r\n, the last chunk will be empty
        // if it didn't end with \r\n\r\n, then we want to leave it in the accumulator
        accum = chunks.removeLast();
        for (var chunk in chunks) {
          try {
            var decoded = json.decode(chunk);
            print(decoded);
            sc.add({...decoded});
          } catch (e) {
            print('JSON ERROR: $e');
          }
        }
      }).onDone(() {
        sc.close();
      });
      return sc.stream;
    } else {
      var err = await _awaitBytes(res.stream);
      throw http.ClientException(err);
    }
    // return null;
  }
}

Future<String> _awaitBytes(http.ByteStream s) {
  var accum = <int>[];
  var completer = Completer<String>();
  s.listen((bytes) => accum.addAll(bytes)).onDone(() {
    completer.complete(utf8.decode(accum));
  });
  return completer.future;
}
