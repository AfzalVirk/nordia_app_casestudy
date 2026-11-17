import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/models.dart';
import '../data/task_repository.dart';
import 'app_controller.dart';
import 'labels.dart';

class TaskFormScreen extends StatefulWidget {
  const TaskFormScreen({super.key, required this.members, this.task});

  final List<Member> members;
  final Task? task; // null = creating a new task

  @override
  State<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends State<TaskFormScreen> {
  late final TextEditingController _title = TextEditingController(
    text: widget.task?.title ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.task?.note ?? '',
  );
  late String _status = widget.task?.status ?? 'todo';
  late String? _assignee = widget.task?.assigneeId;
  late String? _due = widget.task?.dueDate;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(_due ?? '') ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _due = _fmt(d));
  }

  Future<void> _save() async {
    final repo = context.read<TaskRepository>();
    final app = context.read<AppController>();
    final note = _note.text.trim().isEmpty ? null : _note.text;
    try {
      if (widget.task == null) {
        await repo.createTask(
          title: _title.text,
          note: note,
          status: _status,
          assigneeId: _assignee,
          dueDate: _due,
        );
      } else {
        await repo.updateTask(widget.task!.id, {
          'title': _title.text,
          'note': note,
          'status': _status,
          'assigneeId': _assignee,
          'dueDate': _due,
        });
      }
    } on ValidationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    unawaited(app.sync()); // try to send now; if offline it stays Pending
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this task?'),
        content: const Text('It will be deleted for everyone once synced.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final repo = context.read<TaskRepository>();
    final app = context.read<AppController>();
    await repo.deleteTask(widget.task!.id);
    unawaited(app.sync());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final wasDone =
        widget.task?.status == 'done'; // done cannot go back to todo
    final knownIds = widget.members.map((m) => m.id).toSet();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task == null ? 'New task' : 'Edit task'),
        actions: [
          if (widget.task != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            maxLength: 500,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _status,
            decoration: const InputDecoration(
              labelText: 'Status',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final s in statusOrder)
                if (!(wasDone && s == 'todo'))
                  DropdownMenuItem(value: s, child: Text(statusLabel(s))),
            ],
            onChanged: (v) => setState(() => _status = v ?? _status),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String?>(
            initialValue: _assignee,
            decoration: const InputDecoration(
              labelText: 'Assigned to',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Nobody'),
              ),
              for (final m in widget.members)
                DropdownMenuItem<String?>(value: m.id, child: Text(m.name)),
              if (_assignee != null && !knownIds.contains(_assignee))
                DropdownMenuItem<String?>(
                  value: _assignee,
                  child: Text(_assignee!),
                ),
            ],
            onChanged: (v) => setState(() => _assignee = v),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_due == null ? 'No due date' : 'Due $_due'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_due != null)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _due = null),
                  ),
                IconButton(
                  icon: const Icon(Icons.calendar_month),
                  onPressed: _pickDate,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
