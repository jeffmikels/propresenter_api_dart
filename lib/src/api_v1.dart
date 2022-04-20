import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'event_emitter.dart';
import 'propresenter_api_base.dart';
import 'helpers.dart';
import 'api_v1_generated.dart';

/// This class gives full access to the completely new ProPresenter API available in 7.9+
/// This API uses basic HTTP clients. For normal commands, a standard request/response method
/// is employed, but the API also allows for "subscriptions" to certain events which will result
/// in a persistent-ly open HTTP client that receives streamed JSON data in `chunks`.
class ProApiClient with EventEmitter {
  ProSettings settings;
  ProState state = ProState();
  ProApiClient(this.settings);
}
