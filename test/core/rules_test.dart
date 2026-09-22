import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/ids.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/event.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/core/rules/archive_zone.dart';
import 'package:guideline/core/rules/cascade.dart';
import 'package:guideline/core/rules/completion.dart';
import 'package:guideline/core/security/recovery_code.dart';
import 'package:guideline/core/tree/tree_index.dart';

Project project(
  String id, {
  String? parent,
  NodeStatus status = NodeStatus.pending,
  bool archived = false,
  bool deleted = false,
  int order = 1000,
}) {
  return Project(
    id: id,
    title: '项目 $id',
    purpose: '',
    implementation: '',
    date: null,
    status: status,
    archived: archived,
    parentProjectId: parent,
    order: order,
    completedAt: status == NodeStatus.done ? 1700000000000 : null,
    createdAt: 1700000000000,
    updatedAt: 1700000000000,
    deleted: deleted,
  );
}

Task task(
  String id, {
  String eventId = 'e1',
  String? parent,
  TaskType type = TaskType.standard,
  NodeStatus status = NodeStatus.pending,
  bool archived = false,
  bool deleted = false,
  int order = 1000,
}) {
  return Task(
    id: id,
    eventId: eventId,
    parentTaskId: parent,
    taskType: type,
    title: '任务 $id',
    dueAt: null,
    status: status,
    archived: archived,
    order: order,
    completedAt: status == NodeStatus.done ? 1700000000000 : null,
    createdAt: 1700000000000,
    updatedAt: 1700000000000,
    deleted: deleted,
  );
}

Inspiration inspiration(
  String id, {
  String? projectId,
  InspirationStatus status = InspirationStatus.pending,
  String? mergedInto,
  bool deleted = false,
}) {
  return Inspiration(
    id: id,
    text: '灵感 $id',
    projectId: projectId,
    status: status,
    mergedInto: mergedInto,
    mergedAt: status == InspirationStatus.merged ? 1700000000000 : null,
    createdAt: 1700000000000,
    updatedAt: 1700000000000,
    deleted: deleted,
  );
}

Event event(String id, {bool archived = false, bool deleted = false, int order = 1000}) {
  return Event(
    id: id,
    name: '事件 $id',
    status: NodeStatus.pending,
    archived: archived,
    order: order,
    completedAt: null,
    createdAt: 1700000000000,
    updatedAt: 1700000000000,
    deleted: deleted,
  );
}

void main() {
  group('树索引', () {
    final index = TreeIndex(<EntityNode>[
      project('root'),
      project('child', parent: 'root'),
      project('grand', parent: 'child'),
      project('other'),
    ]);

    test('层级从根算起为 1', () {
      expect(index.depthOf('root'), 1);
      expect(index.depthOf('child'), 2);
      expect(index.depthOf('grand'), 3);
    });

    test('子树高度与深度上限', () {
      expect(index.subtreeHeight('grand'), 1);
      expect(index.subtreeHeight('root'), 3);
      expect(index.fitsDepthLimit('other', 'grand', 3), isFalse, reason: '3+1 会超 3 层');
      expect(index.fitsDepthLimit('other', 'child', 3), isTrue);
    });

    test('环路检测：不能移入自身或后代', () {
      expect(index.wouldCreateCycle('root', 'grand'), isTrue);
      expect(index.wouldCreateCycle('root', 'root'), isTrue);
      expect(index.wouldCreateCycle('other', 'grand'), isFalse);
      final check = checkMove(
        index: index,
        nodeId: 'root',
        newParentId: 'grand',
        maxDepth: 3,
        crossEvent: false,
      );
      expect(check.allowed, isFalse);
    });

    test('子节点按 order 升序，order 相同按 id', () {
      final ordered = TreeIndex(<EntityNode>[
        project('b', order: 2000),
        project('a', order: 1000),
        project('c', order: 1000),
      ]).roots;
      expect(ordered.map((n) => n.id).toList(), <String>['a', 'c', 'b']);
    });

    test('父节点不在批内时按根处理，节点不会消失', () {
      final orphanIndex = TreeIndex(<EntityNode>[project('child', parent: 'missing')]);
      expect(orphanIndex.roots.map((n) => n.id).toList(), <String>['child']);
    });
  });

  group('完成规则（4.6 / ADR-054 / ADR-055）', () {
    test('所有参与判定的直接子节点终态才可完成', () {
      final index = TreeIndex(<EntityNode>[
        project('p'),
        project('c1', parent: 'p', status: NodeStatus.done),
        project('c2', parent: 'p', status: NodeStatus.ignored),
      ]);
      expect(checkCompletion(index, 'p').canComplete, isTrue);
      expect(checkCompletion(index, 'c1').canComplete, isTrue, reason: '无子节点时恒成立');
    });

    test('墓碑与归档子节点不参与判定（既不阻塞也不满足）', () {
      final index = TreeIndex(<EntityNode>[
        project('p'),
        project('live', parent: 'p', status: NodeStatus.done),
        project('tomb', parent: 'p', status: NodeStatus.pending, deleted: true),
        project('arch', parent: 'p', status: NodeStatus.pending, archived: true),
      ]);
      final check = checkCompletion(index, 'p');
      expect(check.judgedChildCount, 1);
      expect(check.canComplete, isTrue, reason: '归档的 pending 子项目不应永久阻塞父项目');
    });

    test('未处理子节点会给出可读原因', () {
      final index = TreeIndex(<EntityNode>[
        project('p'),
        project('c1', parent: 'p'),
        project('c2', parent: 'p', status: NodeStatus.done),
      ]);
      final check = checkCompletion(index, 'p');
      expect(check.canComplete, isFalse);
      expect(check.unfinishedCount, 1);
      expect(check.reason, contains('1'));
    });

    test('反向传播：已完成的祖先必须退回 pending', () {
      final index = TreeIndex(<EntityNode>[
        project('root', status: NodeStatus.done),
        project('mid', parent: 'root', status: NodeStatus.done),
        project('leaf', parent: 'mid', status: NodeStatus.pending),
      ]);
      expect(ancestorsToRevert(index, 'leaf'), <String>['mid', 'root']);
      expect(parentsToRevertAfterInsert(index, 'leaf'), <String>['mid', 'root']);
      expect(parentsToRevertAfterInsert(index, 'mid'), <String>['root']);
    });

    test('终态子节点插入不会引发退回', () {
      final index = TreeIndex(<EntityNode>[
        project('root', status: NodeStatus.done),
        task('t1', parent: 'root', status: NodeStatus.ignored),
      ]);
      expect(parentsToRevertAfterInsert(index, 't1'), isEmpty);
      expect(isTerminal(NodeStatus.ignored), isTrue);
      expect(isTerminal(NodeStatus.pending), isFalse);
    });
  });

  group('级联（4.5 / 4.7 / ADR-051 / ADR-056）', () {
    final projectIndex = TreeIndex(<EntityNode>[
      project('a'),
      project('a1', parent: 'a'),
      project('a1x', parent: 'a1'),
      project('b'),
    ]);

    test('级联删除沿树向下收集全部后代', () {
      expect(cascadeDeleteIds(projectIndex, 'a'), <String>{'a', 'a1', 'a1x'});
      expect(cascadeDeleteIds(projectIndex, 'a1'), <String>{'a1', 'a1x'});
    });

    test('归档与取消归档都级联（双向）', () {
      expect(cascadeArchiveIds(projectIndex, 'a', true), <String>{'a', 'a1', 'a1x'});
      final allArchived = TreeIndex(<EntityNode>[
        project('a', archived: true),
        project('a1', parent: 'a', archived: true),
        project('a1x', parent: 'a1', archived: true),
      ]);
      expect(cascadeArchiveIds(allArchived, 'a', false), <String>{'a', 'a1', 'a1x'});
    });

    test('项目删除：pending 灵感删除、merged 灵感回退为未分配', () {
      final plan = planProjectDeletion(
        projectIndex,
        <Inspiration>[
          inspiration('i1', projectId: 'a'),
          inspiration('i2', projectId: 'a1'),
          inspiration('i3', projectId: 'b'),
          inspiration('i4', status: InspirationStatus.merged, projectId: 'a', mergedInto: 'a'),
          inspiration('i5', status: InspirationStatus.discarded),
        ],
        'a',
      );
      expect(plan.projectIds, <String>{'a', 'a1', 'a1x'});
      expect(plan.inspirationIdsToDelete, <String>{'i1', 'i2'});
      expect(plan.inspirationIdsToUnassign, <String>{'i4'});
      expect(plan.affectedInspirationCount, 3);
    });

    test('事件删除收集整条任务线', () {
      final tasks = <Task>[
        task('t1', eventId: 'e1'),
        task('t2', eventId: 'e1', parent: 't1', type: TaskType.subtask),
        task('t3', eventId: 'e2'),
      ];
      expect(eventDeletionTaskIds(tasks, 'e1'), <String>{'t1', 't2'});
    });
  });

  group('归档区（4.10 / ADR-052）', () {
    final projects = <Project>[
      project('p1', status: NodeStatus.done),
      project('p2', archived: true),
      project('p2a', parent: 'p2', archived: true),
      project('gone', deleted: true),
      project('goneChild', parent: 'gone', deleted: true),
    ];
    final events = <Event>[event('e1')];
    final tasks = <Task>[task('t1')];
    final inspirations = <Inspiration>[
      inspiration('pendingFree'),
      inspiration('pendingInArchived', projectId: 'p2'),
      inspiration('merged', status: InspirationStatus.merged, projectId: 'p1', mergedInto: 'p1'),
      inspiration('discarded', status: InspirationStatus.discarded),
      inspiration('deletedInspiration', deleted: true),
    ];

    final zone = deriveArchiveZone(
      projects: projects,
      events: events,
      tasks: tasks,
      inspirations: inspirations,
    );

    test('已归档只列归档根，不列被级联归档的后代', () {
      expect(zone.archivedRoots.map((e) => (e as Project).id).toList(), <String>['p2']);
    });

    test('回收站只列级联根', () {
      expect(zone.trashRoots.map((e) => (e as Project).id).toList(), <String>['gone']);
    });

    test('已合并 / 已丢弃分区各自收拢灵感', () {
      expect((zone.mergedInspirations.first as Inspiration).id, 'merged');
      expect((zone.discardedInspirations.first as Inspiration).id, 'discarded');
    });

    test('归档项目下的灵感一并隐藏（Q53）', () {
      expect((zone.hiddenInspirations.first as Inspiration).id, 'pendingInArchived');
      expect(zone.hiddenInspirations.length, 1);
    });

    test('merged 灵感不因 deleted 过滤而出现在回收站', () {
      final trashIds = zone.trashRoots.map((e) => e.id).toSet();
      expect(trashIds.contains('merged'), isFalse);
    });
  });

  group('ID 与恢复码', () {
    test('uuid v4 形态正确且互不相同', () {
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final a = Ids.uuidV4();
      final b = Ids.uuidV4();
      expect(pattern.hasMatch(a), isTrue);
      expect(pattern.hasMatch(b), isTrue);
      expect(a == b, isFalse);
    });

    test('恢复码 24 位、字母表内、归一化与分组展示', () {
      final code = RecoveryCode.generate();
      expect(code.length, 24);
      for (final unit in code.split('')) {
        expect(RecoveryCode.alphabet.contains(unit), isTrue);
      }
      expect(RecoveryCode.isValid(code), isTrue);
      expect(RecoveryCode.normalize(' abcd-efgh '), 'ABCDEFGH');
      expect(RecoveryCode.formatForDisplay('ABCDEFGH'), 'ABCD-EFGH');
    });

    test('今天日期为 YYYY-MM-DD', () {
      expect(Ids.todayDate(DateTime(2026, 9, 22)), '2026-09-22');
    });
  });
}
