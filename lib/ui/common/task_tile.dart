import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import '../events/event_detail_page.dart';
import 'format.dart';
import 'labels.dart';
import 'task_status_button.dart';

/// 任务行：**到期 / 全部任务 / 搜索结果**共用。
///
/// 点标题进入所属事件的任务线 —— 任务脱离任务线没有意义，所以不在这里就地编辑。
class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.app, required this.task});

  final AppController app;
  final Task task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = app.ws.findEvent(task.eventId);
    final parent = task.parentId == null ? null : app.ws.findTask(task.parentId!);
    final due = describeDate(task.dueAt);
    final overdue = isOverdue(task.dueAt) && task.status != NodeStatus.done;
    final done = task.status == NodeStatus.done;
    final labelStyle = theme.textTheme.labelSmall;

    return ListTile(
      leading: TaskStatusButton(app: app, task: task),
      title: Text(
        task.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: done
            ? theme.textTheme.bodyMedium?.copyWith(
                decoration: TextDecoration.lineThrough,
                color: theme.colorScheme.outline,
              )
            : null,
      ),
      subtitle: Row(
        children: <Widget>[
          const Icon(Icons.timeline, size: 13),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              event?.name ?? '（事件已删除）',
              style: labelStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (parent != null) ...<Widget>[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '· ${parent.title}',
                style: labelStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          if (task.taskType != TaskType.standard) ...<Widget>[
            const SizedBox(width: 8),
            Text('· ${taskTypeLabel(task.taskType)}', style: labelStyle),
          ],
          if (due.isNotEmpty) ...<Widget>[
            const SizedBox(width: 8),
            Icon(
              Icons.event,
              size: 13,
              color: overdue ? theme.colorScheme.error : theme.colorScheme.outline,
            ),
            const SizedBox(width: 3),
            Text(
              due,
              style: labelStyle?.copyWith(color: overdue ? theme.colorScheme.error : null),
            ),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => EventDetailPage(app: app, eventId: task.eventId),
        ),
      ),
    );
  }
}
