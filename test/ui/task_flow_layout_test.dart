import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/core/tree/task_flow.dart';
import 'package:guideline/ui/events/task_flow_layout.dart';

/// 分叉 / 合流的**渲染排布**。
///
/// 这是整件事最容易排错的地方（区域划分、谁属于哪条支路、合流点算谁的），
/// 所以抽成纯函数、逐条钉住。最关键的一条是**每个节点只出现一次**：
/// 少渲染一个就是"任务凭空消失"，多渲染一个就是"同一个任务出现两遍"。
void main() {
  const eventId = 'e1';

  Task task(String id, int order, {List<String> nextIds = const <String>[]}) => Task(
        id: id,
        eventId: eventId,
        parentTaskId: null,
        nextIds: nextIds,
        taskType: TaskType.standard,
        title: id,
        dueAt: null,
        status: NodeStatus.pending,
        archived: false,
        order: order,
        completedAt: null,
        createdAt: 0,
        updatedAt: 0,
        deleted: false,
      );

  TaskFlow flowOf(List<Task> tasks) => TaskFlow.of(tasks, eventId: eventId);

  List<String> idsOf(List<FlowRow> rows) =>
      rows.where((r) => !r.isBranchHeader).map((r) => r.task!.id).toList();

  group('老数据（一条链）', () {
    test('顺序平铺，全是 depth 0，没有支路标题', () {
      final rows = layoutTaskFlow(flowOf(<Task>[
        task('a', 1000, nextIds: <String>['b']),
        task('b', 2000, nextIds: <String>['c']),
        task('c', 3000),
      ]));

      expect(idsOf(rows), <String>['a', 'b', 'c']);
      expect(rows.every((r) => r.depth == 0), isTrue);
      expect(rows.any((r) => r.isBranchHeader), isFalse);
      expect(rows.every((r) => r.badge == null), isTrue);
    });

    test('空流图 → 空排布', () {
      expect(layoutTaskFlow(flowOf(<Task>[])), isEmpty);
    });
  });

  group('分叉 + 合流', () {
    late List<FlowRow> rows;

    setUp(() {
      rows = layoutTaskFlow(flowOf(<Task>[
        task('start', 1000, nextIds: <String>['left', 'right']),
        task('left', 2000, nextIds: <String>['left2']),
        task('left2', 3000, nextIds: <String>['join']),
        task('right', 4000, nextIds: <String>['join']),
        task('join', 5000),
      ]));
    });

    test('分叉点带徽标，两条支路各有一个小标题', () {
      final startRow = rows.firstWhere((r) => r.task?.id == 'start');
      expect(startRow.badge, '分出 2 条支路');
      expect(startRow.depth, 0);

      final headers = rows.where((r) => r.isBranchHeader).toList();
      expect(headers.map((h) => h.branchIndex), <int>[0, 1]);
      expect(headers.every((h) => h.branchCount == 2), isTrue);
      expect(headers.every((h) => h.depth == 1), isTrue);
    });

    test('每条支路的内容各自连成一段，整条支路缩进一层', () {
      final leftIndex = rows.indexWhere((r) => r.task?.id == 'left');
      final left2Index = rows.indexWhere((r) => r.task?.id == 'left2');
      final rightIndex = rows.indexWhere((r) => r.task?.id == 'right');

      expect(left2Index, leftIndex + 1, reason: '支路内部照走，left → left2 相邻');
      expect(rows[leftIndex].depth, 1);
      expect(rows[left2Index].depth, 1);
      expect(rows[leftIndex].branchIndex, 0);
      expect(rows[rightIndex].depth, 1);
      expect(rows[rightIndex].branchIndex, 1);
    });

    test('合流点回到主线层，并带「汇合」徽标', () {
      final joinRow = rows.firstWhere((r) => r.task?.id == 'join');
      expect(joinRow.depth, 0);
      expect(joinRow.branchIndex, isNull);
      expect(joinRow.badge, '2 条支路在此汇合');
      expect(rows.last.task?.id, 'join', reason: '合流点在两条支路之后');
    });

    test('每个节点只出现一次，一个都不少', () {
      final ids = idsOf(rows);
      expect(ids.toSet().length, ids.length, reason: '不能有重复');
      expect(ids.toSet(), <String>{'start', 'left', 'left2', 'right', 'join'});
    });
  });

  group('边界形态', () {
    test('只分叉不合流：两条支路各自走到头', () {
      final rows = layoutTaskFlow(flowOf(<Task>[
        task('start', 1000, nextIds: <String>['a', 'b']),
        task('a', 2000, nextIds: <String>['a2']),
        task('a2', 3000),
        task('b', 4000),
      ]));

      expect(idsOf(rows).toSet(), <String>{'start', 'a', 'a2', 'b'});
      expect(rows.any((r) => r.badge?.contains('汇合') ?? false), isFalse);
      expect(rows.where((r) => r.isBranchHeader).length, 2);
    });

    test('合流点之后还有后续任务，继续按主线渲染', () {
      final rows = layoutTaskFlow(flowOf(<Task>[
        task('start', 1000, nextIds: <String>['a', 'b']),
        task('a', 2000, nextIds: <String>['join']),
        task('b', 3000, nextIds: <String>['join']),
        task('join', 4000, nextIds: <String>['after']),
        task('after', 5000),
      ]));

      expect(rows.last.task?.id, 'after');
      expect(rows.firstWhere((r) => r.task?.id == 'after').depth, 0);
    });

    test('孤立节点按入口渲染出来（不会从界面上消失）', () {
      final rows = layoutTaskFlow(flowOf(<Task>[
        task('a', 1000, nextIds: <String>['b']),
        task('b', 2000),
        task('孤岛', 3000),
      ]));

      expect(idsOf(rows).toSet(), <String>{'a', 'b', '孤岛'});
      final island = rows.firstWhere((r) => r.task?.id == '孤岛');
      expect(island.depth, 0);
      // 注：`TaskFlow` 已保证"每个节点都能从某个入口走到"（有向无环图的性质），
      // 所以排布里那条「未接入主线」的兜底实际不会触发 —— 它是防御性的，
      // 将来若给 TaskFlow 加了过滤、可能造出孤立节点时才会用上。
      expect(island.badge, isNull);
    });

    test('三条支路也能排出来', () {
      final rows = layoutTaskFlow(flowOf(<Task>[
        task('start', 1000, nextIds: <String>['a', 'b', 'c']),
        task('a', 2000, nextIds: <String>['join']),
        task('b', 3000, nextIds: <String>['join']),
        task('c', 4000, nextIds: <String>['join']),
        task('join', 5000),
      ]));

      expect(rows.firstWhere((r) => r.task?.id == 'start').badge, '分出 3 条支路');
      expect(rows.where((r) => r.isBranchHeader).map((h) => h.branchIndex), <int>[0, 1, 2]);
      expect(idsOf(rows).toSet().length, 5);
    });
  });
}
