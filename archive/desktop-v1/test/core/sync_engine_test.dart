import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/store/local_paths.dart';
import 'package:guideline/core/store/local_store.dart';
import 'package:guideline/features/workspace.dart';
import 'package:guideline/sync/fake_backend.dart';
import 'package:guideline/sync/sync_backend.dart';
import 'package:guideline/sync/sync_engine.dart';

void main() {
  late Directory dir;
  late LocalStore store;
  late Workspace ws;
  late FakeSyncBackend backend;
  late SyncEngine engine;

  void rebuildEngine() {
    engine = SyncEngine(
      backend: backend,
      store: store,
      workspace: ws,
      initialState: store.load().syncState,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_sync_');
    store = LocalStore(LocalPaths(dir));
    ws = Workspace.fromLoad(store, store.load());
    backend = FakeSyncBackend();
    rebuildEngine();
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('推送与拉取', () {
    test('本地有数据、云端为空 → 推送并把版本号写回本地', () async {
      final project = ws.createProject(title: '项目 A');
      ws.persist();

      final report = await engine.sync();

      expect(report.ok, isTrue);
      expect(report.pushed, contains(DocName.projects));
      expect(backend.versionOf(DocName.projects), 1);
      expect(backend.payloadOf(DocName.projects), contains(project.id));
      expect(ws.versionOf(DocName.projects), 1);
      expect(ws.dirtyDocs, isEmpty);
      expect(store.load().syncState.firstSyncDone, isTrue);
    });

    test('云端有更高版本 → 拉取并整体替换', () async {
      backend.seed(
        DocName.inspirations,
        version: 3,
        payloadJson: '{"items":[{"id":"remote-1","text":"云端的灵感",'
            '"project_id":null,"status":"pending","merged_into":null,"merged_at":null,'
            '"created_at":1788220800000,"updated_at":1788220800000,"deleted":false}]}',
      );

      final report = await engine.sync();

      expect(report.pulled, contains(DocName.inspirations));
      expect(ws.versionOf(DocName.inspirations), 3);
      expect(ws.inspirationInbox.single.text, '云端的灵感');
    });

    test('云端版本不高于本地时不做无谓拉取', () async {
      ws.createProject(title: 'A');
      await engine.sync();
      final callsAfterFirst = backend.getDocCallCount;

      await engine.sync();

      expect(backend.getDocCallCount, callsAfterFirst, reason: '版本没变就不该下载整包');
    });
  });

  group('跨文档事务（ADR-050 守护）', () {
    test('合并灵感这类跨文档操作，只调用一次 commitTx', () async {
      final project = ws.createProject(title: '项目 A');
      await engine.sync();
      backend.commitTxCallCount = 0;

      final inspiration = ws.captureInspiration('灵感');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );
      expect(ws.pendingTx, isNotNull);
      expect(ws.pendingTx!.isCrossDocument, isTrue);

      final report = await engine.sync();

      expect(report.replayedTx, isTrue);
      expect(backend.commitTxCallCount, 1, reason: '跨文档绝不能退化成两次独立提交');
      expect(ws.pendingTx, isNull, reason: '成功后必须清掉待完成事务');
      expect(backend.versionOf(DocName.projects), 2, reason: 'projects 之前已推到 v1');
      expect(backend.versionOf(DocName.inspirations), 1, reason: 'inspirations 是首次提交');
      expect(ws.dirtyDocs, isEmpty);
    });

    test('重放时同名事务已落库 → 视为成功，不重复 +1（幂等）', () async {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('灵感');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );
      final tx = ws.pendingTx!;

      // 模拟「上一次提交其实成功了，但响应丢了」
      backend.seed(DocName.projects,
          version: tx.docs.firstWhere((d) => d.name == DocName.projects).baseVersion + 1,
          payloadJson: ws.payloadJsonOf(DocName.projects),
          lastTxId: tx.txId);
      backend.seed(DocName.inspirations,
          version: tx.docs.firstWhere((d) => d.name == DocName.inspirations).baseVersion + 1,
          payloadJson: ws.payloadJsonOf(DocName.inspirations),
          lastTxId: tx.txId);

      final report = await engine.sync();

      expect(report.replayedTx, isTrue);
      expect(backend.versionOf(DocName.projects), 1, reason: '不得重复 +1');
      expect(ws.pendingTx, isNull);
    });
  });

  group('冷启动判定表（设计文档 5.10）', () {
    test('两边都空', () async {
      expect(await engine.planColdStart(), ColdStartPlan.bothEmpty);
    });

    test('本地空、云端有 → 拉取', () async {
      backend.seed(DocName.events, version: 2, payloadJson: '{"items":[]}');
      expect(await engine.planColdStart(), ColdStartPlan.pullFromCloud);
    });

    test('本地有、云端空 → 推送', () async {
      ws.createProject(title: 'A');
      expect(await engine.planColdStart(), ColdStartPlan.pushToCloud);
    });

    test('两端都有内容且从未同步过 → 交给用户选，不自动覆盖', () async {
      ws.createProject(title: '本地项目');
      backend.seed(DocName.projects, version: 5, payloadJson: '{"items":[]}');

      expect(await engine.planColdStart(), ColdStartPlan.needsUserChoice);

      final report = await engine.coldStartPull();
      expect(report.pulled.length, greaterThan(0));
      expect(ws.versionOf(DocName.projects), 5);
      expect(store.load().syncState.firstSyncDone, isTrue);
    });
  });

  group('冲突流程（设计文档 5.10）', () {
    test('提交冲突 → 状态进入 conflict 并指出是哪份文档', () async {
      ws.createProject(title: '本地项目');
      backend.forceConflict = true;

      final report = await engine.sync();

      expect(report.status.phase, SyncPhase.conflict);
      expect(report.conflictDoc, DocName.projects);
      expect(ws.dirtyDocs, contains(DocName.projects), reason: '冲突时本地改动不能丢');
    });

    test('选择「以云端为准」→ 本地改动落草稿，随后采用云端', () async {
      ws.createProject(title: '本地项目');
      backend.seed(DocName.projects, version: 4, payloadJson: '{"items":[]}');

      final report = await engine.resolveConflict(DocName.projects, ConflictChoice.takeRemote);

      expect(report.status.phase, SyncPhase.idle);
      expect(ws.versionOf(DocName.projects), 4);
      expect(ws.liveProjects, isEmpty, reason: '已采用云端（空）内容');
      final drafts = store.listConflictDrafts();
      expect(drafts.length, 1);
      expect(drafts.single.path, contains('conflict_'));
    });

    test('选择「以本地为准」→ 用远端版本号作 base 重推成功', () async {
      ws.createProject(title: '本地项目');
      backend.seed(DocName.projects, version: 4, payloadJson: '{"items":[]}');

      final report = await engine.resolveConflict(DocName.projects, ConflictChoice.keepLocal);

      expect(report.status.phase, SyncPhase.idle);
      expect(report.pushed, contains(DocName.projects));
      expect(backend.versionOf(DocName.projects), 5);
      expect(backend.payloadOf(DocName.projects), contains('本地项目'));
      expect(ws.dirtyDocs, isEmpty);
    });
  });

  group('离线与状态可见', () {
    test('离线 → phase=offline，本地改动保留为脏', () async {
      ws.createProject(title: '离线创建');
      backend.offline = true;

      final report = await engine.sync();

      expect(report.status.phase, SyncPhase.offline);
      expect(report.errorCode, BackendErrorCode.network);
      expect(ws.dirtyDocs, contains(DocName.projects));
      expect(engine.status.label, contains('离线'));
      expect(ws.liveProjects.length, 1, reason: '本地优先：离线不影响使用');
    });

    test('未配对导致凭证失效 → phase=error 且可读', () async {
      backend.unauthenticated = true;
      final report = await engine.sync();

      expect(report.status.phase, SyncPhase.error);
      expect(report.errorCode, BackendErrorCode.unauthenticated);
    });

    test('状态文案覆盖各阶段（UI 直接展示）', () {
      expect(const SyncStatus(phase: SyncPhase.replaying).label, contains('补发'));
      expect(const SyncStatus(phase: SyncPhase.pushing).label, contains('上传'));
      expect(const SyncStatus(phase: SyncPhase.pulling).label, contains('拉取'));
      expect(const SyncStatus(phase: SyncPhase.idle).label, '未同步');
      expect(const SyncStatus(phase: SyncPhase.idle, lastSyncAt: 1).label, '已同步');
      expect(const SyncStatus(phase: SyncPhase.offline).label, contains('离线'));
    });
  });

  group('待完成事务的持久化', () {
    test('重启后仍能补发之前没提交成功的事务', () async {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('灵感');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );
      ws.persist();

      // 模拟重启：从磁盘重新加载
      final reloadedStore = LocalStore(LocalPaths(dir));
      final reloadedWs = Workspace.fromLoad(reloadedStore, reloadedStore.load());
      final reloadedEngine = SyncEngine(
        backend: backend,
        store: reloadedStore,
        workspace: reloadedWs,
        initialState: reloadedStore.load().syncState,
      );

      expect(reloadedWs.pendingTx, isNotNull);
      final report = await reloadedEngine.sync();

      expect(report.replayedTx, isTrue);
      expect(backend.versionOf(DocName.projects), 1);
      expect(backend.versionOf(DocName.inspirations), 1);
      expect(reloadedWs.pendingTx, isNull);
    });

    test('PendingTx 只记录本次操作涉及的文档', () {
      ws.createProject(title: 'A');
      ws.persist();
      ws.setPendingTx(null);

      ws.captureInspiration('只动灵感文档');
      expect(ws.pendingTx, isNull);

      final project = ws.liveProjects.first;
      final inspiration = ws.inspirationInbox.first;
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );
      expect(ws.pendingTx, isNotNull);
      expect(
        ws.pendingTx!.docs.map((d) => d.name).toSet(),
        <DocName>{DocName.projects, DocName.inspirations},
      );
      expect(ws.pendingTx!.docs, hasLength(2));
    });
  });
}
