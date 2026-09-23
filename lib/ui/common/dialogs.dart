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

/// 文本输入对话框。
///
/// 返回 `null` 表示取消；空白输入也返回 `null`（业务规则里"名字不能为空"
/// 属于用户错误，不该由调用方逐个再判一遍）。
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initialText = '',
  String? hintText,
  String confirmLabel = '保存',
  int maxLines = 1,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      initialText: initialText,
      hintText: hintText,
      confirmLabel: confirmLabel,
      maxLines: maxLines,
    ),
  );
  final trimmed = result?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
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

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.initialText,
    required this.hintText,
    required this.confirmLabel,
    required this.maxLines,
  });

  final String title;
  final String initialText;
  final String? hintText;
  final String confirmLabel;
  final int maxLines;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final multiline = widget.maxLines > 1;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: multiline ? 3 : 1,
        maxLines: widget.maxLines,
        textInputAction: multiline ? TextInputAction.newline : TextInputAction.done,
        decoration: InputDecoration(hintText: widget.hintText, border: const OutlineInputBorder()),
        onSubmitted: multiline ? null : (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
