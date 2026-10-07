import '../json/canonical.dart';
import 'entity.dart';
import 'enums.dart';

/// 事件（《数据契约》§3.3）—— 任务线的根；无时间、无描述、无父引用。
class Event implements EntityNode {
  const Event({
    required this.id,
    required this.name,
    required this.status,
    required this.archived,
    required this.order,
    required this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.deleted,
    this.color,
    this.extra = const <String, dynamic>{},
  });

  static const Set<String> knownKeys = <String>{
    'id',
    'name',
    'status',
    'archived',
    'order',
    'completed_at',
    'created_at',
    'updated_at',
    'deleted',
    'color',
  };

  @override
  final String id;

  /// 注意字段名是 `name`（不是 `title`）—— 历史冻结，不得改名。
  final String name;

  /// 给 [EntityNode] 用的显示名。
  ///
  /// 为什么不把字段改名成 `title`：`name` 是**冻结的契约键**（见上一行注释），
  /// 改名要动契约与全部样本；而树算法（`TreeIndex.fullName` 这类）只需要
  /// "这条叫什么"，一个只读别名就够 —— 转发到 [name]，不新增第二个真相。
  @override
  String get title => name;

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

  /// 标识色（与项目同一套系统）：`#rrggbb` 小写，未设置为 `null`。
  ///
  /// 用途：任务列表里一眼看出"这条任务属于哪条线"，以及「接下来的任务」的
  /// 日历上按事件色画圆环。**未设置时不写出这个字段** —— 老数据读进来再写出去
  /// 仍然逐字节一致，不需要迁移（与 `Project.color` 同一套规则）。
  final String? color;

  final Map<String, dynamic> extra;

  /// 事件永远是任务线的根。
  @override
  String? get parentId => null;

  Event copyWith({
    String? name,
    NodeStatus? status,
    bool? archived,
    int? order,
    Object? completedAt = _unset,
    int? updatedAt,
    bool? deleted,
    Object? color = _unset,
  }) {
    return Event(
      id: id,
      name: name ?? this.name,
      status: status ?? this.status,
      archived: archived ?? this.archived,
      order: order ?? this.order,
      completedAt: completedAt == _unset ? this.completedAt : completedAt as int?,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      color: color == _unset ? this.color : color as String?,
      extra: extra,
    );
  }

  factory Event.fromJson(Map<String, dynamic> json, DecodeIssues issues) {
    return Event(
      id: Canonical.readString(json['id'], 'event.id', issues) ?? '',
      name: Canonical.readString(json['name'], 'event.name', issues) ?? '',
      status: NodeStatus.fromWire(json['status'], issues.error),
      archived: Canonical.readBool(json['archived'], 'event.archived', issues) ?? false,
      order: Canonical.readInt(json['order'], 'event.order', issues) ?? 1000,
      completedAt: Canonical.readInt(json['completed_at'], 'event.completed_at', issues),
      createdAt: Canonical.readInt(json['created_at'], 'event.created_at', issues) ?? 0,
      updatedAt: Canonical.readInt(json['updated_at'], 'event.updated_at', issues) ?? 0,
      deleted: Canonical.readBool(json['deleted'], 'event.deleted', issues) ?? false,
      color: Canonical.readHexColor(json['color'], 'event.color', issues),
      extra: Canonical.readExtra(json, knownKeys),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'id': id,
      'name': name,
      'status': status.wire,
      'archived': archived,
      'order': order,
      'completed_at': completedAt,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted': deleted,
    };
    // 未设置标识色就不写出：老数据没有这个字段，写出来会破坏"读入→写出"
    // 的逐字节一致。新字段追加在末尾，不打乱既有字段顺序。
    if (color != null) out['color'] = color;
    out.addAll(extra);
    return out;
  }
}

const Object _unset = Object();
