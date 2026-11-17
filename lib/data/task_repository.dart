import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'app_database.dart';
import 'models.dart';

enum SyncState { synced, pending, rejected }

/// What a screen needs to show one task.
class TaskView {
  const TaskView({
    required this.task,
    required this.state,
    this.message,
    this.hasLostValues = false,
    this.notice,
  });
  final Task task; // confirmed state + my waiting edits on top
  final SyncState state;
  final String? message; // why it was rejected
  final bool hasLostValues; // I lost a conflict on some field
  final String? notice; // what happened in the last conflict merge
}

/// My value that lost a conflict, kept so the user can restore it.
class LostValue {
  const LostValue({
    required this.id,
    required this.taskId,
    required this.field,
    required this.myValue,
    required this.serverValue,
  });
  final int id;
  final String taskId;
  final String field;
  final String? myValue;
  final String? serverValue;
}

class ValidationException implements Exception {
  ValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TaskRepository extends ChangeNotifier {
  TaskRepository(
    this.database, {
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? (() => const Uuid().v4()),
       _now = now ?? DateTime.now;

  final AppDatabase database;
  final String Function() _newId;
  final DateTime Function() _now;
  Database get _db => database.db;

  // ---------- members + "who am I" ----------

  Future<void> saveMembers(List<Member> members) async {
    await _db.transaction((txn) async {
      await txn.delete('members');
      for (final m in members) {
        await txn.insert('members', {'id': m.id, 'name': m.name});
      }
    });
    notifyListeners();
  }

  Future<List<Member>> members() async {
    final rows = await _db.query('members', orderBy: 'name');
    return rows
        .map((r) => Member(r['id'] as String, r['name'] as String))
        .toList();
  }

  Future<String?> currentMemberId() => database.getMeta('me');

  Future<void> setCurrentMember(String id) async {
    await database.setMeta('me', id);
    notifyListeners();
  }

  // ---------- reading (what the screen shows) ----------

  Future<List<TaskView>> loadTasks() async {
    final taskRows = await _db.query(
      'tasks',
      where:
          "deleted = 0 OR id IN "
          "(SELECT task_id FROM ops WHERE status = 'rejected')",
    );
    final opRows = await _db.query('ops', orderBy: 'seq');
    final lostRows = await _db.rawQuery(
      'SELECT DISTINCT task_id FROM lost_values',
    );
    final lost = {for (final r in lostRows) r['task_id'] as String};
    final noticeRows = await _db.query('notices', orderBy: 'id');
    final notices = {
      for (final r in noticeRows)
        r['task_id'] as String: r['message'] as String,
    };

    final opsByTask = <String, List<SyncOp>>{};
    for (final r in opRows) {
      final op = SyncOp.fromRow(r);
      (opsByTask[op.taskId] ??= []).add(op);
    }

    final views = <TaskView>[];
    for (final r in taskRows) {
      var task = Task.fromRow(r);
      final ops = opsByTask[task.id] ?? const <SyncOp>[];
      final queued = ops.where((o) => o.status == OpStatus.queued).toList();
      final rejected = ops.where((o) => o.status == OpStatus.rejected).toList();

      // A delete waiting in the outbox hides the task right away.
      if (queued.any((o) => o.type == OpType.delete)) continue;

      // Confirmed state + my waiting edits on top (rejected edits are NOT applied).
      for (final o in queued.where((o) => o.type == OpType.update)) {
        task = task.withPatch(o.payload);
      }

      SyncState state;
      String? message;
      if (rejected.isNotEmpty) {
        state = SyncState.rejected;
        message = rejected.last.errorMessage ?? rejected.last.errorCode;
      } else if (queued.isNotEmpty) {
        state = SyncState.pending;
      } else {
        state = SyncState.synced;
      }
      views.add(
        TaskView(
          task: task,
          state: state,
          message: message,
          hasLostValues: lost.contains(task.id),
          notice: notices[task.id],
        ),
      );
    }

    // Newest first. updatedAt is only used for the ORDER OF THE LIST, never to
    // decide whose edit wins (that is always the server version number).
    views.sort((a, b) {
      final c = b.task.updatedAt.compareTo(a.task.updatedAt);
      return c != 0 ? c : a.task.id.compareTo(b.task.id);
    });
    return views;
  }

  Future<List<SyncOp>> allOps() async {
    final rows = await _db.query('ops', orderBy: 'seq');
    return rows.map(SyncOp.fromRow).toList();
  }

  Future<int> pendingCount() async {
    final r = await _db.rawQuery(
      "SELECT COUNT(*) AS n FROM ops WHERE status = 'queued'",
    );
    return r.first['n'] as int;
  }

  void changed() => notifyListeners();

  // ---------- writing (always local first, then the outbox) ----------

  Future<String> createTask({
    required String title,
    String? note,
    String status = 'todo',
    String? assigneeId,
    String? dueDate,
  }) async {
    final t = title.trim();
    _checkTitle(t);
    _checkNote(note);
    _checkStatus(status);

    final id = _newId();
    final task = Task(
      id: id,
      title: t,
      note: note,
      status: status,
      assigneeId: assigneeId,
      dueDate: dueDate,
      version: 0, // the server will give version 1
      updatedAt: _now().toUtc().toIso8601String(), // list order only
      localOnly: true,
    );
    await _db.transaction((txn) async {
      await txn.insert('tasks', task.toRow());
      await _insertOp(
        txn,
        type: OpType.create,
        taskId: id,
        payload: task.toCreateJson(),
        baseValues: {},
        baseVersion: null,
      );
    });
    notifyListeners();
    return id;
  }

  /// Returns true if something really changed (and an op was queued).
  Future<bool> updateTask(String taskId, Map<String, dynamic> changes) async {
    for (final k in changes.keys) {
      if (!taskFields.contains(k)) throw ArgumentError('unknown field $k');
    }
    var changed = false;
    await _db.transaction((txn) async {
      final confirmed = await _confirmed(txn, taskId);
      final shown = await _displayed(txn, taskId);
      if (confirmed == null || shown == null) {
        throw ValidationException('Task not found');
      }

      final patch = <String, dynamic>{};
      final base = <String, dynamic>{};
      changes.forEach((k, v) {
        final value = k == 'title' ? (v as String).trim() : v;
        if (shown.field(k) != value) {
          patch[k] = value;
          base[k] = shown.field(k); // the value I started from
        }
      });
      if (patch.isEmpty) return; // nothing changed: no op

      _validatePatch(patch);
      if (shown.status == 'done' && patch['status'] == 'todo') {
        throw ValidationException(
          'A done task cannot go back to todo (use doing)',
        );
      }

      await _insertOp(
        txn,
        type: OpType.update,
        taskId: taskId,
        payload: patch,
        baseValues: base,
        baseVersion: confirmed.localOnly ? null : confirmed.version,
      );
      changed = true;
    });
    if (changed) notifyListeners();
    return changed;
  }

  Future<void> deleteTask(String taskId) async {
    await _db.transaction((txn) async {
      final confirmed = await _confirmed(txn, taskId);
      if (confirmed == null) return;
      final already = await txn.query(
        'ops',
        where: "task_id = ? AND type = 'delete' AND status = 'queued'",
        whereArgs: [taskId],
      );
      if (already.isNotEmpty) return;
      await _insertOp(
        txn,
        type: OpType.delete,
        taskId: taskId,
        payload: {},
        baseValues: {},
        baseVersion: confirmed.localOnly ? null : confirmed.version,
      );
    });
    notifyListeners();
  }

  /// The user has read the rejection and wants it gone.
  Future<void> dismissRejected(String taskId) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'ops',
        where: "task_id = ? AND status = 'rejected'",
        whereArgs: [taskId],
      );
      final task = await _confirmed(txn, taskId);
      if (task != null && task.localOnly) {
        final stillCreating = await txn.query(
          'ops',
          where: "task_id = ? AND type = 'create'",
          whereArgs: [taskId],
        );
        if (stillCreating.isEmpty) {
          // The create was refused: the task never existed on the server.
          await txn.delete('ops', where: 'task_id = ?', whereArgs: [taskId]);
          await txn.delete('tasks', where: 'id = ?', whereArgs: [taskId]);
        }
      }
    });
    notifyListeners();
  }

  Future<List<LostValue>> lostValues(String taskId) async {
    final rows = await _db.query(
      'lost_values',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'id',
    );
    return rows
        .map(
          (r) => LostValue(
            id: r['id'] as int,
            taskId: r['task_id'] as String,
            field: r['field'] as String,
            myValue: r['my_value'] as String?,
            serverValue: r['server_value'] as String?,
          ),
        )
        .toList();
  }

  /// "Use mine": queue my saved value as a new edit. It is checked against
  /// the server again, like any other edit.
  Future<void> useMine(int lostId) async {
    final rows = await _db.query(
      'lost_values',
      where: 'id = ?',
      whereArgs: [lostId],
    );
    if (rows.isEmpty) return;
    final r = rows.first;
    await updateTask(r['task_id'] as String, {
      r['field'] as String: r['my_value'],
    });
    await _db.delete('lost_values', where: 'id = ?', whereArgs: [lostId]);
    notifyListeners();
  }

  /// "Keep theirs": forget my saved value.
  Future<void> discardLost(int lostId) async {
    await _db.delete('lost_values', where: 'id = ?', whereArgs: [lostId]);
    notifyListeners();
  }

  Future<void> dismissNotice(String taskId) async {
    await _db.delete('notices', where: 'task_id = ?', whereArgs: [taskId]);
    notifyListeners();
  }

  // ---------- helpers ----------

  Future<Task?> _confirmed(DatabaseExecutor ex, String taskId) async {
    final rows = await ex.query('tasks', where: 'id = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : Task.fromRow(rows.first);
  }

  /// Confirmed task + my waiting update ops applied on top.
  Future<Task?> _displayed(DatabaseExecutor ex, String taskId) async {
    var task = await _confirmed(ex, taskId);
    if (task == null) return null;
    final rows = await ex.query(
      'ops',
      where: "task_id = ? AND status = 'queued' AND type = 'update'",
      whereArgs: [taskId],
      orderBy: 'seq',
    );
    for (final r in rows) {
      task = task!.withPatch(SyncOp.fromRow(r).payload);
    }
    return task;
  }

  Future<void> _insertOp(
    DatabaseExecutor ex, {
    required OpType type,
    required String taskId,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> baseValues,
    required int? baseVersion,
  }) async {
    await ex.insert('ops', {
      'op_id': _newId(), // this is the Idempotency-Key, it never changes
      'task_id': taskId,
      'type': type.name,
      'payload': jsonEncode(payload),
      'base_values': jsonEncode(baseValues),
      'base_version': baseVersion,
      'status': 'queued',
      'attempts': 0,
    });
  }

  void _checkTitle(String t) {
    if (t.isEmpty || t.length > 120) {
      throw ValidationException('Title must be 1 to 120 characters');
    }
  }

  void _checkNote(String? n) {
    if (n != null && n.length > 500) {
      throw ValidationException('Note must be at most 500 characters');
    }
  }

  void _checkStatus(String s) {
    if (!statusOrder.contains(s)) {
      throw ValidationException('Status must be todo, doing or done');
    }
  }

  void _validatePatch(Map<String, dynamic> p) {
    if (p.containsKey('title')) _checkTitle(p['title'] as String);
    if (p.containsKey('note')) _checkNote(p['note'] as String?);
    if (p.containsKey('status')) _checkStatus(p['status'] as String);
  }
}
