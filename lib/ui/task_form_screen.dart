import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/models.dart';
import '../data/task_repository.dart';
import 'app_controller.dart';
import 'labels.dart';

// ─── Status colour helpers (mirrors task_list_screen.dart) ────────────────────

Color _sColor(String s) => switch (s) {
      'done' => const Color(0xFF2E7D32),
      'doing' => const Color(0xFFE65100),
      _ => const Color(0xFF1565C0),
    };

Color _sBg(String s) => switch (s) {
      'done' => const Color(0xFFE8F5E9),
      'doing' => const Color(0xFFFFF3E0),
      _ => const Color(0xFFE3F2FD),
    };

// ─── TaskFormScreen ───────────────────────────────────────────────────────────

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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete this task?'),
        content: const Text('It will be deleted for everyone once synced.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
            ),
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
    final cs = Theme.of(context).colorScheme;
    final wasDone = widget.task?.status == 'done';
    final knownIds = widget.members.map((m) => m.id).toSet();
    final isNew = widget.task == null;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: cs.primary,
        foregroundColor: Colors.white,
        title: Text(
          isNew ? 'New task' : 'Edit task',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (!isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'Delete',
              color: Colors.red.shade200,
              onPressed: _delete,
            ),
        ],
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          // ── Details section ──
          _SectionLabel(label: isNew ? 'Task details' : 'Task details'),
          const SizedBox(height: 10),

          // Title field
          TextField(
            controller: _title,
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Title',
              hintText: 'What needs to be done?',
              prefixIcon: Icon(Icons.edit_note_rounded),
            ),
          ),
          const SizedBox(height: 12),

          // Note field
          TextField(
            controller: _note,
            maxLength: 500,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'Any extra details…',
              prefixIcon: Padding(
                padding: EdgeInsets.only(bottom: 48),
                child: Icon(Icons.notes_rounded),
              ),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 20),

          // ── Status section ──
          const _SectionLabel(label: 'Status'),
          const SizedBox(height: 10),
          _StatusSelector(
            current: _status,
            wasDone: wasDone,
            onChanged: (v) => setState(() => _status = v),
          ),
          const SizedBox(height: 20),

          // ── Assignment section ──
          const _SectionLabel(label: 'Assignment'),
          const SizedBox(height: 10),

          // Assignee dropdown
          _StyledDropdown<String?>(
            value: _assignee,
            icon: Icons.person_outline_rounded,
            label: 'Assigned to',
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
          const SizedBox(height: 12),

          // Due date tile
          _DueDateTile(
            due: _due,
            onPick: _pickDate,
            onClear: () => setState(() => _due = null),
          ),
          const SizedBox(height: 28),

          // ── Save button ──
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              onPressed: _save,
              icon: Icon(isNew ? Icons.add_rounded : Icons.check_rounded),
              label: Text(
                isNew ? 'Create task' : 'Save changes',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section label ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
        color: Colors.grey.shade500,
      ),
    );
  }
}

// ─── Status selector (pill row) ───────────────────────────────────────────────

class _StatusSelector extends StatelessWidget {
  const _StatusSelector({
    required this.current,
    required this.wasDone,
    required this.onChanged,
  });
  final String current;
  final bool wasDone;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = [
      if (!wasDone) 'todo',
      'doing',
      'done',
    ];

    return Row(
      children: [
        for (final s in options) ...[
          Expanded(
            child: _StatusPill(
              status: s,
              selected: current == s,
              onTap: () => onChanged(s),
            ),
          ),
          if (s != options.last) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.status,
    required this.selected,
    required this.onTap,
  });
  final String status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _sColor(status);
    final bg = _sBg(status);
    final icon = switch (status) {
      'done' => Icons.check_circle_rounded,
      'doing' => Icons.timelapse_rounded,
      _ => Icons.radio_button_unchecked_rounded,
    };

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? color : bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? color : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withAlpha(60),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  )
                ]
              : [],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? Colors.white : color,
            ),
            const SizedBox(height: 4),
            Text(
              statusLabel(status),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Styled dropdown wrapper ──────────────────────────────────────────────────

class _StyledDropdown<T> extends StatelessWidget {
  const _StyledDropdown({
    required this.value,
    required this.icon,
    required this.label,
    required this.items,
    required this.onChanged,
  });
  final T value;
  final IconData icon;
  final String label;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
      ),
      items: items,
      onChanged: onChanged,
      borderRadius: BorderRadius.circular(16),
    );
  }
}

// ─── Due date tile ────────────────────────────────────────────────────────────

class _DueDateTile extends StatelessWidget {
  const _DueDateTile({
    required this.due,
    required this.onPick,
    required this.onClear,
  });
  final String? due;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasDate = due != null;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasDate ? cs.primary.withAlpha(80) : Colors.grey.shade200,
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                Icons.event_rounded,
                size: 20,
                color: hasDate ? cs.primary : Colors.grey.shade400,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Due date',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasDate ? due! : 'No due date',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            hasDate ? FontWeight.w600 : FontWeight.normal,
                        color: hasDate
                            ? const Color(0xFF1A1A2E)
                            : Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasDate)
                IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 18),
                  color: Colors.grey.shade400,
                  onPressed: onClear,
                  tooltip: 'Clear date',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
