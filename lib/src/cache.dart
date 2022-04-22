import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class CacheNotReadyException implements Exception {
  String errMsg() => 'Cache must be initialized first with `Cache.init`';
}

/// Provides static functions to fetch data from the Internet and cache it
/// locally. The cache only works if `Cache.init(path)` is called first.
/// Until it has been initialized, the cache functions will simply do
/// network requests and return the results.
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

  static File? _fileFromFilename(String filename) {
    // if (!_initialized) { throw CacheNotReadyException; }
    if (!_initialized) return null;
    var path = (cacheDir.path + '/' + filename).replaceAll(RegExp(r'//+'), '/');
    return File(path);
  }

  static String _uriToCacheFile(Uri uri) {
    var modifiable = [...uri.pathSegments];
    if (uri.pathSegments.isEmpty) return 'index.html';
    var last = modifiable.removeLast();
    if (last == '') {
      modifiable.add('index.html');
    } else {
      modifiable.add(last);
    }
    return modifiable.join('/');
  }

  static Future<Uint8List> _fetchAndCache(Uri uri) async {
    late Uint8List bytes;
    var r = await http.get(uri);
    if (r.statusCode > 199 && r.statusCode < 300) {
      bytes = r.bodyBytes;
    } else {
      bytes = Uint8List(0);
    }
    if (bytes.isNotEmpty) {
      var target = _uriToCacheFile(uri);
      await _toCache(target, bytes);
    }
    return bytes;
  }

  static Future<bool> _toCache(String filename, Uint8List data) async {
    var target = _fileFromFilename(filename);
    if (target == null) return false;
    try {
      await target.writeAsBytes(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Uint8List> _fromCache(String filename) async {
    // assert (uri == null || filename == null);
    // if (uri == null && filename == null) return Uint8List(0);

    // if (!_initialized) throw CacheNotReadyException;
    var target = _fileFromFilename(filename);
    if (target?.existsSync() == true) {
      return target!.readAsBytes();
    } else {
      return Uint8List(0);
    }
  }

  /// normal function that will return data from cache or from url
  static Future<Uint8List> _fromCacheOrFetch(Uri uri, {refreshFirst = false}) async {
    if (refreshFirst) {
      return _fetchAndCache(uri);
    }
    var cacheFile = _uriToCacheFile(uri);
    Uint8List data = await _fromCache(cacheFile);
    if (data.isNotEmpty) return data;
    return _fetchAndCache(uri);
  }

  static void _finishCachedThenRefresh(StreamController<Uint8List> sc, List<Future<Uint8List>> futures) async {
    for (var future in futures) {
      var res = await future;
      if (res.isNotEmpty) sc.add(res);
    }
    sc.close();
  }

  static Stream<Uint8List> _getCachedThenRefresh(Uri uri) {
    var sc = StreamController<Uint8List>();
    var cacheFile = _uriToCacheFile(uri);
    _finishCachedThenRefresh(sc, [
      _fromCache(cacheFile),
      _fetchAndCache(uri),
    ]);
    return sc.stream;
  }

  /// returns a stream of results as bytes. The first element in the stream
  /// will be bytes from the cached file if it exists, and the second will be
  /// bytes from the network request.
  static Stream<Uint8List> getBytesCachedFirst(Uri uri) {
    return _getCachedThenRefresh(uri);
  }

  /// returns a stream of results as string. The first element in the stream
  /// will be the String data from the cached file if it exists, and the second
  /// will be the String data from the network request.
  static Stream<String> getStringCachedFirst(Uri uri) {
    return _getCachedThenRefresh(uri).map((e) => utf8.decode(e));
  }

  /// returns bytes from cached file if it exists or from the network if there
  /// is no cached file. If [refreshFirst] is `true` the local cache file
  /// will be ignored and regenerated from the network request.
  static Future<Uint8List> fetchBytes(Uri uri, {refreshFirst = false}) async {
    return _fromCacheOrFetch(uri, refreshFirst: refreshFirst);
  }

  /// returns String data from cached file if it exists or from the network if there
  /// is no cached file. If [refreshFirst] is `true` the local cache file
  /// will be ignored and regenerated from the network request.
  static Future<String> fetchString(Uri uri, {refreshFirst = false}) async {
    return utf8.decode(await _fromCacheOrFetch(uri, refreshFirst: refreshFirst));
  }

  /// returns string from cached file if it exists. Doesn't do any network requests.
  /// [filename] must be given as a path *relative* to the initialized cache directory.
  static Future<String> readString(String filename) async {
    return utf8.decode(await _fromCache(filename));
  }

  /// returns bytes from cached file if it exists. Doesn't do any network requests.
  /// [filename] must be given as a path *relative* to the initialized cache directory.
  static Future<Uint8List> readBytes(String filename) async {
    return _fromCache(filename);
  }

  /// saves arbitrary String data into the cache directory as `filename`
  static Future<bool> saveString(String filename, String data) async {
    return _toCache(filename, Uint8List.fromList(utf8.encode(data)));
  }

  /// saves arbitrary bytes data into the cache directory as `filename`
  static Future<bool> saveBytes(String filename, Uint8List data) async {
    return _toCache(filename, data);
  }
}
