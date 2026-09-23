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
  };

  @override
  final String id;

  /// 注意字段名是 `name`（不是 `title`）—— 历史冻结，不得改名。
  final String name;

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
    out.addAll(extra);
    return out;
  }
}

const Object _unset = Object();
