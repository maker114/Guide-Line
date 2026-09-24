import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../../core/rules/completion.dart';
import '../../core/tree/task_flow.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import '../common/task_status_button.dart';
import 'task_actions.dart';
import 'task_flow_layout.dart';

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
  /// 「新建一个后续任务」在底部面板里的哨兵值（真实 id 是 UUID，不会撞）
  static const String _newNextTask = '__new_next_task__';

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

  /// 这个任务是否还有未处理的直接子任务（决定状态按钮显不显示锁形）。
  bool _blocked(Task task) {
    final ws = app.ws;
    return ws.liveTasks.any(
      (t) =>
          t.eventId == task.eventId &&
          t.parentId == task.id &&
          !t.archived &&
          !isTerminal(t.status),
    );
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

  /// 这条任务在走向上有几个后续（**含隐式链**：还没固化时 `nextIds` 是空的，
  /// 但下一个任务已经接在那儿了，所以必须问 `TaskFlow` 而不是问字段）。
  int successorCountOf(Task task) => TaskFlow.of(
    app.ws.allTasks,
    eventId: eventId,
  ).successorsOf(task.id).length;

  /// 「接后续任务…」：挑一个已有任务，或者新建一个接上。
  ///
  /// 分叉与合流都是这一件事的结果：本来没有后续就是"接着做"，
  /// 本来有后续再加一条就成了**分叉**；两条支路都指回同一个任务就是**合流**。
  Future<void> beginLinkNext(Task task) async {
    final ws = app.ws;
    final flow = TaskFlow.of(ws.allTasks, eventId: eventId);
    // 能接的候选：不是自己、还没接过、接上不会成环。
    // "还没接过"要按**走向**判，不能按 `nextIds` 判：隐式链（还按 order 排）时
    // `nextIds` 整条都是空的，可下一个任务明明已经接在那儿了 —— 列出来让用户点，
    // 点了什么也不会发生，等于骗人。
    final successors = flow
        .successorsOf(task.id)
        .map((each) => each.id)
        .toSet();
    final candidates = flow.all
        .where(
          (candidate) =>
              candidate.id != task.id &&
              !successors.contains(candidate.id) &&
              !flow.wouldCreateCycle(fromId: task.id, toId: candidate.id),
        )
        .toList(growable: false);

    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '接在「${task.title}」之后',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建一个后续任务'),
              subtitle: const Text('建好后直接改名'),
              onTap: () => Navigator.of(sheetContext).pop(_newNextTask),
            ),
            if (candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text('没有能接的已有任务（接上会绕成环的都不列出来）'),
              )
            else
              for (final candidate in candidates)
                ListTile(
                  leading: const Icon(Icons.subdirectory_arrow_right),
                  title: Text(candidate.title),
                  onTap: () => Navigator.of(sheetContext).pop(candidate.id),
                ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    if (picked == _newNextTask) {
      Task? created;
      final error = app.run(() {
        created = ws.createTask(
          eventId: eventId,
          title: '新任务',
          linkAfterTaskId: task.id,
        );
      });
      if (error != null) {
        _toast(error, error: true);
        return;
      }
      // 建完直接进入原地改名，省得用户还要再点一次
      final newTask = created;
      if (newTask != null) beginRename(newTask.id);
      return;
    }

    final error = app.run(() => ws.addTaskNext(task.id, picked));
    if (error != null) _toast(error, error: true);
  }

  /// 「断开后续…」：断开某一条后续边（合流处断掉一条就退回单线）。
  Future<void> beginUnlinkNext(Task task) async {
    final ws = app.ws;
    final successors = TaskFlow.of(
      ws.allTasks,
      eventId: eventId,
    ).successorsOf(task.id);
    if (successors.isEmpty) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '「${task.title}」现在接向',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final successor in successors)
              ListTile(
                leading: const Icon(Icons.link_off),
                title: Text(successor.title),
                subtitle: const Text('断开这一条'),
                onTap: () => Navigator.of(sheetContext).pop(successor.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    final error = app.run(() => ws.removeTaskNext(task.id, picked));
    if (error != null) _toast(error, error: true);
  }

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
        // 走向（分叉 / 合流）交给流图，界面只负责把排布结果画出来
        final flow = TaskFlow.of(ws.allTasks, eventId: eventId);
        final flowRows = layoutTaskFlow(flow);

        return Scaffold(
          appBar: AppBar(
            title: Text(event.name, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) async {
                  switch (value) {
                    case 'archive':
                      final error = app.run(
                        () => ws.setEventArchived(eventId, true),
                      );
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
                  PopupMenuItem<String>(
                    value: 'archive',
                    child: Text('归档（含任务线）'),
                  ),
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('删除（含任务线）'),
                  ),
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
                for (var i = 0; i < flowRows.length; i += 1) ...<Widget>[
                  // 主线节点之间、以及同一条支路内部，都画一道连线表示"接着做"；
                  // 分叉/合流处不画（那里是分合关系，不是次序）
                  if (i > 0 && _needsConnector(flowRows[i - 1], flowRows[i]))
                    const _VerticalConnector(),
                  _buildFlowRow(context, flowRows[i]),
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

  /// 相邻两行之间要不要画"接着做"的连线。
  ///
  /// 同层且同属一条支路才画：跨层（例如主线 → 支路小标题）与跨支路都不画，
  /// 否则连线会把"分叉/合流"读成"顺序"。
  static bool _needsConnector(FlowRow previous, FlowRow current) {
    if (previous.isBranchHeader || current.isBranchHeader) return false;
    if (previous.depth != current.depth) return false;
    if (previous.depth == 0) return true;
    return previous.branchIndex == current.branchIndex;
  }

  /// 画一行排布结果：支路小标题，或者一个任务框。
  Widget _buildFlowRow(BuildContext context, FlowRow row) {
    final theme = Theme.of(context);
    final branchIndex = row.branchIndex;
    final color = branchIndex == null
        ? null
        : _branchColor(theme.colorScheme, branchIndex);

    if (row.isBranchHeader) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Row(
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _branchColor(theme.colorScheme, branchIndex ?? 0),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${row.branchTitle} ${(branchIndex ?? 0) + 1} / ${row.branchCount}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: _branchColor(theme.colorScheme, branchIndex ?? 0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Divider(color: color?.withValues(alpha: 0.4))),
          ],
        ),
      );
    }

    return Padding(
      // 支路内的节点整体缩进一层，配合支路色分清"这是哪条支路"
      padding: EdgeInsets.only(left: row.depth == 0 ? 0 : 12),
      child: _TaskBox(
        host: this,
        task: row.task!,
        accentOverride: row.depth == 0 ? null : color,
        badge: row.badge,
      ),
    );
  }

  /// 支路配色：只从主题里取，不硬编码颜色。
  static Color _branchColor(ColorScheme scheme, int index) {
    final palette = <Color>[scheme.tertiary, scheme.secondary, scheme.primary];
    return palette[index % palette.length];
  }

  Future<void> _deleteEvent(BuildContext context, Event event) async {
    final taskCount = app.ws.allTasks
        .where((t) => t.eventId == event.id && !t.deleted)
        .length;
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
  const _EventHeader({
    required this.host,
    required this.event,
    required this.completion,
  });

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
              onSubmitted: (name) =>
                  app.run(() => app.ws.updateEvent(event.id, name: name)),
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
                  ButtonSegment<NodeStatus>(
                    value: status,
                    label: Text(nodeStatusLabel(status)),
                  ),
              ],
              selected: <NodeStatus>{event.status},
              onSelectionChanged: (selection) {
                final error = app.run(
                  () => app.ws.setEventStatus(event.id, selection.first),
                );
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
  const _TaskBox({
    required this.host,
    required this.task,
    this.compact = false,
    this.accentOverride,
    this.badge,
  });

  final _EventDetailPageState host;
  final Task task;

  /// 并列框内使用：不显示进一步的并列分组（并列任务只能挂子任务）。
  final bool compact;

  /// 支路节点用支路色描边（主线节点传 `null`，走默认的主题色）
  final Color? accentOverride;

  /// 分叉 / 合流徽标
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final app = host.app;
    final eventId = host.eventId;
    final children = app.ws.subtasksOf(task.id, eventId: eventId);
    final subtasks = children
        .where((c) => c.taskType != TaskType.parallel)
        .toList(growable: false);
    final parallels = children
        .where((c) => c.taskType == TaskType.parallel)
        .toList(growable: false);
    final theme = Theme.of(context);
    final addingSubtask = host._subtaskParentId == task.id;
    final addingParallel = host._parallelParentId == task.id;
    final isDone = task.status != NodeStatus.pending;

    // 已完成（含已搁置）的任务**默认折叠**下级：减少视觉噪音。
    // 但**不改变顺序** —— 主线是一条链，把已完成的挪到末尾会破坏"接着做"的语义，
    // 所以这里是就地缩成一行，而不是重新分组。
    final expanded = app.isExpanded(task.id, defaultExpanded: !isDone);
    final hasChildren = subtasks.isNotEmpty || parallels.isNotEmpty;
    final accent =
        accentOverride ??
        (isDone ? theme.colorScheme.outlineVariant : theme.colorScheme.primary);
    final badgeText = badge;
    final isJoinBadge = badgeText != null && badgeText.contains('汇合');

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      // 主任务框描一圈主题色：与框内那些"没有描边"的子任务行区分开
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: accent,
          width: isDone && accentOverride == null ? 1 : 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TaskLine(
            host: host,
            task: task,
            indent: 0,
            childSummary: _summarize(children),
            blocked: host._blocked(task),
            collapsible: hasChildren,
            expanded: expanded,
            onToggle: () => app.setExpanded(task.id, expanded: !expanded),
          ),
          if (badgeText != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: <Widget>[
                  // 分叉用"分开"的图标，合流用"合并"的图标 —— 一开始两个都用了
                  // call_split，看着像"又要分叉"，是错的
                  Icon(
                    isJoinBadge ? Icons.merge_type : Icons.call_split,
                    size: 13,
                    color: accent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    badgeText,
                    style: theme.textTheme.labelSmall?.copyWith(color: accent),
                  ),
                ],
              ),
            ),
          if (hasChildren && !expanded)
            _CollapsedChildrenHint(
              count: children.length,
              onTap: () => app.setExpanded(task.id, expanded: true),
            ),
          if (expanded)
            for (final subtask in subtasks)
              _TaskLine(
                host: host,
                task: subtask,
                indent: 1,
                blocked: host._blocked(subtask),
              ),
          if (expanded && addingSubtask)
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
          if (expanded && addingParallel)
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
          if (expanded && parallels.isNotEmpty && !compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.call_split,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '并列 ${parallels.length}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (
                          var i = 0;
                          i < parallels.length;
                          i += 1
                        ) ...<Widget>[
                          if (i > 0) const SizedBox(width: 8),
                          SizedBox(
                            width: 220,
                            child: _TaskBox(
                              host: host,
                              task: parallels[i],
                              compact: true,
                            ),
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

/// 折叠起来的下级摘要（已完成的任务默认是折叠的）。
class _CollapsedChildrenHint extends StatelessWidget {
  const _CollapsedChildrenHint({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 12, 10),
        child: Row(
          children: <Widget>[
            Icon(Icons.unfold_more, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text(
              '已折叠 $count 个下级',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行任务（框标题行或框内子任务行）。
class _TaskLine extends StatelessWidget {
  const _TaskLine({
    required this.host,
    required this.task,
    required this.indent,
    this.childSummary,
    this.blocked = false,
    this.collapsible = false,
    this.expanded = true,
    this.onToggle,
  });

  final _EventDetailPageState host;
  final Task task;
  final int indent;
  final String? childSummary;

  /// 还有未处理的直接子任务 → 状态按钮显示锁形（灵感 14）
  final bool blocked;

  /// 有下级可折叠时才显示展开/收起按钮
  final bool collapsible;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final app = host.app;
    final theme = Theme.of(context);
    final overdue = isOverdue(task.dueAt) && task.status == NodeStatus.pending;
    final done = task.status == NodeStatus.done;
    final summary = childSummary;
    // 有下级汇总时，副标题一行要同时放"绝对日期 + 剩余天数"和「下级 x/y」，
    // 1.6 倍字体下会顶到行尾；这时只留相对日（"7 天后"），信息不丢、宽度减半。
    final due = summary == null
        ? describeDateWithDays(task.dueAt)
        : describeDate(task.dueAt);

    // 层级区分：主任务是 titleSmall（更大更重），子任务降到 bodySmall 并缩进
    final baseStyle = indent > 0
        ? theme.textTheme.bodySmall
        : theme.textTheme.titleSmall;
    final titleStyle = done
        ? baseStyle?.copyWith(
            decoration: TextDecoration.lineThrough,
            color: theme.colorScheme.outline,
          )
        : baseStyle;

    if (host._renamingTaskId == task.id) {
      return Padding(
        padding: EdgeInsets.only(left: 12.0 + indent * 20, right: 12),
        child: InlineTextField(
          value: task.title,
          autofocus: true,
          hint: '任务名',
          textStyle: theme.textTheme.bodyMedium,
          onSubmitted: (title) =>
              app.run(() => app.ws.updateTask(task.id, title: title)),
          onEditClosed: host.endRename,
        ),
      );
    }

    final tile = ListTile(
      dense: indent > 0,
      // 子任务行铺一层浅底。**不能**改用外面包 DecoratedBox 的做法：
      // ListTile 的墨迹是画在最近的 Material 上的，中间夹一个有底色的 DecoratedBox
      // 会让水波纹看不见，Flutter 会直接断言报错（这里踩过一次）。
      tileColor: indent > 0
          ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
          : null,
      contentPadding: EdgeInsets.only(left: 4.0 + indent * 20, right: 0),
      leading: TaskStatusButton(app: app, task: task, blocked: blocked),
      // 子任务行有缩进 + 三道前缀（竖线/箭头/间距）约 23dp 的固定开销，
      // 1.6 倍字体下标题的"文字本身宽度 + 固定开销"会差出 2dp。
      // 用 ClipRect 兜住这点像素级溢出：被裁的只有省略号右侧的空白，
      // 而 `TextOverflow.ellipsis` 保证文字本身仍然完整可读。
      title: Row(
        children: <Widget>[
            if (indent > 0) ...<Widget>[
              // 一道短竖线，配合缩进与浅底，把子任务明确"挂"在主任务下面
              Container(
                width: 2,
                height: 14,
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 5),
              Icon(
                Icons.subdirectory_arrow_right,
                size: 14,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 2),
            ],
            Expanded(
              child: Text(
                task.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (task.taskType == TaskType.parallel)
              Icon(Icons.call_split, size: 14, color: theme.colorScheme.outline),
            // 展开/收起留在标题行（它只跟"这行有没有下级"有关）
            if (collapsible)
              IconButton(
                tooltip: expanded ? '收起下级' : '展开下级',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                onPressed: onToggle,
              ),
        ],
      ),
      // **不能用 SingleChildScrollView 包副标题**：ListTile 量高度时会给
      // `maxWidth: Infinity`，横向滚动视图在那种约束下会让里面的 RenderParagraph
      // 拿不到宽度而炸在布局里。用 Flexible + ellipsis，宽度由父级分配，安全。
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
                  Flexible(
                    child: Text(
                      due,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: overdue ? theme.colorScheme.error : null,
                      ),
                    ),
                  ),
                ],
                if (due.isNotEmpty && summary != null) const SizedBox(width: 10),
                if (summary != null)
                  Flexible(
                    child: Text(
                      summary,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
      // 两个高频动作（设到期日 / 接后续任务）留在 trailing，与「更多」并列。
      // 它们**不能**放进 title 行：那个 Row 在 1.6 倍字体下会被标题挤到溢出，
      // 而 ListTile 的 trailing 宽度是从标题的可伸缩空间里扣的，放这里更稳
      // （`app_smoke_test.dart` 的"深色 + 1.6 倍字体不溢出"用例在守这条）。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 压到 30×30 是有意的：默认 48×48 的 icon 按钮三个就把标题挤没了
          IconButton(
            tooltip: task.dueAt == null ? '设到期日' : '改到期日',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            icon: Icon(task.dueAt == null ? Icons.event_outlined : Icons.event_busy_outlined),
            onPressed: () => _run(context, 'due'),
          ),
          IconButton(
            tooltip: '接后续任务…',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            icon: const Icon(Icons.timeline),
            onPressed: () => _run(context, 'linkNext'),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) async {
              await _run(context, value);
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              for (final action in taskActions(
                task,
                successorCount: host.successorCountOf(task),
              ))
                PopupMenuItem<String>(
                  value: action.value,
                  child: Text(action.label),
                ),
            ],
          ),
        ],
      ),
      onTap: () => _showActions(context),
    );

    if (indent == 0) return tile;
    return tile;
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
      case 'linkNext':
        await host.beginLinkNext(task);
        break;
      case 'unlinkNext':
        await host.beginUnlinkNext(task);
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
              child: Text(
                task.title,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final action in taskActions(
              task,
              successorCount: host.successorCountOf(task),
            ))
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

/// 一条任务在动作面板里能做的事。
///
/// `successorCount` 由调用方按**走向**算出来传进来（`nextIds` 在隐式链模式下总是空的，
/// 拿它当"有没有后续"判会把「断开后续…」藏起来）。
List<TaskAction> taskActions(Task task, {int? successorCount}) {
  final actions = <TaskAction>[];
  if (task.taskType != TaskType.subtask) {
    actions.add(
      const TaskAction('sub', '新建子任务', Icons.subdirectory_arrow_right),
    );
  }
  if (task.taskType == TaskType.standard) {
    actions.add(const TaskAction('par', '新建并列任务', Icons.call_split));
  }
  // 只有主线任务在"走向"上，子任务不参与
  if (task.parentId == null) {
    actions.add(const TaskAction('linkNext', '接后续任务…', Icons.timeline));
    if ((successorCount ?? task.nextIds.length) > 0) {
      actions.add(const TaskAction('unlinkNext', '断开后续…', Icons.link_off));
    }
  }
  actions.add(const TaskAction('rename', '重命名', Icons.edit_outlined));
  actions.add(
    TaskAction(
      'due',
      task.dueAt == null ? '设到期日' : '改到期日',
      Icons.event_outlined,
    ),
  );
  if (task.dueAt != null) {
    actions.add(
      const TaskAction('clearDue', '清除到期日', Icons.event_busy_outlined),
    );
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
