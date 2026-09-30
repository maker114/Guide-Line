import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/project.dart';
import '../../core/models/project_item.dart';
import '../common/dialogs.dart';
import '../common/event_picker.dart';
import '../common/inline_editor.dart';
import '../events/event_detail_page.dart';

/// 项目「实现」的**实现清单**（《数据契约》§3.2.1）。
///
/// 口径用词（Q4）：项目里的叫「清单」/「实现清单」，**"待办"只指事件里的任务**。
///
/// 四条必须守住的性质：
///   · **不参与任何业务判定** —— 勾选只是打勾，全勾完也不会把项目变成已完成
///     （项目**根本没有完成态**，见 Q1）。进度 `n/m` 只是展示；
///   · **与事件里的任务没有联动** —— 这里勾了不代表任务线那边动了；
///   · 唯一的出口是「**建成任务…**」（Q24）：把这一条**一次性**建成某个事件末尾的
///     一条任务。建完条目**留着、也不自动打勾** —— 清单只是一份笔记，
///     删不删由用户决定（《定义与边界》§2.1 / §2.3）。建完**依旧没有联动**；
///   · 条目是轻量内容：删除**不弹二次确认**（误删重打一句就好，
///     弹确认反而烦），编辑是点一下原地改。
///
/// 清单区的标题行在 `_FieldCard`（项目详情页）那边：进度 `n/m` 与
/// 「重拆 / 清空」的胶囊入口都挂在那里（Q32），这里不重复一个标题工具栏。
class ProjectChecklist extends StatelessWidget {
  const ProjectChecklist({
    super.key,
    required this.app,
    required this.project,
  });

  final AppController app;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = project.items;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 这里**没有**标题工具栏（2026-09-28）：进度 `n/m` 已按要求从「实现」
        // 卡片撤掉，「重拆」也交给了 AI（实机反馈：重拆功能由 AI 完成）。
        //
        // 一条都没有时**只留一句弱提示**：从前这里还有一个「从正文拆成条目」
        // 按钮，现在拆这一步的出口是下面那颗「AI 整理」——
        // 同一条路上不留两个入口，否则"该点哪个"本身就成了问题。
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Text('还没有条目', style: theme.textTheme.bodySmall),
          )
        else ...<Widget>[
          for (var i = 0; i < items.length; i += 1)
            _ItemRow(
              app: app,
              projectId: project.id,
              item: items[i],
              isFirst: i == 0,
              isLast: i == items.length - 1,
            ),
        ],
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
        // 「AI 整理成「如何解决」」那一行**不在这里**：它由 `_ImplementationField`
        // 统一画在卡片底部（两种模式各有一个收尾动作），见那边的注释。
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
      // 点文本**就地改**（与「有什么问题 / 思路」等字段一样用 `InlineTextField`），
      // **长按**才弹出条目操作 —— 这条路上移 / 下移 / 删除都有，但它是隐藏的，
      // 所以清单上方有一行说明兜着（Q32）。
      // 行尾那个"重命名"小铅笔也去掉了（实机反馈）：点这一行本身就是改名，
      // 再挂一个图标只是多一个看不出区别的记号。
      // 编辑态自带**确认 / 取消**两个键（现在是 `InlineTextField` 的默认，Q33）。
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

  /// 条目操作：长按弹出（**建成任务** / 上移 / 下移 / 删除）。
  ///
  /// 与清单上方的说明行、标题行的「重拆 / 清空」入口分工：这里管**单条**，
  /// 那里管**整份清单**。
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
            // 规划 → 执行的那座桥（Q24）：清单条目的**唯一出口**。
            // 副标题把三条边界写在门上：条目留着、只在某条事件末尾新建一条。
            ListTile(
              leading: const Icon(Icons.playlist_add_check),
              title: const Text('建成任务…'),
              subtitle: const Text('在某个事件末尾新建一条同名任务'),
              onTap: () => Navigator.of(sheetContext).pop('task'),
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
    if (action == 'task') {
      _buildTask(context);
      return;
    }
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

  /// 把这条清单条目**建成某个事件末尾的一条任务**（Q24）。
  ///
  /// 三条边界都在这里守住：
  ///   · 条目**不删、也不自动打勾** —— 它只是一份笔记，删不删由用户决定；
  ///   · 建完**不建立联动** —— 之后勾清单不影响那条任务，反之亦然（刻意定的口径）；
  ///   · 还没有事件时先说清下一步，别让用户对着一个空选择器发愣。
  Future<void> _buildTask(BuildContext context) async {
    final events =
        app.ws.liveEvents.where((e) => !e.archived).toList(growable: false);
    if (events.isEmpty) {
      showToast(context, '请先在「事件」中新建一条事件。');
      return;
    }

    final eventId = await pickEvent(context, app, title: '建成哪个事件的任务');
    if (eventId == null || !context.mounted) return;
    final eventName = app.ws.findEvent(eventId)?.name ?? '';

    final error = app.run(
      () => app.ws.createTaskFromProjectItem(
        projectId: projectId,
        itemId: item.id,
        eventId: eventId,
      ),
    );
    if (!context.mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    _announceCreatedTask(context, eventName, eventId);
  }

  /// 建成之后**必须交代三件事**：建在哪条线、条目还在、去哪儿看那条任务。
  ///
  /// 这里刻意不用 `showToast`：那条轻提示给不了"点一下就过去"的按钮，
  /// 而"我建的任务去哪了"正是这一句要回答的。
  void _announceCreatedTask(BuildContext context, String eventName, String eventId) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('已建成任务：$eventName，清单条目保留。'),
        action: SnackBarAction(
          label: '去看看',
          onPressed: () {
            if (!context.mounted) return;
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => EventDetailPage(app: app, eventId: eventId),
              ),
            );
          },
        ),
      ),
    );
  }
}
