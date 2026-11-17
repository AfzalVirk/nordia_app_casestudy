import 'package:hydatis_app/sync/task_api.dart';
import 'package:uuid/uuid.dart';

Future<void> main() async {
  // On your PC (not the emulator) the server is at localhost.
  final api = HttpTaskApi(baseUrl: 'http://localhost:3002');

  final members = await api.getMembers();
  print(
    'members: status ${members.status}, count ${(members.body as List).length}',
  );

  final page = await api.getTasks(limit: 3);
  final b = page.body as Map;
  print(
    'tasks page: status ${page.status}, items ${(b['items'] as List).length}, '
    'nextCursor ${b['nextCursor']}, hasMore ${b['hasMore']}',
  );

  final id = const Uuid().v4();
  final key = const Uuid().v4();
  final body = {'id': id, 'title': 'Try from Dart'};

  final first = await api.createTask(key, body);
  print('create:        status ${first.status}, replay ${first.replay}');

  final second = await api.createTask(key, body); // SAME key
  print('create again:  status ${second.status}, replay ${second.replay}');

  final bad = await api.updateTask(const Uuid().v4(), id, 99, {'title': 'x'});
  print(
    'wrong version: status ${bad.status}, code ${bad.code}, '
    'current version ${bad.current?['version']}',
  );
}
