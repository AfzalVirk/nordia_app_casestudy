import 'package:flutter_test/flutter_test.dart';
import 'package:hydatis_app/data/task_repository.dart';
import 'package:hydatis_app/sync/sync_engine.dart';
import 'test_support.dart';

void main() {
  late TaskRepository repo;
  late FakeApi api;
  late SyncEngine engine;

  setUp(() async {
    repo = await newRepo();
    api = FakeApi();
    var n = 0;
    // The fake server refuses a key reused for another request (422), exactly
    // like the real one: so these tests also prove we use a NEW key after a 409.
    engine = SyncEngine(repo: repo, api: api, newId: () => 'retry-key-${++n}');
  });

  test('different fields: both changes are kept', () async {
    await seedBoth(repo, api); // version 3
    await repo.updateTask('t1', {'status': 'doing'});
    api.colleagueEdit('t1', {'title': 'Lift 2'}); // server is now version 4

    final r = await engine.pushOutbox();

    expect(r.merged, 1);
    expect(r.done, 1);
    expect(api.tasks['t1']!['title'], 'Lift 2'); // theirs
    expect(api.tasks['t1']!['status'], 'doing'); // mine
    expect(api.tasks['t1']!['version'], 5);
    expect(await repo.allOps(), isEmpty);
    expect(await repo.lostValues('t1'), isEmpty);
    final view = (await repo.loadTasks()).single;
    expect(view.task.title, 'Lift 2');
    expect(view.state, SyncState.synced);
    expect(view.notice, isNotNull);
  });

  test(
    'status on both sides: the furthest along wins (theirs is further)',
    () async {
      await seedBoth(repo, api);
      await repo.updateTask('t1', {'status': 'doing'});
      api.colleagueEdit('t1', {'status': 'done'});

      final r = await engine.pushOutbox();

      expect(r.merged, 1);
      expect(api.tasks['t1']!['status'], 'done');
      expect(api.tasks['t1']!['version'], 4); // my edit sent nothing
      expect(await repo.allOps(), isEmpty);
      expect(await repo.lostValues('t1'), isEmpty);
      expect((await repo.loadTasks()).single.task.status, 'done');
    },
  );

  test(
    'status on both sides: the furthest along wins (mine is further)',
    () async {
      await seedBoth(repo, api);
      await repo.updateTask('t1', {'status': 'done'});
      api.colleagueEdit('t1', {'status': 'doing'});

      await engine.pushOutbox();

      expect(api.tasks['t1']!['status'], 'done');
      expect(api.tasks['t1']!['version'], 5);
      expect(await repo.allOps(), isEmpty);
    },
  );

  test('same field, different values: server stays, mine is saved', () async {
    await seedBoth(repo, api);
    await repo.updateTask('t1', {'title': 'Mine'});
    api.colleagueEdit('t1', {'title': 'Theirs'});

    await engine.pushOutbox();

    expect(api.tasks['t1']!['title'], 'Theirs');
    expect(api.tasks['t1']!['version'], 4); // I did not overwrite anything
    final lost = (await repo.lostValues('t1')).single;
    expect(lost.field, 'title');
    expect(lost.myValue, 'Mine');
    expect(lost.serverValue, 'Theirs');
    final view = (await repo.loadTasks()).single;
    expect(view.task.title, 'Theirs');
    expect(view.hasLostValues, true);
    expect(view.notice, isNotNull);
  });

  test('"Use mine" brings my saved value back', () async {
    await seedBoth(repo, api);
    await repo.updateTask('t1', {'title': 'Mine'});
    api.colleagueEdit('t1', {'title': 'Theirs'});
    await engine.pushOutbox();
    final lost = (await repo.lostValues('t1')).single;

    await repo.useMine(lost.id);
    expect(await repo.lostValues('t1'), isEmpty);
    expect((await repo.loadTasks()).single.task.title, 'Mine'); // at once

    await engine.pushOutbox();
    expect(api.tasks['t1']!['title'], 'Mine');
    expect(api.tasks['t1']!['version'], 5);
    expect(await repo.allOps(), isEmpty);
  });

  test('both ended on the same value: nothing to send, nothing lost', () async {
    await seedBoth(repo, api);
    await repo.updateTask('t1', {'title': 'Same'});
    api.colleagueEdit('t1', {'title': 'Same'});

    await engine.pushOutbox();

    expect(api.tasks['t1']!['version'], 4);
    expect(await repo.allOps(), isEmpty);
    expect(await repo.lostValues('t1'), isEmpty);
  });

  test('a delete that hits a conflict is cancelled, with a message', () async {
    await seedBoth(repo, api);
    await repo.deleteTask('t1');
    api.colleagueEdit('t1', {'title': 'Updated by a colleague'});

    final r = await engine.pushOutbox();

    expect(r.merged, 1);
    expect(api.tasks['t1']!['deleted'], false);
    expect(await repo.allOps(), isEmpty);
    final view = (await repo.loadTasks()).single; // the task is back
    expect(view.task.title, 'Updated by a colleague');
    expect(view.notice, contains('cancelled'));
  });

  test(
    'two offline edits of one field that both lose: my latest is saved',
    () async {
      await seedBoth(repo, api);
      await repo.updateTask('t1', {'title': 'A'});
      await repo.updateTask('t1', {'title': 'B'});
      api.colleagueEdit('t1', {'title': 'C'});

      await engine.pushOutbox();

      expect(api.tasks['t1']!['title'], 'C');
      expect(await repo.allOps(), isEmpty);
      final lost = await repo.lostValues('t1');
      expect(lost.length, 1);
      expect(lost.single.myValue, 'B');
    },
  );
}
