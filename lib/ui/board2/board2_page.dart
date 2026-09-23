import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../../core/rules/completion.dart';
import '../shared/widgets.dart';

/// 板块二：事件与任务线（设计文档 3.3 / 4.4 / 4.9）。
///
/// 渲染规则（ADR-036 / ADR-053）：
///   · `standard` —— 独立节点框，同一事件下的标准任务**沿主线纵向排列并用连线表示次序**
///   · `subtask`  —— 渲染在**父节点框内**，缩进列表（叶子，不能再有子节点）
///   · `parallel` —— **独立节点框**，与兄弟并列排布表达分叉；它自己的子任务仍在**该框内**
class Board2Page extends StatefulWidget {
  const Board2Page({super.key, required this.app});

  final AppController app;

  @override
  State<Board2Page> createState() => _Board2PageState();
}

class _Board2PageState extends State<Board2Page> {
  String? _selectedEventId;

  @override
  Widget build(BuildContext context) {
    final events = widget.app.ws.liveEvents.where((e) => !e.archived).toList(growable: false);
    final selected = _selectedEventId == null
        ? (events.isEmpty ? null : events.first)
        : widget.app.ws.findEvent(_selectedEventId!);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 300,
          child: _EventListPane(
            app: widget.app,
            events: events,
            selectedId: selected?.id,
            onSelect: (id) => setState(() => _selectedEventId = id),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null || selected.deleted
              ? const EmptyState(
                  icon: Icons.timeline_outlined,
                  title: '选一个事件',
                  hint: '事件是一条任务线的根；左栏新建后即可往后排标准任务',
                )
              : TaskTreePane(app: widget.app, event: selected),
        ),
      ],
    );
  }
}

/// 左栏：事件列表。
class _EventListPane extends StatelessWidget {
  const _EventListPane({
    required this.app,
    required this.events,
    required this.selectedId,
    required this.onSelect,
  });

  final AppController app;
  final List<Event> events;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionLabel(
          '事件（${events.length}）',
          trailing: IconButton(
            tooltip: '新建事件',
            icon: const Icon(Icons.add),
            onPressed: () => createEvent(context, app),
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? EmptyState(
                  icon: Icons.timeline_outlined,
                  title: '还没有事件',
                  hint: '事件只需要一个名字，它是一条任务线的起点',
                  action: FilledButton.icon(
                    onPressed: () => createEvent(context, app),
                    icon: const Icon(Icons.add),
                    label: const Text('新建事件'),
                  ),
                )
              : ListView(
                  children: <Widget>[
                    for (final event in events)
                      _EventTile(
                        app: app,
                        event: event,
                        selected: event.id == selectedId,
                        onTap: () => onSelect(event.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  static Future<void> createEvent(BuildContext context, AppController app) async {
    final name = await promptText(context, title: '新建事件', label: '事件名');
    if (name == null) return;
    final event = app.ws.createEvent(name: name);
    app.run(() {});
    if (context.mounted) {
      showNotice(context, '已创建「${event.name}」，可以往里加标准任务了');
    }
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.app,
    required this.event,
    required this.selected,
    required this.onTap,
  });

  final AppController app;
  final Event event;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final mainLine = ws.mainLineOf(event.id);
    final done = mainLine.where((t) => isTerminal(t.status)).length;
    final check = ws.checkEventCompletion(event.id);

    return ListTile(
      dense: true,
      onTap: onTap,
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
      leading: NodeStatusChip(
        status: event.status,
        completeBlockedReason: check.canComplete ? null : check.reason,
        onChanged: (status) {
          final error = app.run(() => ws.setEventStatus(event.id, status));
          if (error != null) showNotice(context, error, error: true);
        },
      ),
      title: Text(event.name, overflow: TextOverflow.ellipsis),
      subtitle: Text('$done/${mainLine.length} 主线任务终态'),
    );
  }
}

/// 右栏：一条任务线的完整渲染。
class TaskTreePane extends StatelessWidget {
  const TaskTreePane({super.key, required this.app, required this.event});

  final AppController app;
  final Event event;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final mainLine = ws.mainLineOf(event.id);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: <Widget>[
              NodeStatusChip(
                status: event.status,
                dense: false,
                completeBlockedReason:
                    ws.checkEventCompletion(event.id).canComplete ? null : ws.checkEventCompletion(event.id).reason,
                onChanged: (status) {
                  final error = app.run(() => ws.setEventStatus(event.id, status));
                  if (error != null) showNotice(context, error, error: true);
                },
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(event.name, style: theme.textTheme.headlineSmall)),
              IconButton(
                tooltip: '重命名事件',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final name = await promptText(
                    context,
                    title: '重命名事件',
                    label: '事件名',
                    initial: event.name,
                    confirmLabel: '保存',
                  );
                  if (name == null) return;
                  app.run(() => ws.updateEvent(event.id, name: name));
                },
              ),
              IconButton(
                tooltip: '归档事件（含整条任务线）',
                icon: const Icon(Icons.archive_outlined),
                onPressed: () {
                  app.run(() => ws.setEventArchived(event.id, true));
                  showNotice(context, '已归档，可在归档区取消');
                },
              ),
              IconButton(
                tooltip: '删除事件（含整条任务线）',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteEvent(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: <Widget>[
              if (mainLine.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: EmptyState(
                    icon: Icons.linear_scale,
                    title: '这条任务线还是空的',
                    hint: '标准任务沿主线排列，用连线表示先后次序（不构成依赖）',
                    action: FilledButton.icon(
                      onPressed: () => _addStandardTask(context),
                      icon: const Icon(Icons.add),
                      label: const Text('添加标准任务'),
                    ),
                  ),
                )
              else
                for (var i = 0; i < mainLine.length; i += 1) ...<Widget>[
                  StandardTaskCard(
                    app: app,
                    event: event,
                    task: mainLine[i],
                    index: i,
                    total: mainLine.length,
                  ),
                  if (i < mainLine.length - 1) const _ChainConnector(),
                ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _addStandardTask(context),
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('添加标准任务'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addStandardTask(BuildContext context) async {
    final title = await promptText(context, title: '添加标准任务', label: '任务名');
    if (title == null) return;
    app.run(() => app.ws.createTask(eventId: event.id, title: title));
  }

  Future<void> _deleteEvent(BuildContext context) async {
    final count = app.ws.liveTasks.where((t) => t.eventId == event.id).length;
    final ok = await confirmAction(
      context,
      title: '删除事件',
      message: '「${event.name}」及其整条任务线（$count 个任务）将一起删除。\n\n删除后可在「归档区 → 回收站」恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    app.run(() => app.ws.deleteEvent(event.id));
    if (context.mounted) showNotice(context, '已删除，可在归档区恢复');
  }
}

/// 主线上的连线（表达"次序"，不是依赖）。
class _ChainConnector extends StatelessWidget {
  const _ChainConnector();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(width: 2, height: 20, color: color),
          Icon(Icons.arrow_drop_down, size: 18, color: color),
        ],
      ),
    );
  }
}

/// 标准任务卡片：自己是一个框，**子任务渲染在框内**，并列任务作为独立框并列排布。
class StandardTaskCard extends StatelessWidget {
  const StandardTaskCard({
    super.key,
    required this.app,
    required this.event,
    required this.task,
    required this.index,
    required this.total,
  });

  final AppController app;
  final Event event;
  final Task task;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final theme = Theme.of(context);
    final children = ws.subtasksOf(task.id, eventId: event.id);
    final subtasks = children.where((t) => t.taskType == TaskType.subtask).toList(growable: false);
    final parallels = children.where((t) => t.taskType == TaskType.parallel).toList(growable: false);
    final check = checkCompletion(ws.taskTree, task.id);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NodeStatusChip(
                status: task.status,
                completeBlockedReason: check.canComplete ? null : check.reason,
                onChanged: (status) {
                  final error = app.run(() => ws.setTaskStatus(task.id, status));
                  if (error != null) showNotice(context, error, error: true);
                },
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${index + 1}. ${task.title}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    decoration:
                        task.status == NodeStatus.done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              _DueChip(task: task),
              _TaskMenu(
                app: app,
                event: event,
                task: task,
                onMoveUp: index > 0 ? () => _moveMainLine(-1) : null,
                onMoveDown: index < total - 1 ? () => _moveMainLine(1) : null,
                allowParallel: true,
              ),
            ],
          ),
          if (subtasks.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            for (final subtask in subtasks)
              _SubtaskRow(app: app, event: event, task: subtask),
          ],
          if (parallels.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              '并列任务（分叉，互不依赖）',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                for (final parallel in parallels)
                  _ParallelTaskCard(app: app, event: event, task: parallel),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: () => _addChild(context, TaskType.subtask),
                icon: const Icon(Icons.subdirectory_arrow_right, size: 16),
                label: const Text('子任务'),
              ),
              TextButton.icon(
                onPressed: () => _addChild(context, TaskType.parallel),
                icon: const Icon(Icons.call_split, size: 16),
                label: const Text('并列任务'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _moveMainLine(int delta) {
    final ws = app.ws;
    final ids = ws.mainLineOf(event.id).map((t) => t.id).toList();
    final from = ids.indexOf(task.id);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= ids.length) return;
    final moved = ids.removeAt(from);
    ids.insert(to, moved);
    app.run(() => ws.reorder(DocName.tasks, null, ids));
  }

  Future<void> _addChild(BuildContext context, TaskType type) async {
    final title = await promptText(
      context,
      title: type == TaskType.subtask ? '添加子任务' : '添加并列任务',
      label: '任务名',
    );
    if (title == null) return;
    final error = app.run(
      () => app.ws.createTask(
        eventId: event.id,
        title: title,
        parentTaskId: task.id,
        type: type,
      ),
    );
    if (error != null && context.mounted) showNotice(context, error, error: true);
  }
}

/// 并列任务：**独立节点框**（与兄弟并列），其子任务仍在该框内。
class _ParallelTaskCard extends StatelessWidget {
  const _ParallelTaskCard({required this.app, required this.event, required this.task});

  final AppController app;
  final Event event;
  final Task task;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final theme = Theme.of(context);
    final subtasks = ws
        .subtasksOf(task.id, eventId: event.id)
        .where((t) => t.taskType == TaskType.subtask)
        .toList(growable: false);
    final check = checkCompletion(ws.taskTree, task.id);

    return Container(
      width: 250,
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              NodeStatusChip(
                status: task.status,
                completeBlockedReason: check.canComplete ? null : check.reason,
                onChanged: (status) {
                  final error = app.run(() => ws.setTaskStatus(task.id, status));
                  if (error != null) showNotice(context, error, error: true);
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '⑂ ${task.title}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    decoration:
                        task.status == NodeStatus.done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              _TaskMenu(app: app, event: event, task: task, allowParallel: false),
            ],
          ),
          if (task.dueAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: _DueChip(task: task),
            ),
          for (final subtask in subtasks) _SubtaskRow(app: app, event: event, task: subtask),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final title = await promptText(context, title: '添加子任务', label: '任务名');
                if (title == null) return;
                final error = app.run(
                  () => ws.createTask(
                    eventId: event.id,
                    title: title,
                    parentTaskId: task.id,
                    type: TaskType.subtask,
                  ),
                );
                if (error != null && context.mounted) showNotice(context, error, error: true);
              },
              icon: const Icon(Icons.subdirectory_arrow_right, size: 15),
              label: const Text('子任务'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 子任务行（渲染在父节点框内，缩进）。
class _SubtaskRow extends StatelessWidget {
  const _SubtaskRow({required this.app, required this.event, required this.task});

  final AppController app;
  final Event event;
  final Task task;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final theme = Theme.of(context);
    final check = checkCompletion(ws.taskTree, task.id);

    return Padding(
      padding: const EdgeInsets.only(left: 22),
      child: Row(
        children: <Widget>[
          Text('└', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(width: 4),
          NodeStatusChip(
            status: task.status,
            completeBlockedReason: check.canComplete ? null : check.reason,
            onChanged: (status) {
              final error = app.run(() => ws.setTaskStatus(task.id, status));
              if (error != null) showNotice(context, error, error: true);
            },
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              task.title,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                decoration: task.status == NodeStatus.done ? TextDecoration.lineThrough : null,
                color: task.status == NodeStatus.ignored ? theme.colorScheme.outline : null,
              ),
            ),
          ),
          if (task.dueAt != null)
            Text(task.dueAt!, style: theme.textTheme.labelSmall),
          _TaskMenu(app: app, event: event, task: task, allowParallel: false),
        ],
      ),
    );
  }
}

class _DueChip extends StatelessWidget {
  const _DueChip({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    if (task.dueAt == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final today = DateTime.now();
    final todayText =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final overdue = task.status == NodeStatus.pending && task.dueAt!.compareTo(todayText) < 0;

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (overdue)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(Icons.error_outline, size: 13, color: theme.colorScheme.error),
            ),
          Text(
            task.dueAt!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: overdue ? theme.colorScheme.error : theme.colorScheme.outline,
              fontWeight: overdue ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 任务级操作菜单。
class _TaskMenu extends StatelessWidget {
  const _TaskMenu({
    required this.app,
    required this.event,
    required this.task,
    this.onMoveUp,
    this.onMoveDown,
    this.allowParallel = false,
  });

  final AppController app;
  final Event event;
  final Task task;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final bool allowParallel;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    return PopupMenuButton<String>(
      tooltip: '操作',
      iconSize: 18,
      padding: EdgeInsets.zero,
      onSelected: (value) async {
        switch (value) {
          case 'rename':
            final title = await promptText(
              context,
              title: '重命名任务',
              label: '任务名',
              initial: task.title,
              confirmLabel: '保存',
            );
            if (title == null) return;
            app.run(() => ws.updateTask(task.id, title: title));
            break;
          case 'due':
            final picked = await showDatePicker(
              context: context,
              initialDate: task.dueAt == null ? DateTime.now() : DateTime.parse(task.dueAt!),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              helpText: '选择到期 / 目标日',
            );
            if (picked == null) return;
            final text =
                '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
            app.run(() => ws.updateTask(task.id, dueAt: text));
            break;
          case 'clearDue':
            app.run(() => ws.updateTask(task.id, dueAt: null));
            break;
          case 'parallel':
            final title = await promptText(context, title: '添加并列任务', label: '任务名');
            if (title == null) return;
            final error = app.run(
              () => ws.createTask(
                eventId: event.id,
                title: title,
                parentTaskId: task.id,
                type: TaskType.parallel,
              ),
            );
            if (error != null && context.mounted) showNotice(context, error, error: true);
            break;
          case 'up':
            onMoveUp?.call();
            break;
          case 'down':
            onMoveDown?.call();
            break;
          case 'archive':
            app.run(() => ws.setTaskArchived(task.id, true));
            showNotice(context, '已归档（含子任务），可在归档区取消');
            break;
          case 'delete':
            final ok = await confirmAction(
              context,
              title: '删除任务',
              message: '「${task.title}」及其子任务将被删除，可在归档区恢复。',
              confirmLabel: '删除',
              danger: true,
            );
            if (!ok) return;
            app.run(() => ws.deleteTask(task.id));
            break;
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
        const PopupMenuItem<String>(value: 'due', child: Text('设置到期日…')),
        if (task.dueAt != null)
          const PopupMenuItem<String>(value: 'clearDue', child: Text('清除到期日')),
        if (allowParallel)
          const PopupMenuItem<String>(value: 'parallel', child: Text('添加并列任务')),
        if (onMoveUp != null) const PopupMenuItem<String>(value: 'up', child: Text('上移')),
        if (onMoveDown != null) const PopupMenuItem<String>(value: 'down', child: Text('下移')),
        const PopupMenuItem<String>(value: 'archive', child: Text('归档')),
        const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
      ],
    );
  }
}
