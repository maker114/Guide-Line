import '../json/canonical.dart';
import 'entity.dart';
import 'enums.dart';

/// 任务（《数据契约》§3.4）。
///
/// 两种关系**分开表达**：
///   · `parent_task_id` —— **归属**（子任务挂在主任务框内）；
///   · `next_task_ids`  —— **走向**（主线上下一步接到哪些任务，可多可合）。
///
/// 原来只有前者，于是主线只能是一条兄弟链、并列出来的几条只能"分叉不能合流"。
class Task implements EntityNode {
  const Task({
    required this.id,
    required this.eventId,
    required String? parentTaskId,
    this.nextIds = const <String>[],
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
  }) : parentId = parentTaskId;

  static const Set<String> knownKeys = <String>{
    'id',
    'event_id',
    'parent_task_id',
    'next_task_ids',
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

  /// **后续边**：这条任务往下接到哪些主线任务。
  ///
  /// 空列表 = 没有显式后续（老数据都是这样，按 `order` 顺序成链，见 `TaskFlow`）。
  /// 两条以上 = 分叉；被两条以上任务指向 = 合流。
  final List<String> nextIds;

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
  ///
  /// 新数据只会问"能不能挂 `subtask`"；`parallel` 这一支是为**老数据**留的：
  /// 当年它也能挂子任务，现在那些记录还在用户文件里，读进来之后
  /// 增删改查都得照旧成立（`parallel` 本身已经不允许新建了，见 [TaskType]）。
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
    List<String>? nextIds,
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
      nextIds: nextIds ?? this.nextIds,
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
      nextIds: _readIdList(json['next_task_ids']),
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

  /// 容错读取后续边：不是列表就当空，列表里非字符串的项直接丢掉。
  /// 按契约 §8，**绝不因为一个字段畸形就让整条记录失败**。
  static List<String> _readIdList(Object? raw) {
    if (raw is! List) return const <String>[];
    final out = <String>[];
    for (final item in raw) {
      if (item is String && item.isNotEmpty) out.add(item);
    }
    return List<String>.unmodifiable(out);
  }

  @override
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'id': id,
      'event_id': eventId,
      'parent_task_id': parentTaskId,
      'next_task_ids': nextIds,
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
