import 'dart:convert';

const taskFields = ['title', 'note', 'status', 'assigneeId', 'dueDate'];
const statusOrder = ['todo', 'doing', 'done'];
int statusRank(String s) => statusOrder.indexOf(s);

class Member {
  const Member(this.id, this.name);
  final String id;
  final String name;
  factory Member.fromJson(Map<String, dynamic> j) =>
      Member(j['id'] as String, j['name'] as String);
}

/// A task as the server last confirmed it (plus tasks created offline: localOnly).
class Task {
  const Task({
    required this.id,
    required this.title,
    this.note,
    required this.status,
    this.assigneeId,
    this.dueDate,
    required this.version,
    this.deleted = false,
    this.updatedAt = '',
    this.localOnly = false,
  });

  final String id;
  final String title;
  final String? note;
  final String status;
  final String? assigneeId;
  final String? dueDate;
  final int version;
  final bool deleted;
  final String updatedAt;
  final bool localOnly; // created on the phone, server doesn't know it yet

  factory Task.fromJson(Map<String, dynamic> j) => Task(
    id: j['id'] as String,
    title: j['title'] as String,
    note: j['note'] as String?,
    status: j['status'] as String,
    assigneeId: j['assigneeId'] as String?,
    dueDate: j['dueDate'] as String?,
    version: j['version'] as int,
    deleted: j['deleted'] == true,
    updatedAt: (j['updatedAt'] as String?) ?? '',
  );

  factory Task.fromRow(Map<String, Object?> r) => Task(
    id: r['id'] as String,
    title: r['title'] as String,
    note: r['note'] as String?,
    status: r['status'] as String,
    assigneeId: r['assignee_id'] as String?,
    dueDate: r['due_date'] as String?,
    version: r['version'] as int,
    deleted: (r['deleted'] as int) == 1,
    updatedAt: r['updated_at'] as String,
    localOnly: (r['local_only'] as int) == 1,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'title': title,
    'note': note,
    'status': status,
    'assignee_id': assigneeId,
    'due_date': dueDate,
    'version': version,
    'deleted': deleted ? 1 : 0,
    'updated_at': updatedAt,
    'local_only': localOnly ? 1 : 0,
  };

  /// Body for POST /tasks
  Map<String, dynamic> toCreateJson() => {
    'id': id,
    'title': title,
    'note': note,
    'status': status,
    'assigneeId': assigneeId,
    'dueDate': dueDate,
  };

  Object? field(String name) => switch (name) {
    'title' => title,
    'note' => note,
    'status' => status,
    'assigneeId' => assigneeId,
    'dueDate' => dueDate,
    _ => throw ArgumentError('unknown field $name'),
  };

  /// Returns a copy with the changed fields applied (a null value is allowed).
  Task withPatch(Map<String, dynamic> p) => Task(
    id: id,
    title: p.containsKey('title') ? p['title'] as String : title,
    note: p.containsKey('note') ? p['note'] as String? : note,
    status: p.containsKey('status') ? p['status'] as String : status,
    assigneeId: p.containsKey('assigneeId')
        ? p['assigneeId'] as String?
        : assigneeId,
    dueDate: p.containsKey('dueDate') ? p['dueDate'] as String? : dueDate,
    version: version,
    deleted: deleted,
    updatedAt: updatedAt,
    localOnly: localOnly,
  );
}

enum OpType { create, update, delete }

enum OpStatus { queued, rejected }

/// One line in the outbox.
class SyncOp {
  const SyncOp({
    required this.seq,
    required this.opId,
    required this.taskId,
    required this.type,
    required this.payload,
    required this.baseValues,
    this.baseVersion,
    this.status = OpStatus.queued,
    this.attempts = 0,
    this.nextAttemptAt,
    this.errorCode,
    this.errorMessage,
  });

  final int seq; // order in the outbox
  final String opId; // = the Idempotency-Key, never changes for this op
  final String taskId;
  final OpType type;
  final Map<String, dynamic> payload; // only the fields being changed
  final Map<String, dynamic> baseValues; // those fields BEFORE my edit
  final int? baseVersion; // null = waiting for the create to be confirmed
  final OpStatus status;
  final int attempts;
  final int? nextAttemptAt; // ms since epoch: don't retry before this
  final String? errorCode;
  final String? errorMessage;

  factory SyncOp.fromRow(Map<String, Object?> r) => SyncOp(
    seq: r['seq'] as int,
    opId: r['op_id'] as String,
    taskId: r['task_id'] as String,
    type: OpType.values.byName(r['type'] as String),
    payload: jsonDecode(r['payload'] as String) as Map<String, dynamic>,
    baseValues: jsonDecode(r['base_values'] as String) as Map<String, dynamic>,
    baseVersion: r['base_version'] as int?,
    status: OpStatus.values.byName(r['status'] as String),
    attempts: r['attempts'] as int,
    nextAttemptAt: r['next_attempt_at'] as int?,
    errorCode: r['error_code'] as String?,
    errorMessage: r['error_message'] as String?,
  );
}
