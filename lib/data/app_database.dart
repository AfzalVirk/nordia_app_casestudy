import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._(this.db);
  final Database db;

  /// factory + path are parameters so tests can use an in-memory database.
  static Future<AppDatabase> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: _create,
        // Each in-memory open must be its own empty database (tests).
        // A real file keeps the default: one shared connection.
        singleInstance: path != inMemoryDatabasePath,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute(
      'CREATE TABLE members (id TEXT PRIMARY KEY, name TEXT NOT NULL)',
    );
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        note TEXT,
        status TEXT NOT NULL,
        assignee_id TEXT,
        due_date TEXT,
        version INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        local_only INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE ops (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        op_id TEXT NOT NULL UNIQUE,
        task_id TEXT NOT NULL,
        type TEXT NOT NULL,
        payload TEXT NOT NULL,
        base_values TEXT NOT NULL,
        base_version INTEGER,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        error_code TEXT,
        error_message TEXT
      )''');
    await db.execute('''
      CREATE TABLE lost_values (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT NOT NULL,
        field TEXT NOT NULL,
        my_value TEXT,
        server_value TEXT
      )''');
    await db.execute('''
      CREATE TABLE notices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT NOT NULL,
        message TEXT NOT NULL
      )''');
    await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
  }

  Future<String?> getMeta(String key, [DatabaseExecutor? ex]) async {
    final rows = await (ex ?? db).query(
      'meta',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value, [DatabaseExecutor? ex]) async {
    await (ex ?? db).insert('meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> close() => db.close();
}
