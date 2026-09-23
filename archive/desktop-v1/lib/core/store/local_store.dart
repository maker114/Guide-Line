import 'dart:convert';
import 'dart:io';

import '../json/canonical.dart';
import '../json/document.dart';
import '../models/entity.dart';
import '../models/enums.dart';
import 'atomic_file.dart';
import 'local_paths.dart';
import 'local_state.dart';
import 'pending_tx.dart';

/// 启动加载报告：把"读到了什么"与"哪里有问题"一起交给上层。
class LoadReport {
  const LoadReport({
    required this.documents,
    required this.syncState,
    required this.pendingTx,
    required this.uiPrefs,
    required this.issues,
    required this.quarantinedPaths,
  });

  final Map<DocName, Document> documents;
  final SyncState syncState;
  final PendingTx? pendingTx;
  final UiPrefs uiPrefs;
  final DecodeIssues issues;

  /// 被隔离保留的损坏文件路径（**绝不允许静默重建空数据**）。
  final List<String> quarantinedPaths;

  bool get hasCorruptDocument => quarantinedPaths.isNotEmpty;
}

/// 本地存储（设计文档 5.7 / 《同步与云函数契约》§1）。
///
/// 只负责"文件 ↔ 对象"，不含业务规则；所有写入都是**原子**的。
class LocalStore {
  LocalStore(this.paths);

  final LocalPaths paths;

  /// 启动加载：先清残留 `.tmp`，再逐份读取并解析。
  LoadReport load({int? nowMillis}) {
    paths.ensureDirectories();
    AtomicFile.cleanupTmp(paths.allManagedFiles);

    final issues = DecodeIssues();
    final quarantined = <String>[];
    final documents = <DocName, Document>{};
    final stamp = nowMillis ?? DateTime.now().millisecondsSinceEpoch;

    for (final name in DocName.values) {
      final file = paths.docFile(name);
      final raw = file.existsSync() ? file.readAsStringSync(encoding: utf8) : null;
      if (raw == null) {
        documents[name] = Document.empty(name);
        continue;
      }

      // 先做一次严格解析：整体非法 JSON 属于"文件损坏"，必须隔离而不是当空文档
      try {
        Canonical.decode(raw);
      } catch (error) {
        issues.error('${name.fileName} 不是合法 JSON（$error）—— 已隔离保留现场');
        quarantined.add(AtomicFile(file).quarantine(stamp));
        documents[name] = Document.empty(name);
        continue;
      }

      final document = Document.parse(name, raw, issues);
      documents[name] = document;
    }

    final syncState = _readSyncState(issues);
    final pendingTx = PendingTx.parse(paths.pendingTx.existsSync() ? paths.pendingTx.readAsStringSync() : null);
    final uiPrefs = _readUiPrefs();

    return LoadReport(
      documents: documents,
      syncState: syncState,
      pendingTx: pendingTx,
      uiPrefs: uiPrefs,
      issues: issues,
      quarantinedPaths: quarantined,
    );
  }

  /// 保存一份文档（**与云端逐字节同构**）。
  void saveDocument(Document document) {
    paths.ensureDirectories();
    AtomicFile(paths.docFile(document.name)).writeText(document.toCanonicalText());
  }

  void saveAll(Map<DocName, Document> documents) {
    for (final document in documents.values) {
      saveDocument(document);
    }
  }

  void saveSyncState(SyncState state) {
    paths.ensureDirectories();
    AtomicFile(paths.syncState).writeText(state.toCanonicalText());
  }

  void saveUiPrefs(UiPrefs prefs) {
    paths.ensureDirectories();
    AtomicFile(paths.uiPrefs).writeText(prefs.toCanonicalText());
  }

  void savePendingTx(PendingTx tx) {
    paths.ensureDirectories();
    AtomicFile(paths.pendingTx).writeText(Canonical.documentText(tx.toJson()));
  }

  /// 提交成功后**立即**删除（设计文档 5.9）。
  void clearPendingTx() {
    final file = paths.pendingTx;
    if (file.existsSync()) file.deleteSync();
    final tmp = AtomicFile.tmpOf(file);
    if (tmp.existsSync()) tmp.deleteSync();
  }

  /// 冲突草稿：不参与同步、不进版本（设计文档 5.10）。
  String saveConflictDraft(DocName name, String text, int timestamp, {String kind = 'conflict'}) {
    paths.ensureDirectories();
    final file = paths.conflictDraft(name, timestamp, kind: kind);
    AtomicFile(file).writeText(text);
    return file.path;
  }

  List<File> listConflictDrafts() {
    final dir = paths.conflicts;
    if (!dir.existsSync()) return <File>[];
    final files = dir.listSync().whereType<File>().toList(growable: false);
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Document documentOf(DocName name, Map<DocName, Document> documents) =>
      documents[name] ?? Document.empty(name);

  SyncState _readSyncState(DecodeIssues issues) {
    final file = paths.syncState;
    if (!file.existsSync()) return SyncState.initial;
    try {
      final decoded = Canonical.decode(file.readAsStringSync(encoding: utf8));
      if (decoded is Map) return SyncState.fromJson(decoded.cast<String, dynamic>());
      issues.error('sync_state.json 结构异常 —— 使用初始值');
    } catch (error) {
      issues.error('sync_state.json 解析失败：$error —— 使用初始值');
    }
    return SyncState.initial;
  }

  UiPrefs _readUiPrefs() {
    final file = paths.uiPrefs;
    if (!file.existsSync()) return UiPrefs.empty;
    try {
      final decoded = Canonical.decode(file.readAsStringSync(encoding: utf8));
      if (decoded is Map) return UiPrefs.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      // 视图偏好损坏无关紧要，直接重置
    }
    return UiPrefs.empty;
  }
}

/// 便于测试与上层使用：把实体序列化成 payload JSON 字符串。
String payloadJsonOf(Iterable<Entity> items) {
  return Canonical.compact(<String, dynamic>{
    'items': items.map((e) => e.toJson()).toList(growable: false),
  });
}
