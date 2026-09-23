import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import '../common/dialogs.dart';
import '../common/event_picker.dart';

/// 任务的常用动作（事件页与任务框菜单共用）。

/// 新建任务：主线（[parentTaskId] 为空）或挂在某任务下。
Future<void> createTaskAction(
  BuildContext context,
  AppController app, {
  required String eventId,
  String? parentTaskId,
  TaskType type = TaskType.standard,
}) async {
  final titles = <TaskType, String>{
    TaskType.standard: '新建主线任务',
    TaskType.subtask: '新建子任务',
    TaskType.parallel: '新建并列任务',
  };
  final title = await promptText(
    context,
    title: titles[type] ?? '新建任务',
    hintText: '任务名',
  );
  if (title == null || !context.mounted) return;

  final error = app.run(
    () => app.ws.createTask(
      eventId: eventId,
      title: title,
      parentTaskId: parentTaskId,
      type: type,
    ),
  );
  if (error != null && context.mounted) showToast(context, error, error: true);
}

Future<void> renameTaskAction(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final title = await promptText(
    context,
    title: '重命名任务',
    initialText: task.title,
    hintText: '任务名',
  );
  if (title == null || !context.mounted) return;
  final error = app.run(() => app.ws.updateTask(task.id, title: title));
  if (error != null && context.mounted) showToast(context, error, error: true);
}

/// 设置 / 清除到期日。
Future<void> setTaskDueAction(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final now = DateTime.now();
  final initial = task.dueAt == null ? now : (DateTime.tryParse(task.dueAt!) ?? now);
  final picked = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(now.year - 5),
    lastDate: DateTime(now.year + 20),
  );
  if (picked == null || !context.mounted) return;
  final month = picked.month.toString().padLeft(2, '0');
  final day = picked.day.toString().padLeft(2, '0');
  final error = app.run(() => app.ws.updateTask(task.id, dueAt: '${picked.year}-$month-$day'));
  if (error != null && context.mounted) showToast(context, error, error: true);
}

Future<void> clearTaskDueAction(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final error = app.run(() => app.ws.updateTask(task.id, dueAt: null));
  if (error != null && context.mounted) showToast(context, error, error: true);
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
  showToast(context, archived ? '已归档（级联子任务）' : '已取消归档');
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
