/// 任务列表的**分组与组内排序**（「全部任务」与「接下来的任务」共用）。
///
/// 抽成单独文件的原因：分组是**纯逻辑**（可单测），而两个页面要的观感必须一样 ——
/// 各写一份迟早出现"同一个紧迫度在两页里排序不同"。
library;

import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../common/labels.dart';
import '../common/urgency.dart';

/// 任务的显示方式。
///
/// 「不分组」已被「按完成度」取代（实机反馈）：平铺列表里已完成的任务混在
/// 未完成中间，扫一列看不出还有多少欠着。三个选项现在都是**分组**：
/// 完成度 / 事件 / 紧迫度。
enum TaskGrouping {
  completion('按完成度'),
  event('按事件'),
  urgency('按紧迫度');

  const TaskGrouping(this.label);

  final String label;
}

/// 一个分组：分组头 + 组内任务。
class TaskGroup {
  const TaskGroup({required this.label, required this.tone, required this.tasks});

  final String label;

  /// 配色档位；`null` 表示"已结束"那一档（走灰）。
  final Urgency? tone;

  final List<Task> tasks;
}

/// 完成度排序键：**未完成 → 已搁置 → 已完成**（实机反馈给的固定顺序）。
int completionRank(NodeStatus status) {
  switch (status) {
    case NodeStatus.pending:
      return 0;
    case NodeStatus.ignored:
      return 1;
    case NodeStatus.done:
      return 2;
  }
}

/// 到期日近的在前；没排期的垫底。
int byDueThenOrder(Task a, Task b) {
  final da = a.dueAt;
  final db = b.dueAt;
  if (da == null && db != null) return 1;
  if (da != null && db == null) return -1;
  if (da != null && db != null) {
    final byDate = da.compareTo(db);
    if (byDate != 0) return byDate;
  }
  return byOrderOfTask(a, b);
}

int byOrderOfTask(Task a, Task b) => compareByOrder(a.order, a.id, b.order, b.id);

/// 组内排序：**先按完成度，同一档再按到期日**（近的在前、没排期的垫底）。
///
/// 「按事件」分组也用这一条（实机反馈）：一个事件下面先看到还欠着的，
/// 已完成 / 已搁置的沉到组尾。
int byCompletionThenDue(Task a, Task b) {
  final byStatus = completionRank(a.status).compareTo(completionRank(b.status));
  if (byStatus != 0) return byStatus;
  return byDueThenOrder(a, b);
}

/// 按完成度分组：**未完成 → 已搁置 → 已完成**（实机反馈给的固定顺序）。
///
/// 取代了原来的「不分组」：平铺列表把三种状态混在一起，看不出还剩多少。
/// 组内仍按到期日排（近的在前、没排期的垫底）。
List<TaskGroup> groupByCompletion(List<Task> tasks) {
  const order = <NodeStatus>[NodeStatus.pending, NodeStatus.ignored, NodeStatus.done];
  final groups = <TaskGroup>[];
  for (final status in order) {
    final group = tasks.where((Task t) => t.status == status).toList(growable: false)
      ..sort(byDueThenOrder);
    if (group.isEmpty) continue;
    groups.add(TaskGroup(label: nodeStatusLabel(status), tone: null, tasks: group));
  }
  return groups;
}

/// 按紧迫度分组。
///
/// **纯粹的排序 + 分桶**，不依赖界面，所以可以直接单测 ——
/// 这里出过一个错：把已完成的任务也塞进 `none` 档，而那一档的标签是
/// 「没有到期日」，于是一个写着 `10月15日` 的已完成任务被归到了"没有到期日"下面。
List<TaskGroup> groupByUrgency(List<Task> tasks) {
  final groups = <TaskGroup>[];

  final finished = tasks
      .where((Task t) => t.status != NodeStatus.pending)
      .toList(growable: false)
    ..sort(byDueThenOrder);

  final byUrgency = <Urgency, List<Task>>{};
  for (final task in tasks.where((Task t) => t.status == NodeStatus.pending)) {
    byUrgency.putIfAbsent(urgencyOf(task.dueAt), () => <Task>[]).add(task);
  }
  for (final urgency in Urgency.values) {
    final group = byUrgency[urgency];
    if (group == null || group.isEmpty) continue;
    group.sort(byDueThenOrder);
    groups.add(TaskGroup(label: urgencyLabel(urgency), tone: urgency, tasks: group));
  }

  if (finished.isNotEmpty) {
    groups.add(TaskGroup(label: '已完成 / 已搁置', tone: null, tasks: finished));
  }
  return groups;
}

/// 按所属事件分组（组序 = 事件顺序）。
///
/// 组内**先按完成度（未完成 → 已搁置 → 已完成），同一档再按到期日**
/// （实机反馈）：一个事件下面先看到还欠着的，做完的沉到组尾。
List<TaskGroup> groupByEvent(
  List<Task> tasks,
  Iterable<Event> events,
  String Function(String eventId) nameOf,
) {
  int eventOrder(String id) {
    for (final Event event in events) {
      if (event.id == id) return event.order;
    }
    return 1 << 30;
  }

  final byEvent = <String, List<Task>>{};
  for (final task in tasks) {
    byEvent.putIfAbsent(task.eventId, () => <Task>[]).add(task);
  }
  final ordered = byEvent.keys.toList()
    ..sort((a, b) => eventOrder(a).compareTo(eventOrder(b)));

  return <TaskGroup>[
    for (final eventId in ordered)
      TaskGroup(
        label: nameOf(eventId),
        tone: null,
        tasks: byEvent[eventId]!..sort(byCompletionThenDue),
      ),
  ];
}

// ---------------------------------------------------------------- 摊平给列表用

/// 分组标题行：左边一个色点 + 标题，右边「N 条」。
class TaskGroupHeader extends StatelessWidget {
  const TaskGroupHeader({super.key, required this.title, required this.count, this.color});

  final String title;
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dot = color;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: <Widget>[
          if (dot != null) ...<Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: dot ?? theme.colorScheme.primary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text('$count 条', style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// 扁平列表里的一行：要么是分组头，要么是一条任务。
class TaskRow {
  const TaskRow.header(this.header, this.count, [this.color]) : task = null;

  const TaskRow.task(Task this.task)
      : header = null,
        count = 0,
        color = null;

  final String? header;
  final int count;
  final Color? color;
  final Task? task;
}

/// 把分组摊成「分组头 + 任务」的一维列表，交给 `ListView.builder` 增量构建。
///
/// [toneColor] 负责把配色档位翻成颜色（`null` 档 = 已结束，走灰）。
List<TaskRow> flattenTaskGroups(
  List<TaskGroup> groups,
  Color Function(Urgency? tone) toneColor,
) {
  final rows = <TaskRow>[];
  for (final group in groups) {
    rows.add(TaskRow.header(group.label, group.tasks.length, toneColor(group.tone)));
    rows.addAll(group.tasks.map(TaskRow.task));
  }
  return rows;
}
