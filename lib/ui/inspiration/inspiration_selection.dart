import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../common/dialogs.dart';
import '../common/project_picker.dart';
import 'merge_editor_page.dart';

/// 灵感多选的**共用动作条 + 四个批量动作**。
///
/// 抽出来是因为有两处要用（2026-09-28 实机反馈：项目界面的待处理灵感也应当可以
/// 长按多选）：灵感页那一条列表，与项目详情页的「待处理灵感」。
/// 两处如果各写一套，"批量丢弃到底会不会进归档区"这种口径迟早会漂。
///
/// 形状与习惯（长按进入、点条目切换、全选只作用于**当前可见**的那些）
/// 与灵感页完全一致 —— 《界面规范》§7 的「已选 N 条」仍由页面标题行给。
class InspirationSelectionBar extends StatelessWidget {
  const InspirationSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.canSelectAll,
    required this.onToggleAll,
    required this.onExit,
    required this.onAssign,
    required this.onMerge,
    required this.onDiscard,
    required this.onDelete,
  });

  final int selectedCount;
  final bool allSelected;

  /// 当前可见项为空时"全选"要禁用（选上看不见的，用户不知道自己提交了什么）。
  final bool canSelectAll;
  final VoidCallback onToggleAll;
  final VoidCallback onExit;

  /// `null` = 没选中任何一条，那时四个动作都点不动。
  final VoidCallback? onAssign;
  final VoidCallback? onMerge;
  final VoidCallback? onDiscard;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = selectedCount > 0;
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
            // 全选只作用于**当前可见**的那些：有筛选时就是筛出来的那些。
            // 勾选框放在前面（"已选 n 条"由标题行显示，这里不重复）。
            Checkbox(
              value: allSelected,
              tristate: false,
              onChanged: canSelectAll ? (_) => onToggleAll() : null,
            ),
            Tooltip(
              message: allSelected ? '取消全选' : '全选',
              child: const Icon(Icons.done_all, size: 18),
            ),
            const Spacer(),
            _BarAction(
              tooltip: '分配到项目…',
              icon: Icons.drive_file_move_outline,
              onPressed: enabled ? onAssign : null,
            ),
            _BarAction(
              tooltip: '合并…',
              icon: Icons.merge_type,
              onPressed: enabled ? onMerge : null,
            ),
            _BarAction(
              tooltip: '丢弃',
              icon: Icons.visibility_off_outlined,
              onPressed: enabled ? onDiscard : null,
            ),
            _BarAction(
              tooltip: '删除',
              icon: Icons.delete_outline,
              onPressed: enabled ? onDelete : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 动作条上的一个**胶囊图标按钮**（与「全部任务」那条批量条同一套外观）。
class _BarAction extends StatelessWidget {
  const _BarAction({required this.tooltip, required this.icon, required this.onPressed});

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

/// 四个批量动作的**实现**（两处共用同一份口径）。
///
/// 每个方法都在成功之后调 [onDone]（调用方据此退出多选与刷新）——
/// 被业务层拦下时**不退出**，留在原地让用户重选。
class InspirationBatchActions {
  const InspirationBatchActions({
    required this.app,
    required this.selectedIds,
    required this.onDone,
  });

  final AppController app;

  /// 当前选中的 id（调用方每次动作前给一份当下的快照）。
  final List<String> selectedIds;

  /// 动作真的落盘之后回调。
  final void Function() onDone;

  Future<void> assign(BuildContext context) async {
    final picked = await pickProject(
      context,
      app,
      title: '分配到项目',
      allowNone: true,
      noneLabel: '解除分配',
    );
    if (picked == null || !context.mounted) return;
    final projectId = picked == pickNone ? null : picked;
    final error = app.run(() => app.ws.assignInspirations(selectedIds, projectId));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) {
      showToast(
        context,
        projectId == null ? '已解除 ${selectedIds.length} 条的分配' : '已分配 ${selectedIds.length} 条',
      );
    }
    onDone();
  }

  /// 多选合并：选中的多条**一次带进合并编辑器**，并进用户选定的目标。
  ///
  /// 三条口径（与灵感页那版一字不差）：
  ///   · **顺序 = 列表当前顺序**；
  ///   · **落点项目先选**：多选可能跨项目，走同一个 `pickProject`，分类不可选；
  ///   · 合并完退出多选 —— 那些灵感已经不在这一页了。
  Future<void> merge(BuildContext context, List<Inspiration> ordered) async {
    final picks = ordered
        .where((inspiration) => selectedIds.contains(inspiration.id))
        .toList(growable: false);
    if (picks.isEmpty) return;

    final picked = await pickProject(context, app, title: '合并到哪个项目');
    if (picked == null || !context.mounted) return;
    final project = app.ws.findProject(picked);
    if (project == null || !context.mounted) return;

    final result = await Navigator.of(context).push<MergeResult>(
      MaterialPageRoute<MergeResult>(
        builder: (_) => MergeEditorPage.many(
          project: project,
          inspirations: picks,
          isCategory: app.ws.isProjectCategory(project.id),
        ),
      ),
    );
    if (result == null || !context.mounted) return;

    final merged = await applyMergeResultFor(
      context,
      app,
      project,
      inspirations: picks,
      result: result,
    );
    if (!merged || !context.mounted) return;
    onDone();
  }

  Future<void> discard(BuildContext context) async {
    final error = app.run(() => app.ws.discardInspirations(selectedIds));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) {
      showToast(context, '已丢弃 ${selectedIds.length} 条，可在归档区「已处理的灵感」找回');
    }
    onDone();
  }

  Future<void> delete(BuildContext context) async {
    final ok = await confirmAction(
      context,
      title: '删除 ${selectedIds.length} 条灵感',
      // 灵感是扁平实体，**不进回收站**（回收站只装项目 / 事件 / 任务），
      // 所以这里不能写"可恢复" —— 删除就是删除；备份里可能仍有原文，
      // 但只能整库退回。
      message: '灵感不进回收站，删除后无法在应用里找回。\n'
          '备份与历次导出里可能仍有，但只能整库退回。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    final error = app.run(() => app.ws.deleteInspirations(selectedIds));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) showToast(context, '已删除 ${selectedIds.length} 条');
    onDone();
  }
}
