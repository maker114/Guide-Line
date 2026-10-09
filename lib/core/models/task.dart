import '../json/canonical.dart';
import 'entity.dart';
import 'enums.dart';
import 'project_item.dart';

/// 任务（《数据契约》§3.4）。
///
/// **一条任务线 = 一条链**：事件下的主线节点按 `order` 依次往下走，
/// 每个节点可以挂若干子任务（`parent_task_id`）。就这么多。
///
/// 这里删掉过一整套「走向边」（`next_task_ids`）：它当年用来表达分叉 / 合流，
/// 让人得同时理解"支路""分叉点""合流点"三个概念 —— 与"快速理清一件事的脉络"
/// 这条初心是冲突的。**并行两条线请开两个事件**，或者把两条并成同一节点下的
/// 两条子任务。细节见《数据契约》§3.4.1 与 §7 的 v3 说明。
///
/// **任务内部还有一份「待办清单」**（[checklist]，2026-10-09 加，契约 §3.4.2）：
/// 它是这条任务的细则，与子任务是两回事 —— 子任务是**参与完成判定**的节点，
/// 待办只是打勾。所以待办：
///   · **仅两态**（勾 / 不勾），没有 `ignored`；
///   · **没有自己的 `due_at`**，到期日**继承宿主任务**：任务逾期即待办逾期；
///   · **不参与任何判定** —— 全勾完也不会把任务变成 `done`，未勾完也不阻塞任务。
class Task implements EntityNode {
  const Task({
    required this.id,
    required this.eventId,
    required String? parentTaskId,
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
    this.checklist = const <ProjectItem>[],
    this.extra = const <String, dynamic>{},
  }) : parentId = parentTaskId;

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
    'checklist',
  };

  /// v3 删掉的字段：读老文件时**丢掉**，并且不再透传（`extra`）——
  /// 否则那个键会跟着用户的数据永远活下去，等于没删。
  static const Set<String> droppedKeys = <String>{'next_task_ids'};

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

  /// 这条任务的**待办清单**（细则，契约 §3.4.2）。空数组 = 没有待办。
  ///
  /// 条目结构用的是 [ProjectItem] —— 那个类名来自"项目实现清单"，但它的结构
  /// （`{id, text, done}`）就是"清单条目"的通用结构，两处逐字同构，
  /// 所以**共用一套**而不另立一个类：两套结构早晚会在解析容错上分叉。
  /// 名字带 `Project` 是历史原因，不代表它只能用在项目里。
  ///
  /// **顺序 := 数组下标**（与项目清单同一条口径）：条目没有 `order` 字段。
  final List<ProjectItem> checklist;

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
    TaskType? taskType,
    String? title,
    Object? dueAt = _unset,
    NodeStatus? status,
    bool? archived,
    int? order,
    Object? completedAt = _unset,
    int? updatedAt,
    bool? deleted,
    Object? checklist = _unset,
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
      // `checklist` 走哨兵值而不是 `?? this.checklist`：**清空清单是合法操作**，
      // 用空数组当"没传"会让清空永远写不下去（与 `dueAt` / `completedAt` 同一个坑）。
      // 转换用 `List<ProjectItem>.from(...)` 而**不是** `as List<ProjectItem>`：
      // 后者在调用方传 `const []`（推断成 `List<dynamic>`）时会直接抛类型错 ——
      // "清空清单"偏偏最可能就用那个写法传（这行是 `task_checklist_model_test`
      // 里那条用例逼出来的）。
      checklist: checklist == _unset
          ? this.checklist
          : List<ProjectItem>.from(checklist as Iterable<Object?>),
      extra: extra,
    );
  }

  factory Task.fromJson(Map<String, dynamic> json, DecodeIssues issues) {
    final extra = Canonical.readExtra(json, knownKeys);
    // v3 删掉的字段从这里丢掉（见 [droppedKeys]）：留着会被透传、写回去，
    // 那个字段就永远活下来了，等于没删
    extra.removeWhere((key, _) => droppedKeys.contains(key));
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
      checklist: readProjectItems(json['checklist'], 'task.checklist', issues),
      extra: extra,
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
      // 空清单也照写 `[]`：**字段在不在**本身是信息（"这条任务有清单这个概念"），
      // 写成条件键会让"读过老文件再写出"与"新建的任务"两份数据长得不一样，
      // 而契约的首个样本要求同一形态。见《数据契约》§3.4.2。
      'checklist': <Map<String, dynamic>>[
        for (final item in checklist) item.toJson(),
      ],
    };
    out.addAll(extra);
    return out;
  }
}

const Object _unset = Object();
