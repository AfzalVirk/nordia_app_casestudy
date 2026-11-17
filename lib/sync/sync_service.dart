import '../data/models.dart';
import '../data/task_repository.dart';
import 'sync_engine.dart';
import 'task_api.dart';

class PullReport {
  int items = 0;
  int pages = 0;
  bool failed = false;
  String? error;
}

class SyncSummary {
  SyncSummary(this.push, this.pull);
  final SyncReport push;
  final PullReport pull;

  /// Something is still waiting or could not be read: tell the user.
  bool get hasProblem => pull.failed || push.retryLater > 0;
}

/// What the Sync button (and the app launch) calls:
/// 1. send the outbox, 2. read what changed on the server.
class SyncService {
  SyncService({
    required this.repo,
    required this.api,
    required this.engine,
    this.pageSize = 50,
  });

  final TaskRepository repo;
  final TaskApi api;
  final SyncEngine engine;
  final int pageSize;
  Future<SyncSummary>? _running;

  Future<SyncSummary> syncAll({bool force = false}) {
    final running = _running;
    if (running != null) return running;
    final run = _syncAll(force).whenComplete(() => _running = null);
    _running = run;
    return run;
  }

  Future<SyncSummary> _syncAll(bool force) async {
    final push = await engine.pushOutbox(force: force);
    await pullMembers();
    final pull = await pullChanges();
    repo.changed();
    return SyncSummary(push, pull);
  }

  Future<void> pullMembers() async {
    final res = await api.getMembers();
    if (!res.isOk) return; // keep the members we already have
    try {
      final list = (res.body as List)
          .map((j) => Member.fromJson(Map<String, dynamic>.from(j as Map)))
          .toList();
      if (list.isNotEmpty) await repo.saveMembers(list);
    } catch (_) {}
  }

  Future<PullReport> pullChanges() async {
    final report = PullReport();
    final appDb = repo.database;
    var cursor = await appDb.getMeta('cursor'); // null = from the beginning

    while (true) {
      final res = await api.getTasks(since: cursor, limit: pageSize);
      if (!res.isOk) {
        report.failed = true; // the cursor is untouched: we resume from here
        report.error = res.message;
        break;
      }
      final page = _parsePage(res);
      if (page == null) {
        report.failed = true;
        report.error = 'Unreadable answer from the server';
        break;
      }
      final (items, next, more) = page;

      // The tasks and the new cursor are saved TOGETHER or not at all.
      await appDb.db.transaction((txn) async {
        for (final t in items) {
          await storeConfirmed(txn, t);
        }
        if (next != null) await appDb.setMeta('cursor', next, txn);
      });

      report.items += items.length;
      report.pages++;
      cursor = next;
      repo.changed();
      if (!more || items.isEmpty) break;
    }
    return report;
  }

  (List<Task>, String?, bool)? _parsePage(ApiResponse res) {
    try {
      final body = Map<String, dynamic>.from(res.body as Map);
      final items = [
        for (final j in body['items'] as List)
          Task.fromJson(Map<String, dynamic>.from(j as Map)),
      ];
      return (items, body['nextCursor'] as String?, body['hasMore'] == true);
    } catch (_) {
      return null;
    }
  }
}
