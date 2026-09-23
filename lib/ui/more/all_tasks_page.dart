import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import '../common/empty_state.dart';
import '../common/labels.dart';
import '../common/task_tile.dart';

/// 全部任务：**跨事件的任务总表**，按状态筛选。
///
/// 事件层级在手机上层层点进去太慢，这里给一个"平铺"的入口。
class AllTasksPage extends StatefulWidget {
  const AllTasksPage({super.key, required this.app});

  final AppController app;

  @override
  State<AllTasksPage> createState() => _AllTasksPageState();
}

class _AllTasksPageState extends State<AllTasksPage> {
  NodeStatus? _filter;

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
        tasks.sort(_byEventThenOrder);

        return Scaffold(
          appBar: AppBar(title: const Text('全部任务')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
              Expanded(
                child: tasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.checklist_outlined,
                        title: '没有符合条件的任务',
                        hint: '换一个筛选条件，或先去「事件」页新建任务',
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

  /// 按所属事件、再按任务自身 `order` 排 —— 与任务线里的先后顺序一致。
  int _byEventThenOrder(Task a, Task b) {
    final events = widget.app.ws.liveEvents;
    int eventOrder(String eventId) {
      for (final event in events) {
        if (event.id == eventId) return event.order;
      }
      return 1 << 30;
    }

    final byEvent = eventOrder(a.eventId).compareTo(eventOrder(b.eventId));
    if (byEvent != 0) return byEvent;
    return compareByOrder(a.order, a.id, b.order, b.id);
  }
}
