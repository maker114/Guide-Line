import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/task.dart';
import '../common/empty_state.dart';
import '../common/status_selector.dart';
import '../common/task_tile.dart';
import '../common/urgency.dart';
import 'task_grouping.dart';

/// 全部任务：**跨事件的任务总表**。
///
/// 事件层级在手机上层层点进去太慢，这里给一个"平铺"的入口：
/// 可以按完成度 / 事件 / 紧迫度分组（分组与排序在 `task_grouping.dart`）。
class AllTasksPage extends StatefulWidget {
  const AllTasksPage({super.key, required this.app});

  final AppController app;

  @override
  State<AllTasksPage> createState() => _AllTasksPageState();
}

class _AllTasksPageState extends State<AllTasksPage> {
  TaskGrouping _grouping = TaskGrouping.completion;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final theme = Theme.of(context);
        final app = widget.app;
        // 顶部那排「全部 / 未完成 / 已完成 / 已搁置」筛选条整行去掉了
        // （实机反馈：分类不要了）—— 想看某种状态，切「按完成度」就行，
        // 它天然把三种状态分成三组、顺序固定。
        final tasks = app.ws.liveTasks.where((t) => !t.archived).toList(growable: false);
        final rows = _buildRows(context, tasks);

        return Scaffold(
          appBar: AppBar(title: const Text('全部任务')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                // 分组调节栏走全应用统一的胶囊选择器（与项目详情的「状态」
                // 同一套观感），不再是 Material 的分段控件
                child: StatusPillSelector<TaskGrouping>(
                  values: TaskGrouping.values,
                  selected: _grouping,
                  labelOf: (value) => value.label,
                  onSelected: (value) => setState(() => _grouping = value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text('共 ${tasks.length} 条（含子任务）', style: theme.textTheme.labelSmall),
              ),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(
                        icon: Icons.checklist_outlined,
                        title: '没有符合条件的任务',
                        hint: '换个筛选条件试试；要新建任务，得先去「事件」里开一条线 —— 任务总得有归属',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final header = row.header;
                          if (header != null) {
                            return TaskGroupHeader(
                              title: header,
                              count: row.count,
                              color: row.color,
                            );
                          }
                          return Column(
                            children: <Widget>[
                              TaskTile(app: app, task: row.task!),
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

  List<TaskRow> _buildRows(BuildContext context, List<Task> tasks) {
    final app = widget.app;
    final colors = UrgencyColors.ofContext(context);
    final List<TaskGroup> groups;
    switch (_grouping) {
      case TaskGrouping.completion:
        groups = groupByCompletion(tasks);
      case TaskGrouping.event:
        groups = groupByEvent(
          tasks,
          app.ws.liveEvents,
          (eventId) => app.ws.findEvent(eventId)?.name ?? '（事件已删除）',
        );
      case TaskGrouping.urgency:
        groups = groupByUrgency(tasks);
    }
    return flattenTaskGroups(groups, (tone) => colors.of(tone ?? Urgency.none));
  }
}
