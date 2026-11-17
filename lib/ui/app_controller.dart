import 'package:flutter/foundation.dart';
import '../data/task_repository.dart';
import '../sync/sync_service.dart';

/// Small helper for the screens: who am I, is a sync running, what to tell the user.
class AppController extends ChangeNotifier {
  AppController(this.repo, this.service);

  final TaskRepository repo;
  final SyncService service;

  bool loaded = false;
  String? meId;
  bool syncing = false;
  String? message; // shown under the app bar

  Future<void> init() async {
    meId = await repo.currentMemberId();
    loaded = true;
    notifyListeners();
    await sync(); // sync at launch
  }

  Future<void> pickMember(String id) async {
    await repo.setCurrentMember(id);
    meId = id;
    notifyListeners();
  }

  void changeMember() {
    meId = null;
    notifyListeners();
  }

  Future<void> sync({bool force = false}) async {
    if (syncing) return;
    syncing = true;
    notifyListeners();
    try {
      final s = await service.syncAll(force: force);
      if (s.pull.failed) {
        message =
            'Offline or server problem: showing saved tasks. '
            'Your changes are kept. Pull down or press Sync to retry.';
      } else if (s.push.retryLater > 0) {
        message =
            'Some changes could not be sent yet. '
            'Pull down or press Sync to retry.';
      } else {
        message = null;
      }
    } catch (e) {
      message = 'Sync failed: $e';
    }
    syncing = false;
    notifyListeners();
  }
}
