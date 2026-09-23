import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../../core/rules/completion.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import '../common/task_status_button.dart';
import 'task_actions.dart';

/// 事件详情：**一条任务线的可视化**。
///
/// 渲染规则（设计文档 4.9 / ADR-036 / ADR-053）：
///   · `standard` —— 独立节点框，沿主线**纵向串联**（框间有连线，表示"接着做"）
///   · `subtask`  —— 渲染在父节点**框内**并缩进（叶子，无子节点）
///   · `parallel` —— 独立节点框，与兄弟**横向并排**（表示"两条都能走"），其子任务仍在框内
///
/// 手机屏幕放不下真正的双列，所以并列框用**横向滚动**表达"并联"，而不是硬挤成两列。
///
/// 新建与重命名都是**页面内直接输入**：主线在任务线末尾，子任务 / 并列任务在各自的框内，
/// 重命名就在那一行原地改。只有"必须有副作用提示"的动作（到期 / 移动 / 归档 / 删除）
/// 才用底部面板问一句。
class EventDetailPage extends StatefulWidget {
  const EventDetailPage({super.key, required this.app, required this.eventId});

  final AppController app;
  final String eventId;

  @override
  State<EventDetailPage> createState() => _EventDetailPageState();
}

class _EventDetailPageState extends State<EventDetailPage> {
  AppController get app => widget.app;

  String get eventId => widget.eventId;

  /// 正在原地重命名的任务 id
  String? _renamingTaskId;

  /// 正在为哪个任务录子任务 / 并列任务
  String? _subtaskParentId;
  String? _parallelParentId;

  void _createTask({
    required String title,
    String? parentTaskId,
    TaskType type = TaskType.standard,
  }) {
    final error = app.run(
      () => app.ws.createTask(
        eventId: eventId,
        title: title,
        parentTaskId: parentTaskId,
        type: type,
      ),
    );
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    // 挂完子节点就把那个框内的输入收起来，免得一屏挂着好几个输入框
    if (parentTaskId != null) {
      setState(() {
        _subtaskParentId = null;
        _parallelParentId = null;
      });
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    showToast(context, message, error: error);
  }

  // 下面几个是给同文件里的私有子控件用的：`setState` 是 protected，
  // 子控件不能直接调，所以在这里开几个语义明确的入口。

  void beginRename(String taskId) => setState(() => _renamingTaskId = taskId);

  void endRename() => setState(() => _renamingTaskId = null);

  void beginSubtask(String taskId) => setState(() {
        _subtaskParentId = taskId;
        _parallelParentId = null;
      });

  void beginParallel(String taskId) => setState(() {
        _parallelParentId = taskId;
        _subtaskParentId = null;
      });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final ws = app.ws;
        final event = ws.findEvent(eventId);
        if (event == null || event.deleted) {
          return Scaffold(
            appBar: AppBar(title: const Text('事件')),
            body: const Center(child: Text('这个事件已被删除')),
          );
        }

        final mainLine = ws.mainLineOf(eventId);
        final completion = ws.checkEventCompletion(eventId);

        return Scaffold(
          appBar: AppBar(
            title: Text(event.name, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) async {
                  switch (value) {
                    case 'archive':
                      final error = app.run(() => ws.setEventArchived(eventId, true));
                      if (!context.mounted) return;
                      if (error != null) {
                        showToast(context, error, error: true);
                        return;
                      }
                      showToast(context, '已归档，整条任务线一起归档');
                      Navigator.of(context).maybePop();
                      break;
                    case 'delete':
                      await _deleteEvent(context, event);
                      break;
                  }
                },
                itemBuilder: (_) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'archive', child: Text('归档（含任务线）')),
                  PopupMenuItem<String>(value: 'delete', child: Text('删除（含任务线）')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: <Widget>[
              _EventHeader(host: this, event: event, completion: completion),
              const SizedBox(height: 12),
              if (mainLine.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                  child: Text(
                    '这条任务线还是空的 —— 主线任务是同级兄弟链，沿主线依次向后排',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                for (var i = 0; i < mainLine.length; i += 1) ...<Widget>[
                  if (i > 0) const _VerticalConnector(),
                  _TaskBox(host: this, task: mainLine[i]),
                ],
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: InlineComposer(
                  label: '新建主线任务',
                  hint: '任务名',
                  onCreate: (title) => _createTask(title: title),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteEvent(BuildContext context, Event event) async {
    final taskCount = app.ws.allTasks.where((t) => t.eventId == event.id && !t.deleted).length;
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
    if (!context.mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    Navigator.of(context).maybePop();
  }
}

/// 事件自身：名字（页内可改）+ 三态 + 主线完成情况。
class _EventHeader extends StatelessWidget {
  const _EventHeader({required this.host, required this.event, required this.completion});

  final _EventDetailPageState host;
  final Event event;
  final CompletionCheck completion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = host.app;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('事件名', style: theme.textTheme.labelLarge),
            InlineTextField(
              value: event.name,
              hint: '事件名',
              textStyle: theme.textTheme.titleMedium,
              onSubmitted: (name) => app.run(() => app.ws.updateEvent(event.id, name: name)),
            ),
            const SizedBox(height: 6),
            Text(
              completion.judgedChildCount == 0
                  ? '主线还没有可判定的任务'
                  : '主线 ${completion.judgedChildCount - completion.unfinishedCount}'
                      '/${completion.judgedChildCount} 已完成'
                      '${completion.canComplete ? '（可以标记事件完成）' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<NodeStatus>(
              segments: <ButtonSegment<NodeStatus>>[
                for (final status in NodeStatus.values)
                  ButtonSegment<NodeStatus>(value: status, label: Text(nodeStatusLabel(status))),
              ],
              selected: <NodeStatus>{event.status},
              onSelectionChanged: (selection) {
                final error = app.run(() => app.ws.setEventStatus(event.id, selection.first));
                if (error != null) showToast(context, error, error: true);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 主线框之间的连线（表示"接着做这件事"）。
class _VerticalConnector extends StatelessWidget {
  const _VerticalConnector();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return SizedBox(
      height: 28,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(width: 2, height: 10, color: color),
              Icon(Icons.arrow_drop_down, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个任务节点框：自身 + 框内子任务 + （若有）并排的并列任务框。
class _TaskBox extends StatelessWidget {
  const _TaskBox({required this.host, required this.task, this.compact = false});

  final _EventDetailPageState host;
  final Task task;

  /// 并列框内使用：不显示进一步的并列分组（并列任务只能挂子任务）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = host.app;
    final eventId = host.eventId;
    final children = app.ws.subtasksOf(task.id, eventId: eventId);
    final subtasks = children.where((c) => c.taskType != TaskType.parallel).toList(growable: false);
    final parallels = children.where((c) => c.taskType == TaskType.parallel).toList(growable: false);
    final theme = Theme.of(context);
    final addingSubtask = host._subtaskParentId == task.id;
    final addingParallel = host._parallelParentId == task.id;

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TaskLine(host: host, task: task, indent: 0, childSummary: _summarize(children)),
          for (final subtask in subtasks)
            _TaskLine(host: host, task: subtask, indent: 1),
          if (addingSubtask)
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: InlineComposer(
                label: '新建子任务',
                hint: '子任务名',
                leading: Icons.subdirectory_arrow_right,
                dense: true,
                onCreate: (title) => host._createTask(
                  title: title,
                  parentTaskId: task.id,
                  type: TaskType.subtask,
                ),
              ),
            ),
          if (addingParallel)
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: InlineComposer(
                label: '新建并列任务',
                hint: '并列任务名',
                leading: Icons.call_split,
                dense: true,
                onCreate: (title) => host._createTask(
                  title: title,
                  parentTaskId: task.id,
                  type: TaskType.parallel,
                ),
              ),
            ),
          if (parallels.isNotEmpty && !compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.call_split, size: 14, color: theme.colorScheme.outline),
                      const SizedBox(width: 4),
                      Text('并列 ${parallels.length}', style: theme.textTheme.labelSmall),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (var i = 0; i < parallels.length; i += 1) ...<Widget>[
                          if (i > 0) const SizedBox(width: 8),
                          SizedBox(
                            width: 220,
                            child: _TaskBox(host: host, task: parallels[i], compact: true),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String? _summarize(List<Task> children) {
    if (children.isEmpty) return null;
    final done = children.where((c) => c.status == NodeStatus.done).length;
    return '下级 $done/${children.length}';
  }
}

/// 一行任务（框标题行或框内子任务行）。
class _TaskLine extends StatelessWidget {
  const _TaskLine({
    required this.host,
    required this.task,
    required this.indent,
    this.childSummary,
  });

  final _EventDetailPageState host;
  final Task task;
  final int indent;
  final String? childSummary;

  @override
  Widget build(BuildContext context) {
    final app = host.app;
    final theme = Theme.of(context);
    final due = describeDate(task.dueAt);
    final overdue = isOverdue(task.dueAt) && task.status == NodeStatus.pending;
    final done = task.status == NodeStatus.done;
    final summary = childSummary;

    if (host._renamingTaskId == task.id) {
      return Padding(
        padding: EdgeInsets.only(left: 12.0 + indent * 20, right: 12),
        child: InlineTextField(
          value: task.title,
          autofocus: true,
          hint: '任务名',
          textStyle: theme.textTheme.bodyMedium,
          onSubmitted: (title) => app.run(() => app.ws.updateTask(task.id, title: title)),
          onEditClosed: host.endRename,
        ),
      );
    }

    return ListTile(
      dense: indent > 0,
      contentPadding: EdgeInsets.only(left: 4.0 + indent * 20, right: 0),
      leading: TaskStatusButton(app: app, task: task),
      title: Row(
        children: <Widget>[
          if (indent > 0) ...<Widget>[
            Icon(Icons.subdirectory_arrow_right, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 2),
          ],
          Expanded(
            child: Text(
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
          ),
          if (task.taskType == TaskType.parallel)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.call_split, size: 14, color: theme.colorScheme.outline),
            ),
        ],
      ),
      subtitle: (due.isEmpty && summary == null)
          ? null
          : Row(
              children: <Widget>[
                if (due.isNotEmpty) ...<Widget>[
                  Icon(
                    Icons.event,
                    size: 13,
                    color: overdue ? theme.colorScheme.error : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    due,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: overdue ? theme.colorScheme.error : null),
                  ),
                ],
                if (due.isNotEmpty && summary != null) const SizedBox(width: 10),
                if (summary != null) Text(summary, style: theme.textTheme.labelSmall),
              ],
            ),
      trailing: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (value) async {
          await _run(context, value);
        },
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          for (final action in taskActions(task))
            PopupMenuItem<String>(value: action.value, child: Text(action.label)),
        ],
      ),
      onTap: () => _showActions(context),
    );
  }

  Future<void> _run(BuildContext context, String value) async {
    final app = host.app;
    switch (value) {
      // 新建与重命名不再弹对话框，改为把"页内输入框"在这一行附近展开
      case 'sub':
        host.beginSubtask(task.id);
        break;
      case 'par':
        host.beginParallel(task.id);
        break;
      case 'rename':
        host.beginRename(task.id);
        break;
      case 'due':
        await setTaskDueAction(context, app, task);
        break;
      case 'clearDue':
        await clearTaskDueAction(context, app, task);
        break;
      case 'move':
        await moveTaskToEventAction(context, app, task);
        break;
      case 'archive':
        await archiveTaskAction(context, app, task, archived: true);
        break;
      case 'unarchive':
        await archiveTaskAction(context, app, task, archived: false);
        break;
      case 'delete':
        await deleteTaskAction(context, app, task);
        break;
    }
  }

  Future<void> _showActions(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      // 任务的动作项会随类型变化（最多 7 项），固定高度的弹层在高分屏 / 大字体下会溢出，
      // 所以这里让弹层可以长高，同时内部用可滚动的 ListView 兜底。
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(task.title, style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final action in taskActions(task))
              ListTile(
                leading: Icon(action.icon),
                title: Text(action.label),
                onTap: () => Navigator.of(sheetContext).pop(action.value),
              ),
          ],
        ),
      ),
    );
    if (value == null || !context.mounted) return;
    await _run(context, value);
  }
}

/// 一条任务可用的动作（弹出菜单与底部面板共用同一份）。
class TaskAction {
  const TaskAction(this.value, this.label, this.icon);

  final String value;
  final String label;
  final IconData icon;
}

List<TaskAction> taskActions(Task task) {
  final actions = <TaskAction>[];
  if (task.taskType != TaskType.subtask) {
    actions.add(const TaskAction('sub', '新建子任务', Icons.subdirectory_arrow_right));
  }
  if (task.taskType == TaskType.standard) {
    actions.add(const TaskAction('par', '新建并列任务', Icons.call_split));
  }
  actions.add(const TaskAction('rename', '重命名', Icons.edit_outlined));
  actions.add(TaskAction('due', task.dueAt == null ? '设到期日' : '改到期日', Icons.event_outlined));
  if (task.dueAt != null) {
    actions.add(const TaskAction('clearDue', '清除到期日', Icons.event_busy_outlined));
  }
  actions.add(const TaskAction('move', '移到其它事件…', Icons.swap_horiz));
  actions.add(
    task.archived
        ? const TaskAction('unarchive', '取消归档', Icons.unarchive_outlined)
        : const TaskAction('archive', '归档（含子任务）', Icons.archive_outlined),
  );
  actions.add(const TaskAction('delete', '删除（含子任务）', Icons.delete_outline));
  return actions;
}
