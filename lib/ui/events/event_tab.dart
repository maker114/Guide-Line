import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/rules/cascade.dart';
import '../common/dialogs.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import 'event_detail_page.dart';

/// 事件 Tab：**任务线的入口列表**。
///
/// 事件本身只有名字 + 三态（无时间、无描述），所以列表上给的是
/// 「主线进度」这个唯一有信息量的东西。
///
/// 新建与重命名都是**页面内直接输入**，不弹对话框。
class EventTab extends StatefulWidget {
  const EventTab({super.key, required this.app});

  final AppController app;

  @override
  State<EventTab> createState() => _EventTabState();
}

class _EventTabState extends State<EventTab> {
  String? _renamingId;

  AppController get _app => widget.app;

  @override
  Widget build(BuildContext context) {
    final events = _app.ws.liveEvents.where((e) => !e.archived).toList(growable: false)
      ..sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            events.isEmpty ? '还没有事件' : '共 ${events.length} 个事件',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: <Widget>[
              InlineComposer(
                label: '新建事件',
                hint: '事件名',
                leading: Icons.add,
                onCreate: (name) {
                  final error = _app.run(() => _app.ws.createEvent(name: name));
                  if (error != null) _toast(error, error: true);
                },
              ),
              if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '事件是一条任务线的起点，本身不设时间与描述',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                for (final event in events) ...<Widget>[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  if (_renamingId == event.id)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: InlineTextField(
                        value: event.name,
                        autofocus: true,
                        hint: '事件名',
                        textStyle: Theme.of(context).textTheme.bodyLarge,
                        onSubmitted: (name) =>
                            _app.run(() => _app.ws.updateEvent(event.id, name: name)),
                        onEditClosed: () {
                          if (mounted) setState(() => _renamingId = null);
                        },
                      ),
                    )
                  else
                    _EventTile(
                      app: _app,
                      event: event,
                      onStartRename: () => setState(() => _renamingId = event.id),
                    ),
                ],
            ],
          ),
        ),
      ],
    );
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    showToast(context, message, error: error);
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.app,
    required this.event,
    required this.onStartRename,
  });

  final AppController app;
  final Event event;
  final VoidCallback onStartRename;

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
              onStartRename();
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
