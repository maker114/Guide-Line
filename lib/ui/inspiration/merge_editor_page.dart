import 'package:flutter/material.dart';

import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';

/// 合并编辑器（**手机端形态**）。
///
/// 手机上放不下"上下分区同时可见"，因此按归档设计的建议做适配：
/// 上区仍是可编辑的项目「实现」，下区的灵感原文默认**折叠成一条可展开的参考条**。
///
/// 保存后由调用方写入：项目正文更新 + 灵感置为 `merged`（原灵感可在归档区撤销）。
class MergeEditorPage extends StatefulWidget {
  const MergeEditorPage({super.key, required this.project, required this.inspiration});

  final Project project;
  final Inspiration inspiration;

  @override
  State<MergeEditorPage> createState() => _MergeEditorPageState();
}

class _MergeEditorPageState extends State<MergeEditorPage> {
  late final TextEditingController _implementation =
      TextEditingController(text: widget.project.implementation);
  bool _referenceExpanded = false;

  @override
  void dispose() {
    _implementation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('合并进「${widget.project.title}」', overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_implementation.text),
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('项目的「实现」内容（可编辑）', style: theme.textTheme.labelLarge),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _implementation,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '把下面这条灵感的内容整合进来（不会自动追加）',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _ReferencePanel(
            text: widget.inspiration.text,
            expanded: _referenceExpanded,
            onToggle: () => setState(() => _referenceExpanded = !_referenceExpanded),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              '保存后：项目正文更新，这条灵感从灵感箱消失（可在「更多 → 归档区 → 已合并」撤销）。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReferencePanel extends StatelessWidget {
  const _ReferencePanel({
    required this.text,
    required this.expanded,
    required this.onToggle,
  });

  final String text;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            dense: true,
            leading: const Icon(Icons.lightbulb_outline, size: 18),
            title: Text('灵感原文（参考）', style: theme.textTheme.labelLarge),
            trailing: Icon(expanded ? Icons.expand_more : Icons.expand_less),
            onTap: onToggle,
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SelectableText(text, style: theme.textTheme.bodyMedium),
              ),
            ),
        ],
      ),
    );
  }
}
