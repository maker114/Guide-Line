import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
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
        // `openTasks()`：未完成、未归档，**不管有没有排期、也不管所属事件是不是
        // 已搁置** —— 这一页是"我还欠着什么"的一览，不是催办（催办在逾期角标里）
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
                    ? EmptyState(
                        icon: Icons.upcoming_outlined,
                        title: '接下来没有待办',
                        hint: _whyEmpty(),
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

  /// 空的时候**说清为什么空**（实机反馈："这一页没有东西，但全部任务里是正常的"）。
  ///
  /// 把数字摆出来：共多少条、其中已完成 / 已搁置各多少 —— 剩下的才是"还开着的"。
  String _whyEmpty() {
    final ws = app.ws;
    final all = ws.liveTasks.where((t) => !t.archived).toList(growable: false);
    if (all.isEmpty) return '还没有任务：去「事件」页给某条线加几条';

    final done = all.where((t) => t.status == NodeStatus.done).length;
    final ignored = all.where((t) => t.status == NodeStatus.ignored).length;

    final parts = <String>[
      '共 ${all.length} 条任务',
      if (done > 0) '已完成 $done 条',
      if (ignored > 0) '已搁置 $ignored 条',
    ];
    return '${parts.join(' · ')}。这一页只列未完成的任务；要看全部（含已完成）切到「全部任务」';
  }
}
