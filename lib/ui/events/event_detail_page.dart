import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/due_label.dart';
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

/// 详情页里**任务线那一段**的 key（测试用；界面上看不见）。
///
/// 为什么需要它：这一页除了任务线，顶上那张卡里也有文字，任务线的断言收在
/// 这个 key 里就不用担心别处也出现同名字样（`find.descendant(of: find.byKey(eventDetailLineKey), …)`）。
const Key eventDetailLineKey = Key('event-detail-line');

/// 事件详情：**一条任务线的可视化**。
///
/// 渲染规则（ADR-036 / ADR-053）：
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
///
/// **事件名不在这里改**（标题栏已经写着事件名了，正文再放一遍是重复 ——
/// 与项目详情页同一条裁定）：改名收在标题右侧的 ⋮ 里，点「重命名」之后
/// **标题栏原地变成输入框**。
///
/// 顶上那张卡只回答"这条线走到哪了"（进度 + 三态）。**没有**"最近到期 / 接下来
/// 做什么"这一类摘要：做过一版（叫「时间与任务」）并装到真机，实机反馈"不好看"，
/// 整块撤掉了（见 CHANGELOG 1.5.0）。
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

  /// 标题栏是否处于"改名字"状态（与项目详情页同一套做法）。
  bool _renaming = false;

  final TextEditingController _titleController = TextEditingController();

  /// 正在原地重命名的任务 id
  String? _renamingTaskId;

  /// 正在为哪个任务录子任务
  String? _subtaskParentId;

  /// 是否把**自动收起的已完成节点**全部展开（临时状态，不进偏好）。
  ///
  /// 自动收起规则本身见 `task_fold.dart`；这里只负责"我需要时能再看回来"
  /// （实机反馈：折是折对了，可是想看的时候没地方点）。
  bool _showAllFolded = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  /// 进改名态：**全选原名**，长名字不用先删一遍（与项目详情页一致）。
  void _startRename(Event event) {
    _titleController
      ..text = event.name
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: event.name.length,
      );
    setState(() => _renaming = true);
  }

  void _cancelRename() => setState(() => _renaming = false);

  /// 提交改名。**空名字不提交、保持原名** —— 与 `InlineTextField` 同一条约定
  /// （必填项被清空时不能把标题清没）。
  void _commitRename(Event event) {
    final next = _titleController.text.trim();
    setState(() => _renaming = false);
    if (next.isEmpty || next == event.name) return;
    final error = app.run(() => app.ws.updateEvent(event.id, name: next));
    if (error != null) _toast(error, error: true);
  }

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

  /// 这个事件下**已归档的主线节点**有几个（只在任务线为空时用来解释"为什么空"）。
  int _archivedMainLineCount() => app.ws.liveTasks
      .where((t) => t.eventId == eventId && t.parentId == null && t.archived)
      .length;

  /// 这个任务是否还有未处理的直接子任务（决定状态按钮显不显示锁形）。
  ///
  /// 与任务线里那个「下级 d/t」**同一套取数**（Q18）：两处都排除已归档的子任务 ——
  /// 以前这里自己筛一遍、`_summarize` 数的是另一次取数，同一个框里"能不能勾"
  /// 与"下级 1/3"能对不上。
  bool _blocked(Task task) => app.ws.isTaskBlocked(task.id);

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
            // 改名态：标题栏**原地变成输入框**（与项目详情页同一套交互）
            title: _renaming
                ? TextField(
                    controller: _titleController,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    style: Theme.of(context).textTheme.titleLarge,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '事件名',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _commitRename(event),
                  )
                // 平时：标题旁立一根事件标识色的竖条（与项目详情页同一个控件、同一套系统）
                : Row(
                    children: <Widget>[
                      ProjectColorBar(color: event.color, height: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(event.name, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
            actions: _renaming
                ? <Widget>[
                    IconButton(
                      tooltip: '取消',
                      icon: const Icon(Icons.close),
                      onPressed: _cancelRename,
                    ),
                    IconButton(
                      tooltip: '保存',
                      icon: const Icon(Icons.check),
                      onPressed: () => _commitRename(event),
                    ),
                  ]
                : <Widget>[
                    // 标识色入口：与项目详情页那个调色板图标一致
                    IconButton(
                      tooltip: event.color == null
                          ? '标识色：点一下选'
                          : '标识色 ${event.color}，长按可清除',
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
                          case 'rename':
                            _startRename(event);
                            break;
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
                        // 事件名只在标题栏改（正文不再摆一份，见类文档）
                        PopupMenuItem<String>(
                          value: 'rename',
                          child: Text('重命名'),
                        ),
                        PopupMenuItem<String>(
                          value: 'archive',
                          child: Text('归档整条任务线'),
                        ),
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('删除整条任务线'),
                        ),
                      ],
                    ),
                  ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: <Widget>[
              // 事件自身的状态与进度
              _EventHeader(host: this, event: event),
              const SizedBox(height: 12),
              if (mainLine.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                  child: Text(
                    // 「空了」有两种（Q18）：新事件确实没任务，和节点全被归档了。
                    // 已归档节点不再画在任务线上，所以后者必须说清去哪找回。
                    _archivedMainLineCount() > 0
                        ? '这条线的 ${_archivedMainLineCount()} 个主线节点都已归档，'
                            '去「归档区 → 已归档」取消归档'
                        : '还没有主线任务',
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
                // 任务线整体挂一个 key（`eventDetailLineKey`）：界面测试要能
                // "只看任务线"地断言 —— 上面那张卡里的「接下来」会把当前节点的
                // 标题再写一遍，按全屏 count 去数就会数出两个。
                Column(
                  key: eventDetailLineKey,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
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
                ),
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
          : '「${event.name}」及其整条任务线共 $taskCount 个任务会被一起删除。'
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

/// 事件自身：三态 + 主线完成情况。
///
/// **没有名字字段**：名字在标题栏（改名走标题栏的 ⋮ →「重命名」），
/// 正文再放一遍只是把同一句话写两次。
///
/// 也**没有**"最近到期 / 接下来做什么"：那一版（「时间与任务」）做完实机反馈不满意，
/// 整块撤掉了（见 CHANGELOG 1.5.0）。卡里只留"这条线走到哪了"。
class _EventHeader extends StatelessWidget {
  const _EventHeader({required this.host, required this.event});

  final _EventDetailPageState host;
  final Event event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = host.app;
    // 进度**只认一个算法**（与事件列表卡头共用 `checkEventCompletion`）：
    // 分子含"已搁置"、分母排除"已归档"（Q17）
    final completion = app.ws.checkEventCompletion(event.id);
    final done = completion.judgedChildCount - completion.unfinishedCount;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              completion.judgedChildCount == 0
                  ? '主线还没有可判定的任务'
                  : '主线 $done/${completion.judgedChildCount} 已完成'
                        '${completion.canComplete ? '，可以标记事件完成了' : ''}',
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
    // 分子只数 `done`，分母是这里拿到的**未归档**子任务（Q18）——
    // 与 [Workspace.isTaskBlocked] / 状态按钮上的"锁"用的是同一批子任务。
    // `ignored`（已搁置）刻意不算"完成"：它只是"不做了"，行内有图标区分，
    // 而"能不能勾"要等它显式变成 done。
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
    // 到期日走全应用统一口径（`dueLabelOf`）：默认"绝对日期 + 剩余天数"，
    // 只有宽度真的放不下时才退成相对日。有下级汇总时那一行还要放
    // 「下级 x/y」，1.6 倍字体下会顶到行尾，所以余量多留一点。
    final due = dueLabelOf(
      context,
      task.dueAt,
      reservedWidth: summary == null ? 200 : 300,
    );

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
      // 行尾按 12 留边（原来顶到 0）：那一列是**到期日图标**，贴着行尾在实机上
      // 看着像要掉出屏幕（实机反馈"贴得太边了"，先让 6 还不够，再加到 12）。
      // 这个数还与顶部卡片里「时间与任务」的右缘对齐（那边是卡片 12 + 行 4 − 4）。
      contentPadding: EdgeInsets.only(left: 4.0 + indent * 20, right: 12),
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
      // 行内只留**一个图标**（按实机反馈，去掉行尾的三个点）：
      //   · 日期图标 —— 点一下设 / 改到期日，**长按清除**。
      // 其余动作（新建子任务 / 重命名 / 上下挪一格 / 移到其它事件 / 归档 / 删除）
      // 由**点这一行**弹出的动作面板承接，所以不需要再有一个"更多"菜单。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 压到 30×30 是有意的：默认 48×48 的按钮几个就把标题挤没了
      //
      // **只留这一个日期图标**（实机反馈：改日期与清除日期都要在图标里，
      // 不要藏在动作面板下）。点它弹的是 `pickDateSheet` —— 日历 + 底部的
      // 「清除日期」，所以这一颗同时管"设 / 改 / 清"三件事，
      // 长按清除那条路已经取消（提示与动作曾经是同一个手势，等于没有提示）。
          _TaskIcon(
            tooltip: task.dueAt == null
                ? '设到期日'
                : '到期 ${task.dueAt}，点一下改或清',
            icon: task.dueAt == null ? Icons.event_outlined : Icons.event_available_outlined,
            color: overdue ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            clearable: task.dueAt != null,
            onTap: () => _run(context, 'due'),
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
        _moveInLine(context, up: true);
        break;
      case 'moveDown':
        _moveInLine(context, up: false);
        break;
      case 'due':
        await setTaskDueAction(context, app, task);
        break;
      case 'parent':
        await changeTaskParentAction(context, app, task);
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

  /// 在链上挪一格。**已经在两端时要说一句**（Q27）——
  /// 静默的空操作在用户那边等于"这个按钮坏了"。
  void _moveInLine(BuildContext context, {required bool up}) {
    if (!host.app.ws.canMoveTaskWithinLine(task.id, up: up)) {
      showToast(context, up ? '已经是最前面了' : '已经到最后了');
      return;
    }
    host.moveInLine(task.id, up: up);
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

/// 任务行上的一个小图标按钮：**有值时右下角带个小叉**（表示"这一项是设过的"）。
///
/// 与项目详情页的日期图标是同一套观感（那里叫 `_ClearableIcon`）——
/// "有没有值"在两处保持一致，不然用户得分别记。
///
/// **不再有长按**（2026-09-27）：清除挪进了日期面板的「清除日期」，
/// 长按这条路连同它的 tooltip 一起取消 —— 提示与动作曾经是同一个手势，
/// 等于用户永远看不到那句提示。
class _TaskIcon extends StatelessWidget {
  const _TaskIcon({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.clearable,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final bool clearable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
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
  // 归属：提到主线 / 挂到某个节点下（Q27）。与「移到其它事件…」是两件事 ——
  // 一个改"属于哪条线"，一个改"挂在线上的哪一层"。
  actions.add(const TaskAction('parent', '改归属…', Icons.account_tree_outlined));
  actions.add(const TaskAction('move', '移到其它事件…', Icons.swap_horiz));
  actions.add(
    task.archived
        ? const TaskAction('unarchive', '取消归档', Icons.unarchive_outlined)
        : const TaskAction('archive', '归档这条及其子任务', Icons.archive_outlined),
  );
  actions.add(const TaskAction('delete', '删除这条及其子任务', Icons.delete_outline));
  return actions;
}
