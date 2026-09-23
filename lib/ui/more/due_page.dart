import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../common/empty_state.dart';
import '../common/format.dart';
import '../common/task_tile.dart';

/// 到期：**按截止日聚合的待处理任务**（设计文档 Q29 / Q41 / Q48）。
///
/// 聚合口径统一是 `due_at <= 截止日` 且未完成、未归档；三个档位只是换个截止日。
class DuePage extends StatefulWidget {
  const DuePage({super.key, required this.app});

  final AppController app;

  @override
  State<DuePage> createState() => _DuePageState();
}

class _DuePageState extends State<DuePage> {
  int _range = 0;

  String get _cutoff {
    switch (_range) {
      case 1:
        return dateOffset(6); // 今天 + 6 天 = 一周内
      case 2:
        return dateOffset(-1); // 昨天 → 等价于"严格早于今天"
      default:
        return dateOffset(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final tasks = widget.app.ws.tasksDueOnOrBefore(_cutoff);
        final theme = Theme.of(context);

        return Scaffold(
          appBar: AppBar(title: const Text('到期')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: SegmentedButton<int>(
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment<int>(value: 0, label: Text('今天')),
                    ButtonSegment<int>(value: 1, label: Text('7 天内')),
                    ButtonSegment<int>(value: 2, label: Text('已逾期')),
                  ],
                  selected: <int>{_range},
                  onSelectionChanged: (selection) => setState(() => _range = selection.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  '共 ${tasks.length} 条 · 截止 $_cutoff（含更早）',
                  style: theme.textTheme.labelSmall,
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.event_available_outlined,
                        title: '这个区间没有到期的任务',
                        hint: '给任务设了到期日才会出现在这里',
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
