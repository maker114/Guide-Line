import 'package:flutter/material.dart';

import '../../core/models/enums.dart';

/// 三态标记（待办 / 已完成 / 已忽略）。点击弹出切换菜单。
class NodeStatusChip extends StatelessWidget {
  const NodeStatusChip({
    super.key,
    required this.status,
    this.onChanged,
    this.completeBlockedReason,
    this.dense = true,
  });

  final NodeStatus status;

  /// 为 null 表示只读展示。
  final ValueChanged<NodeStatus>? onChanged;

  /// 完成条件未满足时的原因（非 null 时"标记完成"会被禁用并解释原因）。
  final String? completeBlockedReason;

  final bool dense;

  static IconData iconOf(NodeStatus status) {
    switch (status) {
      case NodeStatus.pending:
        return Icons.radio_button_unchecked;
      case NodeStatus.done:
        return Icons.check_circle;
      case NodeStatus.ignored:
        return Icons.remove_circle_outline;
    }
  }

  static String labelOf(NodeStatus status) {
    switch (status) {
      case NodeStatus.pending:
        return '待办';
      case NodeStatus.done:
        return '已完成';
      case NodeStatus.ignored:
        return '已忽略';
    }
  }

  static Color colorOf(BuildContext context, NodeStatus status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case NodeStatus.pending:
        return scheme.outline;
      case NodeStatus.done:
        return const Color(0xFF2E7D32);
      case NodeStatus.ignored:
        return scheme.outlineVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = colorOf(context, status);
    final icon = Icon(iconOf(status), size: dense ? 18 : 22, color: color);

    if (onChanged == null) {
      return Tooltip(message: labelOf(status), child: icon);
    }

    return PopupMenuButton<NodeStatus>(
      tooltip: labelOf(status),
      onSelected: onChanged,
      itemBuilder: (context) => <PopupMenuEntry<NodeStatus>>[
        const PopupMenuItem<NodeStatus>(value: NodeStatus.pending, child: Text('待办')),
        PopupMenuItem<NodeStatus>(
          value: NodeStatus.done,
          enabled: completeBlockedReason == null,
          child: Text(
            completeBlockedReason == null ? '已完成' : '已完成（$completeBlockedReason）',
          ),
        ),
        const PopupMenuItem<NodeStatus>(value: NodeStatus.ignored, child: Text('已忽略')),
      ],
      child: Padding(padding: const EdgeInsets.all(4), child: icon),
    );
  }
}

/// 空状态占位。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.hint, this.action});

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 52, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(hint!, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
          ],
          if (action != null) ...<Widget>[
            const SizedBox(height: 16),
            action!,
          ],
        ],
      ),
    );
  }
}

/// 小标题。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Row(
        children: <Widget>[
          Text(
            text,
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 二次确认（删除 / 彻底删除等不可逆操作统一走这里）。
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error)
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 单行输入对话框（新建项目 / 事件 / 任务）。
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? label,
  String? initial,
  String confirmLabel = '创建',
}) async {
  final controller = TextEditingController(text: initial ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label ?? '名称'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = result?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// 毫秒时间戳 → 本地日期（仅展示用）。
String formatTimestamp(int? millis) {
  if (millis == null) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 顶部提示条（错误 / 冲突 / 告警）。
void showNotice(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.errorContainer : null,
    ),
  );
}
