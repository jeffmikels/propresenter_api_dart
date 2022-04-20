import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class CacheNotReadyException implements Exception {
  String errMsg() => 'Cache must be initialized first with `Cache.init`';
}

class Cache {
  static bool _initialized = false;
  static Directory cacheDir = Directory('.');

  static init(String path) {
    Cache.cacheDir = Directory(path);
    if (Cache.cacheDir.existsSync()) {
      _initialized = true;
      return;
    } else {
      try {
        Cache.cacheDir.createSync();
        _initialized = true;
      } catch (_) {
        rethrow;
      }
    }
  }

  static Future<File?> _uriToFile(Uri uri) async {
    if (uri.pathSegments.isEmpty) return null;

    // look in local cache first
    var target = File(cacheDir.path + '/' + uri.pathSegments.join('/'));
    return target;
  }

  static Future<Uint8List> _fetchAndCache(Uri uri) async {
    if (!_initialized) throw CacheNotReadyException;
    var target = await _uriToFile(uri);
    var r = await http.get(uri);
    if (r.statusCode > 199 && r.statusCode < 300) {
      var bytes = r.bodyBytes;
      await target?.writeAsBytes(bytes);
      return bytes;
    } else {
      return Uint8List(0);
    }
  }

  static Future<Uint8List> _fromCache(Uri uri) async {
    if (!_initialized) throw CacheNotReadyException;
    var target = await _uriToFile(uri);
    if (target?.existsSync() == true) {
      return target!.readAsBytes();
    } else {
      return Uint8List(0);
    }
  }

  /// normal get function that will return data from cache or from url
  static Future<Uint8List> _get(Uri uri, {refreshFirst = false}) async {
    if (refreshFirst) {
      return _fetchAndCache(uri);
    }
    Uint8List data = await _fromCache(uri);
    if (data.isNotEmpty) return data;

    return _fetchAndCache(uri);
  }

  static void _finishCachedThenRefresh(StreamController<Uint8List> sc, List<Future<Uint8List>> futures) async {
    for (var future in futures) {
      var res = await future;
      sc.add(res);
    }
    sc.close();
  }

  static Stream<Uint8List> _getCachedThenRefresh(Uri uri) {
    var sc = StreamController<Uint8List>();
    _finishCachedThenRefresh(sc, [
      _fromCache(uri),
      _fetchAndCache(uri),
    ]);
    return sc.stream;
  }

  static Stream<Uint8List> getBytesCachedFirst(Uri uri) {
    return _getCachedThenRefresh(uri);
  }

  static Stream<String> getStringCachedFirst(Uri uri) {
    return _getCachedThenRefresh(uri).map((e) => utf8.decode(e));
  }

  static Future<Uint8List> getBytes(Uri uri, {refreshFirst = false}) async {
    return _get(uri, refreshFirst: refreshFirst);
  }

  static Future<String> getString(Uri uri, {refreshFirst = false}) async {
    return utf8.decode(await _get(uri, refreshFirst: refreshFirst));
  }
}
