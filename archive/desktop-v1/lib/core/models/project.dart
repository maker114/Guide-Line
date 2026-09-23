import '../json/canonical.dart';
import 'entity.dart';
import 'enums.dart';

/// 项目（《数据契约》§3.2）—— 树形实体（嵌套 ≤ 3 层）。
class Project implements EntityNode {
  const Project({
    required this.id,
    required this.title,
    required this.purpose,
    required this.implementation,
    required this.date,
    required this.status,
    required this.archived,
    required String? parentProjectId,
    required this.order,
    required this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.deleted,
    this.extra = const <String, dynamic>{},
  }) : parentId = parentProjectId;

  static const Set<String> knownKeys = <String>{
    'id',
    'title',
    'purpose',
    'implementation',
    'date',
    'status',
    'archived',
    'parent_project_id',
    'order',
    'completed_at',
    'created_at',
    'updated_at',
    'deleted',
  };

  @override
  final String id;
  final String title;
  final String purpose;
  final String implementation;

  /// 截止 / 目标日，`"YYYY-MM-DD"`，可为空。
  final String? date;

  @override
  final NodeStatus status;

  @override
  final bool archived;

  @override
  final String? parentId;

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

  /// 契约里的字段名（父引用在 JSON 中叫 `parent_project_id`）。
  String? get parentProjectId => parentId;

  bool get isDone => status == NodeStatus.done;

  Project copyWith({
    String? title,
    String? purpose,
    String? implementation,
    Object? date = _unset,
    NodeStatus? status,
    bool? archived,
    Object? parentId = _unset,
    int? order,
    Object? completedAt = _unset,
    int? updatedAt,
    bool? deleted,
  }) {
    return Project(
      id: id,
      title: title ?? this.title,
      purpose: purpose ?? this.purpose,
      implementation: implementation ?? this.implementation,
      date: date == _unset ? this.date : date as String?,
      status: status ?? this.status,
      archived: archived ?? this.archived,
      parentProjectId: parentId == _unset ? this.parentId : parentId as String?,
      order: order ?? this.order,
      completedAt: completedAt == _unset ? this.completedAt : completedAt as int?,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      extra: extra,
    );
  }

  factory Project.fromJson(Map<String, dynamic> json, DecodeIssues issues) {
    return Project(
      id: Canonical.readString(json['id'], 'project.id', issues) ?? '',
      title: Canonical.readString(json['title'], 'project.title', issues) ?? '',
      purpose: Canonical.readString(json['purpose'], 'project.purpose', issues) ?? '',
      implementation:
          Canonical.readString(json['implementation'], 'project.implementation', issues) ?? '',
      date: Canonical.readDate(json['date'], 'project.date', issues),
      status: NodeStatus.fromWire(json['status'], issues.error),
      archived: Canonical.readBool(json['archived'], 'project.archived', issues) ?? false,
      parentProjectId:
          Canonical.readString(json['parent_project_id'], 'project.parent_project_id', issues),
      order: Canonical.readInt(json['order'], 'project.order', issues) ?? 1000,
      completedAt: Canonical.readInt(json['completed_at'], 'project.completed_at', issues),
      createdAt: Canonical.readInt(json['created_at'], 'project.created_at', issues) ?? 0,
      updatedAt: Canonical.readInt(json['updated_at'], 'project.updated_at', issues) ?? 0,
      deleted: Canonical.readBool(json['deleted'], 'project.deleted', issues) ?? false,
      extra: Canonical.readExtra(json, knownKeys),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'id': id,
      'title': title,
      'purpose': purpose,
      'implementation': implementation,
      'date': date,
      'status': status.wire,
      'archived': archived,
      'parent_project_id': parentProjectId,
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
