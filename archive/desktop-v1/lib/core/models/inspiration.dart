import '../json/canonical.dart';
import 'entity.dart';
import 'enums.dart';

/// 灵感（《数据契约》§3.1）—— 扁平列表，**不参与完成判定**。
class Inspiration implements Entity {
  const Inspiration({
    required this.id,
    required this.text,
    required this.projectId,
    required this.status,
    required this.mergedInto,
    required this.mergedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.deleted,
    this.extra = const <String, dynamic>{},
  });

  static const Set<String> knownKeys = <String>{
    'id',
    'text',
    'project_id',
    'status',
    'merged_into',
    'merged_at',
    'created_at',
    'updated_at',
    'deleted',
  };

  @override
  final String id;
  final String text;
  final String? projectId;
  final InspirationStatus status;
  final String? mergedInto;
  final int? mergedAt;

  @override
  final int createdAt;

  @override
  final int updatedAt;

  @override
  final bool deleted;

  /// 未知字段透传（《数据契约》§8：不因再序列化而丢失）。
  final Map<String, dynamic> extra;

  bool get isPending => status == InspirationStatus.pending;

  bool get isMerged => status == InspirationStatus.merged;

  bool get isDiscarded => status == InspirationStatus.discarded;

  /// 跨字段一致性（《数据契约》§4.3）。
  bool get isConsistent {
    if (status == InspirationStatus.merged) {
      return mergedInto != null && mergedAt != null;
    }
    return mergedInto == null && mergedAt == null;
  }

  Inspiration copyWith({
    String? text,
    Object? projectId = _unset,
    InspirationStatus? status,
    Object? mergedInto = _unset,
    Object? mergedAt = _unset,
    int? updatedAt,
    bool? deleted,
  }) {
    return Inspiration(
      id: id,
      text: text ?? this.text,
      projectId: projectId == _unset ? this.projectId : projectId as String?,
      status: status ?? this.status,
      mergedInto: mergedInto == _unset ? this.mergedInto : mergedInto as String?,
      mergedAt: mergedAt == _unset ? this.mergedAt : mergedAt as int?,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      extra: extra,
    );
  }

  factory Inspiration.fromJson(Map<String, dynamic> json, DecodeIssues issues) {
    final id = Canonical.readString(json['id'], 'inspiration.id', issues);
    return Inspiration(
      id: id ?? '',
      text: Canonical.readString(json['text'], 'inspiration.text', issues) ?? '',
      projectId: Canonical.readString(json['project_id'], 'inspiration.project_id', issues),
      status: InspirationStatus.fromWire(json['status'], issues.error),
      mergedInto: Canonical.readString(json['merged_into'], 'inspiration.merged_into', issues),
      mergedAt: Canonical.readInt(json['merged_at'], 'inspiration.merged_at', issues),
      createdAt: Canonical.readInt(json['created_at'], 'inspiration.created_at', issues) ?? 0,
      updatedAt: Canonical.readInt(json['updated_at'], 'inspiration.updated_at', issues) ?? 0,
      deleted: Canonical.readBool(json['deleted'], 'inspiration.deleted', issues) ?? false,
      extra: Canonical.readExtra(json, knownKeys),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      'id': id,
      'text': text,
      'project_id': projectId,
      'status': status.wire,
      'merged_into': mergedInto,
      'merged_at': mergedAt,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted': deleted,
    };
    out.addAll(extra);
    return out;
  }
}

/// copyWith 中区分「未传」与「显式置 null」。
const Object _unset = Object();
