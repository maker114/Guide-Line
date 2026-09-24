import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import 'dialogs.dart';
import 'labels.dart';

/// 任务状态按钮：**点按 = 完成 / 取消完成**，长按 = 三态菜单。
///
/// 手机上的主要操作就是它，所以在所有列表里都必须长得一样、行为一样。
///
/// [blocked] 为真时（还有未处理的子任务）**换成锁形且不可点**，
/// 点它只解释原因 —— 原来要"点了才弹错误"，用户得先撞一次墙才知道做不了（灵感 14）。
class TaskStatusButton extends StatelessWidget {
  const TaskStatusButton({
    super.key,
    required this.app,
    required this.task,
    this.size = 22,
    this.blocked = false,
  });

  final AppController app;
  final Task task;
  final double size;
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: blocked ? '还有子任务未处理，先完成下级' : '点按：完成 / 取消　长按：选择状态',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (blocked) {
            showToast(context, blockedReason, error: true);
            return;
          }
          final next = task.status == NodeStatus.done
              ? NodeStatus.pending
              : NodeStatus.done;
          final error = app.run(() => app.ws.setTaskStatus(task.id, next));
          if (error != null) showToast(context, error, error: true);
        },
        onLongPress: blocked ? null : () => pickTaskStatus(context, app, task),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            blocked ? Icons.lock_outline : nodeStatusIcon(task.status),
            size: size,
            color: blocked
                ? scheme.outline
                : nodeStatusColor(task.status, scheme),
          ),
        ),
      ),
    );
  }

  /// 被挡住时的统一说明（锁形的吐司与 tooltip 共用）。
  static const String blockedReason = '还有子任务未处理，先完成下级再勾这个';
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
            child: Text(
              task.title,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
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
