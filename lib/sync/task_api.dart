import 'dart:convert';
import 'package:http/http.dart' as http;

/// Emulator reaches your PC at 10.0.2.2. Override with:
/// flutter run --dart-define=API_URL=http://192.168.x.x:3002
const defaultBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://10.0.2.2:3002',
);

class ApiResponse {
  const ApiResponse(this.status, this.body, {this.replay = false});

  /// 0 = no answer at all (no network, timeout, broken connection).
  final int status;
  final dynamic body;

  /// true when the server says "I already did this" (Idempotent-Replay header).
  final bool replay;

  bool get isOk => status >= 200 && status < 300;

  /// Temporary problem: retry later with the SAME key.
  bool get isTemporary => status == 0 || status >= 500;

  String? get code {
    final b = body;
    return b is Map ? b['code'] as String? : null;
  }

  String get message {
    final b = body;
    if (b is Map && b['error'] is String) return b['error'] as String;
    if (status == 0) return 'No answer from the server (network or timeout)';
    return 'Server error $status';
  }

  /// The task as the server has it now (sent with 409 and 410 errors).
  Map<String, dynamic>? get current {
    final b = body;
    if (b is Map && b['current'] is Map) {
      return Map<String, dynamic>.from(b['current'] as Map);
    }
    return null;
  }

  bool get isVersionConflict => status == 409 && code == 'version_conflict';
}

abstract class TaskApi {
  Future<ApiResponse> getMembers();
  Future<ApiResponse> getTasks({String? since, int limit = 50});
  Future<ApiResponse> createTask(String opId, Map<String, dynamic> body);
  Future<ApiResponse> updateTask(
    String opId,
    String id,
    int baseVersion,
    Map<String, dynamic> fields,
  );
  Future<ApiResponse> deleteTask(String opId, String id, int baseVersion);
}

class HttpTaskApi implements TaskApi {
  HttpTaskApi({
    this.baseUrl = defaultBaseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  Future<ApiResponse> _send(
    String method,
    String path, {
    String? key,
    Object? jsonBody,
  }) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    if (key != null) req.headers['Idempotency-Key'] = key;
    if (jsonBody != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(jsonBody);
    }
    try {
      final streamed = await _client.send(req).timeout(timeout);
      final res = await http.Response.fromStream(streamed).timeout(timeout);
      dynamic body;
      try {
        body = res.body.isEmpty ? null : jsonDecode(res.body);
      } catch (_) {
        body = null;
      }
      return ApiResponse(
        res.statusCode,
        body,
        replay: res.headers['idempotent-replay'] == 'true',
      );
    } catch (_) {
      // Timeout, no network, connection reset: we do NOT know what happened.
      return const ApiResponse(0, null);
    }
  }

  @override
  Future<ApiResponse> getMembers() => _send('GET', '/members');

  @override
  Future<ApiResponse> getTasks({String? since, int limit = 50}) {
    final q = StringBuffer('?limit=$limit');
    if (since != null) q.write('&since=${Uri.encodeQueryComponent(since)}');
    return _send('GET', '/tasks$q');
  }

  @override
  Future<ApiResponse> createTask(String opId, Map<String, dynamic> body) =>
      _send('POST', '/tasks', key: opId, jsonBody: body);

  @override
  Future<ApiResponse> updateTask(
    String opId,
    String id,
    int baseVersion,
    Map<String, dynamic> fields,
  ) => _send(
    'PATCH',
    '/tasks/$id',
    key: opId,
    jsonBody: {'baseVersion': baseVersion, ...fields},
  );

  @override
  Future<ApiResponse> deleteTask(String opId, String id, int baseVersion) =>
      _send('DELETE', '/tasks/$id?baseVersion=$baseVersion', key: opId);
}
