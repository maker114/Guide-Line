import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../common/empty_state.dart';
import '../common/labels.dart';
import '../common/status_selector.dart';
import '../common/task_tile.dart';
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
        tasks: byEvent[eventId]!..sort(byOrderOfTask),
      ),
  ];
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

/// 全部任务：**跨事件的任务总表**。
///
/// 事件层级在手机上层层点进去太慢，这里给一个"平铺"的入口：
/// 可以按状态筛，也可以按完成度 / 事件 / 紧迫度分组。
///
/// 注：任务在数据上挂在**事件**下、不属于项目，所以分组维度是事件与紧迫度，
/// 没有"按项目"这一项。
class AllTasksPage extends StatefulWidget {
  const AllTasksPage({super.key, required this.app});

  final AppController app;

  @override
  State<AllTasksPage> createState() => _AllTasksPageState();
}

class _AllTasksPageState extends State<AllTasksPage> {
  NodeStatus? _filter;
  TaskGrouping _grouping = TaskGrouping.completion;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final ws = widget.app.ws;
        final all = ws.liveTasks.where((t) => !t.archived).toList(growable: false);
        final tasks = _filter == null
            ? List<Task>.from(all)
            : all.where((t) => t.status == _filter).toList(growable: true);
        final rows = _buildRows(tasks);

        return Scaffold(
          appBar: AppBar(title: const Text('全部任务')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      FilterChip(
                        label: Text('全部 ${all.length}'),
                        selected: _filter == null,
                        onSelected: (_) => setState(() => _filter = null),
                      ),
                      for (final status in NodeStatus.values) ...<Widget>[
                        const SizedBox(width: 8),
                        FilterChip(
                          label: Text(
                            '${nodeStatusLabel(status)} '
                            '${all.where((t) => t.status == status).length}',
                          ),
                          selected: _filter == status,
                          onSelected: (_) => setState(() => _filter = status),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                // 分组调节栏走全应用统一的胶囊选择器（与「到期」的档位栏、
                // 项目详情的「状态」同一套观感），不再是 Material 的分段控件
                child: StatusPillSelector<TaskGrouping>(
                  values: TaskGrouping.values,
                  selected: _grouping,
                  labelOf: (value) => value.label,
                  onSelected: (value) => setState(() => _grouping = value),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(
                        icon: Icons.checklist_outlined,
                        title: '没有符合条件的任务',
                        hint: '换一个筛选条件，或先去「事件」页新建任务',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final header = row.header;
                          if (header != null) {
                            return _GroupHeader(
                              title: header,
                              count: row.count,
                              color: row.color,
                            );
                          }
                          return Column(
                            children: <Widget>[
                              TaskTile(app: widget.app, task: row.task!),
                              const Divider(height: 1, indent: 16, endIndent: 16),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 把任务摊成「分组头 + 任务」的扁平列表，交给 `ListView.builder` 增量构建。
  ///
  /// 分组本身在文件顶部的纯函数里（可单测），这里只负责摊平。
  List<_Row> _buildRows(List<Task> tasks) {
    final rows = <_Row>[];
    final app = widget.app;

    switch (_grouping) {
      case TaskGrouping.completion:
        for (final group in groupByCompletion(tasks)) {
          rows.add(_Row.header(group.label, group.tasks.length));
          rows.addAll(group.tasks.map(_Row.task));
        }

      case TaskGrouping.event:
        final groups = groupByEvent(
          tasks,
          app.ws.liveEvents,
          (eventId) => app.ws.findEvent(eventId)?.name ?? '（事件已删除）',
        );
        for (final group in groups) {
          rows.add(_Row.header(group.label, group.tasks.length));
          rows.addAll(group.tasks.map(_Row.task));
        }

      case TaskGrouping.urgency:
        final colors = UrgencyColors.ofContext(context);
        for (final group in groupByUrgency(tasks)) {
          rows.add(
            _Row.header(
              group.label,
              group.tasks.length,
              colors.of(group.tone ?? Urgency.none),
            ),
          );
          rows.addAll(group.tasks.map(_Row.task));
        }
    }

    return rows;
  }
}

/// 扁平列表里的一行：要么是分组头，要么是一条任务。
class _Row {
  const _Row.header(this.header, this.count, [this.color]) : task = null;

  const _Row.task(Task this.task)
      : header = null,
        count = 0,
        color = null;

  final String? header;
  final int count;
  final Color? color;
  final Task? task;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.count, this.color});

  final String title;
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dot = color;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
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
