import 'dart:convert';
import 'dart:io';

import 'package:propresenter_api/propresenter_api.dart';
import 'package:propresenter_api/src/api_v1_generated.dart';
import 'package:propresenter_api/src/cache.dart';

void debug(Object s) {
  var enc = JsonEncoder.withIndent('  ');
  print(enc.convert(s));
}

void main() async {
  Cache.init('.');

  // // final awesome = ProApiClient();
  // var url = 'http://localhost:60157/v1/status/slide?chunked=true';
  // print('Connecting to $url');
  // var t = await ChunkedJsonClient.request(url);
  // if (t == null) print('failed request');
  // t?.listen((event) {
  //   var encoder = JsonEncoder.withIndent('  ');
  //   print('------------ NEW EVENT ---------------------');
  //   print(encoder.convert(event));
  //   print('--------------------------------------------');
  // });
  // PP.config('localhost', 60157);

  // var r = await PP.presentationGetActive();
  // var puuid = r['presentation']['id']['uuid'];
  // var u = await PP.presentationThumbnailGet(puuid, 0, quality: 600);
  // File('tmp.jpg').writeAsBytesSync(u);

  // var s = await PP.slideStatusGetStream();
  // if (s != null) {
  //   var encoder = JsonEncoder.withIndent('  ');
  //   s.listen((e) => print(encoder.convert(e)));
  // }

  var pro = ProApiClient(ProSettings(version: ProVersion.seven9, host: 'localhost', port: 60157));
  pro.on('all', (e) => debug(e));
  pro.subscribeAll();
}
