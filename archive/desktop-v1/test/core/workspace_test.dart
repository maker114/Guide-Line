import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/rules/completion.dart';
import 'package:guideline/core/store/local_paths.dart';
import 'package:guideline/core/store/local_store.dart';
import 'package:guideline/features/workspace.dart';

void main() {
  late Directory dir;
  late LocalStore store;
  late Workspace ws;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_ws_');
    store = LocalStore(LocalPaths(dir));
    ws = Workspace.fromLoad(store, store.load());
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

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
    test('合并是跨文档操作，会记录待完成事务', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('这条灵感要并进去');
      ws.persist();
      ws.setPendingTx(null);

      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '手写后的实现段落',
      );

      final merged = ws.findInspiration(inspiration.id)!;
      expect(merged.status, InspirationStatus.merged);
      expect(merged.mergedInto, project.id);
      expect(merged.deleted, isFalse, reason: '合并不用 deleted 表达');
      expect(ws.findProject(project.id)!.implementation, '手写后的实现段落');

      final tx = ws.pendingTx;
      expect(tx, isNotNull);
      expect(tx!.docs.map((d) => d.name).toSet(),
          <DocName>{DocName.projects, DocName.inspirations});
      expect(tx.docs.every((d) => d.baseVersion == 0), isTrue, reason: 'base 取本地当前版本');
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

    test('目标项目在远端被删除后，撤销合并会解除归属（悬挂引用）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('原文');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );
      ws.persist();

      // 模拟「另一台设备删掉了该项目、projects 文档被整体拉取回来」：
      // 本地灵感仍是 merged，但它指向的项目已不在 → 悬挂引用
      final projectsDoc = ws.documentOf(DocName.projects);
      ws.applyRemoteDocument(
        projectsDoc.copyWith(
          version: 5,
          items: <Entity>[
            for (final p in projectsDoc.projectItems)
              if (p.id == project.id) p.copyWith(deleted: true) else p,
          ],
        ),
      );

      ws.undoMerge(inspiration.id);

      final restored = ws.findInspiration(inspiration.id)!;
      expect(restored.status, InspirationStatus.pending);
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
    test('pending 灵感被删、merged 灵感回退为未分配，且两份文档同时脏', () {
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
      ws.persist();

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

      expect(ws.dirtyDocs,
          containsAll(<DocName>[DocName.projects, DocName.inspirations]));
    });

    test('没有任何灵感受影响时，不把灵感文档标记为脏', () {
      final project = ws.createProject(title: '项目 A');
      ws.persist();
      ws.clearDirty(ws.dirtyDocs);

      ws.deleteProject(project.id);

      expect(ws.dirtyDocs, <DocName>{DocName.projects});
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

    test('归档事件会级联整条任务线，且跨文档记录事务', () {
      final event = ws.createEvent(name: '事件 1');
      final task = ws.createTask(eventId: event.id, title: '任务');
      ws.persist();
      ws.setPendingTx(null);

      ws.setEventArchived(event.id, true);

      expect(ws.findEvent(event.id)!.archived, isTrue);
      expect(ws.findTask(task.id)!.archived, isTrue);
      expect(ws.pendingTx, isNotNull);
      expect(ws.pendingTx!.docs.map((d) => d.name).toSet(),
          <DocName>{DocName.events, DocName.tasks});
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

  group('持久化', () {
    test('persist 后重新加载，数据与事务都在', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('灵感');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );
      ws.setCollapsed(project.id, true);
      ws.persist();

      final reloaded = Workspace.fromLoad(store, store.load());

      expect(reloaded.findProject(project.id)!.implementation, '正文');
      expect(reloaded.findInspiration(inspiration.id)!.status, InspirationStatus.merged);
      expect(reloaded.prefs.isCollapsed(project.id), isTrue);
      expect(reloaded.pendingTx, isNotNull, reason: '未提交的事务必须在重启后仍在');
      expect(reloaded.pendingTx!.docs.length, 2);
    });

    test('两次互不相关的单文档改动不会绑成一笔事务', () {
      ws.createProject(title: '项目 A');
      ws.persist();
      ws.setPendingTx(null);

      final inspiration = ws.captureInspiration('只有灵感文档被改');
      expect(inspiration.id, isNotEmpty);

      expect(ws.pendingTx, isNull, reason: '单文档改动不需要事务');
    });

    test('markSynced 写回服务端版本并清除 dirty', () {
      ws.createProject(title: '项目 A');
      expect(ws.dirtyDocs, contains(DocName.projects));

      ws.markSynced(DocName.projects, 7);

      expect(ws.versionOf(DocName.projects), 7);
      expect(ws.dirtyDocs, isNot(contains(DocName.projects)));
    });

    test('applyRemoteDocument 整体替换并作废相关事务', () {
      final project = ws.createProject(title: '本地项目');
      final inspiration = ws.captureInspiration('灵感');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '本地正文',
      );
      expect(ws.pendingTx, isNotNull);

      final remote = store.load().documents[DocName.projects]!;
      ws.applyRemoteDocument(remote.copyWith(version: 9));

      expect(ws.versionOf(DocName.projects), 9);
      expect(ws.pendingTx, isNull, reason: '文档被远端替换，旧事务作废');
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
