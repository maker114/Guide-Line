import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/event.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/ui/common/urgency.dart';
import 'package:guideline/ui/more/all_tasks_page.dart';

/// 「全部任务」的分组逻辑。
///
/// 这些是**纯函数**，所以能直接单测，不必去点界面。分出来就是为了这个：
/// 下面第一条用例守的是一个真实出现过的错误 —— 已完成的任务被归进了
/// 「没有到期日」那一档，而它明明写着 `10月15日`。
void main() {
  Task task({
    required String id,
    required String title,
    String? dueAt,
    NodeStatus status = NodeStatus.pending,
    int order = 1000,
    String eventId = 'e1',
  }) =>
      Task(
        id: id,
        eventId: eventId,
        parentTaskId: null,
        taskType: TaskType.standard,
        title: title,
        dueAt: dueAt,
        status: status,
        archived: false,
        order: order,
        completedAt: null,
        createdAt: 0,
        updatedAt: 0,
        deleted: false,
      );

  group('按紧迫度分组', () {
    test('有日期的已完成任务不会混进「没有到期日」', () {
      final groups = groupByUrgency(<Task>[
        task(id: 'a', title: '做完了但有日期', dueAt: '2099-10-15', status: NodeStatus.done),
        task(id: 'b', title: '真没日期'),
      ]);

      final labels = groups.map((g) => g.label).toList();
      expect(labels, <String>['没有到期日', '已完成 / 已搁置']);

      final none = groups.firstWhere((g) => g.label == '没有到期日');
      expect(none.tasks.map((t) => t.title), <String>['真没日期'],
          reason: '这一档的标签承诺了"没有到期日"，就不能混进有日期的任务');

      final finished = groups.firstWhere((g) => g.label == '已完成 / 已搁置');
      expect(finished.tasks.map((t) => t.title), <String>['做完了但有日期']);
      expect(finished.tone, isNull, reason: '已结束那一档不参与色阶，走灰');
    });

    test('组序按紧迫程度：逾期 → 今天 → … → 没排期 → 已结束', () {
      final groups = groupByUrgency(<Task>[
        task(id: 'n', title: '没日期'),
        task(id: 'l', title: '很久以后', dueAt: '2099-01-01'),
        task(id: 'o', title: '逾期了', dueAt: '2000-01-01'),
        task(id: 'd', title: '做完了', dueAt: '2000-01-01', status: NodeStatus.done),
      ]);

      expect(
        groups.map((g) => g.label).toList(),
        <String>['已逾期', '7 天后', '没有到期日', '已完成 / 已搁置'],
      );
      expect(groups.first.tone, Urgency.overdue);
    });

    test('组内按到期日排，没排期的垫底', () {
      final groups = groupByUrgency(<Task>[
        task(id: 'x', title: '没日期'),
        task(id: 'y', title: '晚一点', dueAt: '2099-05-05'),
        task(id: 'z', title: '早一点', dueAt: '2099-05-01'),
      ]);

      final later = groups.firstWhere((g) => g.label == '7 天后');
      expect(later.tasks.map((t) => t.title), <String>['早一点', '晚一点']);
    });

    test('没有任务时不产生空分组', () {
      expect(groupByUrgency(<Task>[]), isEmpty);
    });
  });

  group('按事件分组', () {
    test('组序跟事件顺序走，组内按任务顺序', () {
      Event event(String id, String name, int order) => Event(
            id: id,
            name: name,
            status: NodeStatus.pending,
            archived: false,
            order: order,
            completedAt: null,
            createdAt: 0,
            updatedAt: 0,
            deleted: false,
          );

      final groups = groupByEvent(
        <Task>[
          task(id: 't2', title: '第二个', eventId: 'e2', order: 2000),
          task(id: 't1', title: '第一个', eventId: 'e1', order: 1000),
          task(id: 't3', title: '也是第一个', eventId: 'e1', order: 3000),
        ],
        <Event>[event('e2', '后面的事件', 2000), event('e1', '前面的事件', 1000)],
        (id) => id == 'e1' ? '前面的事件' : '后面的事件',
      );

      expect(groups.map((g) => g.label).toList(), <String>['前面的事件', '后面的事件']);
      expect(
        groups.first.tasks.map((t) => t.title).toList(),
        <String>['第一个', '也是第一个'],
        reason: '组内按 order 升序',
      );
    });
  });
}
