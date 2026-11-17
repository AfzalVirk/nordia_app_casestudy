import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydatis_app/sync/task_api.dart';

void main() {
  test(
    'PATCH sends the Idempotency-Key, baseVersion and only changed fields',
    () async {
      late http.Request seen;
      final api = HttpTaskApi(
        baseUrl: 'http://x',
        client: MockClient((req) async {
          seen = req;
          return http.Response(jsonEncode({'id': 'a', 'version': 4}), 200);
        }),
      );

      final r = await api.updateTask('key-12345678', 'a', 3, {
        'status': 'doing',
      });

      expect(r.isOk, true);
      expect(seen.method, 'PATCH');
      expect(seen.url.path, '/tasks/a');
      expect(seen.headers['Idempotency-Key'], 'key-12345678');
      expect(jsonDecode(seen.body), {'baseVersion': 3, 'status': 'doing'});
    },
  );

  test('a 500 is temporary', () async {
    final api = HttpTaskApi(
      baseUrl: 'http://x',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 'simulated_error', 'error': 'boom'}),
          500,
        ),
      ),
    );
    final r = await api.deleteTask('key-12345678', 'a', 1);
    expect(r.isTemporary, true);
    expect(r.isOk, false);
  });

  test('no network gives status 0, which is temporary', () async {
    final api = HttpTaskApi(
      baseUrl: 'http://x',
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    final r = await api.getMembers();
    expect(r.status, 0);
    expect(r.isTemporary, true);
  });

  test('a 409 exposes the current task and a 422 is not temporary', () async {
    var n = 0;
    final api = HttpTaskApi(
      baseUrl: 'http://x',
      client: MockClient((_) async {
        n++;
        if (n == 1) {
          return http.Response(
            jsonEncode({
              'code': 'version_conflict',
              'error': 'changed',
              'current': {'id': 'a', 'version': 5},
            }),
            409,
          );
        }
        return http.Response(
          jsonEncode({'code': 'validation_error', 'error': 'bad'}),
          422,
        );
      }),
    );

    final conflict = await api.updateTask('key-12345678', 'a', 3, {
      'title': 'x',
    });
    expect(conflict.isVersionConflict, true);
    expect(conflict.current!['version'], 5);

    final refused = await api.updateTask('key-87654321', 'a', 5, {'title': ''});
    expect(refused.isTemporary, false);
    expect(refused.isVersionConflict, false);
  });

  test('the replay header is detected', () async {
    final api = HttpTaskApi(
      baseUrl: 'http://x',
      client: MockClient(
        (_) async => http.Response(
          '{"id":"a"}',
          201,
          headers: {'idempotent-replay': 'true'},
        ),
      ),
    );
    final r = await api.createTask('key-12345678', {'id': 'a', 'title': 't'});
    expect(r.replay, true);
  });
}
