import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/models.dart';
import '../data/task_repository.dart';
import 'app_controller.dart';

class PickMemberScreen extends StatelessWidget {
  const PickMemberScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final app = context.watch<AppController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Who are you?')),
      body: FutureBuilder<List<Member>>(
        future: repo.members(),
        builder: (context, snap) {
          final members = snap.data ?? const <Member>[];
          if (members.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      app.syncing
                          ? 'Loading the team...'
                          : 'The team list is not loaded yet.\n'
                                'Connect once to download it.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: app.syncing
                          ? null
                          : () => app.sync(force: true),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final m in members)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(m.name.isEmpty ? '?' : m.name[0]),
                  ),
                  title: Text(m.name),
                  onTap: () => app.pickMember(m.id),
                ),
            ],
          );
        },
      ),
    );
  }
}
