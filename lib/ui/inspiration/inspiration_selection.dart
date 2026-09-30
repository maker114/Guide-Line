import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
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
            // 版式（2026-09-28 实机反馈）：**全是胶囊** —— 退出与全选原来用的是
            // 正圆，现在也改成胶囊外框；全选带上文字（胶囊里只放一枚图标会显空）。
            _PillAction(
              tooltip: '退出多选',
              icon: Icons.close,
              onPressed: onExit,
            ),
            _PillAction(
              tooltip: allSelected ? '取消全选' : '全选',
              icon: allSelected ? Icons.check_circle : Icons.radio_button_unchecked,
              label: '全选',
              active: allSelected,
              onPressed: canSelectAll ? onToggleAll : null,
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

/// 动作条上的一个**胶囊**图标按钮（退出 / 全选：一个记号，可带文字）。
///
/// 2026-09-28 实机反馈：这两个也要是**胶囊外框**（原来用的是正圆），
/// 与四个批量动作、与全应用的"能点的用胶囊"对齐。
/// [active] 为真时给主题色的低透明底 —— 与「未完成 / 已完成 / 已搁置」
/// 那枚胶囊的选中态同一条口径。
class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.label,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  /// 有文字时按钮更宽（「全选」需要说出来；`✕` 自己就够明白）。
  final String? label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tooltip,
        child: label == null
            ? IconButton(
                onPressed: onPressed,
                icon: Icon(icon, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: active
                      ? theme.colorScheme.primary.withValues(alpha: 0.16)
                      : null,
                  foregroundColor: foreground,
                  // **胶囊**（不是正圆）：高度撑开成一条，与旁边四个动作一致
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(44, 40),
                ),
              )
            : TextButton.icon(
                onPressed: onPressed,
                icon: Icon(icon, size: 20),
                label: Text(label!),
                style: TextButton.styleFrom(
                  backgroundColor: active
                      ? theme.colorScheme.primary.withValues(alpha: 0.16)
                      : null,
                  foregroundColor: foreground,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(44, 40),
                ),
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

  /// 多选合并（2026-09-28 实机反馈："点击合并时直接将已经分配了项目的灵感
  /// 直接合并进对应项目"，并按"拆成几次合并，流水作业"落地）。
  ///
  /// 流程：
  /// ```
  /// 选中的灵感按「所属项目」分组
  ///   ├─ 只有一个**有效**目标  → 不问落点，直接进那个项目的合并编辑器
  ///   ├─ 有没分配的 / 有无效目标（分类、已删）→ 退回"问一次落点"那条路，
  ///   │     把这一批一起并进用户选的那一个（否则那些灵感没有落点可选）
  ///   └─ 分成几组有效目标      → 一组一组流水做完，最后给一句汇总
  /// ```
  ///
  /// 边界（刻意定的，不是漏做）：
  ///   · **分类不是落点**（Q2：分类只回答"归哪一类"）—— 灵感挂在分类上时，
  ///     那一组不算"有效目标"，会走"问一次"那条路，用户自己挑一个真目标；
  ///   · 一组内部走**一次批量合并**（`MergeLanding` 同一个方向），不逐条弹编辑器。
  Future<void> merge(BuildContext context, List<Inspiration> ordered) async {
    final picks = ordered
        .where((inspiration) => selectedIds.contains(inspiration.id))
        .toList(growable: false);
    if (picks.isEmpty) return;

    // 按归属项目分组（保持列表顺序：同一个项目里的先后就是用户看到的先后）
    final byProject = <String?, List<Inspiration>>{};
    for (final inspiration in picks) {
      byProject.putIfAbsent(inspiration.projectId, () => <Inspiration>[]).add(inspiration);
    }

    // 哪些组是**有效落点**：项目在、没删、而且不是分类
    final valid = <Project>[];
    var hasUnassigned = false;
    for (final entry in byProject.entries) {
      final id = entry.key;
      if (id == null) {
        hasUnassigned = true;
        continue;
      }
      final project = app.ws.findProject(id);
      if (project == null || project.deleted || app.ws.isProjectCategory(id)) continue;
      valid.add(project);
    }

    // 只有一个有效目标、而且没有"没着落"的那些：**不问，直接并**
    if (!hasUnassigned && valid.length == 1) {
      await _mergeInto(context, valid.single, picks);
      onDone();
      return;
    }
    // 没得推断（全未分配 / 目标全是分类或已删）：照旧问一次落点
    if (valid.isEmpty) {
      await _mergeIntoPicked(context, picks);
      return;
    }
    // 只剩一组有效目标、但有未分配的：一起并进它（不问）
    if (valid.length == 1) {
      await _mergeInto(context, valid.single, picks);
      onDone();
      return;
    }

    // 分成几组：一条一组、流水做完
    var groups = 0;
    var merged = 0;
    final skipped = <String>[];
    for (final project in valid) {
      final group = byProject[project.id] ?? const <Inspiration>[];
      final ok = await _mergeInto(context, project, group);
      if (ok) {
        groups += 1;
        merged += group.length;
      } else {
        skipped.add('${group.length} 条（${project.title}）');
      }
      if (!context.mounted) return;
    }

    if (!context.mounted) return;
    if (merged == 0) {
      showToast(context, '选中的灵感都没有合并到项目。', error: true);
      return;
    }
    final skipNote = skipped.isEmpty ? '' : '；未处理 ${skipped.join('、')}';
    showToast(context, '已并进 $groups 个项目，共 $merged 条$skipNote');
    onDone();
  }

  /// 问一次落点再合并（"全都没分配"那条路，以及单条时的老行为）。
  Future<void> _mergeIntoPicked(BuildContext context, List<Inspiration> picks) async {
    final picked = await pickProject(context, app, title: '合并到哪个项目');
    if (picked == null || !context.mounted) return;
    final project = app.ws.findProject(picked);
    if (project == null || !context.mounted) return;
    if (await _mergeInto(context, project, picks)) onDone();
  }

  /// 把 [group] 并进 [project]（一个项目的合并编辑器 + 落盘）。
  ///
  /// 每一步都会**推一次合并编辑器**：流水作业就是这样走的 —— 用户在第一组里
  /// 选好落点（改写 / 追加 / 作为清单条目），返回之后自动进下一组。
  /// 收尾只给**一句汇总**（每组各弹一次提示会连成一串，最后那条反而看不清）。
  ///
  /// 返回是否真的并进去了（用户中途返回 = `false`，那一组会记进"未处理"）。
  Future<bool> _mergeInto(
    BuildContext context,
    Project project,
    List<Inspiration> group,
  ) async {
    if (group.isEmpty) return false;
    final result = await Navigator.of(context).push<MergeResult>(
      MaterialPageRoute<MergeResult>(
        builder: (_) => MergeEditorPage.many(
          project: project,
          inspirations: group,
          isCategory: app.ws.isProjectCategory(project.id),
        ),
      ),
    );
    if (result == null || !context.mounted) return false;

    // `applyMergeResultFor` 自己会给一句"已并进…"的提示；流水时它每步都会弹，
    // 但那正是"一组一组做完"的即时反馈 —— 最后由汇总那句收口。
    return applyMergeResultFor(
      context,
      app,
      project,
      inspirations: group,
      result: result,
    );
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
