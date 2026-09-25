import 'package:flutter/material.dart';

/// 全站通用的对话框与轻提示。
///
/// 手机端输入成本高，所以这里的对话框都尽量短：确认框只有一句话，
/// 输入框自动聚焦并支持回车提交。

/// 确认对话框。返回 `true` 表示用户点了确认按钮（取消 / 返回键都是 `false`）。
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  String cancelLabel = '取消',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error)
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 轻提示（`SnackBar`）。没有 `ScaffoldMessenger` 时静默忽略。
///
/// 报错吐司**必须自己给文字色**：`SnackBar` 的默认文字色来自主题里的
/// `inverseOnSurface`（浅色主题下几乎纯白），底色一旦换成浅色的 `errorContainer`，
/// 白字压在浅红底上等于看不见 —— 实机反馈的"点了「已完成」之后那句提示看不清"
/// 就是这里（子节点没做完时，点完成会被规则拦下来并给一句解释）。
void showToast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        // 只覆盖颜色：字号等仍走主题给的默认文字样式
        style: error ? TextStyle(color: scheme.onErrorContainer) : null,
      ),
      backgroundColor: error ? scheme.errorContainer : null,
    ),
  );
}
