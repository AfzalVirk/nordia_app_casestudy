import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/models.dart';
import '../data/task_repository.dart';
import 'app_controller.dart';
import 'labels.dart';
import 'task_form_screen.dart';

class TaskListScreen extends StatelessWidget {
  const TaskListScreen({super.key});

  Future<(List<TaskView>, List<Member>)> _load(TaskRepository repo) async =>
      (await repo.loadTasks(), await repo.members());

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final app = context.watch<AppController>();

    return FutureBuilder<(List<TaskView>, List<Member>)>(
      future: _load(repo),
      builder: (context, snap) {
        final views = snap.data?.$1;
        final members = snap.data?.$2 ?? const <Member>[];
        final names = {for (final m in members) m.id: m.name};
        final myName = names[app.meId] ?? '';

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Tasks'),
                if (myName.isNotEmpty)
                  Text(myName, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            actions: [
              if (app.syncing)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: 'Sync now',
                  onPressed: () => app.sync(force: true),
                ),
              IconButton(
                icon: const Icon(Icons.switch_account),
                tooltip: 'Change user',
                onPressed: app.changeMember,
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('New task'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TaskFormScreen(members: members),
              ),
            ),
          ),
          body: Column(
            children: [
              if (app.message != null)
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  padding: const EdgeInsets.all(12),
                  child: Text(app.message!),
                ),
              Expanded(
                child: snap.hasError
                    ? Center(child: Text('${snap.error}'))
                    : views == null
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: () => app.sync(force: true),
                        child: views.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 160),
                                  Center(
                                    child: Text(
                                      'No tasks yet. Pull down to sync.',
                                    ),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(bottom: 88),
                                itemCount: views.length,
                                itemBuilder: (context, i) {
                                  final v = views[i];
                                  final a = v.task.assigneeId;
                                  final label = a == null
                                      ? 'Nobody'
                                      : (names[a] ?? a);
                                  return _TaskCard(
                                    view: v,
                                    assignee: label,
                                    members: members,
                                  );
                                },
                              ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.view,
    required this.assignee,
    required this.members,
  });

  final TaskView view;
  final String assignee;
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<TaskRepository>();
    final scheme = Theme.of(context).colorScheme;
    final t = view.task;
    final rejected = view.state == SyncState.rejected;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(t.title),
            subtitle: Text(
              [
                statusLabel(t.status),
                assignee,
                if (t.dueDate != null) 'due ${t.dueDate}',
              ].join(' · '),
            ),
            trailing: _StateChip(view.state),
            onTap: rejected
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TaskFormScreen(members: members, task: t),
                    ),
                  ),
          ),
          if (rejected)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      view.message ?? 'Refused by the server',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                  TextButton(
                    onPressed: () => repo.dismissRejected(t.id),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            ),
          if (view.notice != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(view.notice!)),
                  TextButton(
                    onPressed: () => repo.dismissNotice(t.id),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
          if (view.hasLostValues) _LostValues(taskId: t.id),
        ],
      ),
    );
  }
}

/// My value that lost a same-field conflict: restore it, or let it go.
class _LostValues extends StatelessWidget {
  const _LostValues({required this.taskId});
  final String taskId;

  Future<void> _useMine(
    BuildContext context,
    TaskRepository repo,
    LostValue l,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.useMine(l.id);
    } on ValidationException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<TaskRepository>();
    return FutureBuilder<List<LostValue>>(
      future: repo.lostValues(taskId),
      builder: (context, snap) {
        final items = snap.data ?? const <LostValue>[];
        return Column(
          children: [
            for (final l in items)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Your ${l.field}: "${l.myValue ?? '(empty)'}"\n'
                        'Kept: "${l.serverValue ?? '(empty)'}"',
                      ),
                    ),
                    TextButton(
                      onPressed: () => _useMine(context, repo, l),
                      child: const Text('Use mine'),
                    ),
                    TextButton(
                      onPressed: () => repo.discardLost(l.id),
                      child: const Text('Keep theirs'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip(this.state);
  final SyncState state;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      SyncState.synced => ('Synced', Colors.green, Icons.check_circle),
      SyncState.pending => ('Pending', Colors.orange, Icons.schedule),
      SyncState.rejected => ('Rejected', Colors.red, Icons.error),
    };
    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
