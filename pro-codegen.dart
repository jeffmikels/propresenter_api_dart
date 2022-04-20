import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

extension ListStrings on List {
  List<String> toStrings() => map((e) => e.toString()).toList();
}

extension PrefixStrings on String {
  String prefixLines(String prefix, {String sep = '\n'}) => split(sep).map((e) => '$prefix$e').join(sep);
  String snakeToCamelCase() => replaceAllMapped(RegExp(r'_(\w)'), (match) {
        return match.group(1)!.toUpperCase();
      });
}

var prettyJson = JsonEncoder.withIndent('  ').convert;
Map<String, dynamic> spec = {};
Map<String, dynamic> pathRefs = {};

List<String> parseRef(String refString) {
  List<String> jsonKeys = [];
  var refParts = refString.replaceFirst('#/', '').split('/');
  for (var part in refParts) {
    part = part.replaceAll('~1', '/').replaceAll('%7B', '{').replaceAll('%7D', '}');
    jsonKeys.add(part);
  }
  return jsonKeys;
}

bool isRef(obj) {
  return obj is Map && obj.length == 1 && obj['\$ref'] != null;
}

dynamic deRef(obj) {
  String? refPath;
  if (obj is String) refPath = obj;
  if (isRef(obj)) refPath = obj['\$ref'];
  if (refPath == null) return obj;

  var parts = parseRef(refPath);
  dynamic current = spec;
  for (var key in parts) {
    // print('looking for ${key} in spec file');
    if (current is List) {
      try {
        int p = int.parse(key);
        if (current.length > p) current = current[p];
      } on FormatException {
        throw FormatException('used a non numeric value to index a list');
      }
    } else if (current is Map) {
      current = current[key];
    }

    if (current == null) throw FormatException('could not dereference $refPath');
  }
  return current;
}

/// TODO: see `clearGroupCreate`, handle requestBody/schema/properties
/// TODO: or see `timerSet`, handle requestBody/schema/oneOf
class EndpointSchema {
  bool get isOneOf => oneOf.isNotEmpty;

  String type = ''; // string, array, object, number, integer, boolean

  // sometimes `string` data might represent a `binary` object
  String format = '';

  // the items/keys required in this schema
  List<String> required = [];

  // sometimes only certain options are allowed `enum`
  List<String> options = [];

  String exampleJson = '';
  Object? example;

  List<EndpointSchema> oneOf = [];

  dynamic defaultValue;

  EndpointSchema.fromMap(Map<String, dynamic> data) {
    data = deRef(data);
    if (data['type'] == null && data['oneOf'] != null) {
      for (var item in data['oneOf']) {
        oneOf.add(EndpointSchema.fromMap(item));
      }
    } else {
      type = data['type'];
      defaultValue = data['default'];
      format = data['format'] ?? '';
      options.addAll(((data['enum'] ?? []) as List).toStrings());
      required.addAll(((data['required'] ?? []) as List).toStrings());
      if (data.containsKey('example')) {
        example = data['example'];
        exampleJson = JsonEncoder.withIndent('  ').convert(data['example']);
      }
    }
  }

  toJson() {
    if (isOneOf) {
      var r = [];
      for (var sub in oneOf) {
        r.add(sub.toJson());
      }
      return {'oneOf': r};
    }

    return {
      'type': type, // always required
      'required': required, // always returned
      if (format.isNotEmpty) 'format': format,
      if (defaultValue != null) 'default': defaultValue,
      if (options.isNotEmpty) 'enum': options,
      if (example != null) 'example': example,
    };
  }
}

class EndpointExample {
  String name = '';
  String summary = '';
  Object value;
  String valueJson = '';

  EndpointExample(this.name, this.summary, this.value) {
    valueJson = JsonEncoder.withIndent('  ').convert(value);
  }
}

class EndpointParam {
  String location = ''; // `in` can be 'query', 'path' or
  bool required = false;
  String name = '';
  String description = '';
  late EndpointSchema schema;
  List<EndpointExample> examples = [];

  EndpointParam.fromMap(data) {
    data = deRef(data);
    location = data['in'];
    required = data['required'] == true;
    name = data['name'];
    description = data['description'];
    schema = EndpointSchema.fromMap(data['schema']);

    var singleExample = data['example'];
    if (singleExample != null) {
      examples.add(EndpointExample(name, '', singleExample));
    }

    var someExamples = data['examples'];
    if (someExamples == null) return;

    for (var name in (someExamples as Map).keys) {
      var example = someExamples[name];
      var summary = example['summary'];
      var value = example['value'];
      examples.add(EndpointExample(name, summary, value));
    }
  }
}

class EndpointResponse {
  int code = 0;
  String description = '';
  String contentType = '';
  EndpointSchema? schema;
  List<EndpointExample> examples = [];

  EndpointResponse.fromMap(this.code, Map<String, dynamic> data) {
    data = deRef(data);
    description = data['description'] ?? data['summary'] ?? '';
    if (code == 204) contentType = 'NONE';
    if (data['content'] == null) return;
    if (data['content'].length > 1) {
      print(data);
      print('This data has multiple response content types, only using the first one.');
    }
    contentType = (data['content'] as Map).keys.first;
    if (data['content'][contentType]['schema'] == null) return;
    schema = EndpointSchema.fromMap(data['content'][contentType]['schema']);

    var singleExample = data['example'];
    if (singleExample != null) {
      examples.add(EndpointExample('', '', singleExample));
    }

    var someExamples = data['examples'];
    if (someExamples == null) return;

    for (var name in (someExamples as Map).keys) {
      var example = someExamples[name];
      var summary = example['summary'];
      var value = example['value'];
      examples.add(EndpointExample(name, summary, value));
    }
  }
}

class EndpointRequestBody {
  bool required = false;
  String contentType = '';
  late EndpointSchema schema;
  List<EndpointExample> examples = [];

  EndpointRequestBody.fromMap(Map<String, dynamic> data) {
    data = deRef(data);
    required = data['required'] == true;
    contentType = (data['content'] as Map).keys.first;
    schema = EndpointSchema.fromMap(data['content']![contentType]!['schema']!);

    var singleExample = data['content']![contentType]!['example'];
    if (singleExample != null) {
      examples.add(EndpointExample('', '', singleExample));
    }

    var someExamples = data['content']![contentType]!['examples'];
    if (someExamples == null) return;

    for (var name in (someExamples as Map).keys) {
      var example = someExamples[name];
      var summary = example['summary'];
      var value = example['value'];
      examples.add(EndpointExample(name, summary, value));
    }
  }
}

class EndpointVerb {
  // operationId
  String id = '';
  String method = '';
  String summary = '';
  List<String> tags = [];
  List<EndpointParam> params = [];
  List<EndpointResponse> responses = [];
  EndpointRequestBody? requestBody;

  EndpointVerb.fromMap(this.method, Map<String, dynamic> data) {
    data = deRef(data);
    summary = data['summary']!;
    id = data['operationId']!;
    tags.addAll((data['tags'] as List).toStrings());
    for (var param in data['parameters'] ?? []) {
      params.add(EndpointParam.fromMap(param));
    }
    for (var code in ((data['responses'] ?? {}) as Map).keys) {
      var response = data['responses'][code];
      var realCode = int.tryParse(code) ?? 0;
      if (realCode == 404) continue;
      responses.add(EndpointResponse.fromMap(realCode, response));
    }
    if (data['requestBody'] != null) {
      requestBody = EndpointRequestBody.fromMap(data['requestBody']);
    }
  }
}

class Endpoint {
  String pathspec = '';
  List<EndpointVerb> verbs = [];
  Map<String, EndpointParam> params = {};

  Endpoint.fromPath(this.pathspec, Map<String, dynamic> data) {
    if (pathspec.contains('/status/update')) {
      print('break here');
    }
    // handle verbs
    var methods = data.keys.where((key) => ['get', 'post', 'patch', 'put', 'delete'].contains(key));
    verbs = methods.map((method) => EndpointVerb.fromMap(method, data[method])).toList();

    // handle root params
    for (var param in data['parameters'] ?? []) {
      param = deRef(param);
      params[param['name']] = EndpointParam.fromMap(param);
    }
  }
}

class Spec {
  late String title;
  late String version;
  late String description;
  List<Endpoint> paths = [];

  Spec.fromMap(Map<String, dynamic> spec) {
    title = spec['info']!['title']!;
    version = spec['info']!['version']!;
    description = spec['info']!['description']!;

    for (var path in (spec['paths'] as Map).keys) {
      var data = spec['paths'][path];
      paths.add(Endpoint.fromPath(path, data));
    }
  }
}

String getDartTypeFromSchemaType(String type) {
  String argType = '';
  switch (type) {
    case 'array':
      argType = 'List';
      break;
    case 'boolean':
      argType = 'bool';
      break;
    case 'object':
      argType = 'Map';
      break;
    case 'number':
      argType = 'double';
      break;
    case 'integer':
      argType = 'int';
      break;
    case 'string':
    default:
      argType = 'String';
      break;
  }
  return argType;
}

// String getDartDefaultValueFromSchema(EndpointSchema schema) {
//   String argDef = '';
//   if (schema.defaultValue != null) {
//     switch (schema.type) {
//       case 'array':
//         argDef = 'List';
//         break;
//       case 'boolean':
//         argDef = 'bool';
//         break;
//       case 'object':
//         argDef = 'Map';
//         break;
//       case 'number':
//         argDef = 'double';
//         break;
//       case 'integer':
//         argDef = 'int';
//         break;
//       case 'string':
//       default:
//         argDef = 'String';
//         break;
//     }
//   }
//   return argDef;
// }

String schemaToComment(EndpointSchema schema) {
  return prettyJson(schema);
}

String exampleToComment(EndpointExample example) {
  if (example.name.isNotEmpty) {
    return example.valueJson.contains('\n')
        ? '''Example (${example.name}):

```json
${example.valueJson}
```'''
        : '- Example (${example.name}): `${example.value}`';
  }
  return example.valueJson.contains('\n')
      ? '''Example:

```json
${example.valueJson}
```'''
      : '- Example: `${example.value}`';
}

String pathToFunctions(Endpoint path) {
  // this is the accumulator for the final output
  List<String> output = [];

  // get the path arguments from the params
  String dartPathSpec = path.pathspec.replaceAll('{', r'$').replaceAll('}', '');

  // convert snake_case to camelCase
  dartPathSpec = dartPathSpec.snakeToCamelCase();

  // Some paths have parameters at the "path" level
  // instead of at the "verb" level. We account for them.
  List<String> allVerbFunctionArgs = [];
  List<String> allVerbOptionalArgs = [];
  Map<String, String> allVerbQueryArgs = {};
  List<String> allVerbArgNames = [];
  List<String> allVerbArgComments = [];

  for (var param in path.params.values) {
    String argVar = param.name.snakeToCamelCase();
    String argType = '';

    /// types can be string, boolean, array, object, number, integer
    /// `number` types for ProPresenter usually mean 0-1
    argType = getDartTypeFromSchemaType(param.schema.type);

    // is this param describing a query variable or a path variable?
    // path variables are automatically handled by the url string
    // interpolation created above as `dartPathSpec`
    if (param.location == 'query') {
      allVerbQueryArgs[param.name] = argVar;
    }

    // is this param required or optional?
    if (param.required) {
      allVerbFunctionArgs.add('$argType $argVar');
    } else {
      allVerbOptionalArgs.add('$argType? $argVar');
    }

    allVerbArgNames.add(argVar);
    allVerbArgComments.add('''
[$argVar] (${param.required ? 'required' : 'optional'}) :
${param.description}${param.examples.isNotEmpty ? '\n' : ''}''');
    for (var example in param.examples) {
      allVerbArgComments.add(exampleToComment(example));
    }
  }

  for (var verb in path.verbs) {
    List<String> functionArgs = [...allVerbFunctionArgs];
    List<String> optionalArgs = [...allVerbOptionalArgs];
    Map<String, String> queryArgs = {...allVerbQueryArgs};
    List<String> argNames = [...allVerbArgNames];
    List<String> argComments = ['\n## PARAMETERS', ...allVerbArgComments];

    List<String> responseComments = [];
    List<String> funcComments = [];
    bool canChunk = false;

    // handle params for this verb
    for (var param in verb.params) {
      if (param.name == 'chunked') {
        canChunk = true;
        continue;
      }
      String argVar = param.name.snakeToCamelCase();
      String argType = '';

      /// types can be string, boolean, array, object, number, integer
      /// `number` types for ProPresenter usually mean 0-1
      argType = getDartTypeFromSchemaType(param.schema.type);

      if (param.location == 'query') {
        queryArgs[param.name] = argVar;
      }
      if (param.required) {
        functionArgs.add('$argType $argVar');
      } else {
        optionalArgs.add('$argType? $argVar');
      }

      argNames.add(argVar);
      argComments.add('\n[$argVar] : ${param.description}\n');
      if (param.schema.options.isNotEmpty) {
        argComments.add('- Should be one of: ${param.schema.options.map((e) => '`$e`').join(', ')}\n');
      }
      if (param.schema.example != null) {
        argComments.add('Example: `${param.schema.example!}`');
      }
      for (var example in param.examples) {
        argComments.add(exampleToComment(example));
      }
    }

    // handle items from the request body spec
    if (verb.requestBody != null) {
      var argType = getDartTypeFromSchemaType(verb.requestBody!.schema.type);
      var argVar = 'postBody';
      var canmust = verb.requestBody!.required ? 'must' : 'can';
      var requiredoptional = verb.requestBody!.required ? 'required' : 'optional';
      var example = verb.requestBody!.schema.exampleJson;
      functionArgs.add('$argType $argVar');
      argNames.add(argVar);
      argComments.add('\n[$argVar] ($requiredoptional) : This is the data that $canmust be sent with this request.');
      if (example.isNotEmpty) argComments.add('\nExample:\n```json\n$example\n```');
      if (verb.requestBody!.examples.isNotEmpty) argComments.add('');
      for (var example in verb.requestBody!.examples) {
        argComments.add(exampleToComment(example));
      }
    }

    var funcName = verb.id;
    funcComments.add('''
`$funcName` -> `${path.pathspec}`

${verb.summary}
''');

    // handle responses
    for (var response in verb.responses) {
      responseComments.add('''\n## RESPONSE ${response.code}:
\n${response.description}

content-type: `${response.contentType}`
''');
      if (response.schema != null) responseComments.add('\nschema:\n```json\n${prettyJson(response.schema)}\n```');
      if (response.examples.isNotEmpty) {
        responseComments.add('Examples:');
        for (var example in response.examples) {
          responseComments.add(exampleToComment(example));
        }
      }
    }

    // NOW CREATE THE FUNCTION CONTENT ITSELF
    var funcArgs = functionArgs.join(', ');
    if (optionalArgs.isNotEmpty) {
      var args = ['{${optionalArgs.join(', ')}}'];
      if (funcArgs.isNotEmpty) args.insert(0, funcArgs);
      funcArgs = args.join(', ');
    }
    funcArgs = funcArgs.trim();

    // return values can be Uint8List for image data
    // or Map<String, dynamic> for application/json data
    // or Stream for chunked data (handled later)
    var funcRetVal = verb.responses.isNotEmpty && verb.responses.first.contentType == 'application/json'
        ? 'Map<String, dynamic>'
        : 'Uint8List';
    var funcRetLine = verb.responses.isNotEmpty && verb.responses.first.contentType == 'application/json'
        ? 'return json.decode(r.body);'
        : 'return r.bodyBytes;';

    List<String> queryPairs = [];
    queryArgs.forEach((key, value) => queryPairs.add('\'$key\' : $value.toString()'));
    var queryLine = queryArgs.isNotEmpty ? 'Map<String, dynamic> query = {${queryPairs.join(', ')}};\n' : '';
    var queryArg = queryArgs.isNotEmpty ? ', params: query' : '';
    var funcs = <String>[];

    // non-chunked versions
    if (verb.requestBody != null) {
      // version with post
      funcs.add('''
static Future<$funcRetVal> $funcName($funcArgs) async {
  String url = '$dartPathSpec';
  $queryLine
  return await call('${verb.method}', url$queryArg);
}
''');
    } else {
      // version with no posted data
      funcs.add('''
static Future<$funcRetVal> $funcName($funcArgs) async {
  String url = '$dartPathSpec';
  $queryLine
  return await call('${verb.method}', url$queryArg);
}
''');
    }

    // now, the chunked versions
    if (canChunk) {
      queryArg = queryArgs.isNotEmpty ? '...query, ' : '';

      if (verb.requestBody != null) {
        // version with post
        funcs.add('''
/// Streaming version of [$funcName]
static Future<Stream?> ${funcName}Stream($funcArgs) async {
  String url = '$dartPathSpec';
  $queryLine
  var uri = Uri.http('\$host:\$port', url, {$queryArg'chunked':'true'});
  return ChunkedJsonClient.request(uri, postData: data);
}
''');
      } else {
        // version with no posted data
        funcs.add('''
/// Streaming version of [$funcName]
static Future<Stream?> ${funcName}Stream($funcArgs) async {
  String url = '$dartPathSpec';
  $queryLine
  var uri = Uri.http('\$host:\$port', url, {$queryArg'chunked':'true'});
  return ChunkedJsonClient.request(uri);
}
''');
      }
    }

    output.add(funcComments.join('\n').replaceAll(RegExp(r'\n\n+'), '\n\n').prefixLines('/// '));
    if (argComments.length > 1) {
      output.add(argComments.join('\n').replaceAll(RegExp(r'\n\n+'), '\n\n').prefixLines('/// '));
    }
    if (responseComments.isNotEmpty) {
      output.add(responseComments.join('\n').replaceAll(RegExp(r'\n\n+'), '\n\n').prefixLines('/// '));
    }
    output.add(funcs.join('\n'));
  }
  return output.join('\n');
}

String codeGen(Spec apiSpec) {
  /// the logic of the code generator is to create a single function
  /// for every "path" action on ProPresenter...
  ///
  /// endpoints with path params should take them as function arguments
  /// endpoints with multiple verbs should yield multiple functions
  /// endpoints with chunked results should be separate functions
  ///
  /// Generated code should be commented

  List<String> functions = [];
  for (var path in apiSpec.paths) {
    functions.add(pathToFunctions(path));
  }

  return '''
/// AUTOGENERATED ON ${DateTime.now()}

import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'chunked_request.dart';

class PP {
  static String host = 'localhost';
  static int port = 50001;

  static config(String host, int port) {
    PP.host = host;
    PP.port = port;
  }

  /// [call] will use the response `content-type` to automatically
  /// determine if the response should be decoded from json or
  /// returned as [Uint8List] directly.
  static Future call(String verb, String path, {Map<String, dynamic>? params, Object? data}) async {
    var uri = Uri.http('\$host:\$port', path, params);
    var headers = {'content-type': 'application/json'};
    late http.Response r;
    switch (verb.toLowerCase()) {
      case 'get':
        r = await http.get(uri, headers: headers);
        break;
      case 'put':
        r = await http.put(uri, headers: headers, body: data);
        break;
      case 'delete':
        r = await http.delete(uri, headers: headers, body: data);
        break;
      case 'post':
        r = await http.post(uri, headers: headers, body: data);
        break;
      case 'patch':
        r = await http.patch(uri, headers: headers, body: data);
        break;
    }
    if (r.statusCode > 199 && r.statusCode < 300) {
      if (r.headers['content-type'] == 'application/json') {
        return json.decode(r.body);
      } else {
        return r.bodyBytes;
      }
    } else {
      throw http.ClientException(r.body);
    }
  }

${functions.join('\n').prefixLines('  ')}

}
''';
}

Future getLocalSpec(String specFile) async {
  spec = json.decode(File(specFile).readAsStringSync());
}

Future getRemoteSpec([String? specFile]) async {
  var url = 'https://renewedvision.com/api_spec/swagger.json';
  var r = await http.get(Uri.parse(url));

  // it's not a real json file, ignore the first line
  var source = r.body.split('\n').sublist(1).join('\n');
  spec = json.decode(source);

  if (specFile != null) File(specFile).writeAsStringSync(source);
}

void main() async {
  var specFile = 'pro-openapi-spec.json';
  getLocalSpec(specFile);
  // await getRemoteSpec(specFile);
  var apiSpec = Spec.fromMap(spec);

  // correct some path specs for consistency with parameter names
  var pathCorrections = {
    '/v1/stage/layout/{id}': '/v1/stage/layout/{layout_id}',
    '/v1/library/{id}': '/v1/library/{library_id}',
    '/v1/stage/layout/{id}/thumbnail': '/v1/stage/layout/{layout_id}/thumbnail',
  };
  for (var p in apiSpec.paths) {
    if (pathCorrections.containsKey(p.pathspec)) p.pathspec = pathCorrections[p.pathspec]!;
    print(p.pathspec);
  }

  var targetFile = 'lib/src/api_v1_generated.dart';
  String code = codeGen(apiSpec);

  File(targetFile).writeAsStringSync(code);
  Process.runSync('dart', ['format', '-l', '120', targetFile]);

  // print(deRef("#/paths/~1v1~1look~1current/put/responses/204"));
}