import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../features/workspace.dart';
import '../common/dialogs.dart';

/// 合并编辑器交回去的结果：**这条灵感落在哪、落了什么文本**。
class MergeResult {
  const MergeResult.intoImplementation(this.text) : asChecklistItem = false;

  const MergeResult.intoChecklist(this.text) : asChecklistItem = true;

  final String text;

  /// `true` = 作为清单的新一条追加；`false` = 写进「实现计划」
  final bool asChecklistItem;
}

/// 合并编辑器（**手机端形态**）：把一条灵感并进项目，页面上给**三种选择**。
///
/// ```
/// 实现计划（可编辑）                    ← 一进来就是当前正文
/// ┌──────────────────────────────────┐
/// │ （正文原文，编辑框）                │
/// └──────────────────────────────────┘
///  [追加原文]   [作为清单条目]
///  灵感原文（参考）
/// ```
///
///   1. **手改正文**：照着这条灵感把正文改清楚，改完点右上角「保存」→ 替换
///      「实现计划」；
///   2. **追加原文**：把灵感文本原封不动**另起一行**接到正文末尾（只改编辑框，
///      仍要点保存才写盘；不润色、不改写）；
///   3. **作为清单条目**：不碰正文，直接把它追加成「实现清单」的新一条。
///
/// 三个动作都以"这条灵感已经处理掉"收尾（置为 `merged`，原文可在归档区
/// 「已合并」找回）。第 3 种是**立刻结束**的：编辑框里没保存的改动不会写回，
/// 所以它单独做成一个按钮，而不是混进「保存」。
class MergeEditorPage extends StatefulWidget {
  const MergeEditorPage({super.key, required this.project, required this.inspiration});

  final Project project;
  final Inspiration inspiration;

  @override
  State<MergeEditorPage> createState() => _MergeEditorPageState();
}

class _MergeEditorPageState extends State<MergeEditorPage> {
  /// 编辑框的初值 = **当前的「实现计划」**（不是灵感原文）
  late final TextEditingController _implementation =
      TextEditingController(text: widget.project.implementation);
  bool _referenceExpanded = false;

  @override
  void dispose() {
    _implementation.dispose();
    super.dispose();
  }

  /// 选择一：把改好的正文写回「实现计划」。
  void _save() {
    final text = _implementation.text.trim();
    if (text.isEmpty) {
      // 空正文会把「实现计划」清没，业务层同样会拒；提示留在这一页更近
      showToast(context, '正文不能是空的（想只留清单条目就用「作为清单条目」）', error: true);
      return;
    }
    Navigator.of(context).pop(MergeResult.intoImplementation(text));
  }

  /// 选择二：灵感原文原封不动作为新的一行接到末尾（**仍要点保存**）。
  void _appendOriginal() {
    final next = Workspace.appendToImplementation(
      _implementation.text,
      widget.inspiration.text,
    );
    _implementation.text = next;
    _implementation.selection = TextSelection.collapsed(offset: next.length);
  }

  /// 选择三：不碰正文，直接把它追加成清单的新一条（点一下即结束合并）。
  void _asChecklistItem() {
    Navigator.of(context).pop(MergeResult.intoChecklist(widget.inspiration.text));
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
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            child: Row(
              children: <Widget>[
                Text('实现计划（可编辑）', style: theme.textTheme.labelLarge),
                const Spacer(),
                // 「追加原文」：不做润色、也不直接写盘 —— 用户还能在保存前再调一下
                TextButton.icon(
                  onPressed: _appendOriginal,
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('追加原文'),
                ),
              ],
            ),
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
                  hintText: '照着这条灵感把正文改清楚，改完点右上角「保存」',
                ),
              ),
            ),
          ),
          // 三个选择里最"一键"的那一个：直接把它变成清单的一条待办
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _asChecklistItem,
                icon: const Icon(Icons.checklist, size: 18),
                label: const Text('作为清单条目'),
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
              '「追加原文」和手改都走「保存」：保存后项目正文更新，这条灵感从灵感箱消失。'
              '「作为清单条目」不碰正文，直接把原文追加成清单的新一条（上面没保存的改动不会写回）。'
              '两种情况都能在「更多 → 归档区 → 已合并」撤销。',
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

/// 把合并编辑器交回来的结果落到数据上（项目侧与灵感侧两个入口共用）。
///
/// 两条路都走 `Workspace` 的跨文档动作（正文或清单 + 灵感状态一次落盘），
/// 所以这里只负责"选哪条 + 给一句提示"。
Future<void> applyMergeResult(
  BuildContext context,
  AppController app,
  Project project,
  Inspiration inspiration,
  MergeResult result,
) async {
  final error = app.run(() {
    if (result.asChecklistItem) {
      app.ws.mergeInspirationAsItem(
        inspirationId: inspiration.id,
        projectId: project.id,
        itemText: result.text,
      );
    } else {
      app.ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: result.text,
      );
    }
  });
  if (!context.mounted) return;
  if (error != null) {
    showToast(context, error, error: true);
    return;
  }
  showToast(
    context,
    result.asChecklistItem
        ? '已追加到「${project.title}」的清单，原文可在归档区「已合并」找回'
        : '已合并进「${project.title}」，原文可在归档区「已合并」找回',
  );
}
