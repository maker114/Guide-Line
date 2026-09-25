import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/task.dart';
import '../common/empty_state.dart';
import '../common/format.dart';
import '../common/status_selector.dart';
import '../common/task_tile.dart';

/// 「到期」页的档位：**由近到远**，最后一个是"所有排了期的"。
///
/// 加「全部排期」是一条实机反馈的直接结果：默认停在「今天」时，如果任务都排在
/// 更远的将来，整页看着就是空的 —— 页面没错，是范围太窄。现在打开时会自动落到
/// **第一个有内容的档**，实在一个都没有才显示空状态。
enum DueRange {
  today('今天'),
  week('7 天内'),
  overdue('已逾期'),
  scheduled('全部排期');

  const DueRange(this.label);

  final String label;
}

/// 到期：**按截止日聚合的待处理任务**（设计文档 Q29 / Q41 / Q48）。
///
/// 聚合口径统一是 `due_at <= 截止日` 且未完成、未归档；前三个档位只是换个截止日，
/// 第四个不设截止日。
class DuePage extends StatefulWidget {
  const DuePage({super.key, required this.app});

  final AppController app;

  @override
  State<DuePage> createState() => _DuePageState();
}

class _DuePageState extends State<DuePage> {
  /// 用户手动选过的档位；`null` = 还没选过 → 自动挑一个**有内容的**档。
  DueRange? _picked;

  List<Task> _tasksOf(DueRange range) {
    final ws = widget.app.ws;
    switch (range) {
      case DueRange.today:
        return ws.tasksDueOnOrBefore(dateOffset(0));
      case DueRange.week:
        // 今天 + 6 天 = 7 天内（含今天共 7 个日历天）
        return ws.tasksDueOnOrBefore(dateOffset(6));
      case DueRange.overdue:
        // 昨天 → 等价于"严格早于今天"
        return ws.tasksDueOnOrBefore(dateOffset(-1));
      case DueRange.scheduled:
        return ws.tasksScheduled();
    }
  }

  /// 当前档位：用户选过就用他的选择，否则**第一个有内容的档**。
  ///
  /// 「已逾期」不用参与挑选：它是「今天」的子集，今天为空时它必然也是空的。
  DueRange _currentRange() {
    final picked = _picked;
    if (picked != null) return picked;
    for (final range in <DueRange>[DueRange.today, DueRange.week, DueRange.scheduled]) {
      if (_tasksOf(range).isNotEmpty) return range;
    }
    return DueRange.today;
  }

  /// 档位下面那行说明：把"这一档到底算了哪一段"写清楚。
  String _noteOf(DueRange range, int count) {
    switch (range) {
      case DueRange.today:
        return '共 $count 条 · 截止 ${dateOffset(0)}（含更早）';
      case DueRange.week:
        return '共 $count 条 · 截止 ${dateOffset(6)}（含更早）';
      case DueRange.overdue:
        return '共 $count 条 · 严格早于今天';
      case DueRange.scheduled:
        return '共 $count 条 · 所有排了期的任务（不管多远）';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final theme = Theme.of(context);
        final range = _currentRange();
        final tasks = _tasksOf(range);

        return Scaffold(
          appBar: AppBar(title: const Text('到期')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 调节栏与「全部任务」的筛选栏是同一种观感（全应用统一走
              // `StatusPillSelector`：胶囊里套小胶囊、无分割线）
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: StatusPillSelector<DueRange>(
                  values: DueRange.values,
                  selected: range,
                  labelOf: (value) => value.label,
                  onSelected: (value) => setState(() => _picked = value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(_noteOf(range, tasks.length), style: theme.textTheme.labelSmall),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.event_available_outlined,
                        title: '这个区间没有到期的任务',
                        hint: '给任务设了到期日才会出现在这里；'
                            '排得更远的日子可以切到「全部排期」看',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 16, endIndent: 16),
                        itemBuilder: (context, index) =>
                            TaskTile(app: widget.app, task: tasks[index]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
