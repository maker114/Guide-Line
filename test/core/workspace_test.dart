import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/rules/completion.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/features/workspace.dart';

/// 业务逻辑层（`Workspace`）测试 —— 由归档的电脑端工程移植到**手机单机版**。
///
/// 移植原则：
///   · 实体模型与业务规则与归档版一致 → 断言逐条保留，中文用例名不变；
///   · 云端同步 / 待完成事务（`version`、`pending_tx`、`dirty`、`markSynced`、
///     `applyRemoteDocument`、`SyncBackend`）在单机版已随代码删除 → 相关用例不再移植；
///   · 构造方式改为 `Workspace.fromLoad(AppStorage, LoadReport)`，每个用例一个临时目录；
///   · 落盘只有一份 `guideline.json`：**每次业务变更立刻原子写入**，
///     所以「改动马上能在磁盘上看到」和「第二次保存前有备份」本身就是要守住的行为。
void main() {
  late Directory dir;
  late AppStorage storage;
  late Workspace ws;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_ws_');
    storage = AppStorage(AppPaths(dir));
    // 与线上启动路径完全一致：先 load() 拿到 LoadReport，再由它构造 Workspace
    ws = Workspace.fromLoad(storage, storage.load());
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 主数据文件（`guideline.json`）的原始文本。
  String storeTextOnDisk() => storage.paths.storeFile.readAsStringSync(encoding: utf8);

  /// 把磁盘上的主数据文件按正式解析路径读回来（验证"写下去的确实能读回"）。
  StoreFile storeFileOnDisk() => StoreFile.parse(storeTextOnDisk(), DecodeIssues());

  group('项目：创建 / 层级 / 完成规则', () {
    test('可以建三层，第四层被拒绝', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      final grand = ws.createProject(title: '孙', parentId: child.id);

      expect(ws.projectTree.depthOf(grand.id), 3);
      expect(
        () => ws.createProject(title: '曾孙', parentId: grand.id),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('子项目未终态时父项目不可完成，并给出可读原因', () {
      final root = ws.createProject(title: '根');
      ws.createProject(title: '子', parentId: root.id);

      expect(() => ws.setProjectStatus(root.id, NodeStatus.done), throwsA(isA<RuleViolation>()));
      try {
        ws.setProjectStatus(root.id, NodeStatus.done);
      } on RuleViolation catch (violation) {
        expect(violation.message, contains('未处理'));
      }
    });

    test('归档与墓碑子项目不阻塞父项目完成（ADR-054 死锁修复）', () {
      final root = ws.createProject(title: '根');
      final archived = ws.createProject(title: '归档子', parentId: root.id);
      ws.setProjectArchived(archived.id, true);

      ws.setProjectStatus(root.id, NodeStatus.done);
      expect(ws.findProject(root.id)!.status, NodeStatus.done);
      expect(ws.findProject(root.id)!.completedAt, isNotNull);
    });

    test('反向传播：把子项目退回 pending，已完成的父项目自动退回（ADR-055）', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      ws.setProjectStatus(child.id, NodeStatus.done);
      ws.setProjectStatus(root.id, NodeStatus.done);
      expect(ws.findProject(root.id)!.status, NodeStatus.done);

      ws.setProjectStatus(child.id, NodeStatus.pending);

      expect(ws.findProject(child.id)!.status, NodeStatus.pending);
      expect(ws.findProject(root.id)!.status, NodeStatus.pending, reason: '硬约束必须恒真');
      expect(ws.findProject(root.id)!.completedAt, isNull);
    });

    test('ignore 是终态，可撤销', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      ws.setProjectStatus(child.id, NodeStatus.ignored);
      ws.setProjectStatus(root.id, NodeStatus.done);
      expect(ws.findProject(root.id)!.status, NodeStatus.done);
    });

    test('归档与取消归档双向级联（ADR-051）', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);

      ws.setProjectArchived(root.id, true);
      expect(ws.findProject(child.id)!.archived, isTrue);
      expect(ws.findProject(child.id)!.deleted, isFalse, reason: '归档不是删除');
      expect(ws.findProject(child.id)!.status, NodeStatus.pending, reason: '归档不改 status');

      ws.setProjectArchived(root.id, false);
      expect(ws.findProject(child.id)!.archived, isFalse);
    });

    test('移动：不能移入自身后代', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      expect(
        () => ws.updateProject(root.id, parentId: child.id),
        throwsA(isA<RuleViolation>()),
      );
    });
  });

  group('灵感：分配 / 合并 / 撤销 / 丢弃', () {
    test('合并灵感：项目正文与灵感状态一起变（跨集合，单文件里天然原子）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('这条灵感要并进去');

      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '手写后的实现段落',
      );

      final merged = ws.findInspiration(inspiration.id)!;
      expect(merged.status, InspirationStatus.merged);
      expect(merged.mergedInto, project.id);
      expect(merged.deleted, isFalse, reason: '合并不用 deleted 表达');
      expect(merged.isConsistent, isTrue, reason: 'merged 必须同时有 merged_into / merged_at');
      expect(ws.findProject(project.id)!.implementation, '手写后的实现段落');

      // 跨集合改动要么一起落盘、要么一起没有（这是单文件存储要换来的性质）
      final onDisk = storeFileOnDisk();
      expect(
        onDisk.documentOf(DocName.projects).projectItems.single.implementation,
        '手写后的实现段落',
      );
      expect(
        onDisk.documentOf(DocName.inspirations).inspirationItems.single.status,
        InspirationStatus.merged,
      );
    });

    test('撤销合并只恢复灵感，不回滚项目正文（ADR-057）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('原文');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '用户编辑后的正文',
      );

      ws.undoMerge(inspiration.id);

      final restored = ws.findInspiration(inspiration.id)!;
      expect(restored.status, InspirationStatus.pending);
      expect(restored.mergedInto, isNull);
      expect(restored.projectId, project.id, reason: '项目还在 → 保留归属');
      expect(ws.findProject(project.id)!.implementation, '用户编辑后的正文',
          reason: '正文不回滚');
    });

    test('目标项目被彻底删除后，撤销合并会解除归属（悬挂引用）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('原文');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );

      // 单机形态下没有"另一台设备整体替换文档"这回事，而 deleteProject 一定会把
      // merged 灵感一并解除归属（ADR-056），所以"灵感还是 merged、目标项目却已不在"
      // 只能由彻底删除（purge）直接抹掉项目来构造 —— 这正是 undoMerge 里
      // projectAlive 分支要兜住的情况，必须留用例守住。
      ws.purge(DocName.projects, <String>[project.id]);
      expect(ws.findProject(project.id), isNull, reason: '墓碑骨架不是 Project');

      ws.undoMerge(inspiration.id);

      final restored = ws.findInspiration(inspiration.id)!;
      expect(restored.status, InspirationStatus.pending);
      expect(restored.mergedInto, isNull);
      expect(restored.projectId, isNull, reason: '目标项目已不在 → 解除归属');
    });

    test('丢弃后进入归档区「已丢弃」，可恢复', () {
      final inspiration = ws.captureInspiration('待丢弃');
      ws.discardInspiration(inspiration.id);

      expect(ws.inspirationInbox, isEmpty);
      expect(ws.archiveZone.discardedInspirations.length, 1);

      ws.restoreInspiration(inspiration.id);
      expect(ws.inspirationInbox.length, 1);
    });

    test('已分配的 pending 灵感仍留在灵感列表（设计文档 4.12）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('已分配未合并');
      ws.assignInspiration(inspiration.id, project.id);

      expect(ws.inspirationInbox.map((i) => i.id), contains(inspiration.id));
      expect(ws.findInspiration(inspiration.id)!.projectId, project.id);
    });
  });

  group('删除项目的跨文档影响面（4.5 / ADR-056）', () {
    test('pending 灵感被删、merged 灵感回退为未分配，且一次落盘同时生效', () {
      final project = ws.createProject(title: '项目 A');
      final child = ws.createProject(title: '子项目', parentId: project.id);
      final assigned = ws.captureInspiration('分配给子项目', projectId: child.id);
      final mergedInspiration = ws.captureInspiration('将被合并');
      ws.mergeInspiration(
        inspirationId: mergedInspiration.id,
        projectId: child.id,
        newImplementation: '正文',
      );
      final unrelated = ws.captureInspiration('无关灵感');

      final plan = ws.deleteProject(project.id);

      expect(plan.projectIds.length, 2);
      expect(ws.findProject(project.id)!.deleted, isTrue);
      expect(ws.findProject(child.id)!.deleted, isTrue);
      expect(ws.findInspiration(assigned.id)!.deleted, isTrue);
      expect(ws.findInspiration(unrelated.id)!.deleted, isFalse);

      final reverted = ws.findInspiration(mergedInspiration.id)!;
      expect(reverted.status, InspirationStatus.pending, reason: '项目没了，内容要还回灵感列表');
      expect(reverted.projectId, isNull);
      expect(reverted.mergedInto, isNull);
      expect(reverted.deleted, isFalse);

      // 归档版这里断言的是"两份文档同时脏"（同步概念）；单机版改为直接核对磁盘：
      // 一次写入必须同时反映 projects 与 inspirations 的新状态。
      final onDisk = storeFileOnDisk();
      final projectOnDisk = onDisk
          .documentOf(DocName.projects)
          .projectItems
          .where((p) => p.id == project.id)
          .single;
      expect(projectOnDisk.deleted, isTrue);
      final revertedOnDisk = onDisk
          .documentOf(DocName.inspirations)
          .inspirationItems
          .where((i) => i.id == mergedInspiration.id)
          .single;
      expect(revertedOnDisk.status, InspirationStatus.pending);
      expect(revertedOnDisk.projectId, isNull);
    });
  });

  group('任务：结构约束 / 完成 / 移动', () {
    test('主线必须是标准任务，且父类型约束生效', () {
      final event = ws.createEvent(name: '事件 1');
      final standard = ws.createTask(eventId: event.id, title: '标准任务');
      final subtask = ws.createTask(
        eventId: event.id,
        title: '子任务',
        parentTaskId: standard.id,
        type: TaskType.subtask,
      );

      expect(subtask.parentId, standard.id);
      expect(
        () => ws.createTask(eventId: event.id, title: '非法', type: TaskType.parallel),
        throwsA(isA<RuleViolation>()),
        reason: '主线只能是标准任务',
      );
      expect(
        () => ws.createTask(eventId: event.id, title: '非法', parentTaskId: subtask.id, type: TaskType.subtask),
        throwsA(isA<RuleViolation>()),
        reason: '子任务是叶子',
      );
    });

    test('并列任务可以有自己的子任务（ADR-036/053）', () {
      final event = ws.createEvent(name: '事件 1');
      final standard = ws.createTask(eventId: event.id, title: '标准任务');
      final parallel = ws.createTask(
        eventId: event.id,
        title: '并列任务',
        parentTaskId: standard.id,
        type: TaskType.parallel,
      );
      final leaf = ws.createTask(
        eventId: event.id,
        title: '并列下的子任务',
        parentTaskId: parallel.id,
        type: TaskType.subtask,
      );
      expect(leaf.parentId, parallel.id);
      expect(ws.taskTree.depthOf(leaf.id), 3);
    });

    test('子任务未终态时父任务不可完成；完成后子任务退回会连带父任务退回', () {
      final event = ws.createEvent(name: '事件 1');
      final parent = ws.createTask(eventId: event.id, title: '父任务');
      final child = ws.createTask(
        eventId: event.id,
        title: '子任务',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );

      expect(() => ws.setTaskStatus(parent.id, NodeStatus.done), throwsA(isA<RuleViolation>()));
      ws.setTaskStatus(child.id, NodeStatus.done);
      ws.setTaskStatus(parent.id, NodeStatus.done);
      expect(ws.findTask(parent.id)!.status, NodeStatus.done);

      ws.setTaskStatus(child.id, NodeStatus.pending);
      expect(ws.findTask(parent.id)!.status, NodeStatus.pending);
    });

    test('跨事件移动任务时父引用归零', () {
      final eventA = ws.createEvent(name: '事件 A');
      final eventB = ws.createEvent(name: '事件 B');
      final parent = ws.createTask(eventId: eventA.id, title: '父');
      final child = ws.createTask(
        eventId: eventA.id,
        title: '子',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );

      ws.moveTask(child.id, newEventId: eventB.id, newParentTaskId: parent.id);

      final moved = ws.findTask(child.id)!;
      expect(moved.eventId, eventB.id);
      expect(moved.parentId, isNull, reason: '禁止跨事件父子');
    });

    test('删除任务级联子任务', () {
      final event = ws.createEvent(name: '事件 1');
      final parent = ws.createTask(eventId: event.id, title: '父');
      final child = ws.createTask(
        eventId: event.id,
        title: '子',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );

      final deleted = ws.deleteTask(parent.id);

      expect(deleted, <String>{parent.id, child.id});
      expect(ws.findTask(child.id)!.deleted, isTrue);
    });

    test('事件完成要求所有主线任务终态', () {
      final event = ws.createEvent(name: '事件 1');
      final first = ws.createTask(eventId: event.id, title: '任务 1');
      ws.createTask(eventId: event.id, title: '任务 2');

      expect(ws.checkEventCompletion(event.id).canComplete, isFalse);
      expect(() => ws.setEventStatus(event.id, NodeStatus.done), throwsA(isA<RuleViolation>()));

      ws.setTaskStatus(first.id, NodeStatus.done);
      // 让第二个任务也进入终态
      final second = ws.mainLineOf(event.id).firstWhere((t) => t.id != first.id);
      ws.setTaskStatus(second.id, NodeStatus.ignored);

      ws.setEventStatus(event.id, NodeStatus.done);
      expect(ws.findEvent(event.id)!.status, NodeStatus.done);
    });

    test('任务退回 pending 会连带把已完成的事件退回', () {
      final event = ws.createEvent(name: '事件 1');
      final task = ws.createTask(eventId: event.id, title: '任务');
      ws.setTaskStatus(task.id, NodeStatus.done);
      ws.setEventStatus(event.id, NodeStatus.done);

      ws.setTaskStatus(task.id, NodeStatus.pending);

      expect(ws.findEvent(event.id)!.status, NodeStatus.pending);
    });

    test('归档事件会级联整条任务线（跨集合）', () {
      final event = ws.createEvent(name: '事件 1');
      final task = ws.createTask(eventId: event.id, title: '任务');

      ws.setEventArchived(event.id, true);

      expect(ws.findEvent(event.id)!.archived, isTrue);
      expect(ws.findTask(task.id)!.archived, isTrue);
    });
  });

  group('归档区 / 搜索 / 到期 / 彻底删除', () {
    test('已归档只列归档根，回收站只列级联根', () {
      final root = ws.createProject(title: '根');
      ws.createProject(title: '子', parentId: root.id);
      ws.setProjectArchived(root.id, true);

      final other = ws.createProject(title: '要删的');
      ws.createProject(title: '它的子', parentId: other.id);
      ws.deleteProject(other.id);

      final zone = ws.archiveZone;
      expect(zone.archivedRoots.map((e) => e.id).toList(), <String>[root.id]);
      expect(zone.trashRoots.map((e) => e.id).toList(), <String>[other.id]);
    });

    test('搜索排除归档与已删除，灵感只搜 pending', () {
      final project = ws.createProject(title: '知识库', purpose: '让灵感有归宿');
      final archived = ws.createProject(title: '知识库-归档副本');
      ws.setProjectArchived(archived.id, true);
      final inspiration = ws.captureInspiration('知识库的一条灵感');
      ws.discardInspiration(inspiration.id);

      final hits = ws.search('知识库');
      final ids = hits.map((h) => h.entity.id).toSet();

      expect(ids, contains(project.id));
      expect(ids, isNot(contains(archived.id)));
      expect(ids, isNot(contains(inspiration.id)), reason: 'discarded 不参与搜索');
    });

    test('到期聚合按日期升序，只含未完成未归档', () {
      final event = ws.createEvent(name: '事件');
      final overdue = ws.createTask(eventId: event.id, title: '逾期', dueAt: '2026-01-01');
      final soon = ws.createTask(eventId: event.id, title: '本周', dueAt: '2026-09-25');
      final far = ws.createTask(eventId: event.id, title: '很久以后', dueAt: '2027-01-01');
      ws.setTaskStatus(far.id, NodeStatus.done);

      final due = ws.tasksDueOnOrBefore('2026-09-30');

      expect(due.map((t) => t.id).toList(), <String>[overdue.id, soon.id]);
    });

    test('彻底删除 = 墓碑骨架化，只保留 3 个 key（ADR-052）', () {
      final project = ws.createProject(title: '要彻底删掉');
      ws.deleteProject(project.id);
      final ids = ws.purgeIdsFor(DocName.projects, project.id);

      ws.purge(DocName.projects, ids);

      final entity = ws.documentOf(DocName.projects).items.firstWhere((e) => e.id == project.id);
      expect(entity, isA<Tombstone>());
      expect(entity.toJson().keys.toList(), <String>['id', 'deleted', 'purged_at']);
      expect(entity.toJson().containsKey('title'), isFalse);
    });
  });

  group('持久化（单文件：每次变更立刻原子落盘）', () {
    test('变更无需显式保存，磁盘上立刻就能看到', () {
      final project = ws.createProject(title: '立刻落盘');

      // 没有调用 persist() / snapshotNow()，主文件里就应该已经有这条记录
      final text = storeTextOnDisk();
      expect(text, contains(project.id));
      expect(text, contains('立刻落盘'));

      // 而且写下去的是一份完整可解析的文件，不是半截中间态
      final reloaded = Workspace.fromLoad(storage, storage.load());
      expect(reloaded.findProject(project.id)!.title, '立刻落盘');
    });

    test('第二次保存前，上一份数据已轮转进滚动备份', () {
      final first = ws.createProject(title: '第一版');
      expect(
        storage.paths.rollingBackup(1).existsSync(),
        isFalse,
        reason: '首次保存时磁盘上还没有旧文件可轮转',
      );

      final second = ws.createProject(title: '第二版');

      final backup1 = storage.paths.rollingBackup(1);
      expect(backup1.existsSync(), isTrue);
      final backedUp = StoreFile.parse(backup1.readAsStringSync(encoding: utf8), DecodeIssues());
      final backedUpIds =
          backedUp.documentOf(DocName.projects).projectItems.map((p) => p.id).toSet();
      expect(backedUpIds, contains(first.id));
      expect(backedUpIds, isNot(contains(second.id)), reason: 'backup.1 是最近一次保存之前的状态');
      expect(storeTextOnDisk(), contains(second.id));
    });

    test('snapshotNow 能强制落盘并轮转出备份（批量操作前的手动快照）', () {
      final project = ws.createProject(title: '项目 A');
      expect(storage.paths.rollingBackup(1).existsSync(), isFalse);

      ws.snapshotNow();

      // 注释里承诺"手动触发一次备份轮转"，那就必须有 backup.1 可回退
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue);
      expect(
        storeFileOnDisk().documentOf(DocName.projects).projectItems.single.id,
        project.id,
      );
    });

    test('persist 后重新加载，数据与视图偏好都在', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('灵感');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );
      ws.setExpanded(project.id, expanded: false);
      ws.persist();

      final reloaded = Workspace.fromLoad(storage, storage.load());

      expect(reloaded.findProject(project.id)!.implementation, '正文');
      expect(reloaded.findInspiration(inspiration.id)!.status, InspirationStatus.merged);
      expect(reloaded.findInspiration(inspiration.id)!.mergedInto, project.id);
      expect(reloaded.prefs.isExpanded(project.id), isFalse);
    });
  });

  group('完成规则工具', () {
    test('isTerminal 只认 done / ignored', () {
      expect(isTerminal(NodeStatus.done), isTrue);
      expect(isTerminal(NodeStatus.ignored), isTrue);
      expect(isTerminal(NodeStatus.pending), isFalse);
    });
  });
}
