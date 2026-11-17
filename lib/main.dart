import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'data/app_database.dart';
import 'data/task_repository.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_service.dart';
import 'sync/task_api.dart';
import 'ui/app_controller.dart';
import 'ui/pick_member_screen.dart';
import 'ui/task_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = await AppDatabase.open(
    factory: databaseFactory,
    path: p.join(await getDatabasesPath(), 'hydatis_tasks.db'),
  );
  final repo = TaskRepository(database);
  final api = HttpTaskApi();
  final engine = SyncEngine(repo: repo, api: api);
  final service = SyncService(repo: repo, api: api, engine: engine);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: repo),
        ChangeNotifierProvider(
          create: (_) => AppController(repo, service)..init(),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hydatis Tasks',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const Gate(),
    );
  }
}

/// Decides what to show: loading, "who are you?", or the task list.
class Gate extends StatelessWidget {
  const Gate({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    if (!app.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (app.meId == null) return const PickMemberScreen();
    return const TaskListScreen();
  }
}
