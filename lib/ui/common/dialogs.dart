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
void showToast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.errorContainer : null,
    ),
  );
}
