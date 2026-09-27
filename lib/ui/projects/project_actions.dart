import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/rules/cascade.dart';
import '../common/dialogs.dart';
import '../common/project_picker.dart';

/// 项目的常用动作：**移动 / 归档 / 删除**。
///
/// 新建与重命名不在这里 —— 它们改成了**页面内直接输入**（`InlineComposer` /
/// `InlineTextField`），不再弹对话框，所以没有对应的 action 函数。
/// 留在这里的都是"必须问一句"的动作（会有级联副作用），用确认框而不是输入框。

Future<void> moveProjectAction(
  BuildContext context,
  AppController app,
  String projectId, {
  String title = '移动到…',
}) async {
  final picked = await pickProject(
    context,
    app,
    title: title,
    allowNone: true,
    excludeSubtreeOf: projectId,
    // 移动侧与灵感侧相反：**移进一个分类正是"建分类"的做法**，分类照常可选。
    // 只有"灵感的落点"才限定为目标（Q2）。
    requireTarget: false,
  );
  if (picked == null || !context.mounted) return;
  final parentId = picked == pickNone ? null : picked;
  final error = app.run(() => app.ws.updateProject(projectId, parentId: parentId));
  if (error != null && context.mounted) showToast(context, error, error: true);
}

/// 归档 / 取消归档（**沿树级联**，ADR-051）。
Future<void> archiveProjectAction(
  BuildContext context,
  AppController app,
  String projectId, {
  required bool archived,
}) async {
  final ws = app.ws;
  final project = ws.findProject(projectId);
  if (project == null) return;

  final subtreeCount = ws.projectTree.subtreeOf(projectId).length;
  if (archived && subtreeCount > 1) {
    final ok = await confirmAction(
      context,
      title: '归档项目',
      message: '「${project.title}」及其下 ${subtreeCount - 1} 个子项目会一起归档，'
          '分配到这些项目下的未处理灵感也会从列表里隐藏。可在「更多 → 归档区」找回。',
      confirmLabel: '归档',
    );
    if (!ok || !context.mounted) return;
  }

  final error = app.run(() => ws.setProjectArchived(projectId, archived));
  if (!context.mounted) return;
  if (error != null) {
    showToast(context, error, error: true);
    return;
  }
  showToast(context, archived ? '已归档，可在「归档区」取消归档' : '已取消归档');
}

/// 删除项目（置墓碑，可在回收站恢复）。
Future<void> deleteProjectAction(
  BuildContext context,
  AppController app,
  String projectId,
) async {
  final ws = app.ws;
  final project = ws.findProject(projectId);
  if (project == null) return;

  final plan = planProjectDeletion(ws.projectTree, ws.allInspirations, projectId);
  // 两句话必须**分开说**：项目 / 事件 / 任务进回收站、30 天内能找回，
  // 而灵感不进回收站（《定义与边界》§8 的对照表）—— 合成一句"全部可恢复"，
  // 用户会以为灵感也躺在回收站里等它。
  final lines = <String>['「${project.title}」及其下 ${plan.projectIds.length - 1} 个子项目会被删除；'];
  if (plan.inspirationIdsToUnassign.isNotEmpty) {
    lines.add('${plan.inspirationIdsToUnassign.length} 条已合并灵感会退回「未分配」；');
  }
  lines.add('项目 / 事件 / 任务可在「更多 → 归档区 → 回收站」恢复，30 天后自动清除。');
  if (plan.inspirationIdsToDelete.isNotEmpty) {
    // 这里的 N 是"未处理灵感"，按契约口径**包含已丢弃但没恢复的那些**
    // （`planProjectDeletion` 只看"是否已合并"，不看 discarded），
    // 所以文案必须把这一层说出来，否则用户会以为丢弃过的那些不受影响。
    lines.add(
      '这 ${plan.inspirationIdsToDelete.length} 条未处理灵感会被永久删除，'
      '含已经丢弃、还没恢复的那些。它们不进回收站 —— 只能靠备份与历次导出找回。',
    );
  }

  final ok = await confirmAction(
    context,
    title: '删除项目',
    message: lines.join('\n'),
    confirmLabel: '删除',
    danger: true,
  );
  if (!ok || !context.mounted) return;

  final error = app.run(() => ws.deleteProject(projectId));
  if (!context.mounted) return;
  if (error != null) showToast(context, error, error: true);
}
