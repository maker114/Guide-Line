import 'dart:convert';
import 'dart:io';

import '../core/ids.dart';
import '../core/json/canonical.dart';
import '../core/json/document.dart';
import '../core/models/entity.dart';
import '../core/models/enums.dart';
import 'workspace.dart';

/// 导出包：一份自描述的数据快照，用于**完全离线**的搬移（U 盘 / 蓝牙 / 微信发文件）。
///
/// 设计取舍：
///   · 用 `dart:io` 自带的 gzip，**不引入任何第三方依赖**；
///   · 4 份文档连版本号一起带走，便于导入方判断"谁更新"；
///   · 墓碑与墓碑骨架**一并导出** —— 否则导入后已删数据会"复活"（ADR-003 的初衷）。
class ExportBundle {
  const ExportBundle({
    required this.exportedAt,
    required this.deviceId,
    required this.appVersion,
    required this.documents,
  });

  static const String formatTag = 'guideline-export';

  static const int currentFormatVersion = 1;

  final int exportedAt;
  final String? deviceId;
  final String appVersion;
  final Map<DocName, Document> documents;

  int get totalItems =>
      documents.values.fold<int>(0, (sum, doc) => sum + doc.items.length);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'format': formatTag,
        'formatVersion': currentFormatVersion,
        'exportedAt': exportedAt,
        'deviceId': deviceId,
        'appVersion': appVersion,
        'documents': <String, dynamic>{
          for (final entry in documents.entries) entry.key.fileName: entry.value.toJson(),
        },
      };

  static ExportBundle? fromJson(Object? json, DecodeIssues issues) {
    if (json is! Map) {
      issues.error('导出包根节点不是对象');
      return null;
    }
    final map = json.cast<String, dynamic>();
    if (map['format'] != formatTag) {
      issues.error('不是 GuideLine 导出包（format=${map['format']}）');
      return null;
    }
    final formatVersion = map['formatVersion'];
    if (formatVersion is! int || formatVersion > currentFormatVersion) {
      issues.error('导出包版本 $formatVersion 高于本机支持的 $currentFormatVersion —— 请升级 App');
      return null;
    }

    final rawDocs = map['documents'];
    if (rawDocs is! Map) {
      issues.error('导出包缺少 documents');
      return null;
    }

    final documents = <DocName, Document>{};
    for (final name in DocName.values) {
      final raw = rawDocs[name.fileName];
      if (raw is! Map) continue;
      final text = Canonical.documentText(raw.cast<String, dynamic>());
      documents[name] = Document.parse(name, text, issues);
    }
    if (documents.isEmpty) {
      issues.error('导出包里没有任何文档');
      return null;
    }

    return ExportBundle(
      exportedAt: map['exportedAt'] is int ? map['exportedAt'] as int : 0,
      deviceId: map['deviceId'] is String ? map['deviceId'] as String : null,
      appVersion: map['appVersion'] is String ? map['appVersion'] as String : 'unknown',
      documents: documents,
    );
  }
}

/// 导入时对**单份文档**的判定。
enum ImportAction {
  /// 内容相同（只可能把版本号对齐）
  identical,

  /// 采用导入包（`takeIncoming`）
  takeIncoming,

  /// 保留本地（导入包更旧）
  keepLocal,

  /// 双方都有改动 → 交给用户决定
  conflict,
}

class ImportDecision {
  const ImportDecision({required this.name, required this.action, required this.detail});

  final DocName name;
  final ImportAction action;
  final String detail;
}

/// 冲突时用户的选择。
enum ImportConflictChoice {
  /// 以导入包为准（本地未提交内容先落草稿）
  takeIncoming,

  /// 以本地为准（导入包内容落草稿备查）
  keepLocal,
}

class ImportReport {
  const ImportReport({
    required this.decisions,
    required this.applied,
    required this.draftPaths,
  });

  final List<ImportDecision> decisions;
  final List<DocName> applied;

  /// 冲突草稿落盘路径（不参与同步、不进版本）
  final List<String> draftPaths;

  bool get needsUserDecision =>
      decisions.any((d) => d.action == ImportAction.conflict);
}

/// 导出 / 导入（零第三方搬移数据）。
class Portability {
  const Portability._();

  /// 导出为 gzip 压缩的 JSON 字节流（`.json.gz`）。
  static List<int> exportBytes(
    Workspace workspace, {
    String? deviceId,
    String appVersion = 'unknown',
    int? nowMillis,
  }) {
    final bundle = ExportBundle(
      exportedAt: nowMillis ?? Ids.nowMillis(),
      deviceId: deviceId,
      appVersion: appVersion,
      documents: <DocName, Document>{
        for (final name in DocName.values) name: workspace.documentOf(name),
      },
    );
    return gzip.encode(utf8.encode(Canonical.documentText(bundle.toJson())));
  }

  static ExportBundle? decodeBytes(List<int> bytes, DecodeIssues issues) {
    try {
      final text = utf8.decode(gzip.decode(bytes));
      return ExportBundle.fromJson(Canonical.decode(text), issues);
    } catch (error) {
      issues.error('导出包解压/解析失败：$error');
      return null;
    }
  }

  /// 预览：逐份文档判定会发生什么（**不改动任何数据**）。
  ///
  /// 判定规则（顺序即优先级）：
  ///   1. payload 完全相同 → `identical`（只对齐版本号）
  ///   2. 本地有未提交改动 → `conflict`（**绝不静默覆盖**）
  ///   3. 导入包版本更高 → `takeIncoming`
  ///   4. 导入包版本更低 → `keepLocal`
  ///   5. 版本相同但内容不同、且本地干净 → `takeIncoming`
  ///      （**离线手动搬移时两端版本号常常都是 0**，而"导入"本身就是用户的显式动作）
  static List<ImportDecision> preview(Workspace workspace, ExportBundle bundle) {
    final decisions = <ImportDecision>[];

    for (final name in DocName.values) {
      final incoming = bundle.documents[name];
      if (incoming == null) continue;

      final local = workspace.documentOf(name);
      final localDirty = workspace.dirtyDocs.contains(name);
      final samePayload = local.payloadJson() == incoming.payloadJson();

      if (samePayload) {
        decisions.add(ImportDecision(
          name: name,
          action: ImportAction.identical,
          detail: '内容相同（本地 v${local.version} / 导入 v${incoming.version}）',
        ));
        continue;
      }

      if (localDirty) {
        decisions.add(ImportDecision(
          name: name,
          action: ImportAction.conflict,
          detail: '本地有未提交改动，导入包也不同（本地 v${local.version} / 导入 v${incoming.version}）',
        ));
        continue;
      }

      if (incoming.version > local.version) {
        decisions.add(ImportDecision(
          name: name,
          action: ImportAction.takeIncoming,
          detail: '导入包更新（本地 v${local.version} → 导入 v${incoming.version}）',
        ));
      } else if (incoming.version < local.version) {
        decisions.add(ImportDecision(
          name: name,
          action: ImportAction.keepLocal,
          detail: '本地更新（本地 v${local.version} / 导入 v${incoming.version}）',
        ));
      } else {
        decisions.add(ImportDecision(
          name: name,
          action: ImportAction.takeIncoming,
          detail: '版本相同（v${local.version}）但内容不同，本地无未提交改动 → 采用导入包',
        ));
      }
    }
    return decisions;
  }

  /// 应用导入。
  ///
  /// - 非冲突项按 [preview] 的判定自动处理；
  /// - 冲突项若 [choices] 未给选择，则**保持本地不动**（安全的默认），
  ///   并把导入包内容写成草稿文件供事后查看（`conflicts/imported_*.json`）。
  static ImportReport apply(
    Workspace workspace,
    ExportBundle bundle, {
    Map<DocName, ImportConflictChoice> choices = const <DocName, ImportConflictChoice>{},
    int? nowMillis,
  }) {
    final decisions = preview(workspace, bundle);
    final applied = <DocName>[];
    final drafts = <String>[];
    final now = nowMillis ?? Ids.nowMillis();

    for (final decision in decisions) {
      final incoming = bundle.documents[decision.name];
      if (incoming == null) continue;

      switch (decision.action) {
        case ImportAction.identical:
          workspace.markSynced(decision.name, incoming.version);
          break;
        case ImportAction.takeIncoming:
          workspace.applyRemoteDocument(incoming);
          applied.add(decision.name);
          break;
        case ImportAction.keepLocal:
          break;
        case ImportAction.conflict:
          final choice = choices[decision.name];
          if (choice == ImportConflictChoice.takeIncoming) {
            // 本地未提交内容先落草稿，再整体替换（设计文档 5.10 的同一原则）
            drafts.add(workspace.saveConflictDraft(decision.name, now));
            workspace.applyRemoteDocument(incoming);
            applied.add(decision.name);
          } else {
            // 以本地为准（或用户尚未选择）：导入包内容落草稿备查，本地不动
            drafts.add(workspace.saveImportedDraft(decision.name, incoming, now));
          }
          break;
      }
    }

    workspace.persist();
    return ImportReport(decisions: decisions, applied: applied, draftPaths: drafts);
  }

  /// 便携文件名：`guideline-export-YYYYMMDD-HHmmss.json.gz`
  static String suggestedFileName(int timestamp) {
    final d = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String two(int v) => v.toString().padLeft(2, '0');
    return 'guideline-export-${d.year}${two(d.month)}${two(d.day)}'
        '-${two(d.hour)}${two(d.minute)}${two(d.second)}.json.gz';
  }
}
