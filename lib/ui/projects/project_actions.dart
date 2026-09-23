import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/rules/cascade.dart';
import '../common/dialogs.dart';
import '../common/project_picker.dart';

/// 项目的常用动作。项目 Tab 的菜单、详情页的菜单共用这一套，
/// 保证确认文案与副作用（归档级联、删除连带灵感）说法一致。

Future<void> createProjectAction(
  BuildContext context,
  AppController app, {
  String? parentId,
}) async {
  final title = await promptText(
    context,
    title: parentId == null ? '新建项目' : '新建子项目',
    hintText: '项目名',
  );
  if (title == null || !context.mounted) return;
  final error = app.run(() => app.ws.createProject(title: title, parentId: parentId));
  if (error != null && context.mounted) showToast(context, error, error: true);
}

Future<void> renameProjectAction(
  BuildContext context,
  AppController app,
  String projectId,
  String currentTitle,
) async {
  final title = await promptText(
    context,
    title: '重命名项目',
    initialText: currentTitle,
    hintText: '项目名',
  );
  if (title == null || !context.mounted) return;
  final error = app.run(() => app.ws.updateProject(projectId, title: title));
  if (error != null && context.mounted) showToast(context, error, error: true);
}

Future<void> editProjectFieldAction(
  BuildContext context,
  AppController app,
  String projectId, {
  required String field,
  required String currentValue,
}) async {
  final labels = <String, String>{'purpose': '目的', 'implementation': '实现'};
  final value = await promptText(
    context,
    title: '编辑${labels[field] ?? field}',
    initialText: currentValue,
    hintText: field == 'purpose' ? '为什么做这个项目' : '怎么做 —— 灵感合并进来会写到这里',
    maxLines: 8,
  );
  if (value == null || !context.mounted) return;
  final error = app.run(
    () => field == 'purpose'
        ? app.ws.updateProject(projectId, purpose: value)
        : app.ws.updateProject(projectId, implementation: value),
  );
  if (error != null && context.mounted) showToast(context, error, error: true);
}

Future<void> moveProjectAction(
  BuildContext context,
  AppController app,
  String projectId,
) async {
  final picked = await pickProject(
    context,
    app,
    title: '移动到…',
    allowNone: true,
    excludeSubtreeOf: projectId,
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
  final lines = <String>['「${project.title}」及其下 ${plan.projectIds.length - 1} 个子项目会被删除；'];
  if (plan.inspirationIdsToDelete.isNotEmpty) {
    lines.add('${plan.inspirationIdsToDelete.length} 条未处理灵感会一并删除；');
  }
  if (plan.inspirationIdsToUnassign.isNotEmpty) {
    lines.add('${plan.inspirationIdsToUnassign.length} 条已合并灵感会退回「未分配」；');
  }
  lines.add('全部可在「更多 → 归档区 → 回收站」恢复。');

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
