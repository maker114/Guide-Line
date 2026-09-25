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
        // 这里**没有**自己的标题工具栏：标题与进度由外面的 `_FieldCard` 给
        // （那里显示 n/m）。原来这里还挂着一个「清单操作」的更多按钮，
        // 它一个人占一整行、又只有"重拆 / 清空"两件事（实机反馈：影响美观、
        // 没什么用），整个去掉了。想重来就长按条目删掉，或直接改条目文字。
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
        // AI 整理：把清单**反向压成**一段通顺的实现说明（设计文档 §2.1）。
        // 只在有清单时才给入口 —— 空清单没什么可整理的。
        if (items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.auto_awesome_outlined, size: 18),
              title: const Text('AI 整理成计划'),
              subtitle: const Text('把清单合成一段通顺说明，写进「实现计划」'),
              onTap: () => startAiSummarize(context, app, project.id, project.title),
            ),
          ),
      ],
    );
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
      // **长按**才弹出条目操作。行尾那个"重命名"小铅笔也去掉了（实机反馈）：
      // 点这一行本身就是改名，再挂一个图标只是多一个看不出区别的记号。
      // 编辑态自带**确认 / 取消**两个键 —— 改到一半想放弃时不用自己改回去。
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
                showEditIcon: false,
                editorActions: true,
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

  void _act(BuildContext context, String action) {
    void Function()? job;
    switch (action) {
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
