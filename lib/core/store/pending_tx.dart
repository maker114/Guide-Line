import '../json/canonical.dart';
import '../models/enums.dart';

/// 待完成事务（《同步与云函数契约》§5 / 设计文档 5.9）。
///
/// 任何**跨文档**操作在「改内存 → 置 dirty」的同一时刻写入本结构；
/// 提交成功后立即删除，失败则下次同步优先补发。
///
/// 注意：这里用 camelCase（与实体 JSON 的 snake_case 不同），
/// 因为它是**本地结构**，不参与跨端逐字节比对。
class PendingTx {
  const PendingTx({
    required this.txId,
    required this.createdAt,
    required this.docs,
    required this.retry,
    required this.lastError,
  });

  final String txId;
  final int createdAt;
  final List<PendingTxDoc> docs;
  final int retry;
  final String? lastError;

  bool get isCrossDocument => docs.length > 1;

  bool get needsManualAttention => retry >= 3;

  PendingTx copyWith({int? retry, Object? lastError = _unset}) => PendingTx(
        txId: txId,
        createdAt: createdAt,
        docs: docs,
        retry: retry ?? this.retry,
        lastError: lastError == _unset ? this.lastError : lastError as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'txId': txId,
        'createdAt': createdAt,
        'docs': docs.map((d) => d.toJson()).toList(growable: false),
        'retry': retry,
        'lastError': lastError,
      };

  static PendingTx? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    final txId = map['txId'];
    final docsRaw = map['docs'];
    if (txId is! String || docsRaw is! List) return null;
    final docs = <PendingTxDoc>[];
    for (final item in docsRaw) {
      final doc = PendingTxDoc.fromJson(item);
      if (doc != null) docs.add(doc);
    }
    if (docs.isEmpty) return null;
    return PendingTx(
      txId: txId,
      createdAt: map['createdAt'] is int ? map['createdAt'] as int : 0,
      docs: docs,
      retry: map['retry'] is int ? map['retry'] as int : 0,
      lastError: map['lastError'] is String ? map['lastError'] as String : null,
    );
  }

  static PendingTx? parse(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      return fromJson(Canonical.decode(text));
    } catch (_) {
      return null;
    }
  }
}

/// 事务中单份文档的提交凭据（payload 不在此处重复存储）。
class PendingTxDoc {
  const PendingTxDoc({required this.name, required this.baseVersion});

  final DocName name;
  final int baseVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name.fileName,
        'baseVersion': baseVersion,
      };

  static PendingTxDoc? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final baseVersion = json['baseVersion'];
    if (name is! String || baseVersion is! int) return null;
    final doc = DocName.fromFileName(name);
    if (doc == null) return null;
    return PendingTxDoc(name: doc, baseVersion: baseVersion);
  }
}

const Object _unset = Object();
