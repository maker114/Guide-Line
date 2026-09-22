import '../json/canonical.dart';
import 'entity.dart';
import 'enums.dart';

/// 任务（《数据契约》§3.4）—— 树形实体，主线为 `parent_task_id == null` 的兄弟链。
class Task implements EntityNode {
  const Task({
    required this.id,
    required this.eventId,
    required this.parentTaskId,
    required this.taskType,
    required this.title,
    required this.dueAt,
    required this.status,
    required this.archived,
    required this.order,
    required this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.deleted,
    this.extra = const <String, dynamic>{},
  });

  static const Set<String> knownKeys = <String>{
    'id',
    'event_id',
    'parent_task_id',
    'task_type',
    'title',
    'due_at',
    'status',
    'archived',
    'order',
    'completed_at',
    'created_at',
    'updated_at',
    'deleted',
  };

  @override
  final String id;

  /// 所属事件（必填）。
  final String eventId;

  @override
  final String? parentId;

  final TaskType taskType;
  final String title;

  /// 到期 / 目标日，可为空；**不联动任何任务**（A3）。
  final String? dueAt;

  @override
  final NodeStatus status;

  @override
  final bool archived;

  @override
  final int order;

  @override
  final int? completedAt;

  @override
  final int createdAt;

  @override
  final int updatedAt;

  @override
  final bool deleted;

  final Map<String, dynamic> extra;

  String? get parentTaskId => parentId;

  /// 主线任务：事件下的直接子节点。
  bool get isMainLine => parentId == null;

  /// 允许的子节点（ADR-053 的父子组合约束）。
  bool canHaveChild(TaskType childType) {
    switch (taskType) {
      case TaskType.subtask:
        return false;
      case TaskType.standard:
        return childType == TaskType.subtask || childType == TaskType.parallel;
      case TaskType.parallel:
        return childType == TaskType.subtask;
    }
  }

  Task copyWith({
    String? eventId,
    Object? parentId = _unset,
    TaskType? taskType,
    String? title,
    Object? dueAt = _unset,
    NodeStatus? status,
    bool? archived,
    int? order,
    Object? completedAt = _unset,
    int? updatedAt,
    bool? deleted,
  }) {
    return Task(
      id: id,
      eventId: eventId ?? this.eventId,
      parentTaskId: parentId == _unset ? this.parentId : parentId as String?,
      taskType: taskType ?? this.taskType,
      title: title ?? this.title,
      dueAt: dueAt == _unset ? this.dueAt : dueAt as String?,
      status: status ?? this.status,
      archived: archived ?? this.archived,
      order: order ?? this.order,
      completedAt: completedAt == _unset ? this.completedAt : completedAt as int?,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      extra: extra,
    );
  }

  factory Task.fromJson(Map<String, dynamic> json, DecodeIssues issues) {
    return Task(
      id: Canonical.readString(json['id'], 'task.id', issues) ?? '',
      eventId: Canonical.readString(json['event_id'], 'task.event_id', issues) ?? '',
      parentTaskId: Canonical.readString(json['parent_task_id'], 'task.parent_task_id', issues),
      taskType: TaskType.fromWire(json['task_type'], issues.error),
      title: Canonical.readString(json['title'], 'task.title', issues) ?? '',
      dueAt: Canonical.readDate(json['due_at'], 'task.due_at', issues),
      status: NodeStatus.fromWire(json['status'], issues.error),
      archived: Canonical.readBool(json['archived'], 'task.archived', issues) ?? false,
      order: Canonical.readInt(json['order'], 'task.order', issues) ?? 1000,
      completedAt: Canonical.readInt(json['completed_at'], 'task.completed_at', issues),
      createdAt: Canonical.readInt(json['created_at'], 'task.created_at', issues) ?? 0,
      updatedAt: Canonical.readInt(json['updated_at'], 'task.updated_at', issues) ?? 0,
      deleted: Canonical.readBool(json['deleted'], 'task.deleted', issues) ?? false,
      extra: Canonical.readExtra(json, knownKeys),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'id': id,
      'event_id': eventId,
      'parent_task_id': parentTaskId,
      'task_type': taskType.wire,
      'title': title,
      'due_at': dueAt,
      'status': status.wire,
      'archived': archived,
      'order': order,
      'completed_at': completedAt,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted': deleted,
    };
    out.addAll(extra);
    return out;
  }
}

const Object _unset = Object();
