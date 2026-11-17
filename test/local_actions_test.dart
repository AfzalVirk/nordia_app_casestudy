import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hydatis_app/data/app_database.dart';
import 'package:hydatis_app/data/models.dart';
import 'package:hydatis_app/data/task_repository.dart';

String Function() counter() {
  var n = 0;
  // 8+ characters, like a real Idempotency-Key must be
  return () => 'id-${(++n).toString().padLeft(8, '0')}';
}

Future<TaskRepository> newRepo() async {
  final db = await AppDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  return TaskRepository(db, newId: counter());
}

/// A task the server already confirmed, at version 3.
Future<void> seed(TaskRepository repo, {String status = 'todo'}) async {
  await repo.database.db.insert(
    'tasks',
    Task(
      id: 't1',
      title: 'Fix lift',
      status: status,
      version: 3,
      updatedAt: '2026-01-01T00:00:00Z',
    ).toRow(),
  );
}

void main() {
  sqfliteFfiInit();

  test(
    'creating a task offline shows it as pending and queues a create op',
    () async {
      final repo = await newRepo();
      final id = await repo.createTask(title: '  Check boiler  ');

      final list = await repo.loadTasks();
      expect(list.single.task.title, 'Check boiler');
      expect(list.single.task.localOnly, true);
      expect(list.single.state, SyncState.pending);

      final op = (await repo.allOps()).single;
      expect(op.type, OpType.create);
      expect(op.baseVersion, isNull);
      expect(op.payload['id'], id);
    },
  );

  test(
    'an edit queues only the changed field, with its old value and version',
    () async {
      final repo = await newRepo();
      await seed(repo);

      await repo.updateTask('t1', {'status': 'doing', 'title': 'Fix lift'});

      final op = (await repo.allOps()).single;
      expect(op.type, OpType.update);
      expect(op.payload, {'status': 'doing'}); // title did not change
      expect(op.baseValues, {'status': 'todo'}); // where I started from
      expect(op.baseVersion, 3);

      final view = (await repo.loadTasks()).single;
      expect(view.task.status, 'doing'); // screen reacts immediately
      expect(view.state, SyncState.pending);
    },
  );

  test(
    'two offline edits of one task are both shown and both queued',
    () async {
      final repo = await newRepo();
      await seed(repo);

      await repo.updateTask('t1', {'title': 'A'});
      await repo.updateTask('t1', {'title': 'B', 'status': 'doing'});

      final ops = await repo.allOps();
      expect(ops.length, 2);
      // Both start from version 3 for now; Step 4 will rebase the 2nd one
      // after the 1st is confirmed.
      expect(ops[0].baseVersion, 3);
      expect(ops[1].baseVersion, 3);
      expect(ops[1].baseValues['title'], 'A'); // starts from MY first edit

      final task = (await repo.loadTasks()).single.task;
      expect(task.title, 'B');
      expect(task.status, 'doing');
    },
  );

  test(
    'editing a task the server does not know yet waits (baseVersion null)',
    () async {
      final repo = await newRepo();
      final id = await repo.createTask(title: 'New');
      await repo.updateTask(id, {'status': 'doing'});

      final ops = await repo.allOps();
      expect(ops.map((o) => o.type), [OpType.create, OpType.update]);
      expect(ops[1].baseVersion, isNull);
    },
  );

  test('deleting hides the task at once and queues a delete op', () async {
    final repo = await newRepo();
    await seed(repo);

    await repo.deleteTask('t1');

    expect(await repo.loadTasks(), isEmpty);
    final op = (await repo.allOps()).single;
    expect(op.type, OpType.delete);
    expect(op.baseVersion, 3);
  });

  test('an edit that changes nothing creates no op', () async {
    final repo = await newRepo();
    await seed(repo);

    final changed = await repo.updateTask('t1', {'title': 'Fix lift'});

    expect(changed, false);
    expect(await repo.allOps(), isEmpty);
  });

  test('invalid input is refused locally and queues nothing', () async {
    final repo = await newRepo();
    await expectLater(
      repo.createTask(title: '   '),
      throwsA(isA<ValidationException>()),
    );

    await seed(repo, status: 'done');
    await expectLater(
      repo.updateTask('t1', {'status': 'todo'}),
      throwsA(isA<ValidationException>()),
    );
    await repo.updateTask('t1', {'status': 'doing'}); // done -> doing is fine

    expect((await repo.allOps()).length, 1);
  });

  test('a rejected op is shown as rejected and can be dismissed', () async {
    final repo = await newRepo();
    final id = await repo.createTask(title: 'Bad one');
    await repo.database.db.update('ops', {
      'status': 'rejected',
      'error_message': 'Server said no',
    });

    final view = (await repo.loadTasks()).single;
    expect(view.state, SyncState.rejected);
    expect(view.message, 'Server said no');

    await repo.dismissRejected(id);
    expect(await repo.loadTasks(), isEmpty);
    expect(await repo.allOps(), isEmpty);
  });

  test('the queue survives closing and reopening the database', () async {
    final dir = Directory.systemTemp.createTempSync('hydatis_test');
    final path = '${dir.path}/tasks.db';

    var db = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    var repo = TaskRepository(db, newId: counter());
    await repo.createTask(title: 'Survive');
    await db.close(); // "the app is closed"

    db = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    repo = TaskRepository(db, newId: counter());
    expect((await repo.allOps()).length, 1);
    final view = (await repo.loadTasks()).single;
    expect(view.task.title, 'Survive');
    expect(view.state, SyncState.pending);

    await db.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {} // Windows can keep the file locked for a moment: ignore
  });
}
