import 'package:flutter/material.dart';

import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../common/dialogs.dart';

/// 合并编辑器（**手机端形态**）。
///
/// 合并的落点是项目的**实现清单**：这条灵感会被追加成清单的**新的一条**
/// （2026-09-25 实机反馈）。原先它写进「实现」正文 —— 但合并本来就该产出一件
/// "要做的事"，往一段文字里再添一句，做的时候还得自己去清单里重打一遍。
///
/// 编辑框**一进来就是灵感原文**：直接点保存 = 原文原样成为新条目；也可以先
/// 改成一句更清楚的话再保存 —— 改的只是这一条条目的措辞，不改写原灵感
/// （原文照旧在归档区「已合并」里）。
///
/// 保存后由调用方写入：清单追加条目 + 灵感置为 `merged`。
class MergeEditorPage extends StatefulWidget {
  const MergeEditorPage({super.key, required this.project, required this.inspiration});

  final Project project;
  final Inspiration inspiration;

  @override
  State<MergeEditorPage> createState() => _MergeEditorPageState();
}

class _MergeEditorPageState extends State<MergeEditorPage> {
  late final TextEditingController _itemText =
      TextEditingController(text: widget.inspiration.text);

  @override
  void dispose() {
    _itemText.dispose();
    super.dispose();
  }

  void _save() {
    final text = _itemText.text.trim();
    if (text.isEmpty) {
      // 清空了就不提交：条目不允许空文字（业务层同样会拒），留在这里提示更近
      showToast(context, '条目内容不能为空', error: true);
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('合并进「${widget.project.title}」', overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('要追加的清单条目（可编辑）', style: theme.textTheme.labelLarge),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _itemText,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '这条要做什么',
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              '保存后：这条灵感成为「${widget.project.title}」实现清单的新条目，'
              '从灵感箱消失（可在「更多 → 归档区 → 已合并」撤销）。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
