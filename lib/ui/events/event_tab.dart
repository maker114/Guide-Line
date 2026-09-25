import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../../core/rules/cascade.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import 'event_detail_page.dart';
import 'task_fold.dart';

/// 事件 Tab：**任务线的入口列表**，与项目页同一套观感。
///
/// 实机反馈：事件页原来只是一行行"事件名 + 主线 3/5"，看不出这条线在做哪一步；
/// 项目页那种"一个主条目一张卡 + 下级嵌在卡里"的排布直观得多，于是照搬：
///   · **一个事件一张卡**，卡里嵌着它的主线任务（已完成的自动收起，只留当前节点
///     的上一个 —— 与详情页同一条规则，见 `task_fold.dart`）；
///   · 卡头一行给"主线 3/5 + 当前 · 某任务"，一眼知道做到哪了；
///   · 展开 / 收起用 `AnimatedSize` 做高度过渡，折叠状态存在 `UiPrefs` 里。
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
                // **一个事件一张卡**（与项目页同一种观感）：卡内靠"同框"表达归属，
                // 卡与卡之间留空隙 —— 这是"两个不同事件"的唯一线索。
                for (final event in events)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    child: Card(
                      margin: EdgeInsets.zero,
                      elevation: 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (_renamingId == event.id)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: InlineTextField(
                                value: event.name,
                                autofocus: true,
                                hint: '事件名',
                                textStyle: Theme.of(context).textTheme.bodyLarge,
                                onSubmitted: (name) => _app.run(
                                  () => _app.ws.updateEvent(event.id, name: name),
                                ),
                                onEditClosed: () {
                                  if (mounted) setState(() => _renamingId = null);
                                },
                              ),
                            )
                          else
                            _EventCardHeader(
                              app: _app,
                              event: event,
                              onStartRename: () =>
                                  setState(() => _renamingId = event.id),
                            ),
                          // 展开 / 收起用 `AnimatedSize` 做**高度过渡**：直接重建列表
                          // 会因行数突变"跳"一下，看着像动画坏了（项目页踩过同一个坑）。
                          AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _buildLine(context, event),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  /// 卡里那一段任务线（收起时为空）。
  List<Widget> _buildLine(BuildContext context, Event event) {
    if (!_app.isExpanded(event.id)) return const <Widget>[];

    final mainLine = _app.ws.mainLineOf(event.id);
    if (mainLine.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 0, 12, 10),
          child: Text(
            '还没有主线任务 —— 点开这条事件去加第一个节点',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ];
    }

    final folded = autoFoldedMainLineIds(
      mainLine,
      // 用户手动展开过的**不折**（显式选择优先于自动规则）
      userExpanded: (id) =>
          _app.isExpanded(id, defaultExpanded: false) &&
          _app.ws.prefs.expandedIds.contains(id),
    );
    final visible = mainLine.where((t) => !folded.contains(t.id)).toList(growable: false);
    final hidden = mainLine.length - visible.length;
    final muted = _app.ws.isEventMutedForDue(event.id);

    return <Widget>[
      for (final task in visible) _EventTaskRow(app: _app, task: task, muted: muted),
      if (hidden > 0)
        // 收起了多少要说出来：不然"这条线怎么忽然只有两步"会让人以为数据丢了
        InkWell(
          onTap: () => _open(event),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 2, 12, 8),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.unfold_more,
                  size: 14,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 4),
                // 1.6 倍字体下这行会顶到卡片右边（实机字号放大是常规场景），
                // 所以必须让它可压缩
                Expanded(
                  child: Text(
                    '另有 $hidden 个已完成节点（点开看全过程）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 6),
    ];
  }

  void _open(Event event) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => EventDetailPage(app: _app, eventId: event.id),
      ),
    );
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    showToast(context, message, error: error);
  }
}

/// 卡头：状态 + 事件名 + 「主线 3/5 · 当前 · 某任务」，右侧是这一条的动作菜单。
class _EventCardHeader extends StatelessWidget {
  const _EventCardHeader({
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
    final expanded = app.isExpanded(event.id);
    // "当前节点" = 第一个还没终结的主线任务：列表上最该回答的就是这个问题
    final current = mainLine
        .where((t) => t.status == NodeStatus.pending)
        .firstOrNull;

    return ListTile(
      // 有主线任务才给展开箭头（与项目页的"有子项目才有箭头"一致）
      contentPadding: const EdgeInsets.only(left: 4, right: 4),
      leading: mainLine.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Icon(
                nodeStatusIcon(event.status),
                size: 20,
                color: nodeStatusColor(event.status, theme.colorScheme),
              ),
            )
          : IconButton(
              tooltip: expanded ? '收起任务线' : '展开任务线',
              icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
              onPressed: () => app.setExpanded(event.id, expanded: !expanded),
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
          Icon(Icons.timeline, size: 13, color: theme.colorScheme.outline),
          const SizedBox(width: 3),
          Text(
            mainLine.isEmpty ? '还没有主线任务' : '主线 $done/${mainLine.length}',
            style: theme.textTheme.labelSmall,
          ),
          if (current != null) ...<Widget>[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '当前 · ${current.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
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

/// 卡里的一条主线任务：比卡头**紧凑**一档，靠缩进表达"它属于上面那个事件"。
///
/// [muted] 用于**已搁置的事件**：那类事件不参与到期统计（见
/// `Workspace.tasksDueOnOrBefore`），所以这里也不把日期标成逾期红 ——
/// 一边说"不再催"，一边画个红日期自相矛盾。
class _EventTaskRow extends StatelessWidget {
  const _EventTaskRow({
    required this.app,
    required this.task,
    required this.muted,
  });

  final AppController app;
  final Task task;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = describeDate(task.dueAt);
    final overdue = !muted && isOverdue(task.dueAt) && task.status != NodeStatus.done;
    final done = task.status != NodeStatus.pending;

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      // 卡头左起 4dp、这里 40dp：靠缩进差表达主从，而不是靠字号或分割线
      contentPadding: const EdgeInsets.only(left: 40, right: 4),
      minLeadingWidth: 18,
      leading: Icon(
        nodeStatusIcon(task.status),
        size: 18,
        color: nodeStatusColor(task.status, theme.colorScheme),
      ),
      title: Text(
        task.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          decoration: task.status == NodeStatus.done
              ? TextDecoration.lineThrough
              : null,
          color: done ? theme.colorScheme.outline : null,
        ),
      ),
      subtitle: due.isEmpty && task.status != NodeStatus.ignored
          ? null
          : Row(
              children: <Widget>[
                if (due.isNotEmpty) ...<Widget>[
                  Icon(
                    Icons.event,
                    size: 13,
                    color: overdue
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    due,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: overdue ? theme.colorScheme.error : null,
                    ),
                  ),
                ],
                if (task.status == NodeStatus.ignored) ...<Widget>[
                  if (due.isNotEmpty) const SizedBox(width: 8),
                  Text('已搁置', style: theme.textTheme.labelSmall),
                ],
              ],
            ),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => EventDetailPage(app: app, eventId: task.eventId),
        ),
      ),
    );
  }
}
