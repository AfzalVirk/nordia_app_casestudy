import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/models.dart';
import '../data/task_repository.dart';
import 'app_controller.dart';
import 'labels.dart';
import 'task_form_screen.dart';

// ─── Color helpers ────────────────────────────────────────────────────────────

Color _statusColor(String status) => switch (status) {
  'done'  => const Color(0xFF2E7D32),
  'doing' => const Color(0xFFE65100),
  _       => const Color(0xFF1565C0),
};

Color _statusBg(String status) => switch (status) {
  'done'  => const Color(0xFFE8F5E9),
  'doing' => const Color(0xFFFFF3E0),
  _       => const Color(0xFFE3F2FD),
};

IconData _statusIcon(String status) => switch (status) {
  'done'  => Icons.check_circle_rounded,
  'doing' => Icons.timelapse_rounded,
  _       => Icons.radio_button_unchecked_rounded,
};

// ─── TaskListScreen ────────────────────────────────────────────────────────────

class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen>
    with SingleTickerProviderStateMixin {
  bool _onlyMine = false;
  late AnimationController _fabController;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
  }

  @override
  void dispose() {
    _fabController.dispose();
    super.dispose();
  }

  Future<(List<TaskView>, List<Member>)> _load(TaskRepository repo) async =>
      (await repo.loadTasks(), await repo.members());

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final app = context.watch<AppController>();
    final cs = Theme.of(context).colorScheme;

    return FutureBuilder<(List<TaskView>, List<Member>)>(
      future: _load(repo),
      builder: (context, snap) {
        final allViews = snap.data?.$1 ?? const [];
        final members  = snap.data?.$2 ?? const [];
        final names    = {for (final m in members) m.id: m.name};
        final myName   = names[app.meId] ?? '';

        final views = _onlyMine && app.meId != null
            ? allViews.where((v) => v.task.assigneeId == app.meId).toList()
            : allViews;

        return Scaffold(
          backgroundColor: const Color(0xFFF5F7FA),
          appBar: _buildAppBar(context, cs, app, myName),
          floatingActionButton: ScaleTransition(
            scale: CurvedAnimation(
              parent: _fabController,
              curve: Curves.elasticOut,
            ),
            child: FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TaskFormScreen(members: members),
                ),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New task',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              elevation: 4,
            ),
          ),
          body: Column(
            children: [
              // ── Offline / retry banner ──
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: app.message != null
                    ? _OfflineBanner(message: app.message!)
                    : const SizedBox.shrink(),
              ),

              // ── Filter tabs ──
              _FilterBar(
                onlyMine: _onlyMine,
                onChanged: (v) => setState(() => _onlyMine = v),
              ),

              // ── List ──
              Expanded(
                child: snap.hasError
                    ? _ErrorState(error: '${snap.error}')
                    : snap.data == null
                    ? const _LoadingState()
                    : RefreshIndicator(
                        onRefresh: () => app.sync(force: true),
                        color: cs.primary,
                        child: views.isEmpty
                            ? _EmptyState(onlyMine: _onlyMine)
                            : ListView.separated(
                                physics:
                                    const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                    16, 8, 16, 100),
                                itemCount: views.length,
                                separatorBuilder: (ctx, i) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, i) {
                                  final v = views[i];
                                  final a = v.task.assigneeId;
                                  final label =
                                      a == null ? 'Nobody' : (names[a] ?? a);
                                  return _AnimatedTaskCard(
                                    index: i,
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

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    ColorScheme cs,
    AppController app,
    String myName,
  ) {
    return AppBar(
      backgroundColor: cs.primary,
      foregroundColor: Colors.white,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Nordia Tasks',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 20,
              color: Colors.white,
            ),
          ),
          if (myName.isNotEmpty)
            Text(
              myName,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
        ],
      ),
      actions: [
        if (app.syncing)
          Padding(
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white.withAlpha(220),
              ),
            ),
          )
        else
          IconButton(
            icon: const Icon(Icons.sync_rounded, color: Colors.white),
            tooltip: 'Sync now',
            onPressed: () => app.sync(force: true),
          ),
        IconButton(
          icon: const Icon(Icons.switch_account_rounded, color: Colors.white),
          tooltip: 'Change user',
          onPressed: app.changeMember,
        ),
      ],
    );
  }
}

// ─── Animated card wrapper ─────────────────────────────────────────────────────

class _AnimatedTaskCard extends StatefulWidget {
  const _AnimatedTaskCard({
    required this.index,
    required this.view,
    required this.assignee,
    required this.members,
  });

  final int index;
  final TaskView view;
  final String assignee;
  final List<Member> members;

  @override
  State<_AnimatedTaskCard> createState() => _AnimatedTaskCardState();
}

class _AnimatedTaskCardState extends State<_AnimatedTaskCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 300 + widget.index * 40),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    Future.delayed(Duration(milliseconds: widget.index * 40), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: TaskCard(
          view: widget.view,
          assignee: widget.assignee,
          members: widget.members,
        ),
      ),
    );
  }
}

// ─── TaskCard (also used by widget_test.dart) ─────────────────────────────────

class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.view,
    required this.assignee,
    required this.members,
  });

  final TaskView view;
  final String assignee;
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    final repo     = context.read<TaskRepository>();
    final cs       = Theme.of(context).colorScheme;
    final t        = view.task;
    final rejected = view.state == SyncState.rejected;
    final sColor   = _statusColor(t.status);
    final sBg      = _statusBg(t.status);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: rejected
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TaskFormScreen(members: members, task: t),
                ),
              ),
        splashColor: sColor.withAlpha(20),
        highlightColor: sColor.withAlpha(10),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: sColor, width: 4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Top row: title + sync badge ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        t.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: rejected
                              ? Colors.grey.shade400
                              : const Color(0xFF1A1A2E),
                          decoration: rejected
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SyncBadge(state: view.state),
                  ],
                ),
                const SizedBox(height: 10),
                // ── Status pill + meta row ──
                Row(
                  children: [
                    _StatusPill(status: t.status, color: sColor, bg: sBg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MetaRow(
                        assignee: assignee,
                        dueDate: t.dueDate,
                      ),
                    ),
                  ],
                ),
                // ── Rejection banner ──
                if (rejected) ...[
                  const SizedBox(height: 10),
                  _RejectionRow(
                    message: view.message ?? 'Refused by the server',
                    onDismiss: () => repo.dismissRejected(t.id),
                  ),
                ],
                // ── Conflict notice ──
                if (view.notice != null) ...[
                  const SizedBox(height: 10),
                  _NoticeRow(
                    notice: view.notice!,
                    cs: cs,
                    onDismiss: () => repo.dismissNotice(t.id),
                  ),
                ],
                // ── Lost values ──
                if (view.hasLostValues) ...[
                  const SizedBox(height: 4),
                  _LostValues(taskId: t.id),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Status pill ───────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.status,
    required this.color,
    required this.bg,
  });
  final String status;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_statusIcon(status), size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            statusLabel(status),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Meta row (assignee + due date) ───────────────────────────────────────────

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.assignee, required this.dueDate});
  final String assignee;
  final String? dueDate;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.person_outline_rounded,
            size: 13, color: Color(0xFF9E9E9E)),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            assignee,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xFF757575)),
          ),
        ),
        if (dueDate != null) ...[
          const SizedBox(width: 10),
          const Icon(Icons.event_rounded, size: 13, color: Color(0xFF9E9E9E)),
          const SizedBox(width: 3),
          Text(
            dueDate!,
            style: const TextStyle(fontSize: 12, color: Color(0xFF757575)),
          ),
        ],
      ],
    );
  }
}

// ─── Sync badge ───────────────────────────────────────────────────────────────

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.state});
  final SyncState state;

  @override
  Widget build(BuildContext context) {
    final (icon, color, bg) = switch (state) {
      SyncState.synced   => (Icons.cloud_done_rounded,  const Color(0xFF2E7D32), const Color(0xFFE8F5E9)),
      SyncState.pending  => (Icons.cloud_upload_rounded, const Color(0xFFE65100), const Color(0xFFFFF3E0)),
      SyncState.rejected => (Icons.cloud_off_rounded,    const Color(0xFFC62828), const Color(0xFFFFEBEE)),
    };
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, size: 15, color: color),
    );
  }
}

// ─── Rejection row ────────────────────────────────────────────────────────────

class _RejectionRow extends StatelessWidget {
  const _RejectionRow({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 16, color: Color(0xFFC62828)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFFC62828)),
            ),
          ),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFC62828),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Dismiss',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─── Conflict notice ──────────────────────────────────────────────────────────

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.notice,
    required this.cs,
    required this.onDismiss,
  });
  final String notice;
  final ColorScheme cs;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: Color(0xFFF57F17)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF5D4037)),
            ),
          ),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF57F17),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('OK',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─── Lost values ──────────────────────────────────────────────────────────────

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
        final items = snap.data ?? const [];
        return Column(
          children: [
            for (final l in items)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3E5F5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.edit_note_rounded,
                        size: 16, color: Color(0xFF6A1B9A)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Your ${l.field}: "${l.myValue ?? '(empty)'}"\n'
                        'Kept: "${l.serverValue ?? '(empty)'}"',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF4A148C)),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _useMine(context, repo, l),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF6A1B9A),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Use mine',
                          style: TextStyle(fontSize: 11)),
                    ),
                    TextButton(
                      onPressed: () => repo.discardLost(l.id),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.grey.shade600,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Keep theirs',
                          style: TextStyle(fontSize: 11)),
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

// ─── Filter bar ───────────────────────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.onlyMine, required this.onChanged});
  final bool onlyMine;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<bool>(
        style: SegmentedButton.styleFrom(
          backgroundColor: const Color(0xFFF5F7FA),
          selectedBackgroundColor: cs.primary,
          selectedForegroundColor: Colors.white,
          foregroundColor: cs.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        segments: const [
          ButtonSegment(
            value: false,
            label: Text('All tasks'),
            icon: Icon(Icons.list_alt_rounded, size: 16),
          ),
          ButtonSegment(
            value: true,
            label: Text('My tasks'),
            icon: Icon(Icons.person_rounded, size: 16),
          ),
        ],
        selected: {onlyMine},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

// ─── Offline banner ───────────────────────────────────────────────────────────

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFE65100),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.wifi_off_rounded, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty / loading / error states ──────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onlyMine});
  final bool onlyMine;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          onlyMine ? Icons.person_off_rounded : Icons.task_alt_rounded,
          size: 64,
          color: Colors.grey.shade300,
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            onlyMine
                ? 'No tasks assigned to you.'
                : 'No tasks yet.\nPull down to sync.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: Colors.grey.shade500,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: CircularProgressIndicator(
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 48, color: Colors.red.shade300),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
