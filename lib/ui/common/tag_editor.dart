import 'package:flutter/material.dart';

/// 标签编辑（灵感整理第 5 条）：一次性返回编辑好的标签列表。
///
/// 做成底部面板而不是对话框：手机上填"/删标签"是连续动作，面板里能一边看已有标签
/// 一边敲新的，比"输入框 + 确定"的对话框顺手。返回 `null` 表示用户取消。
Future<List<String>?> editTags(
  BuildContext context, {
  required List<String> initial,
  String title = '标签',
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TagEditorSheet(initial: initial, title: title),
  );
}

class _TagEditorSheet extends StatefulWidget {
  const _TagEditorSheet({required this.initial, required this.title});

  final List<String> initial;
  final String title;

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  late final List<String> _tags = <String>[...widget.initial];
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      // 与 `Workspace.updateInspirationTags` / `Canonical.readStringList` 同一套口径：
      // 去空格、丢空串、**按首次出现顺序去重**
      if (!_tags.contains(text)) _tags.add(text);
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 键盘弹起来时把面板顶上去，输入框才不会被挡住
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(widget.title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '标签只是给自己分类用的，不影响归档与完成判定。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_tags.isEmpty)
                Text('还没有标签', style: theme.textTheme.bodySmall)
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final tag in _tags)
                      InputChip(
                        label: Text(tag),
                        onDeleted: () => setState(() => _tags.remove(tag)),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _add(),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '加一个标签，回车确认',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: '添加标签',
                    icon: const Icon(Icons.add),
                    onPressed: _add,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_tags),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
