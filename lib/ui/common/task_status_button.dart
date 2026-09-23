import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import 'dialogs.dart';
import 'labels.dart';

/// 任务状态按钮：**点按 = 完成 / 取消完成**，长按 = 三态菜单。
///
/// 手机上的主要操作就是它，所以在所有列表里都必须长得一样、行为一样。
class TaskStatusButton extends StatelessWidget {
  const TaskStatusButton({super.key, required this.app, required this.task, this.size = 22});

  final AppController app;
  final Task task;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '点按：完成 / 取消　长按：选择状态',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final next = task.status == NodeStatus.done ? NodeStatus.pending : NodeStatus.done;
          final error = app.run(() => app.ws.setTaskStatus(task.id, next));
          if (error != null) showToast(context, error, error: true);
        },
        onLongPress: () => pickTaskStatus(context, app, task),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            nodeStatusIcon(task.status),
            size: size,
            color: nodeStatusColor(task.status, Theme.of(context).colorScheme),
          ),
        ),
      ),
    );
  }
}

/// 三态选择面板（未完成 / 已完成 / 已搁置）。
Future<void> pickTaskStatus(
  BuildContext context,
  AppController app,
  Task task,
) async {
  final picked = await showModalBottomSheet<NodeStatus>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(task.title, style: Theme.of(sheetContext).textTheme.titleMedium),
          ),
          for (final status in NodeStatus.values)
            ListTile(
              leading: Icon(nodeStatusIcon(status)),
              title: Text(nodeStatusLabel(status)),
              selected: status == task.status,
              onTap: () => Navigator.of(sheetContext).pop(status),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  final error = app.run(() => app.ws.setTaskStatus(task.id, picked));
  if (error != null && context.mounted) showToast(context, error, error: true);
}
