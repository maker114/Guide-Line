import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/models/project_item.dart';
import '../../features/workspace.dart';
import '../common/dialogs.dart';
import '../common/project_picker.dart';

/// 合并编辑器交回去的结果：**这次并的灵感落在哪、落了什么文本**。
class MergeResult {
  /// 落点一 / 二：写进「如何解决」的**新正文**。
  ///
  /// 多条一起并时，"追加原文"已经在编辑器里按顺序接好了，这里拿到的就是
  /// 最终的整段正文 —— 落盘的是一条相同的路（替换正文）。
  const MergeResult.intoImplementation(this.text)
      : asChecklistItem = false,
        itemTexts = const <String>[];

  /// 落点三：作为「实现清单」的新条目，**一条灵感一条**，顺序即顺序。
  const MergeResult.intoChecklist({required this.itemTexts})
      : asChecklistItem = true,
        text = '';

  /// 落点一 / 二的新正文（落点三用不到它，那时正文一个字都不动）。
  final String text;

  /// 落点三要追加的清单条目文本，与带进编辑器的灵感**一一对应**。
  final List<String> itemTexts;

  /// `true` = 作为清单的新条目追加；`false` = 写进「如何解决」
  final bool asChecklistItem;
}

/// 合并编辑器（**手机端形态**）：把灵感并进**目标**，页面上给**三种选择**。
///
/// ```
/// 如何解决（可编辑）                    ← 一进来就是当前正文
/// ┌──────────────────────────────────┐
/// │ （正文原文，编辑框）                │
/// └──────────────────────────────────┘
///  [追加原文]   [作为清单条目]
///  灵感原文（参考）                     ← 多条一起并时按顺序列出来、默认展开
/// ```
///
///   1. **手改正文**：照着灵感把正文改清楚，改完点右上角「保存」→ 替换
///      「如何解决」；
///   2. **追加原文**：把灵感文本原封不动**另起一行**接到正文末尾（多条则
///      **按顺序各占一行**；只改编辑框，仍要点保存才写盘；不润色、不改写）；
///   3. **作为清单条目**：不碰正文，直接把它追加成「实现清单」的新一条
///      （多条则**各成一条**，顺序就是带进来的顺序）。
///
/// 三个动作都以"这些灵感已经处理掉"收尾（置为 `merged`，原文可在归档区
/// 「已合并」找回）。第 3 种是**立刻结束**的：编辑框里没保存的改动不会写回，
/// 所以它单独做成一个按钮，而不是混进「保存」。
///
/// **落点只能是目标**（Q2）：走到这一页的项目若已经有下级（= 分类），
/// 这一页不给任何合并动作，只说明原因 —— 分类只回答"归哪一类"，不装灵感。
class MergeEditorPage extends StatefulWidget {
  /// 单条合并（项目详情页那条老路）：一条灵感，行为一字不变。
  MergeEditorPage({
    super.key,
    required this.project,
    required Inspiration inspiration,
    this.isCategory = false,
  }) : inspirations = <Inspiration>[inspiration];

  /// **多选合并**：一次把选中的多条带进来（新版修改计划 Q37 的那一条）。
  ///
  /// [inspirations] 的顺序**就是**灵感列表上从上到下的顺序 ——
  /// 「追加原文」各占一行、「作为清单条目」各成一条，都按它来；
  /// 编辑器里的「灵感原文（参考）」也照它列，让用户看得出这次并的是哪几条。
  const MergeEditorPage.many({
    super.key,
    required this.project,
    required this.inspirations,
    this.isCategory = false,
  });

  final Project project;

  /// 这次要并的灵感（至少一条）。
  final List<Inspiration> inspirations;

  /// 这个项目**此刻是不是分类**（有未归档、未删除的直属下级）。
  ///
  /// 分类不装灵感（Q2）：为 `true` 时这一页**不给任何合并动作**，只说明原因。
  /// 由调用方传 —— 这一页只拿得到一个 `Project` 快照，而"有没有下级"要看整棵树。
  /// 默认 `false` 只覆盖"灵感页那条入口"的历史数据：那条路走 `pickProject`，
  /// 选择器已经把分类挡在外面了。
  final bool isCategory;

  @override
  State<MergeEditorPage> createState() => _MergeEditorPageState();
}

class _MergeEditorPageState extends State<MergeEditorPage> {
  /// 编辑框的初值 = **当前的「如何解决」**（不是灵感原文）
  late final TextEditingController _implementation =
      TextEditingController(text: widget.project.implementation);

  /// 两块参考面板是否展开。
  ///
  /// **两块都默认展开**（2026-09-27 实机反馈："追加新灵感时默认展开灵感内容，
  /// 同时显示已有的清单"）。从前单条合并时灵感原文是收起的 ——
  /// 而"这次并的是哪一句"正是合并时最要看的东西，收起它等于让人凭记忆核对。
  /// 参考区有 `maxHeight: 200` 兜着，展开也不会把编辑框挤没。
  bool _referenceExpanded = true;
  bool _checklistExpanded = true;

  /// 这次要并的灵感原文，**顺序即列表顺序**（参考面板与落点三共用一份）。
  List<String> get _originalTexts =>
      <String>[for (final inspiration in widget.inspirations) inspiration.text];

  /// 这个项目**已有的清单条目**，供参考（只读）。
  ///
  /// 为什么要露出来：三选一里的「作为清单条目」是**往后追加**，用户在按之前
  /// 得先看得见已经有哪些条目，否则同一个意思很容易并成两条。
  /// 这里只读 —— 打勾与改字都在项目详情页，编辑器不做第二处清单编辑。
  List<ProjectItem> get _existingItems => widget.project.items;

  @override
  void dispose() {
    _implementation.dispose();
    super.dispose();
  }

  /// 选择一：把改好的正文写回「如何解决」。
  ///
  /// 「一进来就是这个值、用户一个字没改」时**不保存**（Q8）：那样"合并"实际
  /// 什么都没发生，灵感却会被标成已合并并离开灵感箱。业务层（`mergeInspirations`）
  /// 同样会拒 —— 这里挡一道只是为了把话说在离用户最近的这一层。
  void _save() {
    final text = _implementation.text.trim();
    if (text.isEmpty) {
      // 空正文会把「如何解决」清没，业务层同样会拒；提示留在这一页更近
      showToast(context, '正文不能是空的；想只留清单条目就用「作为清单条目」', error: true);
      return;
    }
    if (text == widget.project.implementation.trim()) {
      showToast(context, implementationUnchanged, error: true);
      return;
    }
    Navigator.of(context).pop(MergeResult.intoImplementation(text));
  }

  /// 选择二：灵感原文原封不动作为新的一行接到末尾（多条**按顺序各占一行**，
  /// **仍要点保存**）。
  void _appendOriginal() {
    var next = _implementation.text;
    for (final inspiration in widget.inspirations) {
      next = Workspace.appendToImplementation(next, inspiration.text);
    }
    _implementation.text = next;
    _implementation.selection = TextSelection.collapsed(offset: next.length);
  }

  /// 选择三：不碰正文，直接把原文**各成一条**追加进清单（点一下即结束合并）。
  void _asChecklistItem() {
    Navigator.of(context).pop(
      MergeResult.intoChecklist(itemTexts: _originalTexts),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 分类不是灵感的落点（Q2）：不给任何合并动作，只说清为什么、该怎么办
    if (widget.isCategory) {
      return Scaffold(
        appBar: AppBar(
          title: Text('合并进「${widget.project.title}」', overflow: TextOverflow.ellipsis),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(categoryNotForInspiration, style: theme.textTheme.titleMedium),
            ),
            _ReferencePanel(
              texts: _originalTexts,
              expanded: _referenceExpanded,
              onToggle: () => setState(() => _referenceExpanded = !_referenceExpanded),
            ),
            _ExistingChecklistPanel(
              items: _existingItems,
              expanded: _checklistExpanded,
              onToggle: () => setState(() => _checklistExpanded = !_checklistExpanded),
            ),
          ],
        ),
      );
    }
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
                // 标题**必须能缩**（`Flexible` + 省略号）：「追加原文」是固定宽度的按钮，
                // 标题一旦比剩余宽度长就会把整行顶出去 —— 深色 + 1.6 倍字体 + 窄屏下
                // 实测溢出 19px（改文案时字数变多就会踩到，与文案好坏无关）。
                Flexible(
                  child: Text(
                    '如何解决 · 可编辑',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
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
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: '改成你要的样子',
                ),
              ),
            ),
          ),
          // 三个选择里最"一键"的那一个：直接把它（们）变成清单的一条（每条一条）
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
          // 已有的清单摆在灵感原文**下面**：先看清"这次要并的是什么"，
          // 再对照"项目里已经有什么"决定落点（实机反馈：同时显示已有的清单）
          _ExistingChecklistPanel(
            items: _existingItems,
            expanded: _checklistExpanded,
            onToggle: () => setState(() => _checklistExpanded = !_checklistExpanded),
          ),
          _ReferencePanel(
            texts: _originalTexts,
            expanded: _referenceExpanded,
            onToggle: () => setState(() => _referenceExpanded = !_referenceExpanded),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              // 唯一必须留的一句：恢复灵感**不会**把已经写进项目的内容退回去
              '「恢复为待处理」只把灵感放回灵感箱，项目里的内容不会退回。',
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
    required this.texts,
    required this.expanded,
    required this.onToggle,
  });

  /// 这次并的灵感原文，**按列表顺序**列出（顺序就是落进项目的顺序）。
  final List<String> texts;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final many = texts.length > 1;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            dense: true,
            leading: const Icon(Icons.lightbulb_outline, size: 18),
            // 多条时把条数写进标题：用户得先知道"这次并的是几条"
            title: Text(
              many ? '灵感原文 · 参考 ${texts.length} 条' : '灵感原文 · 参考',
              style: theme.textTheme.labelLarge,
            ),
            trailing: Icon(expanded ? Icons.expand_more : Icons.expand_less),
            onTap: onToggle,
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (var index = 0; index < texts.length; index += 1) ...<Widget>[
                      if (index > 0) const SizedBox(height: 8),
                      // 多条时前面给个序号：顺序是这一页的承诺（各占一行 / 各成一条）
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          if (many)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Text('${index + 1}', style: theme.textTheme.labelSmall),
                            ),
                          Expanded(
                            child: SelectableText(
                              texts[index],
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 项目**已有的实现清单**（只读参考）。
///
/// 为什么要有这一块：三选一里的「作为清单条目」是往后追加，按之前得先看得见
/// 已经有哪些条目 —— 不然同一个意思并两次，而且没有任何地方提示"已经有了"。
///
/// **只读**：打勾、改字、上移下移都在项目详情页。一个参考面板里再塞一套编辑
/// 动作，用户在合并这一页就分不清自己在动哪一层（与分类页展开区的取舍同一条口径）。
class _ExistingChecklistPanel extends StatelessWidget {
  const _ExistingChecklistPanel({
    required this.items,
    required this.expanded,
    required this.onToggle,
  });

  final List<ProjectItem> items;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 一条都没有就整块不画：空面板只会白占一屏
    if (items.isEmpty) return const SizedBox.shrink();
    final done = items.where((item) => item.done).length;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            dense: true,
            leading: const Icon(Icons.checklist, size: 18),
            // 进度写进标题：并之前先知道"这个项目已经做了多少"
            title: Text(
              '项目已有的清单 $done/${items.length}',
              style: theme.textTheme.labelLarge,
            ),
            trailing: Icon(expanded ? Icons.expand_more : Icons.expand_less),
            onTap: onToggle,
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(
                              item.done
                                  ? Icons.check_box_outlined
                                  : Icons.check_box_outline_blank,
                              size: 16,
                              color: item.done
                                  ? theme.colorScheme.outline
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                item.text,
                                style: item.done
                                    ? theme.textTheme.bodyMedium?.copyWith(
                                        decoration: TextDecoration.lineThrough,
                                        color: theme.colorScheme.outline,
                                      )
                                    : theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 把合并编辑器交回来的结果落到数据上（**单条**：项目详情页那条老路）。
///
/// 与灵感页多选那条路走**同一个** [applyMergeResultFor]，只是带一条灵感进去 ——
/// 两条路的校验与提示因此不可能各说各话。
Future<bool> applyMergeResult(
  BuildContext context,
  AppController app,
  Project project,
  Inspiration inspiration,
  MergeResult result,
) {
  return applyMergeResultFor(
    context,
    app,
    project,
    inspirations: <Inspiration>[inspiration],
    result: result,
  );
}

/// 把合并编辑器交回来的结果落到数据上（**支持多条**，Q37）。
///
/// 这里只负责"选哪个项目 + 给一句提示"；真正的跨文档改动走 `Workspace` 的
/// 批量动作（项目正文 / 清单 + 那些灵感的状态**一次落盘**）。
///
/// **落点只能是目标**（Q2）：这里再挡一道 —— 万一入口那侧没把手上的项目判准
/// （它是快照，看不到"有没有下级"），到了写数据这一步也不会悄悄落进分类。
/// 「正文没变」同样在**落盘这一步**再挡（Q8）：传进来的 `project` 是快照，
/// 拿它比对会漏掉"用户在别处刚改过正文"的情况 —— 以库里的当前值为准。
///
/// 返回 `true` 表示真的写进去了（灵感页据此决定要不要退出多选）。
Future<bool> applyMergeResultFor(
  BuildContext context,
  AppController app,
  Project project, {
  required List<Inspiration> inspirations,
  required MergeResult result,
}) async {
  if (app.ws.isProjectCategory(project.id)) {
    showToast(context, categoryNotForInspiration, error: true);
    return false;
  }
  if (!result.asChecklistItem &&
      result.text.trim() == (app.ws.findProject(project.id)?.implementation ?? '').trim()) {
    showToast(context, implementationUnchanged, error: true);
    return false;
  }
  final error = app.run(() {
    app.ws.mergeInspirations(
      inspirationIds: <String>[for (final inspiration in inspirations) inspiration.id],
      projectId: project.id,
      landing: result.asChecklistItem ? MergeLanding.checklist : MergeLanding.implementation,
      newImplementation: result.text,
      itemTexts: result.itemTexts,
    );
  });
  if (!context.mounted) return false;
  if (error != null) {
    showToast(context, error, error: true);
    return false;
  }
  final count = inspirations.length;
  final String message;
  if (result.asChecklistItem) {
    message = count > 1
        ? '已把 $count 条灵感追加到「${project.title}」的清单，原文可在归档区「已合并」找回'
        : '已追加到「${project.title}」的清单，原文可在归档区「已合并」找回';
  } else {
    message = count > 1
        ? '已把 $count 条灵感并进「${project.title}」，原文可在归档区「已合并」找回'
        : '已合并进「${project.title}」，原文可在归档区「已合并」找回';
  }
  showToast(context, message);
  return true;
}
