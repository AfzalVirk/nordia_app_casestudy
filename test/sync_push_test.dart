import 'package:flutter_test/flutter_test.dart';
import 'package:hydatis_app/data/models.dart';
import 'package:hydatis_app/data/task_repository.dart';
import 'package:hydatis_app/sync/sync_engine.dart';
import 'test_support.dart';

void main() {
  late TaskRepository repo;
  late FakeApi api;
  late SyncEngine engine;
  var clock = DateTime(2026, 11, 17, 12);

  setUp(() async {
    clock = DateTime(2026, 11, 17, 12);
    repo = await newRepo();
    api = FakeApi();
    engine = SyncEngine(repo: repo, api: api, now: () => clock);
  });

  test(
    'a task created offline, then edited offline, is sent in order',
    () async {
      final id = await repo.createTask(title: 'Boiler');
      await repo.updateTask(id, {'status': 'doing'});

      final report = await engine.pushOutbox();

      expect(report.done, 2);
      expect(api.tasks[id]!['version'], 2);
      expect(api.tasks[id]!['status'], 'doing');
      expect(await repo.allOps(), isEmpty);
      final view = (await repo.loadTasks()).single;
      expect(view.state, SyncState.synced);
      expect(view.task.version, 2);
      expect(view.task.localOnly, false);
    },
  );

  test(
    'answer lost: the retry reuses the key and creates no duplicate',
    () async {
      api.script.add('lose'); // 1st call is applied, but the app gets a 500
      await repo.createTask(title: 'Once');

      final first = await engine.pushOutbox();
      expect(first.retryLater, 1);
      expect(api.tasks.length, 1); // the server DID create it
      expect((await repo.allOps()).single.attempts, 1);
      expect((await repo.loadTasks()).single.state, SyncState.pending);

      clock = clock.add(const Duration(seconds: 1)); // wait is 2s: too early
      await engine.pushOutbox();
      expect(api.writeCalls, 1);

      clock = clock.add(const Duration(seconds: 5));
      final second = await engine.pushOutbox();
      expect(second.done, 1);
      expect(api.tasks.length, 1); // still ONE task
      expect(api.replays, 1); // the server recognised the same key
      expect(await repo.allOps(), isEmpty);
      expect((await repo.loadTasks()).single.state, SyncState.synced);
    },
  );

  test(
    'offline: waits longer after each failure, Sync now ignores the wait',
    () async {
      api.offline = true;
      await repo.createTask(title: 'Later');

      await engine.pushOutbox();
      expect(api.writeCalls, 1);
      await engine.pushOutbox(); // too early: not even tried
      expect(api.writeCalls, 1);

      clock = clock.add(const Duration(seconds: 3));
      await engine.pushOutbox();
      expect(api.writeCalls, 2);
      expect((await repo.allOps()).single.attempts, 2);

      await engine.pushOutbox(force: true); // the Sync button
      expect(api.writeCalls, 3);

      api.offline = false;
      final r = await engine.pushOutbox(force: true);
      expect(r.done, 1);
      expect(api.tasks.length, 1);
    },
  );

  test('the waiting time grows and stops at 60 seconds', () {
    expect(backoffFor(1), const Duration(seconds: 2));
    expect(backoffFor(2), const Duration(seconds: 4));
    expect(backoffFor(3), const Duration(seconds: 8));
    expect(backoffFor(6), const Duration(seconds: 60));
    expect(backoffFor(50), const Duration(seconds: 60));
  });

  test('a 422 is a rejection: shown as rejected and never retried', () async {
    await repo.createTask(title: 'Bad', assigneeId: 'm-99'); // not a member

    final r = await engine.pushOutbox();

    expect(r.rejected, 1);
    final op = (await repo.allOps()).single;
    expect(op.status, OpStatus.rejected);
    expect(op.errorCode, 'validation_error');
    expect((await repo.loadTasks()).single.state, SyncState.rejected);

    await engine.pushOutbox(force: true);
    expect(api.writeCalls, 1); // never sent again
    expect(api.tasks, isEmpty);
  });

  test(
    'when a create is rejected, later edits of that task are rejected too',
    () async {
      final id = await repo.createTask(title: 'Bad', assigneeId: 'm-99');
      await repo.updateTask(id, {'status': 'doing'});

      final r = await engine.pushOutbox();

      expect(r.rejected, 1); // only the create was sent
      expect(api.writeCalls, 1);
      final ops = await repo.allOps();
      expect(ops.map((o) => o.status), [OpStatus.rejected, OpStatus.rejected]);
    },
  );

  test('a failing task does not block other tasks', () async {
    api.script.add('fail'); // the first call fails (500, not applied)
    final a = await repo.createTask(title: 'A');
    final b = await repo.createTask(title: 'B');

    final r = await engine.pushOutbox();

    expect(r.retryLater, 1);
    expect(r.done, 1);
    expect(api.tasks.containsKey(a), false);
    expect(api.tasks.containsKey(b), true);
  });

  test(
    'two offline edits of a synced task both go through (rebased)',
    () async {
      await seedBoth(repo, api); // version 3 on both sides
      await repo.updateTask('t1', {'title': 'A'});
      await repo.updateTask('t1', {'status': 'doing'});

      final r = await engine.pushOutbox();

      expect(r.done, 2);
      expect(api.tasks['t1']!['version'], 5);
      expect(api.tasks['t1']!['title'], 'A');
      expect(api.tasks['t1']!['status'], 'doing');
      expect(await repo.allOps(), isEmpty);
    },
  );

  test('a delete is sent and the task stays as a hidden tombstone', () async {
    await seedBoth(repo, api);
    await repo.deleteTask('t1');

    final r = await engine.pushOutbox();

    expect(r.done, 1);
    expect(api.tasks['t1']!['deleted'], true);
    expect(await repo.loadTasks(), isEmpty);
    final row = (await repo.database.db.query('tasks')).single;
    expect(row['deleted'], 1);
    expect(row['version'], 4);
    expect(await repo.allOps(), isEmpty);
  });

  test('editing a task a colleague deleted is rejected (410)', () async {
    await seedBoth(repo, api);
    api.colleagueDelete('t1');
    await repo.updateTask('t1', {'title': 'Too late'});

    final r = await engine.pushOutbox();

    expect(r.rejected, 1);
    final view = (await repo.loadTasks()).single;
    expect(view.state, SyncState.rejected);
    expect(view.message, 'This task was deleted by someone else');
  });
}
