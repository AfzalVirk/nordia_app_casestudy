import 'dart:convert';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../data/models.dart';
import '../data/task_repository.dart';
import 'task_api.dart';

/// How long to wait after the Nth failed attempt: 2s, 4s, 8s, 16s, 32s, then 60s.
Duration backoffFor(int attempts) =>
    Duration(seconds: min(60, 1 << min(attempts, 6)));

class SyncReport {
  int done = 0;
  int retryLater = 0;
  int rejected = 0;
  int merged = 0; // conflicts that were resolved
}

enum _Outcome { done, retryLater, rejected, merged }

class SyncEngine {
  SyncEngine({
    required this.repo,
    required this.api,
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? (() => const Uuid().v4());

  final TaskRepository repo;
  final TaskApi api;
  final DateTime Function() _now;
  final String Function() _newId;
  Future<SyncReport>? _running;

  Database get _db => repo.database.db;

  /// Sends the outbox. [force] = the Sync button: ignore the waiting times.
  /// Two calls at the same time share one run (never two sends in parallel).
  Future<SyncReport> pushOutbox({bool force = false}) {
    final running = _running;
    if (running != null) return running;
    final run = _pushAll(force).whenComplete(() => _running = null);
    _running = run;
    return run;
  }

  /// After a conflict is merged, the changed op must be sent again.
  /// We do up to 4 rounds so one press of Sync is enough.
  Future<SyncReport> _pushAll(bool force) async {
    final total = SyncReport();
    for (var round = 0; round < 4; round++) {
      final r = await _push(round == 0 && force);
      total.done += r.done;
      total.retryLater += r.retryLater;
      total.rejected += r.rejected;
      total.merged += r.merged;
      if (r.merged == 0) break;
    }
    return total;
  }

  Future<SyncReport> _push(bool force) async {
    final report = SyncReport();
    final queued = await _db.query(
      'ops',
      columns: ['seq'],
      where: "status = 'queued'",
      orderBy: 'seq',
    );
    final blocked = <String>{}; // tasks whose later ops must wait

    for (final row in queued) {
      // Read the op again: an earlier op may have rebased or removed it.
      final fresh = await _db.query(
        'ops',
        where: 'seq = ?',
        whereArgs: [row['seq']],
      );
      if (fresh.isEmpty) continue;
      final op = SyncOp.fromRow(fresh.first);
      if (op.status != OpStatus.queued || blocked.contains(op.taskId)) continue;

      final waiting =
          op.nextAttemptAt != null &&
          op.nextAttemptAt! > _now().millisecondsSinceEpoch;
      final notReady = op.type != OpType.create && op.baseVersion == null;
      if ((waiting && !force) || notReady) {
        blocked.add(op.taskId);
        continue;
      }

      final res = await _send(op);
      switch (await _handle(op, res)) {
        case _Outcome.done:
          report.done++;
        case _Outcome.retryLater:
          report.retryLater++;
          blocked.add(op.taskId);
        case _Outcome.rejected:
          report.rejected++;
        case _Outcome.merged:
          report.merged++;
          blocked.add(op.taskId); // its re-send happens in the next round
      }
      repo.changed();
    }
    return report;
  }

  Future<ApiResponse> _send(SyncOp op) => switch (op.type) {
    OpType.create => api.createTask(op.opId, op.payload),
    OpType.update => api.updateTask(
      op.opId,
      op.taskId,
      op.baseVersion!,
      op.payload,
    ),
    OpType.delete => api.deleteTask(op.opId, op.taskId, op.baseVersion!),
  };

  Future<_Outcome> _handle(SyncOp op, ApiResponse res) async {
    if (res.isOk) {
      await _applySuccess(op, res);
      return _Outcome.done;
    }
    if (res.isTemporary) {
      await _retryLater(op, res);
      return _Outcome.retryLater;
    }
    if (op.type == OpType.delete && res.status == 404) {
      await _applyGone(op); // nothing to delete on the server: goal reached
      return _Outcome.done;
    }

    // 409: someone else changed the task. We resolve it (rule S4).
    if (res.isVersionConflict) {
      final current = res.current;
      if (current != null) {
        final server = Task.fromJson(current);
        if (op.type == OpType.update) {
          await _mergeUpdate(op, server);
          return _Outcome.merged;
        }
        if (op.type == OpType.delete) {
          await _cancelDelete(op, server);
          return _Outcome.merged;
        }
      }
    }

    // Anything else is the server saying "no": trying again is pointless.
    final message = switch (res.code) {
      'version_conflict' => 'The task was changed by someone else',
      'task_deleted' => 'This task was deleted by someone else',
      'not_found' => 'This task no longer exists on the server',
      _ => res.message,
    };
    await _reject(op, res, message);
    return _Outcome.rejected;
  }

  // ---------- conflict resolution ----------

  Future<void> _mergeUpdate(SyncOp op, Task server) async {
    final keep = <String, dynamic>{}; // my changes that can still be sent
    final lost = <String, dynamic>{}; // my values that lose: saved, not sent
    var statusKept = false;

    for (final e in op.payload.entries) {
      final field = e.key;
      final mine = e.value;
      final theirs = server.field(field);
      final base = op.baseValues[field]; // the value I started from

      if (theirs == base) {
        keep[field] = mine; // only I changed it
        continue;
      }
      if (theirs == mine) continue; // we both ended on the same value
      if (field == 'status') {
        // both changed status: the furthest along wins
        if (statusRank(mine as String) > statusRank(theirs as String)) {
          keep[field] = mine;
        } else {
          statusKept = true;
        }
        continue;
      }
      lost[field] = mine; // same field, different values: server stays
    }

    final parts = <String>[];
    if (lost.isNotEmpty) {
      parts.add(
        'Someone else changed ${lost.keys.join(', ')} too. '
        'Their value was kept; yours is saved so you can restore it.',
      );
    }
    if (statusKept) {
      parts.add('Status kept at "${server.status}" (the furthest along).');
    }
    if (parts.isEmpty) parts.add('Merged with changes made by someone else.');

    await _db.transaction((txn) async {
      // The server's version of the task is the confirmed state now.
      await txn.insert(
        'tasks',
        server.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final e in lost.entries) {
        await txn.delete(
          'lost_values',
          where: 'task_id = ? AND field = ?',
          whereArgs: [op.taskId, e.key],
        ); // keep only my latest lost value
        await txn.insert('lost_values', {
          'task_id': op.taskId,
          'field': e.key,
          'my_value': e.value as String?,
          'server_value': server.field(e.key) as String?,
        });
      }

      if (keep.isEmpty) {
        await txn.delete('ops', where: 'seq = ?', whereArgs: [op.seq]);
      } else {
        // A conflict answer is final for its key: the new attempt is a NEW
        // operation, so it gets a new key and the server's new version.
        await txn.update(
          'ops',
          {
            'op_id': _newId(),
            'payload': jsonEncode(keep),
            'base_values': jsonEncode({
              for (final f in keep.keys) f: server.field(f),
            }),
            'base_version': server.version,
            'attempts': 0,
            'next_attempt_at': null,
            'error_code': null,
            'error_message': null,
          },
          where: 'seq = ?',
          whereArgs: [op.seq],
        );
      }
      await txn.insert('notices', {
        'task_id': op.taskId,
        'message': parts.join(' '),
      });
    });
  }

  Future<void> _cancelDelete(SyncOp op, Task server) async {
    await _db.transaction((txn) async {
      await txn.insert(
        'tasks',
        server.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete('ops', where: 'seq = ?', whereArgs: [op.seq]);
      await txn.insert('notices', {
        'task_id': op.taskId,
        'message':
            'Delete cancelled: someone changed this task meanwhile. '
            'Delete it again if you still want to.',
      });
    });
  }

  // ---------- results of a send ----------

  Future<void> _applySuccess(SyncOp op, ApiResponse res) async {
    final server = Task.fromJson(Map<String, dynamic>.from(res.body as Map));
    await _db.transaction((txn) async {
      // The server's answer is the confirmed state, unless we already hold a
      // NEWER version (a replayed answer can be older than what we pulled).
      final version = await storeConfirmed(txn, server);
      await txn.delete('ops', where: 'seq = ?', whereArgs: [op.seq]);
      if (op.type == OpType.delete) {
        await txn.delete(
          'ops',
          where: "task_id = ? AND seq > ? AND status = 'queued'",
          whereArgs: [op.taskId, op.seq],
        );
      } else {
        // Rebase: my next edits now start from the version we hold.
        await txn.rawUpdate(
          "UPDATE ops SET base_version = ? "
          "WHERE task_id = ? AND seq > ? AND status = 'queued' "
          "AND type != 'create'",
          [version, op.taskId, op.seq],
        );
      }
    });
  }

  Future<void> _applyGone(SyncOp op) async {
    await _db.transaction((txn) async {
      await txn.update(
        'tasks',
        {'deleted': 1},
        where: 'id = ?',
        whereArgs: [op.taskId],
      );
      await txn.delete(
        'ops',
        where: "task_id = ? AND seq >= ? AND status = 'queued'",
        whereArgs: [op.taskId, op.seq],
      );
    });
  }

  Future<void> _retryLater(SyncOp op, ApiResponse res) async {
    final attempts = op.attempts + 1;
    await _db.update(
      'ops',
      {
        'attempts': attempts,
        'next_attempt_at': _now()
            .add(backoffFor(attempts))
            .millisecondsSinceEpoch,
        'error_code': res.code ?? 'no_answer',
        'error_message': res.message,
      },
      where: 'seq = ?',
      whereArgs: [op.seq],
    );
  }

  Future<void> _reject(SyncOp op, ApiResponse res, String message) async {
    await _db.transaction((txn) async {
      await txn.update(
        'ops',
        {
          'status': 'rejected',
          'attempts': op.attempts + 1,
          'error_code': res.code ?? 'http_${res.status}',
          'error_message': message,
        },
        where: 'seq = ?',
        whereArgs: [op.seq],
      );
      if (op.type == OpType.create) {
        // The task never existed on the server: its later edits make no sense.
        await txn.update(
          'ops',
          {
            'status': 'rejected',
            'error_code': 'create_rejected',
            'error_message': message,
          },
          where: "task_id = ? AND seq > ? AND status = 'queued'",
          whereArgs: [op.taskId, op.seq],
        );
      }
    });
  }
}

/// Saves [server] as the confirmed task, unless we already hold a newer
/// version of it. Returns the version we end up holding.
Future<int> storeConfirmed(DatabaseExecutor ex, Task server) async {
  final rows = await ex.query(
    'tasks',
    columns: ['version'],
    where: 'id = ?',
    whereArgs: [server.id],
  );
  if (rows.isNotEmpty) {
    final held = rows.first['version'] as int;
    if (held > server.version) return held;
  }
  await ex.insert(
    'tasks',
    server.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  return server.version;
}
