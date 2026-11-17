import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hydatis_app/data/app_database.dart';
import 'package:hydatis_app/data/models.dart';
import 'package:hydatis_app/data/task_repository.dart';
import 'package:hydatis_app/sync/task_api.dart';

String Function() counter() {
  var n = 0;
  return () => 'id-${(++n).toString().padLeft(8, '0')}';
}

Future<TaskRepository> newRepo() async {
  sqfliteFfiInit();
  final db = await AppDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  return TaskRepository(db, newId: counter());
}

/// A task that the server AND the phone both know, confirmed at [version].
Future<void> seedBoth(
  TaskRepository repo,
  FakeApi api, {
  String id = 't1',
  String title = 'Fix lift',
  String status = 'todo',
  int version = 3,
}) async {
  api.addTask(id: id, title: title, status: status, version: version);
  await repo.database.db.insert(
    'tasks',
    Task(
      id: id,
      title: title,
      status: status,
      version: version,
      updatedAt: '2026-01-01T00:00:00Z',
    ).toRow(),
  );
}

/// A small server that behaves like the real one, but we control it.
class FakeApi implements TaskApi {
  final Map<String, Map<String, dynamic>> tasks = {};
  final Map<String, int> _seq = {};
  int _counter = 0;
  final Map<String, ApiResponse> _answers = {};
  final Map<String, String> _fingerprints = {};

  /// One entry is used up per WRITE call:
  /// 'ok' | 'fail' (500, not applied) | 'lose' (applied, but the answer is lost)
  /// | 'offline' (no answer, not applied)
  final List<String> script = [];
  bool offline = false; // true = every call gets no answer
  int writeCalls = 0; // every write ATTEMPT, even when it fails
  int replays = 0; // how many times the server recognised a repeated key
  Set<String> memberIds = {'m-1', 'm-2', 'm-3'};

  // ---------- helpers for tests ----------

  void addTask({
    required String id,
    String title = 'Fix lift',
    String status = 'todo',
    int version = 1,
    bool deleted = false,
    String? assigneeId,
  }) {
    tasks[id] = {
      'id': id,
      'title': title,
      'note': null,
      'status': status,
      'assigneeId': assigneeId,
      'dueDate': null,
      'version': version,
      'deleted': deleted,
      'updatedAt': _stamp(),
    };
    _seq[id] = ++_counter;
  }

  /// A colleague changes fields of a task on the server.
  void colleagueEdit(String id, Map<String, dynamic> fields) {
    final t = tasks[id]!;
    t.addAll(fields);
    _touch(t);
  }

  void colleagueDelete(String id) {
    final t = tasks[id]!;
    t['deleted'] = true;
    _touch(t);
  }

  void _touch(Map<String, dynamic> t) {
    t['version'] = (t['version'] as int) + 1;
    t['updatedAt'] = _stamp();
    _seq[t['id'] as String] = ++_counter;
  }

  String _stamp() =>
      '2026-11-17T12:00:00.${_counter.toString().padLeft(3, '0')}Z';

  Map<String, dynamic> _copy(String id) =>
      Map<String, dynamic>.from(tasks[id]!);

  String? _validate(Map<String, dynamic> f, {bool creating = false}) {
    if (creating || f.containsKey('title')) {
      final t = f['title'];
      if (t is! String || t.trim().isEmpty || t.trim().length > 120) {
        return 'title: 1 to 120 characters';
      }
    }
    final a = f['assigneeId'];
    if (f.containsKey('assigneeId') && a != null && !memberIds.contains(a)) {
      return 'assigneeId: null or the id of a member';
    }
    return null;
  }

  ApiResponse _invalid(String message) =>
      ApiResponse(422, {'code': 'validation_error', 'error': message});

  // ---------- the idempotency logic of the real server ----------

  Future<ApiResponse> _write(
    String key,
    String fingerprint,
    ApiResponse Function() apply,
  ) async {
    writeCalls++;
    final mode = script.isEmpty ? 'ok' : script.removeAt(0);
    if (offline || mode == 'offline') return const ApiResponse(0, null);
    if (mode == 'fail') {
      return const ApiResponse(500, {
        'code': 'simulated_error',
        'error': 'boom',
      });
    }

    ApiResponse out;
    final previous = _answers[key];
    if (previous != null) {
      if (_fingerprints[key] == fingerprint) {
        replays++;
        out = ApiResponse(previous.status, previous.body, replay: true);
      } else {
        out = const ApiResponse(422, {
          'code': 'idempotency_key_reuse',
          'error': 'key already used',
        });
      }
    } else {
      out = apply();
      _answers[key] = out;
      _fingerprints[key] = fingerprint;
    }
    if (mode == 'lose') {
      return const ApiResponse(500, {
        'code': 'simulated_error',
        'error': 'boom',
      });
    }
    return out;
  }

  // ---------- TaskApi ----------

  @override
  Future<ApiResponse> getMembers() async {
    if (offline) return const ApiResponse(0, null);
    return ApiResponse(200, [
      for (final id in memberIds) {'id': id, 'name': 'Member $id'},
    ]);
  }

  @override
  Future<ApiResponse> getTasks({String? since, int limit = 50}) async {
    if (offline) return const ApiResponse(0, null);
    final s = since == null ? 0 : int.parse(since.substring(1));
    final matching = tasks.keys.where((id) => _seq[id]! > s).toList()
      ..sort((a, b) => _seq[a]!.compareTo(_seq[b]!));
    final page = matching.take(limit).toList();
    return ApiResponse(200, {
      'items': [for (final id in page) _copy(id)],
      'nextCursor': page.isEmpty ? since : 'c${_seq[page.last]}',
      'hasMore': matching.length > page.length,
    });
  }

  @override
  Future<ApiResponse> createTask(String opId, Map<String, dynamic> body) =>
      _write(opId, 'POST ${jsonEncode(body)}', () {
        final error = _validate(body, creating: true);
        if (error != null) return _invalid(error);
        final id = body['id'] as String;
        if (tasks.containsKey(id)) {
          return ApiResponse(409, {
            'code': 'id_exists',
            'error': 'already exists',
            'current': _copy(id),
          });
        }
        addTask(
          id: id,
          title: (body['title'] as String).trim(),
          status: (body['status'] as String?) ?? 'todo',
          assigneeId: body['assigneeId'] as String?,
        );
        tasks[id]!['note'] = body['note'];
        tasks[id]!['dueDate'] = body['dueDate'];
        return ApiResponse(201, _copy(id));
      });

  @override
  Future<ApiResponse> updateTask(
    String opId,
    String id,
    int baseVersion,
    Map<String, dynamic> fields,
  ) => _write(opId, 'PATCH $id $baseVersion ${jsonEncode(fields)}', () {
    final error = _validate(fields);
    if (error != null) return _invalid(error);
    final t = tasks[id];
    if (t == null) {
      return const ApiResponse(404, {
        'code': 'not_found',
        'error': 'Task not found',
      });
    }
    if (t['deleted'] == true) {
      return ApiResponse(410, {
        'code': 'task_deleted',
        'error': 'deleted',
        'current': _copy(id),
      });
    }
    if (t['version'] != baseVersion) {
      return ApiResponse(409, {
        'code': 'version_conflict',
        'error': 'changed',
        'current': _copy(id),
      });
    }
    if (t['status'] == 'done' && fields['status'] == 'todo') {
      return const ApiResponse(422, {
        'code': 'invalid_transition',
        'error': 'done cannot be todo',
      });
    }
    var changed = false;
    fields.forEach((k, v) {
      if (t[k] != v) {
        t[k] = v;
        changed = true;
      }
    });
    if (changed) _touch(t);
    return ApiResponse(200, _copy(id));
  });

  @override
  Future<ApiResponse> deleteTask(String opId, String id, int baseVersion) =>
      _write(opId, 'DELETE $id $baseVersion', () {
        final t = tasks[id];
        if (t == null) {
          return const ApiResponse(404, {
            'code': 'not_found',
            'error': 'Task not found',
          });
        }
        if (t['deleted'] == true) return ApiResponse(200, _copy(id));
        if (t['version'] != baseVersion) {
          return ApiResponse(409, {
            'code': 'version_conflict',
            'error': 'changed',
            'current': _copy(id),
          });
        }
        t['deleted'] = true;
        _touch(t);
        return ApiResponse(200, _copy(id));
      });
}
