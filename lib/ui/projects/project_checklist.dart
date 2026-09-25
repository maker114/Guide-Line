import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/project.dart';
import '../../core/models/project_item.dart';
import '../common/dialogs.dart';
import '../common/inline_editor.dart';
import 'ai_preview_page.dart';

/// 项目「实现」的**待办清单**（设计文档 §1.3）。
///
/// 三条必须守住的性质：
///   · **不参与任何业务判定** —— 勾选只是打勾，全勾完也不会把项目变成已完成。
///     进度 `n/m` 只是展示，项目的三态由它自己决定；
///   · **与事件里的任务没有联动** —— 这里勾了不代表任务线那边动了；
///   · 条目是轻量内容：删除**不弹二次确认**（误删重打一句就好，
///     弹确认反而烦），编辑是点一下原地改。
class ProjectChecklist extends StatelessWidget {
  const ProjectChecklist({
    super.key,
    required this.app,
    required this.project,
    required this.onSplitFromImplementation,
  });

  final AppController app;
  final Project project;

  /// 「从正文拆成条目」——由调用方处理（它要决定拆完怎么提示）
  final VoidCallback onSplitFromImplementation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = project.items;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 标题与进度由外面的 `_FieldCard` 给（那里显示 n/m），
        // 这里只保留"清单操作"菜单，免得同一块出现两个「实现清单」。
        if (items.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: PopupMenuButton<String>(
              tooltip: '清单操作',
              onSelected: (value) {
                switch (value) {
                  case 'split':
                    onSplitFromImplementation();
                    break;
                  case 'clear':
                    _confirmClear(context);
                    break;
                }
              },
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'split', child: Text('清空后从正文重拆…')),
                PopupMenuItem<String>(value: 'clear', child: Text('清空清单')),
              ],
            ),
          ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('还没有条目。把「实现」拆成一条条待办，做起来更清楚。',
                    style: theme.textTheme.bodySmall),
                if (project.implementation.trim().isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onSplitFromImplementation,
                      icon: const Icon(Icons.splitscreen_outlined, size: 18),
                      label: const Text('从正文拆成条目'),
                    ),
                  ),
              ],
            ),
          )
        else
          for (var i = 0; i < items.length; i += 1)
            _ItemRow(
              app: app,
              projectId: project.id,
              item: items[i],
              isFirst: i == 0,
              isLast: i == items.length - 1,
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
          child: InlineComposer(
            label: '添加条目',
            hint: '这条要做什么',
            leading: Icons.add,
            dense: true,
            onCreate: (text) => _run(context, () => app.ws.addProjectItem(project.id, text)),
          ),
        ),
        // AI 整理：把清单**反向压成**一段通顺的实现正文（设计文档 §2.1）。
        // 只在有清单时才给入口 —— 空清单没什么可整理的。
        if (items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.auto_awesome_outlined, size: 18),
              title: const Text('AI 整理成正文'),
              subtitle: const Text('把清单合成一段通顺说明，写进「实现正文」'),
              onTap: () => startAiSummarize(context, app, project.id, project.title),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await confirmAction(
      context,
      title: '清空清单',
      message: '会删掉全部 ${project.items.length} 条条目。\n'
          '「实现」的正文不会动，可以再从正文拆一次。',
      confirmLabel: '清空',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    _run(context, () => app.ws.clearProjectItems(project.id));
  }

  void _run(BuildContext context, void Function() action) {
    final error = app.run(action);
    if (error != null && context.mounted) showToast(context, error, error: true);
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.app,
    required this.projectId,
    required this.item,
    required this.isFirst,
    required this.isLast,
  });

  final AppController app;
  final String projectId;
  final ProjectItem item;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      // 点文本**就地改**（与「目的」等字段一样用 `InlineTextField`），
      // **长按**才弹出条目操作。原来行尾挂了一个三个点，实机反馈"意义不明" ——
      // 编辑本来是最常用的动作，直接点就行，不必先开菜单。
      onLongPress: () => _showActions(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
        child: Row(
          children: <Widget>[
            Checkbox(
              value: item.done,
              onChanged: (value) {
                final error = app.run(
                  () => app.ws.setProjectItemDone(projectId, item.id, value ?? false),
                );
                if (error != null && context.mounted) showToast(context, error, error: true);
              },
            ),
            Expanded(
              child: InlineTextField(
                value: item.text,
                hint: '这条要做什么',
                maxLines: 3,
                textStyle: item.done
                    ? theme.textTheme.bodyMedium?.copyWith(
                        decoration: TextDecoration.lineThrough,
                        color: theme.colorScheme.outline,
                      )
                    : theme.textTheme.bodyMedium,
                onSubmitted: (text) {
                  final error =
                      app.run(() => app.ws.updateProjectItemText(projectId, item.id, text));
                  if (error != null && context.mounted) {
                    showToast(context, error, error: true);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 条目操作：长按弹出（删除 / 上移 / 下移）。
  ///
  /// 删除**不弹二次确认**：条目是轻量内容，误删重打一句就好。
  Future<void> _showActions(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                item.text,
                style: Theme.of(sheetContext).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isFirst)
              ListTile(
                leading: const Icon(Icons.arrow_upward),
                title: const Text('上移'),
                onTap: () => Navigator.of(sheetContext).pop('up'),
              ),
            if (!isLast)
              ListTile(
                leading: const Icon(Icons.arrow_downward),
                title: const Text('下移'),
                onTap: () => Navigator.of(sheetContext).pop('down'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (value == null || !context.mounted) return;
    _act(context, value);
  }

  Future<void> _edit(BuildContext context) async {
    final controller = TextEditingController(text: item.text);
    final next = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑条目'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '这条要做什么',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // 弹窗还在做退场动画时那个 TextField 仍然活着，**不能立刻 dispose 控制器**
    // ——否则会撞上"正在构建的元素被 dispose"。推到下一帧之后再释放。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (next == null || !context.mounted) return;
    final error = app.run(() => app.ws.updateProjectItemText(projectId, item.id, next));
    if (error != null && context.mounted) showToast(context, error, error: true);
  }

  void _act(BuildContext context, String action) {
    void Function()? job;
    switch (action) {
      case 'edit':
        _edit(context);
        return;
      case 'up':
        job = () => app.ws.moveProjectItem(projectId, item.id, -1);
        break;
      case 'down':
        job = () => app.ws.moveProjectItem(projectId, item.id, 1);
        break;
      case 'delete':
        // 条目是轻量内容，**不弹二次确认**
        job = () => app.ws.removeProjectItem(projectId, item.id);
        break;
    }
    if (job == null) return;
    final error = app.run(job);
    if (error != null && context.mounted) showToast(context, error, error: true);
  }
}
