import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import '../events/event_detail_page.dart';
import 'format.dart';
import 'labels.dart';
import 'task_status_button.dart';
import 'urgency.dart';

/// 任务行：**到期 / 全部任务 / 搜索结果**共用。
///
/// 点标题进入所属事件的任务线 —— 任务脱离任务线没有意义，所以不在这里就地编辑。
///
/// 到期日旁有一个**紧迫度色点**：越接近越红、逾期最红、没排期是灰。
/// 之所以用色点 + 彩色文字而不是整行底色：整行上色会盖过"已完成 / 已搁置"这些
/// 本来就有的状态表达，而色点只占一个字的宽度，信息叠加不打架。
class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.app, required this.task});

  final AppController app;
  final Task task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = app.ws.findEvent(task.eventId);
    final parent = task.parentId == null ? null : app.ws.findTask(task.parentId!);
    final done = task.status == NodeStatus.done;

    // 已完成 / 已搁置的任务不再"报警"，一律走灰
    final urgency = task.status == NodeStatus.pending ? urgencyOf(task.dueAt) : Urgency.none;
    final urgencyColor = UrgencyColors.ofContext(context).of(urgency);
    final due = describeDate(task.dueAt);
    final dueText = due.isEmpty ? '没排期' : due;
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
          const SizedBox(width: 8),
          Tooltip(
            message: urgencyLabel(urgency),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: urgencyColor, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 4),
          Text(dueText, style: labelStyle?.copyWith(color: urgencyColor)),
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
