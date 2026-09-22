import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/atomic_file.dart';
import 'package:guideline/core/store/local_paths.dart';
import 'package:guideline/core/store/local_state.dart';
import 'package:guideline/core/store/local_store.dart';
import 'package:guideline/core/store/pending_tx.dart';

void main() {
  late Directory dir;
  late LocalStore store;
  late LocalPaths paths;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_store_');
    paths = LocalPaths(dir);
    store = LocalStore(paths);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('加载', () {
    test('首次加载：4 份空文档 + 初始同步状态 + 无待完成事务', () {
      final report = store.load();

      expect(report.documents.length, 4);
      for (final name in DocName.values) {
        expect(report.documents[name]!.items, isEmpty);
        expect(report.documents[name]!.version, 0);
      }
      expect(report.syncState.accountId, isNull);
      expect(report.syncState.firstSyncDone, isFalse);
      expect(report.pendingTx, isNull);
      expect(report.hasCorruptDocument, isFalse);
      expect(report.issues.errors, isEmpty);
    });

    test('中文与 emoji 往返后逐字节一致', () {
      final project = Project(
        id: 'p1',
        title: '个人知识库 🚀',
        purpose: '让灵感不再散落',
        implementation: '先冻结契约',
        date: '2026-12-31',
        status: NodeStatus.pending,
        archived: false,
        parentProjectId: null,
        order: 1000,
        completedAt: null,
        createdAt: 1788220800000,
        updatedAt: 1788307200000,
        deleted: false,
      );
      final doc = Document.empty(DocName.projects).copyWith(
        version: 3,
        updatedAt: 1788652800000,
        lastTxId: 'tx-1',
        items: <Project>[project],
      );
      store.saveDocument(doc);

      final reloaded = Document.parse(
        DocName.projects,
        paths.docFile(DocName.projects).readAsStringSync(encoding: utf8),
        DecodeIssues(),
      );
      expect(reloaded.toCanonicalText(), doc.toCanonicalText());
      expect(reloaded.items.length, 1);
      expect((reloaded.items.first as Project).title, '个人知识库 🚀');
      expect(reloaded.lastTxId, 'tx-1');
    });

    test('原子写不留 .tmp 残留', () {
      store.saveDocument(Document.empty(DocName.tasks));
      expect(File('${paths.docFile(DocName.tasks).path}.tmp').existsSync(), isFalse);
    });

    test('启动时清理上一次残留的 .tmp', () {
      final tmp = File('${paths.docFile(DocName.events).path}.tmp');
      tmp.writeAsStringSync('{"partial": true');
      store.load();
      expect(tmp.existsSync(), isFalse);
    });

    test('损坏文件被隔离保留，而不是静默重建为空', () {
      paths.ensureDirectories();
      paths.docFile(DocName.projects).writeAsStringSync('{"version": 1, "payload": {');

      final report = store.load();

      expect(report.hasCorruptDocument, isTrue);
      expect(report.quarantinedPaths.length, 1);
      expect(File(report.quarantinedPaths.first).existsSync(), isTrue, reason: '现场必须保留');
      expect(report.documents[DocName.projects]!.items, isEmpty);
      expect(report.issues.errors, isNotEmpty);
      // 其余文档不受影响
      expect(report.documents[DocName.tasks]!.items, isEmpty);
    });
  });

  group('同步元数据与本地结构', () {
    test('sync_state 往返（且不含版本号）', () {
      final state = SyncState.initial.copyWith(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        firstSyncDone: true,
        lastSyncAt: 1788652800000,
      );
      store.saveSyncState(state);

      final report = store.load();
      expect(report.syncState.accountId, 'acc-1');
      expect(report.syncState.firstSyncDone, isTrue);
      expect(report.syncState.isPaired, isTrue);

      final text = paths.syncState.readAsStringSync(encoding: utf8);
      expect(text.contains('version'), isFalse, reason: '版本号只存在本地文档外层');
    });

    test('pending_tx 保存 / 读取 / 清除，非法内容解析为 null', () {
      final tx = PendingTx(
        txId: 'tx-1',
        createdAt: 1788652800000,
        docs: const <PendingTxDoc>[
          PendingTxDoc(name: DocName.projects, baseVersion: 12),
          PendingTxDoc(name: DocName.inspirations, baseVersion: 9),
        ],
        retry: 0,
        lastError: null,
      );
      store.savePendingTx(tx);

      final loaded = PendingTx.parse(paths.pendingTx.readAsStringSync());
      expect(loaded, isNotNull);
      expect(loaded!.isCrossDocument, isTrue);
      expect(loaded.docs.first.name, DocName.projects);
      expect(loaded.needsManualAttention, isFalse);

      store.clearPendingTx();
      expect(paths.pendingTx.existsSync(), isFalse);
      expect(PendingTx.parse(null), isNull);
      expect(PendingTx.parse('{ broken'), isNull);
    });

    test('ui_prefs 往返且折叠状态可切换（不参与同步）', () {
      store.saveUiPrefs(UiPrefs.empty.toggleCollapsed('p1', true));
      final report = store.load();
      expect(report.uiPrefs.isCollapsed('p1'), isTrue);
      expect(report.uiPrefs.isCollapsed('p2'), isFalse);

      final toggled = report.uiPrefs.toggleCollapsed('p1', false);
      store.saveUiPrefs(toggled);
      expect(store.load().uiPrefs.isCollapsed('p1'), isFalse);
    });

    test('冲突草稿落到 conflicts/ 并可列出', () {
      final path = store.saveConflictDraft(DocName.tasks, '{"items":[]}', 1788652800000);
      expect(File(path).existsSync(), isTrue);
      expect(store.listConflictDrafts().length, 1);
    });
  });

  group('AtomicFile', () {
    test('隔离时保留原始内容', () {
      final file = File('${dir.path}${Platform.pathSeparator}sample.json');
      file.writeAsStringSync('oops');
      final moved = AtomicFile(file).quarantine(999);

      expect(File(moved).existsSync(), isTrue);
      expect(File(moved).readAsStringSync(), 'oops');
      expect(file.existsSync(), isFalse);
    });

    test('写入内容与 canonical 文本一致（LF、末尾单换行）', () {
      final doc = Document.empty(DocName.events).copyWith(version: 1);
      store.saveDocument(doc);

      final bytes = paths.docFile(DocName.events).readAsBytesSync();
      final text = utf8.decode(bytes);
      expect(text, doc.toCanonicalText());
      expect(text.contains('\r'), isFalse);
      expect(text.endsWith('\n'), isTrue);
      expect(text.endsWith('\n\n'), isFalse);
    });
  });
}
