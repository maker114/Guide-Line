import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/core/tree/task_flow.dart';

/// 任务线的流图：**分叉 / 合流**。
///
/// 这是"并列任务与主线并列"这件事的底座，所以边界必须钉死：
/// 老数据要照旧成链、坏边要被忽略、有环要能活着退出来。
void main() {
  const eventId = 'e1';

  Task task(
    String id,
    int order, {
    List<String> nextIds = const <String>[],
    String? parentId,
    String event = eventId,
    bool deleted = false,
    TaskType type = TaskType.standard,
  }) =>
      Task(
        id: id,
        eventId: event,
        parentTaskId: parentId,
        nextIds: nextIds,
        taskType: type,
        title: id,
        dueAt: null,
        status: NodeStatus.pending,
        archived: false,
        order: order,
        completedAt: null,
        createdAt: 0,
        updatedAt: 0,
        deleted: deleted,
      );

  group('老数据兼容（没有显式后续边）', () {
    test('按 order 顺次成链，和改动前的"兄弟链"一致', () {
      final flow = TaskFlow.of(<Task>[task('c', 3000), task('a', 1000), task('b', 2000)],
          eventId: eventId);

      expect(flow.usesExplicitEdges, isFalse);
      expect(flow.hasCycle, isFalse);
      expect(flow.roots.map((t) => t.id), <String>['a']);
      expect(flow.sinks.map((t) => t.id), <String>['c']);
      expect(flow.successorsOf('a').map((t) => t.id), <String>['b']);
      expect(flow.successorsOf('c'), isEmpty);
      expect(flow.hasFork, isFalse);
      expect(flow.hasJoin, isFalse);
      expect(flow.layerCount, 3);
      expect(flow.layerOf('a'), 0);
      expect(flow.layerOf('c'), 2);
    });

    test('空事件 → 空流图', () {
      expect(TaskFlow.of(<Task>[], eventId: eventId).isEmpty, isTrue);
      expect(TaskFlow.of(<Task>[task('x', 1000, event: '别的')], eventId: eventId).isEmpty, isTrue);
    });

    test('子任务与并列任务（有归属父节点）不参与走向', () {
      final flow = TaskFlow.of(<Task>[
        task('main', 1000),
        task('sub', 1000, parentId: 'main', type: TaskType.subtask),
        task('par', 2000, parentId: 'main', type: TaskType.parallel),
      ], eventId: eventId);

      expect(flow.all.map((t) => t.id), <String>['main']);
      expect(flow.layerCount, 1);
    });
  });

  group('显式后续边', () {
    test('一个节点两条后续边 = 分叉；两条边指向同一节点 = 合流', () {
      final flow = TaskFlow.of(<Task>[
        task('start', 1000, nextIds: <String>['left', 'right']),
        task('left', 2000, nextIds: <String>['join']),
        task('right', 3000, nextIds: <String>['join']),
        task('join', 4000),
      ], eventId: eventId);

      expect(flow.usesExplicitEdges, isTrue);
      expect(flow.hasCycle, isFalse);
      expect(flow.roots.map((t) => t.id), <String>['start']);
      expect(flow.isFork('start'), isTrue);
      expect(flow.isJoin('join'), isTrue);
      expect(flow.hasFork, isTrue);
      expect(flow.hasJoin, isTrue);
      expect(flow.sinks.map((t) => t.id), <String>['join']);
    });

    test('分叉出去的两条支路在同一层，合流节点在下一层', () {
      final flow = TaskFlow.of(<Task>[
        task('start', 1000, nextIds: <String>['left', 'right']),
        task('left', 2000, nextIds: <String>['join']),
        task('right', 3000, nextIds: <String>['join']),
        task('join', 4000),
      ], eventId: eventId);

      expect(flow.layerOf('start'), 0);
      expect(flow.layerOf('left'), 1);
      expect(flow.layerOf('right'), 1, reason: '并联的两条支路应处于同一层');
      expect(flow.layerOf('join'), 2);
      expect(flow.layerCount, 3);
      expect(flow.layers[1].map((t) => t.id), <String>['left', 'right']);
    });

    test('指向不存在的任务、以及指向自己的边都被忽略', () {
      final flow = TaskFlow.of(<Task>[
        task('a', 1000, nextIds: <String>['不存在', 'a', 'b']),
        task('b', 2000),
      ], eventId: eventId);

      expect(flow.successorsOf('a').map((t) => t.id), <String>['b']);
      expect(flow.hasCycle, isFalse);
      expect(flow.roots.map((t) => t.id), <String>['a']);
    });

    test('孤立节点也算入口，不会从界面上消失', () {
      final flow = TaskFlow.of(<Task>[
        task('a', 1000, nextIds: <String>['b']),
        task('b', 2000),
        task('孤岛', 3000),
      ], eventId: eventId);

      expect(flow.roots.map((t) => t.id), <String>['a', '孤岛']);
      expect(flow.layerOf('孤岛'), 0);
    });
  });

  group('故障兜底', () {
    test('数据里有环 → 标记 hasCycle 并整体退回按 order 的链（不死循环）', () {
      final flow = TaskFlow.of(<Task>[
        task('a', 1000, nextIds: <String>['b']),
        task('b', 2000, nextIds: <String>['c']),
        task('c', 3000, nextIds: <String>['a']),
      ], eventId: eventId);

      expect(flow.hasCycle, isTrue);
      expect(flow.usesExplicitEdges, isFalse, reason: '有环时不该声称自己在用显式边');
      expect(flow.roots.map((t) => t.id), <String>['a']);
      expect(flow.sinks.map((t) => t.id), <String>['c']);
      expect(flow.layerCount, 3, reason: '退回成链之后是一条直线');
    });

    test('已删除的任务不参与', () {
      final flow = TaskFlow.of(<Task>[
        task('a', 1000, nextIds: <String>['b']),
        task('b', 2000, deleted: true),
      ], eventId: eventId);

      expect(flow.all.map((t) => t.id), <String>['a']);
      expect(flow.successorsOf('a'), isEmpty, reason: '指向已删除节点的边应被丢掉');
    });
  });

  group('接边前的自检', () {
    late TaskFlow flow;

    setUp(() {
      flow = TaskFlow.of(<Task>[
        task('a', 1000, nextIds: <String>['b']),
        task('b', 2000, nextIds: <String>['c']),
        task('c', 3000),
        task('other', 4000),
      ], eventId: eventId);
    });

    test('接到自己 → 会成环', () {
      expect(flow.wouldCreateCycle(fromId: 'a', toId: 'a'), isTrue);
    });

    test('接回自己的下游 → 会成环', () {
      expect(flow.wouldCreateCycle(fromId: 'c', toId: 'a'), isTrue);
      expect(flow.wouldCreateCycle(fromId: 'c', toId: 'b'), isTrue);
    });

    test('接到下游之后 → 不成环', () {
      expect(flow.wouldCreateCycle(fromId: 'a', toId: 'c'), isFalse);
      expect(flow.wouldCreateCycle(fromId: 'b', toId: 'other'), isFalse);
      expect(flow.wouldCreateCycle(fromId: 'other', toId: 'a'), isFalse);
    });
  });
}
