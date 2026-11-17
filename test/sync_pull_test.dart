import 'package:flutter_test/flutter_test.dart';
import 'package:hydatis_app/data/task_repository.dart';
import 'package:hydatis_app/sync/sync_engine.dart';
import 'package:hydatis_app/sync/sync_service.dart';
import 'test_support.dart';

void main() {
  late TaskRepository repo;
  late FakeApi api;
  late SyncEngine engine;
  late SyncService service;

  setUp(() async {
    repo = await newRepo();
    api = FakeApi();
    var n = 0;
    engine = SyncEngine(repo: repo, api: api, newId: () => 'retry-key-${++n}');
    service = SyncService(repo: repo, api: api, engine: engine, pageSize: 2);
  });

  test(
    'reads every page, saves the cursor, and the next read is empty',
    () async {
      for (var i = 1; i <= 5; i++) {
        api.addTask(id: 'a$i', title: 'Task $i');
      }

      final r = await service.pullChanges();

      expect(r.failed, false);
      expect(r.pages, 3); // 2 + 2 + 1
      expect(r.items, 5);
      expect((await repo.loadTasks()).length, 5);
      expect(await repo.database.getMeta('cursor'), 'c5');

      final again = await service.pullChanges();
      expect(again.items, 0); // nothing changed since the cursor
    },
  );

  test('a deleted task arrives as a tombstone: stored, but hidden', () async {
    api.addTask(id: 't1');
    await service.pullChanges();
    expect((await repo.loadTasks()).length, 1);

    api.colleagueDelete('t1');
    await service.pullChanges();

    expect(await repo.loadTasks(), isEmpty);
    final row = (await repo.database.db.query('tasks')).single;
    expect(row['deleted'], 1);
    expect(row['version'], 2);
  });

  test(
    'a failed read keeps the cursor, the next one only gets what is new',
    () async {
      api.addTask(id: 'a1');
      api.addTask(id: 'a2');
      expect((await service.pullChanges()).items, 2);
      expect(await repo.database.getMeta('cursor'), 'c2');

      api.addTask(id: 'a3');
      api.offline = true;
      final failed = await service.pullChanges();
      expect(failed.failed, true);
      expect(await repo.database.getMeta('cursor'), 'c2'); // untouched

      api.offline = false;
      final ok = await service.pullChanges();
      expect(ok.items, 1); // only a3, not everything again
      expect((await repo.loadTasks()).length, 3);
    },
  );

  test('a read keeps my waiting edit on top; Sync then merges both', () async {
    await seedBoth(repo, api); // version 3
    await repo.updateTask('t1', {'title': 'Mine'});
    api.colleagueEdit('t1', {'status': 'doing'}); // server version 4

    await service.pullChanges();

    var view = (await repo.loadTasks()).single;
    expect(view.task.title, 'Mine'); // my edit, still on top
    expect(view.task.status, 'doing'); // their change, just arrived
    expect(view.task.version, 4);
    expect(view.state, SyncState.pending);

    await service.syncAll();

    expect(api.tasks['t1']!['title'], 'Mine');
    expect(api.tasks['t1']!['status'], 'doing');
    expect(api.tasks['t1']!['version'], 5);
    view = (await repo.loadTasks()).single;
    expect(view.state, SyncState.synced);
    expect(await repo.allOps(), isEmpty);
  });

  test(
    'a replayed old answer never replaces a newer version we pulled',
    () async {
      api.script.add('lose'); // the server creates the task, the answer is lost
      final id = await repo.createTask(title: 'Once');
      await engine.pushOutbox();
      expect(api.tasks.containsKey(id), true);

      api.colleagueEdit(id, {'title': 'Edited by a colleague'}); // version 2
      await service.pullChanges(); // we now hold version 2

      await engine.pushOutbox(
        force: true,
      ); // retry: the server replays version 1

      final row = (await repo.database.db.query('tasks')).single;
      expect(row['version'], 2); // not pushed back to 1
      expect(row['title'], 'Edited by a colleague');
      expect(row['local_only'], 0);
      expect(await repo.allOps(), isEmpty);
    },
  );
}
