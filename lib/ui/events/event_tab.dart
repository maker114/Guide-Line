import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/rules/cascade.dart';
import '../common/dialogs.dart';
import '../common/empty_state.dart';
import '../common/labels.dart';
import 'event_detail_page.dart';
import 'task_actions.dart';

/// 事件 Tab：**任务线的入口列表**。
///
/// 事件本身只有名字 + 三态（无时间、无描述），所以列表上给的是
/// 「主线进度」这个唯一有信息量的东西。
class EventTab extends StatelessWidget {
  const EventTab({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final events = app.ws.liveEvents.where((e) => !e.archived).toList(growable: false)
      ..sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
          child: Row(
            children: <Widget>[
              Text('共 ${events.length} 个事件', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              TextButton.icon(
                onPressed: () => createEventAction(context, app),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? EmptyState(
                  icon: Icons.timeline_outlined,
                  title: '还没有事件',
                  hint: '事件是一条任务线的起点，本身不设时间与描述',
                  action: FilledButton.icon(
                    onPressed: () => createEventAction(context, app),
                    icon: const Icon(Icons.add),
                    label: const Text('新建事件'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: events.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) => _EventTile(app: app, event: events[index]),
                ),
        ),
      ],
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.app, required this.event});

  final AppController app;
  final Event event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mainLine = app.ws.mainLineOf(event.id);
    final done = mainLine.where((t) => t.status == NodeStatus.done).length;

    return ListTile(
      leading: Icon(
        nodeStatusIcon(event.status),
        color: nodeStatusColor(event.status, theme.colorScheme),
      ),
      title: Text(
        event.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: event.status == NodeStatus.done
            ? theme.textTheme.bodyLarge?.copyWith(
                decoration: TextDecoration.lineThrough,
                color: theme.colorScheme.outline,
              )
            : null,
      ),
      subtitle: Row(
        children: <Widget>[
          const Icon(Icons.timeline, size: 13),
          const SizedBox(width: 3),
          Text(
            mainLine.isEmpty ? '还没有主线任务' : '主线 $done/${mainLine.length} 完成',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (value) async {
          switch (value) {
            case 'rename':
              final name = await promptText(
                context,
                title: '重命名事件',
                initialText: event.name,
                hintText: '事件名',
              );
              if (name == null || !context.mounted) return;
              final error = app.run(() => app.ws.updateEvent(event.id, name: name));
              if (error != null && context.mounted) showToast(context, error, error: true);
              break;
            case 'task':
              await createTaskAction(context, app, eventId: event.id);
              break;
            case 'archive':
              final error = app.run(() => app.ws.setEventArchived(event.id, true));
              if (!context.mounted) return;
              showToast(
                context,
                error ?? '已归档，整条任务线一起归档（可在「归档区」找回）',
                error: error != null,
              );
              break;
            case 'delete':
              await _delete(context);
              break;
          }
        },
        itemBuilder: (_) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'task', child: Text('新建主线任务')),
          PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
          PopupMenuItem<String>(value: 'archive', child: Text('归档（含任务线）')),
          PopupMenuItem<String>(value: 'delete', child: Text('删除（含任务线）')),
        ],
      ),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => EventDetailPage(app: app, eventId: event.id),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final taskCount = eventDeletionTaskIds(app.ws.allTasks, event.id).length;
    final ok = await confirmAction(
      context,
      title: '删除事件',
      message: taskCount == 0
          ? '删除「${event.name}」。可在「更多 → 归档区 → 回收站」恢复。'
          : '「${event.name}」及其整条任务线（$taskCount 个任务）会被一起删除。'
              '可在「更多 → 归档区 → 回收站」恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    final error = app.run(() => app.ws.deleteEvent(event.id));
    if (error != null && context.mounted) showToast(context, error, error: true);
  }
}

Future<void> createEventAction(BuildContext context, AppController app) async {
  final name = await promptText(context, title: '新建事件', hintText: '事件名');
  if (name == null || !context.mounted) return;
  final error = app.run(() => app.ws.createEvent(name: name));
  if (error != null && context.mounted) showToast(context, error, error: true);
}
