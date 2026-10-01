import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/event.dart';
import '../../core/models/task.dart';
import '../../core/rules/cascade.dart';
import '../common/dialogs.dart';
import '../common/due_sheet.dart';
import '../common/event_picker.dart';

/// 任务的常用动作：**到期 / 归属 / 归档 / 删除**。
///
/// 新建与重命名不在这里 —— 它们改成了**页面内直接输入**
/// （主线在任务线末尾、子任务在框内、重命名就在那一行），
/// 不再弹对话框。留在这里的都是"改完会有副作用、值得问一句"的动作。

/// 问一句"真的要删这条事件吗"，答 `true` 才让调用方去删。
///
/// **全应用只有这一份文案**（2026-10-01 合并）：事件列表（`event_tab.dart`）
/// 与事件详情页（`event_detail_page.dart`）原来各写一遍，标题、两种文案、
/// 确认词、`danger` **逐字相同** —— 而**任务数的算法不一样**：列表页调
/// `eventDeletionTaskIds`（cascade 的规格实现），详情页内联了一段
/// `allTasks.where(eventId 匹配 && !deleted)`。
/// 两者当时**恰好等价**，所以是"等爆耦合"：cascade 一改（例如把归档任务也算进来），
/// 两个入口就会报出不同的条数，而用户正是照那个数决定要不要删。
/// 现在两边都走 [eventDeletionTaskIds]。
///
/// 只问、不删：删除本身由调用方做（详情页删完还要 `maybePop`，列表页不用）。
Future<bool> confirmDeleteEvent(
  BuildContext context,
  AppController app,
  Event event,
) async {
  final taskCount = eventDeletionTaskIds(app.ws.allTasks, event.id).length;
  return confirmAction(
    context,
    title: '删除事件',
    message: taskCount == 0
        ? '删除「${event.name}」。可在「更多 → 归档区 → 回收站」恢复。'
        : '「${event.name}」及其整条任务线共 $taskCount 个任务会被一起删除。'
              '可在「更多 → 归档区 → 回收站」恢复。',
    confirmLabel: '删除',
    danger: true,
  );
}

/// 设置 / 清除到期日。
///
/// 两件事走**同一个面板**（`pickDateSheet`）：点日期图标弹日历，清除键就在
/// 日历下面。从前清除只挂在长按上、而提示也写在同一个长按的 tooltip 里，
/// 点开系统日历**只能改不能删** —— 实机反馈"日期取消不掉"就是从这来的。
///
/// 返回 `true` 表示真的落盘了（调用方可以据此给提示）。
Future<bool> setTaskDueAction(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final picked = await pickDateSheet(
    context,
    title: task.dueAt == null ? '选择到期日' : '改到期日',
    current: task.dueAt,
  );
  if (picked == null || !context.mounted) return false;

  // 空串 = 用户点了「清除日期」
  final dueAt = picked == clearDateValue ? null : picked;
  final error = app.run(() => app.ws.updateTask(task.id, dueAt: dueAt));
  if (!context.mounted) return false;
  if (error != null) {
    showToast(context, error, error: true);
    return false;
  }
  showToast(context, dueAt == null ? '已清除到期日' : '到期日：$dueAt');
  return true;
}

/// 移到其它事件（跨事件移动时父引用会被业务层强制归零）。
Future<void> moveTaskToEventAction(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final target = await pickEvent(
    context,
    app,
    title: '移到哪个事件',
    excludeId: task.eventId,
  );
  if (target == null || !context.mounted) return;
  final error = app.run(() => app.ws.moveTask(task.id, newEventId: target));
  if (error != null && context.mounted) showToast(context, error, error: true);
}

/// 「改归属…」：**提到主线**，或**挂到同一事件里某个节点下**（Q27）。
///
/// 数据层一直支持（`moveTask` 的 `newParentTaskId`），缺的是入口；没有它，
/// "子任务提成主线 / 主线挂到某个节点下"这条路只能靠改数据文件。
///
/// 两个边界在这里就说清，而不是等点了才报错：
///   · 能不能挂**只取决于数据层的 `canHaveChild`** —— 子任务是叶子，
///     所以候选里只有主线上那些节点；
///   · 自己下面还有下级的，挂到节点下会变成子任务（子任务不能有下级），
///     于是这一项直接不列出来，并说明为什么。
Future<void> changeTaskParentAction(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final ws = app.ws;
  final inMainLine = task.parentId == null;
  // 能当父的节点：同一事件主线上、除了它自己以外的节点
  final candidates = ws
      .mainLineOf(task.eventId)
      .where((each) => each.id != task.id)
      .toList(growable: false);
  final descendantCount = ws.taskTree.descendantsOf(task.id).length;

  final value = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '改归属：${task.title}',
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!inMainLine)
              ListTile(
                leading: const Icon(Icons.vertical_align_top),
                title: const Text('提到主线'),
                subtitle: const Text('变成任务线上的一个节点，排在末尾'),
                onTap: () => Navigator.of(sheetContext).pop(_mainLineValue),
              ),
            if (descendantCount > 0)
              // 挂到节点下 = 自己变成子任务，而子任务不能再有下级
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  '这条下面还有 $descendantCount 个下级，子任务不能再有下级',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...<Widget>[
              for (final node in candidates)
                ListTile(
                  leading: const Icon(Icons.subdirectory_arrow_right),
                  title: Text('挂到「${node.title}」下'),
                  onTap: () => Navigator.of(sheetContext).pop(node.id),
                ),
              if (candidates.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    '这个事件里还没有别的节点可以挂',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
  if (value == null || !context.mounted) return;

  final parentId = value == _mainLineValue ? null : value;
  final error = app.run(() => app.ws.moveTask(task.id, newParentTaskId: parentId));
  if (!context.mounted) return;
  if (error != null) {
    showToast(context, error, error: true);
    return;
  }
  showToast(context, parentId == null ? '已提到主线，排在末尾' : '已挂到节点下');
}

/// "提到主线"在面板里的返回值。事件 id 是 UUID，不会与它撞上。
const String _mainLineValue = '__main_line__';

/// 批量设到期日（Q26）。
///
/// 校验与落盘都在 `Workspace.setTasksDue` 里**一次做完**：一条不合法就都不动，
/// 这里只负责把原因原样报出来。返回 `true` 表示真的落盘了（调用方可以退出多选）。
Future<bool> batchSetTasksDueAction(
  BuildContext context,
  AppController app,
  List<String> taskIds,
) async {
  if (taskIds.isEmpty) return false;

  final firstDue = app.ws.findTask(taskIds.first)?.dueAt;
  final picked = await pickDateSheet(
    context,
    title: '给这 ${taskIds.length} 条设到期日',
    current: firstDue,
  );
  if (picked == null || !context.mounted) return false;

  final dueAt = picked == clearDateValue ? null : picked;
  final error = app.run(() => app.ws.setTasksDue(taskIds, dueAt));
  if (!context.mounted) return false;
  if (error != null) {
    showToast(context, error, error: true);
    return false;
  }
  showToast(
    context,
    dueAt == null ? '已清除 ${taskIds.length} 条的到期日' : '已给 ${taskIds.length} 条设到期日 $dueAt',
  );
  return true;
}

/// 批量归档（Q26）。**二次确认要说清影响条数（含子任务）**：归档是级联的，
/// "我选了 3 条"与"一共动了 7 条"是两件事，不说清用户就不知道自己交出去了多少。
///
/// 返回 `true` 表示真的落盘了。
Future<bool> batchArchiveTasksAction(
  BuildContext context,
  AppController app,
  List<String> taskIds,
) async {
  if (taskIds.isEmpty) return false;
  final impact = app.ws.taskArchiveImpact(taskIds, archived: true);
  final ok = await confirmAction(
    context,
    title: '归档 ${taskIds.length} 条任务',
    message: '会归档选中的 ${taskIds.length} 条，连同它们的子任务一共 ${impact.length} 条。\n'
        '可在「更多 → 归档区 → 已归档」取消归档。',
    confirmLabel: '归档',
  );
  if (!ok || !context.mounted) return false;

  final error = app.run(() => app.ws.setTasksArchived(taskIds, true));
  if (!context.mounted) return false;
  if (error != null) {
    showToast(context, error, error: true);
    return false;
  }
  showToast(context, '已归档 ${impact.length} 条，子任务一并归档');
  return true;
}

/// 多选态的动作条：「全部任务」与搜索页共用（Q26）。
///
/// 习惯与灵感页**一模一样**（长按进入多选、点条目切换选中、「全选」只作用于
/// 当前可见项），所以这里的形状也照它来：退出是正圆图标按钮，批量动作是
/// 带底色的胶囊图标按钮（《界面规范》§1：能点的用胶囊、只有图标的用正圆）。
class TaskSelectionBar extends StatelessWidget {
  const TaskSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.canSelectAll,
    required this.onToggleAll,
    required this.onExit,
    required this.onSetDue,
    required this.onArchive,
  });

  final int selectedCount;
  final bool allSelected;
  final bool canSelectAll;
  final VoidCallback onToggleAll;
  final VoidCallback onExit;
  final VoidCallback? onSetDue;
  final VoidCallback? onArchive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: '退出多选',
              icon: const Icon(Icons.close),
              onPressed: onExit,
            ),
            // 「全选」只作用于**当前可见**的那些：选上看不见的，用户就不知道
            // 自己提交了什么。已选条数由页面标题行给（界面规范 §7：已选 N 条），
            // 这里不重复写一遍。
            Checkbox(
              value: allSelected,
              onChanged: canSelectAll ? (_) => onToggleAll() : null,
            ),
            Tooltip(
              message: allSelected ? '取消全选' : '全选',
              child: const Icon(Icons.done_all, size: 18),
            ),
            const Spacer(),
            _BatchAction(
              tooltip: '设到期日',
              icon: Icons.event_outlined,
              onPressed: selectedCount == 0 ? null : onSetDue,
            ),
            _BatchAction(
              tooltip: '归档',
              icon: Icons.archive_outlined,
              onPressed: selectedCount == 0 ? null : onArchive,
            ),
          ],
        ),
      ),
    );
  }
}

/// 动作条上的一个胶囊图标按钮（与灵感页的批量动作条同一套外观）。
class _BatchAction extends StatelessWidget {
  const _BatchAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.surface,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: const Size(44, 36),
          ),
        ),
      ),
    );
  }
}

Future<void> archiveTaskAction(
  BuildContext context,
  AppController app,
  Task task, {
  required bool archived,
}) async {
  final error = app.run(() => app.ws.setTaskArchived(task.id, archived));
  if (!context.mounted) return;
  if (error != null) {
    showToast(context, error, error: true);
    return;
  }
  showToast(context, archived ? '已归档，子任务一并归档' : '已取消归档');
}

Future<void> deleteTaskAction(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final descendants = app.ws.taskTree.descendantsOf(task.id).length;
  final ok = await confirmAction(
    context,
    title: '删除任务',
    message: descendants == 0
        ? '删除「${task.title}」。可在「更多 → 归档区 → 回收站」恢复。'
        : '「${task.title}」及其下 $descendants 个子任务会被一起删除。可在「更多 → 归档区 → 回收站」恢复。',
    confirmLabel: '删除',
    danger: true,
  );
  if (!ok || !context.mounted) return;
  final error = app.run(() => app.ws.deleteTask(task.id));
  if (error != null && context.mounted) showToast(context, error, error: true);
}
