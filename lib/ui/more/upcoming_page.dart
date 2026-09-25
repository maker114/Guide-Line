import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../common/empty_state.dart';
import '../common/task_tile.dart';
import '../common/urgency.dart';
import 'task_calendar_page.dart';
import 'task_grouping.dart';

/// 「接下来的任务」：**还开着的任务按紧迫度排**（实机反馈）。
///
/// 与「全部任务」的「按紧迫度」分组是同一套分档（同一份纯函数），差别只有一个：
/// 这里**只列未完成** —— 已搁置与已完成不出现，"接下来的事"才名副其实。
///
/// 页面右上角那个「日历」按钮会打开按月排的任务日历：哪几天有任务、
/// 分别属于哪条线（事件标识色），点一天就能看到那天的任务。
class UpcomingTasksPage extends StatelessWidget {
  const UpcomingTasksPage({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final colors = UrgencyColors.ofContext(context);
        // `openTasks()`：未完成、未归档、不在已搁置事件下（放下的线不该继续催），
        // **不要求有到期日** —— "没有到期日"本来就是紧迫度里的一档
        final tasks = app.ws.openTasks();
        final rows = flattenTaskGroups(
          groupByUrgency(tasks),
          (tone) => colors.of(tone ?? Urgency.none),
        );

        return Scaffold(
          appBar: AppBar(title: const Text('接下来的任务')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        tasks.isEmpty ? '现在没有待办' : '共 ${tasks.length} 条 · 按紧迫度排',
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    // 日历按钮：按月看"哪几天有任务"
                    FilledButton.tonalIcon(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => TaskCalendarPage(app: app),
                        ),
                      ),
                      icon: const Icon(Icons.calendar_month_outlined, size: 18),
                      label: const Text('日历'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(
                        icon: Icons.upcoming_outlined,
                        title: '接下来没有待办',
                        hint: '任务都做完了；或者去「事件」页给这条线排上几条',
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
}
