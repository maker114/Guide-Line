import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../../core/rules/completion.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import '../common/status_selector.dart';
import '../common/task_status_button.dart';
import '../theme/shape_tokens.dart';
import 'fold_toggle_row.dart';
import 'task_actions.dart';
import 'task_fold.dart';

/// 展开 / 收起箭头的旋转时长（与项目页、事件页同一个节奏）。
const Duration _foldDuration = Duration(milliseconds: 180);

/// 事件详情：**一条任务线的可视化**。
///
/// 渲染规则（设计文档 4.9 / ADR-036 / ADR-053）：
///   · `standard` —— 独立节点框，沿链路**纵向串联**（框间有连线，表示"接着做"）；
///   · `subtask`  —— 渲染在父节点**框内**并缩进（叶子，无子节点）。
///
/// 这里删掉过「支路 / 分叉点 / 合流点」那一整套渲染（以及支撑它的走向边）：
/// 一条线就是一件事的脉络，节点一个接一个往下走 —— 不用先学一套图的概念。
/// 老文件里若还有 `parallel` 之类的历史类型，同样**按子任务的样子渲染**。
///
/// 新建与重命名都是**页面内直接输入**：主线在任务线末尾，子任务在各自的框内，
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

  /// 正在为哪个任务录子任务
  String? _subtaskParentId;

  /// 是否把**自动收起的已完成节点**全部展开（临时状态，不进偏好）。
  ///
  /// 自动收起规则本身见 `task_fold.dart`；这里只负责"我需要时能再看回来"
  /// （实机反馈：折是折对了，可是想看的时候没地方点）。
  bool _showAllFolded = false;

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
      setState(() => _subtaskParentId = null);
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

  void beginSubtask(String taskId) => setState(() => _subtaskParentId = taskId);

  /// 这条任务是不是**链上的节点**（parent_task_id == null）。
  bool isInMainLine(Task task) => task.parentId == null;

  /// 把某个主线节点在链上挪一格（上移 / 下移）。
  ///
  /// 任务线是一条链，顺序就是 `order`；分叉 / 合流那套已经删掉了（见 `Task`），
  /// 所以"调整先后"只剩下这一件事。
  void moveInLine(String taskId, {required bool up}) {
    final error = app.run(() => app.ws.moveTaskWithinLine(taskId, up: up));
    if (error != null) _toast(error, error: true);
  }

  /// 选事件标识色（`null` = 取消，`''` = 明确不要颜色）。
  Future<void> _pickColor(BuildContext context, Event event) async {
    final picked = await pickEventColor(context, current: event.color);
    if (picked == null || !context.mounted) return;
    _setColor(context, event, picked.isEmpty ? null : picked);
  }

  void _setColor(BuildContext context, Event event, String? value) {
    final error = app.run(() => app.ws.setEventColor(event.id, value));
    if (error != null && context.mounted) showToast(context, error, error: true);
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
        // 「已完成的老节点自动收起」：只留**当前节点的上一个节点**
        // （实机反馈：做完的任务一多，任务线就长得看不清现在做到哪了）
        final autoFoldedIds = autoFoldedMainLineIds(
          mainLine,
          // 用户手动展开过的**不折**（显式选择优先于自动规则）
          userExpanded: (id) =>
              app.isExpanded(id, defaultExpanded: false) &&
              app.ws.prefs.expandedIds.contains(id),
        );
        // 用户按了"展开"就全画出来：自动收起是默认视图，不是不可逾越的规则
        final foldedIds = _showAllFolded ? const <String>{} : autoFoldedIds;

        return Scaffold(
          appBar: AppBar(
            // 标题旁立一根事件标识色的竖条（与项目详情页同一个控件、同一套系统）
            title: Row(
              children: <Widget>[
                ProjectColorBar(color: event.color, height: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(event.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            actions: <Widget>[
              // 标识色入口：与项目详情页那个调色板图标一致
              IconButton(
                tooltip: event.color == null
                    ? '标识色：点一下选'
                    : '标识色 ${event.color}（长按清除）',
                icon: Icon(
                  Icons.palette_outlined,
                  color: colorOfHex(event.color) ?? Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                onPressed: () => _pickColor(context, event),
                onLongPress: event.color == null ? null : () => _setColor(context, event, null),
              ),
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
                    '这条任务线还是空的 —— 一条线就是一件事的脉络，一个节点接着一个节点往下走',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else ...<Widget>[
                // 折叠开关放在任务线最上面：被收起来的节点就在它下面
                if (autoFoldedIds.isNotEmpty)
                  FoldToggleRow(
                    hiddenCount: autoFoldedIds.length,
                    expanded: _showAllFolded,
                    onTap: () => setState(() => _showAllFolded = !_showAllFolded),
                  ),
                for (var i = 0; i < mainLine.length; i += 1)
                  // 被自动收起的已完成老节点：不画它、也不画它前面那条连线
                  if (!foldedIds.contains(mainLine[i].id)) ...<Widget>[
                    // 相邻节点之间画一道连线，表示"接着做"
                    if (i > 0 && !foldedIds.contains(mainLine[i - 1].id))
                      const _VerticalConnector(),
                    // 每个节点框按 id 认身份：展开 / 收起自动收起的节点时，后面的框
                    // 会整体往上挪，按位置错配就会把它们行内的动画重放一遍（实机反馈）
                    KeyedSubtree(
                      key: ValueKey<String>('node-${mainLine[i].id}'),
                      child: _TaskBox(host: this, task: mainLine[i]),
                    ),
                  ],
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
            // 与项目详情页同一个控件：胶囊里套小胶囊、无分割线
            StatusPillSelector<NodeStatus>(
              values: NodeStatus.values,
              selected: event.status,
              labelOf: nodeStatusLabel,
              onSelected: (status) {
                final error = app.run(() => app.ws.setEventStatus(event.id, status));
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

/// 一个任务节点框：自身 + 框内的下级任务。
///
/// 框内的行**不区分类型**：新数据里只会有 `subtask`；老数据里可能还有 `parallel`
/// （已废除的框内并列），同样按子任务的样子排在框里 —— 信息不丢，也不再为它
/// 维护一套并排渲染。
class _TaskBox extends StatelessWidget {
  const _TaskBox({required this.host, required this.task});

  final _EventDetailPageState host;
  final Task task;

  @override
  Widget build(BuildContext context) {
    final app = host.app;
    final eventId = host.eventId;
    // 框内的下级：新数据只有子任务；老数据里的 `parallel` 也排在这儿
    final children = app.ws.subtasksOf(task.id, eventId: eventId);
    final theme = Theme.of(context);
    final addingSubtask = host._subtaskParentId == task.id;
    final isDone = task.status != NodeStatus.pending;

    // 已完成（含已搁置）的任务**默认折叠**下级：减少视觉噪音。
    // 但**不改变顺序** —— 主线是一条链，把已完成的挪到末尾会破坏"接着做"的语义，
    // 所以这里是就地缩成一行，而不是重新分组。
    final expanded = app.isExpanded(task.id, defaultExpanded: !isDone);
    final hasChildren = children.isNotEmpty;
    final accent =
        isDone ? theme.colorScheme.outlineVariant : theme.colorScheme.primary;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      // 主任务框描一圈主题色：与框内那些"没有描边"的子任务行区分开。
      // 形状取 `shape_tokens` 的卡片档，不再就地写 `circular(12)`（《界面规范》§2）。
      shape: AppShapes.card.copyWith(
        side: BorderSide(color: accent, width: isDone ? 1 : 1.4),
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
          if (hasChildren && !expanded)
            _CollapsedChildrenHint(
              count: children.length,
              onTap: () => app.setExpanded(task.id, expanded: true),
            ),
          if (expanded)
            for (final child in children)
              KeyedSubtree(
                key: ValueKey<String>('child-${child.id}'),
                child: _TaskLine(
                  host: host,
                  task: child,
                  indent: 1,
                  blocked: host._blocked(child),
                ),
              ),
          // 正在录下级时**不受折叠状态影响**：已完成 / 已搁置的任务默认是折叠的，
          // 如果这里再串上 `expanded`，「点新建子任务」就会什么都不发生 ——
          // 用户只会觉得"这个功能坏了"（实测复现过一次）。
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
            // 展开/收起留在标题行（它只跟"这行有没有下级"有关）
            if (collapsible)
              IconButton(
                tooltip: expanded ? '收起下级' : '展开下级',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                // 箭头**转过去**而不是换图标（与项目页 / 事件页同一个节奏）：
                // `expand_more` 朝下，展开时翻 180° 变成朝上
                icon: AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: _foldDuration,
                  curve: Curves.easeOutCubic,
                  child: const Icon(Icons.expand_more),
                ),
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
      // 行内只留**两个图标**（按实机反馈，去掉行尾的三个点）：
      //   · 日期图标 —— 点一下设/改到期日，**长按清除**；
      //   · 折线图标 —— 弹出这个节点的族内动作（新建子任务 / 接后续 / 断开后续）。
      // 其余动作（重命名 / 移动 / 归档 / 删除）由**点这一行**弹出的动作面板承接，
      // 所以不需要再有一个"更多"菜单。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 压到 30×30 是有意的：默认 48×48 的按钮几个就把标题挤没了
          _TaskIcon(
            tooltip: task.dueAt == null
                ? '设到期日'
                : '到期 ${task.dueAt}（长按清除）',
            icon: task.dueAt == null ? Icons.event_outlined : Icons.event_available_outlined,
            color: overdue ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            clearable: task.dueAt != null,
            onTap: () => _run(context, 'due'),
            onLongPress: task.dueAt == null ? null : () => _run(context, 'clearDue'),
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
      case 'rename':
        host.beginRename(task.id);
        break;
      case 'moveUp':
        host.moveInLine(task.id, up: true);
        break;
      case 'moveDown':
        host.moveInLine(task.id, up: false);
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
            for (final action in taskActions(task, inLine: host.isInMainLine(task)))
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

/// 任务行上的一个小图标按钮：**有值时右下角带个小叉**，长按可清除。
///
/// 与项目详情页的日期图标是同一套交互（那里叫 `_ClearableIcon`）——
/// "点一下改、长按清"在两处保持一致，不然用户得分别记。
class _TaskIcon extends StatelessWidget {
  const _TaskIcon({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.clearable,
    required this.onTap,
    this.onLongPress,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final bool clearable;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Icon(icon, size: 20, color: color),
              if (clearable)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close, size: 10, color: theme.colorScheme.outline),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条任务在动作面板里能做的事。
///
/// [inLine] 为真表示这条任务在**主线上**（`parent_task_id == null`）：
/// 只有链上的节点才谈得上"往上 / 往下挪一格"。子任务不参与顺序。
///
/// 「接后续任务…」「新建后续节点」「断开后续…」三个入口已经删掉 ——
/// 它们服务的是分叉 / 合流那套建模，现在一条线就是一条链，加节点只有
/// 末尾那个「新建主线任务」一条路（顺序用上移 / 下移调）。
List<TaskAction> taskActions(Task task, {bool inLine = false}) {
  final actions = <TaskAction>[];
  if (task.taskType != TaskType.subtask) {
    actions.add(
      const TaskAction('sub', '新建子任务', Icons.subdirectory_arrow_right),
    );
  }
  actions.add(const TaskAction('rename', '重命名', Icons.edit_outlined));
  if (inLine) {
    actions.add(const TaskAction('moveUp', '往上挪一格', Icons.arrow_upward));
    actions.add(const TaskAction('moveDown', '往下挪一格', Icons.arrow_downward));
  }
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
