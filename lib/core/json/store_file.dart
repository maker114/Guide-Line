import '../models/entity.dart';
import '../models/enums.dart';
import 'canonical.dart';
import 'document.dart';

/// 本地数据文件的完整形态（**手机端单文件存储**）。
///
/// ```json
/// {
///   "schemaVersion": 3,
///   "savedAt": 1788652800000,
///   "collections": {
///     "projects":     { "items": [ ... ] },
///     "inspirations": { "items": [ ... ] },
///     "events":       { "items": [ ... ] },
///     "tasks":        { "items": [ ... ] }
///   }
/// }
/// ```
///
/// 为什么是单文件（而不是归档方案里的四份文档）：
///   1. **真正的本地原子性** —— 写临时文件再 rename 是"全有或全无"，
///      跨实体的操作（合并灵感会同时改项目与灵感）不再需要"待完成事务"补偿；
///   2. 一份文件更容易备份与分享；
///   3. 文件内部仍按集合分区，**每条记录的序列化格式与契约完全一致**，
///      因此契约样本测试依然有效。
class StoreFile {
  const StoreFile({required this.documents, required this.savedAt});

  /// 当前 schema 版本。改动文件结构时必须递增，并在 [parse] 里保留旧版读取路径。
  ///
  /// v3（破坏性）：任务表删掉 `next_task_ids`（分叉 / 合流整套删掉，见《数据契约》§3.4.1）。
  /// 读取 v2 文件时那个字段被丢弃、**不再写出**；任务顺序回到 `order` 这一条链。
  static const int currentSchemaVersion = 3;

  factory StoreFile.empty() => StoreFile(
        documents: <DocName, Document>{
          for (final name in DocName.values) name: Document.empty(name),
        },
        savedAt: 0,
      );

  final Map<DocName, Document> documents;
  final int savedAt;

  Document documentOf(DocName name) => documents[name] ?? Document.empty(name);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': currentSchemaVersion,
        'savedAt': savedAt,
        'collections': <String, dynamic>{
          for (final entry in documents.entries) entry.key.key: entry.value.toJson(),
        },
      };

  String toCanonicalText() => Canonical.documentText(toJson());

  StoreFile copyWith({Map<DocName, Document>? documents, int? savedAt}) => StoreFile(
        documents: documents ?? this.documents,
        savedAt: savedAt ?? this.savedAt,
      );

  /// 解析单文件。**任何单条记录的问题都不应让整份数据失败**。
  ///
  /// 同时兼容 **v1 的四文档信封**（`{version, updated_at, last_tx_id, payload:{items}}`）：
  /// 旧数据（例如从电脑端导出的文件）可以直接读入。
  static StoreFile parse(String text, DecodeIssues issues) {
    Object? root;
    try {
      root = Canonical.decode(text);
    } catch (error) {
      issues.error('数据文件不是合法 JSON：$error');
      return StoreFile.empty();
    }

    final map = Canonical.readObject(root, 'store.root', issues);
    if (map == null) return StoreFile.empty();

    final schemaVersion =
        Canonical.readInt(map['schemaVersion'], 'store.schemaVersion', issues) ?? 0;
    if (schemaVersion > currentSchemaVersion) {
      issues.error(
        '数据文件版本 $schemaVersion 高于本应用支持的 $currentSchemaVersion —— 请升级 App',
      );
      return StoreFile.empty();
    }

    final savedAt = Canonical.readInt(map['savedAt'], 'store.savedAt', issues) ?? 0;
    final rawCollections = Canonical.readObject(map['collections'], 'store.collections', issues);

    final documents = <DocName, Document>{};
    for (final name in DocName.values) {
      final raw = rawCollections == null ? null : rawCollections[name.key];
      final collectionMap = raw == null
          ? null
          : Canonical.readObject(raw, 'store.collections.${name.key}', issues);
      if (collectionMap == null) {
        documents[name] = Document.empty(name);
        continue;
      }
      documents[name] = Document.fromJsonMap(name, collectionMap, issues);
    }

    // 兼容 v1 信封：四份文档被拼进一个对象时（键为 projects.json 等）
    if (rawCollections == null && map.containsKey('projects.json')) {
      return _parseLegacyEnvelope(map, issues);
    }

    return StoreFile(documents: documents, savedAt: savedAt);
  }

  /// v1 兼容：{ "projects.json": {version,…,payload:{items}}, … }
  static StoreFile _parseLegacyEnvelope(Map<String, dynamic> map, DecodeIssues issues) {
    final documents = <DocName, Document>{};
    for (final name in DocName.values) {
      final raw = Canonical.readObject(map[name.fileName], 'store.${name.fileName}', issues);
      final payload =
          raw == null ? null : Canonical.readObject(raw['payload'], 'store.${name.fileName}.payload', issues);
      if (payload == null) {
        documents[name] = Document.empty(name);
        continue;
      }
      documents[name] = Document.fromJsonMap(name, payload, issues);
    }
    issues.warn('检测到 v1 四文档信封格式，已按兼容路径读入');
    return StoreFile(
      documents: documents,
      savedAt: Canonical.readInt(map['savedAt'], 'store.savedAt', issues) ?? 0,
    );
  }
}
