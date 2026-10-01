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
  ///
  /// **这是薄壳**：真正的解析在 [parseDetailed]，它把"为什么解析不出东西"也答出来。
  /// 需要区分"损坏"与"版本高于本应用"的调用方（`AppStorage` 就是）
  /// **必须用 [parseDetailed]** —— 只拿 `StoreFile?` 是分不出来的。
  ///
  /// 语义与改动前**一字不变**：解析不出来时给一份**空文件**（不是 null）。
  /// 这是刻意的兼容 —— 契约样本测试与导出/导入那几处都依赖"拿到的永远是一份文件"。
  static StoreFile parse(String text, DecodeIssues issues) =>
      parseDetailed(text, issues).store ?? StoreFile.empty();

  /// 解析单文件，并把**结果的性质**一起答出来。
  ///
  /// 为什么要有它（2026-10-01 修的一处**会丢数据**的缺陷）：
  /// 在这之前，本方法只有"返回一份 `StoreFile`"这一个出口 —— 遇到"文件版本高于
  /// 本应用"时它**也返回一份空 store**，与"文件损坏"长得一模一样。
  /// 于是上层只能靠**匹配错误文案**（`contains('高于本应用支持的')`）去猜是哪一种，
  /// 而那句文案同时又是给用户看的提示语 —— 改动它一个字的措辞，
  /// 上层就会把"版本过新"误判成"损坏"，接着隔离真文件、用旧备份覆盖，
  /// **用户在新版里的数据被静默换掉**。
  ///
  /// 现在这件事由 [StoreParseResult.status] 用**类型**答，不靠文案。
  /// 提示语怎么写、怎么改，都不再影响这个判断。
  static StoreParseResult parseDetailed(String text, DecodeIssues issues) {
    Object? root;
    try {
      root = Canonical.decode(text);
    } catch (error) {
      issues.error('数据文件不是合法 JSON：$error');
      return StoreParseResult.broken();
    }

    final map = Canonical.readObject(root, 'store.root', issues);
    if (map == null) return StoreParseResult.broken();

    final schemaVersion =
        Canonical.readInt(map['schemaVersion'], 'store.schemaVersion', issues) ?? 0;
    if (schemaVersion > currentSchemaVersion) {
      // 这条**给用户看**的话可以随便改；判断不依赖它（见类文档）。
      issues.error(
        '数据文件版本 $schemaVersion 高于本应用支持的 $currentSchemaVersion，请升级 App',
      );
      return const StoreParseResult.tooNew();
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
      return StoreParseResult.ok(_parseLegacyEnvelope(map, issues));
    }

    return StoreParseResult.ok(StoreFile(documents: documents, savedAt: savedAt));
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

/// 一份数据文件"读出来是什么"。
///
/// 与 [StoreParseResult.status] 一一对应：[ok] 时一定有 [StoreFile]，
/// 另两种一定没有。
enum StoreParseStatus {
  /// 读出来了。
  ok,

  /// **版本高于本应用支持的** —— 不是损坏。
  ///
  /// 这一种必须与 [broken] 分开对待：文件是好的、只是这边看不懂，
  /// 所以**绝不能隔离它、也绝不能用旧备份盖它**（用户在新版里的数据就在里面）。
  tooNew,

  /// 读不出来（不是合法 JSON、根不是对象……）。这一种才走隔离 + 备份恢复。
  broken,
}

/// [StoreFile.parseDetailed] 的返回值：**内容 + 它是哪一类结果**。
///
/// 存在的理由见 [StoreFile.parseDetailed] 的文档 —— 一句话：
/// 让"版本过新"这件事由**类型**答，而不是由一句给用户看的错误文案答。
class StoreParseResult {
  const StoreParseResult._(this.status, this.store);

  /// 读出来了。带一份文件，且**一定非空**。
  const StoreParseResult.ok(StoreFile file) : this._(StoreParseStatus.ok, file);

  /// 版本高于本应用。**没有**可用内容（但不代表数据坏了）。
  const StoreParseResult.tooNew() : this._(StoreParseStatus.tooNew, null);

  /// 读不出来。
  const StoreParseResult.broken() : this._(StoreParseStatus.broken, null);

  final StoreParseStatus status;
  final StoreFile? store;
}
