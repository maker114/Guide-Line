import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/due_label.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import 'event_detail_page.dart';
import 'fold_toggle_row.dart';
import 'task_actions.dart';
import 'task_fold.dart';

/// 展开 / 收起箭头的旋转时长（与项目页同一个节奏）。
const Duration _foldDuration = Duration(milliseconds: 180);

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
/// 标题栏那个数字（「事件   2」）：**未归档的事件数**（与项目页同一套口径）。
///
/// 事件没有层级，所以"最外层"就是全部；同样**与卡片展开 / 收起无关** ——
/// 数字只反映"这个页里有几件事"，不随眼睛看到的行数变化。
int visibleEventCount(AppController app) =>
    app.ws.liveEvents.where((event) => !event.archived).length;

class EventTab extends StatefulWidget {
  const EventTab({super.key, required this.app});

  final AppController app;

  @override
  State<EventTab> createState() => _EventTabState();
}

class _EventTabState extends State<EventTab> {
  String? _renamingId;

  /// 哪几条事件线被手动**就地展开**了（临时状态，不进偏好）。
  final Set<String> _revealedLines = <String>{};

  AppController get _app => widget.app;

  @override
  Widget build(BuildContext context) {
    final events =
        _app.ws.liveEvents.where((e) => !e.archived).toList(growable: false)
          ..sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 事件数已经挪到**标题栏**（「事件   2」，与项目页同一套口径），
        // 这里只在一条事件都没有时留一句空态提示 —— 它不是计数行。
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text('还没有事件', style: Theme.of(context).textTheme.labelLarge),
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
              if (events.isNotEmpty)
                // **一个事件一张卡**（与项目页同一种观感）：卡内靠"同框"表达归属，
                // 卡与卡之间留空隙 —— 这是"两个不同事件"的唯一线索。
                for (final event in events)
                  KeyedSubtree(
                    // 用 id 当身份：折叠 / 展开某张卡时，后面的卡片要**整体搬家**，
                    // 不能让它们的内容按"第几个"去和上一帧错配 —— 一错配，
                    // 行内的动画（勾选图标那种）就会重新播一遍（实机反馈）
                    key: ValueKey<String>('event-${event.id}'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                      child: Card(
                        margin: EdgeInsets.zero,
                        elevation: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (_renamingId == event.id)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: InlineTextField(
                                  value: event.name,
                                  autofocus: true,
                                  hint: '事件名',
                                  textStyle: Theme.of(context)
                                      .textTheme
                                      .bodyLarge,
                                  onSubmitted: (name) => _app.run(
                                    () => _app.ws.updateEvent(
                                      event.id,
                                      name: name,
                                    ),
                                  ),
                                  onEditClosed: () {
                                    if (mounted) {
                                      setState(() => _renamingId = null);
                                    }
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
      // 「空了」有两种：新事件确实没任务，和**节点全被归档了**。
      // 后者必须说清去处（Q18）：已归档节点不再显示在任务线里，
      // 不吭声就像"任务丢了"（归档区「已归档」那一区能取消归档找回）。
      final archivedCount = _app.ws.liveTasks
          .where((t) => t.eventId == event.id && t.parentId == null && t.archived)
          .length;
      return <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 0, 12, 10),
          child: Text(
            archivedCount > 0
                ? '主线节点都归档了，共 $archivedCount 个，去「归档区 → 已归档」取消归档'
                : '还没有主线任务',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ];
    }

    // 自动收起：只留当前节点的上一个（规则见 `task_fold.dart`，与详情页共用）
    final autoFolded = autoFoldedMainLineIds(
      mainLine,
      // 用户手动展开过的**不折**（显式选择优先于自动规则）
      userExpanded: (id) =>
          _app.isExpanded(id, defaultExpanded: false) &&
          _app.ws.prefs.expandedIds.contains(id),
    );
    // 想回看的时候要能**就地展开**（实机反馈），所以这里有个开关；
    // 展开状态是临时的：它是"我现在想看一眼"，不是这一页该长期记住的偏好
    final revealed = _revealedLines.contains(event.id);
    final visible = revealed
        ? mainLine
        : mainLine
              .where((t) => !autoFolded.contains(t.id))
              .toList(growable: false);
    final muted = _app.ws.isEventMutedForDue(event.id);

    return <Widget>[
      for (final task in visible)
        KeyedSubtree(
          // 同上：行也要有身份。展开 / 收起自动收起的节点时，后面的行会整体挪位，
          // 按位置错配就会把它们行内的动画重放一遍（实机反馈）
          key: ValueKey<String>('task-${task.id}'),
          child: _EventTaskRow(app: _app, task: task, muted: muted),
        ),
      if (autoFolded.isNotEmpty)
        FoldToggleRow(
          hiddenCount: autoFolded.length,
          expanded: revealed,
          compact: true,
          onTap: () => setState(() {
            if (revealed) {
              _revealedLines.remove(event.id);
            } else {
              _revealedLines.add(event.id);
            }
          }),
        ),
      const SizedBox(height: 6),
    ];
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    showToast(context, message, error: error);
  }
}

/// 卡头：状态 + 事件名 + 「主线 3/5 已完成」，右侧是这一条的动作菜单。
///
/// 卡头**不再写"最近到期 / 接下来做什么"**：那两件事归事件详情页的
/// 「时间与任务」看板（`event_detail_page.dart`，实机反馈）。
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
    // 进度**只认一个算法**（与事件详情页共用 `checkEventCompletion`）：
    // 分子含"已搁置"、分母排除"已归档"。以前这里自己数 done、详情页另算一套，
    // 同一条线会出现两个进度，而且会随"归档一个节点"虚涨（实机反馈）。
    final completion = app.ws.checkEventCompletion(event.id);
    final done = completion.judgedChildCount - completion.unfinishedCount;
    final expanded = app.isExpanded(event.id);

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
              // 箭头**转过去**（与项目页同一个节奏），不是换一个图标
              icon: AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: _foldDuration,
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.chevron_right),
              ),
              onPressed: () => app.setExpanded(event.id, expanded: !expanded),
            ),
      title: Row(
        children: <Widget>[
          // 事件标识色的竖条（与项目树行首同一个控件、同一套色板与规则）
          ProjectColorBar(color: event.color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              event.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: event.status == NodeStatus.done
                  ? theme.textTheme.bodyLarge?.copyWith(
                      decoration: TextDecoration.lineThrough,
                      color: theme.colorScheme.outline,
                    )
                  : theme.textTheme.bodyLarge,
            ),
          ),
        ],
      ),
      // 卡头只留**进度与状态记号**：它回答"这条线走到哪了"。
      // "急不急 / 下一步做哪件"（最近到期 + 接下来）已按实机反馈挪进**事件详情页**
      // 的「时间与任务」（`event_detail_page.dart` 的 `_EventFacts`），
      // 那里有整行的位置、也能把日期单独染色；夹在卡头一行小灰字里反而看不见。
      // 卡头这一行在 1.6 倍字体下本来就紧，去掉它顺带松了一档。
      subtitle: Row(
        children: <Widget>[
          Icon(Icons.timeline, size: 13, color: theme.colorScheme.outline),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              completion.judgedChildCount == 0
                  ? '主线还没有可判定的任务'
                  : '主线 $done/${completion.judgedChildCount} 已完成',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
          // 已搁置的事件在列表里原本和正常事件长得一样，用户没法解释
          // "为什么这条不催我" —— 给它一个明确的记号
          if (event.status == NodeStatus.ignored) ...<Widget>[
            const SizedBox(width: 6),
            Text(
              '· 已搁置',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
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
            case 'moveUp':
              _move(context, up: true);
              break;
            case 'moveDown':
              _move(context, up: false);
              break;
            case 'archive':
              final error = app.run(
                () => app.ws.setEventArchived(event.id, true),
              );
              if (!context.mounted) return;
              showToast(
                context,
                error ?? '已归档，整条任务线一起归档；可在「归档区」找回',
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
          // 事件原来只能按创建顺序排（Q28）：想调整先做哪条线，得有入口。
          // 与任务侧的"往上 / 往下挪一格"是同一件事、同一套叫法（交换相邻 order）。
          PopupMenuItem<String>(value: 'moveUp', child: Text('往上挪一格')),
          PopupMenuItem<String>(value: 'moveDown', child: Text('往下挪一格')),
          PopupMenuItem<String>(value: 'archive', child: Text('归档整条任务线')),
          PopupMenuItem<String>(value: 'delete', child: Text('删除整条任务线')),
        ],
      ),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => EventDetailPage(app: app, eventId: event.id),
        ),
      ),
    );
  }

  /// 事件在列表里挪一格（Q28）= 与相邻的那个交换 `order`。
  ///
  /// 到两端时**要给一句反馈**：静默的空操作在用户那边等于"这个菜单项坏了"
  /// （与任务侧的"往上 / 往下挪一格"同一套口径）。
  void _move(BuildContext context, {required bool up}) {
    if (!app.ws.canMoveEventWithinList(event.id, up: up)) {
      showToast(context, up ? '已经是最前面了' : '已经到最后了');
      return;
    }
    final error = app.run(() => app.ws.moveEventWithinList(event.id, up: up));
    if (error != null && context.mounted) showToast(context, error, error: true);
  }

  Future<void> _delete(BuildContext context) async {
    // 确认框与任务数都走共享实现（`task_actions.dart` 的 `confirmDeleteEvent`）：
    // 这里原来自己弹一遍，文案与详情页逐字相同、任务数算法却不同 ——
    // 详见那个函数的文档。
    if (!await confirmDeleteEvent(context, app, event)) return;
    if (!context.mounted) return;
    final error = app.run(() => app.ws.deleteEvent(event.id));
    if (error != null && context.mounted) {
      showToast(context, error, error: true);
    }
  }
}

/// 卡里的一条主线任务：比卡头**紧凑**一档，靠缩进表达"它属于上面那个事件"。
///
/// [muted] 用于**已搁置的事件**：那类事件里的任务不进「催办」口径
/// （`Workspace.overdueTasks()`，Q19 的唯一算法），所以这里也不把日期标成逾期红 ——
/// 一边说"不再催"，一边画个红日期自相矛盾。它们在「接下来的任务」页上照样列出来，
/// 只是落在「未计入逾期」那一档、走灰。
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
    // 到期日走全应用统一口径（`dueLabelOf`）：默认"绝对日期 + 剩余天数"，
    // 放不下才退成短句。预留宽度用 `dueRowReservedWidth`（真机量出来的，
    // 原先这里拍的是 240 —— 白白扔掉一半空间，带时刻的值一律被截）。
    final due = dueLabelOf(context, task.dueAt);
    // **已搁置的任务不标红**：与事件详情页、任务行一致 ——
    // 一边说"不再催"，一边画个红日期是自相矛盾的。
    // 判据收在 `isTaskRowOverdue` 一处：详情页那处原先漏了 `muted`，
    // 于是同一条任务两处结论不同（2026-10-03 修）。
    final overdue = isTaskRowOverdue(
      task.dueAt,
      pending: task.status == NodeStatus.pending,
      muted: muted,
    );
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
