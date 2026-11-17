import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hydatis_app/data/app_database.dart';
import 'package:hydatis_app/data/models.dart';

void main() {
  sqfliteFfiInit();

  test('database opens, stores a task and a meta value', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );

    await db.setMeta('cursor', 'c5');
    expect(await db.getMeta('cursor'), 'c5');

    const t = Task(id: 'a', title: 'Hello', status: 'todo', version: 1);
    await db.db.insert('tasks', t.toRow());
    final back = Task.fromRow((await db.db.query('tasks')).single);
    expect(back.title, 'Hello');
    expect(back.version, 1);

    await db.close();
  });
}
