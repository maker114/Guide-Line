import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/project.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import 'project_actions.dart';
import 'project_detail_page.dart';

/// 项目 Tab：**项目树（≤ 3 层）**。
///
/// 手机上没有树控件的余地，所以用「扁平化 + 缩进 + 展开箭头」渲染：
/// 折叠状态存在 `UiPrefs` 里，下次进来还是原样。
///
/// 新建与重命名都是**页面内直接输入**（见 `InlineComposer` / `InlineTextField`）：
/// 点一下原地变成输入框，不再弹对话框。
class ProjectTab extends StatefulWidget {
  const ProjectTab({super.key, required this.app});

  final AppController app;

  @override
  State<ProjectTab> createState() => _ProjectTabState();
}

class _ProjectTabState extends State<ProjectTab> {
  /// 正在重命名的项目 id
  String? _renamingId;

  /// 正在为哪个项目录子项目
  String? _addingChildOf;

  AppController get _app => widget.app;

  void _create({String? parentId, required String title}) {
    final error = _app.run(() => _app.ws.createProject(title: title, parentId: parentId));
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    // 加完子项目就把那一行的输入框收起来，避免列表里挂着一排展开的输入
    if (parentId != null) setState(() => _addingChildOf = null);
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.errorContainer : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _flatten(_app);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            rows.isEmpty ? '还没有项目' : '共 ${rows.length} 个项目',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: <Widget>[
              InlineComposer(
                label: '新建项目',
                hint: '项目名',
                leading: Icons.create_new_folder_outlined,
                onCreate: (title) => _create(title: title),
              ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '项目是「目的 + 实现」的容器，灵感可以合并进项目正文',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                for (final row in rows) ...<Widget>[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  _buildTile(row),
                  if (_addingChildOf == row.project.id)
                    Padding(
                      padding: EdgeInsets.only(left: 16.0 + row.depth * 16),
                      child: InlineComposer(
                        label: '新建子项目',
                        hint: '子项目名',
                        leading: Icons.subdirectory_arrow_right,
                        dense: true,
                        onCreate: (title) =>
                            _create(parentId: row.project.id, title: title),
                      ),
                    ),
                ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTile(_ProjectRow row) {
    final project = row.project;
    if (_renamingId == project.id) {
      return Padding(
        padding: EdgeInsets.only(left: 12.0 + row.depth * 16, right: 12),
        child: InlineTextField(
          value: project.title,
          autofocus: true,
          hint: '项目名',
          textStyle: Theme.of(context).textTheme.bodyLarge,
          onSubmitted: (title) =>
              _app.run(() => _app.ws.updateProject(project.id, title: title)),
          onEditClosed: () {
            if (mounted) setState(() => _renamingId = null);
          },
        ),
      );
    }
    return _ProjectTile(
      app: _app,
      row: row,
      onStartRename: () => setState(() => _renamingId = project.id),
      onStartAddChild: () => setState(() => _addingChildOf = project.id),
    );
  }
}

/// 一条扁平化后的项目行（已按折叠状态决定要不要展开后代）。
class _ProjectRow {
  const _ProjectRow({
    required this.project,
    required this.depth,
    required this.childCount,
    required this.expanded,
  });

  final Project project;
  final int depth;
  final int childCount;
  final bool expanded;
}

List<_ProjectRow> _flatten(AppController app) {
  final tree = app.ws.projectTree;
  final rows = <_ProjectRow>[];

  void walk(String? parentId, int depth) {
    for (final project in tree.childrenOf(parentId).whereType<Project>()) {
      if (project.archived) continue;
      final children = tree
          .childrenOf(project.id)
          .whereType<Project>()
          .where((p) => !p.archived)
          .toList(growable: false);
      final expanded = !app.isCollapsed(project.id);
      rows.add(
        _ProjectRow(
          project: project,
          depth: depth,
          childCount: children.length,
          expanded: expanded,
        ),
      );
      if (children.isNotEmpty && expanded) walk(project.id, depth + 1);
    }
  }

  walk(null, 0);
  return rows;
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.app,
    required this.row,
    required this.onStartRename,
    required this.onStartAddChild,
  });

  final AppController app;
  final _ProjectRow row;
  final VoidCallback onStartRename;
  final VoidCallback onStartAddChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = row.project;
    final due = describeDate(project.date);
    final overdue = isOverdue(project.date) && project.status != NodeStatus.done;

    return ListTile(
      contentPadding: EdgeInsets.only(left: 4.0 + row.depth * 16, right: 4),
      leading: row.childCount == 0
          ? Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Icon(
                nodeStatusIcon(project.status),
                size: 20,
                color: nodeStatusColor(project.status, theme.colorScheme),
              ),
            )
          : IconButton(
              tooltip: row.expanded ? '收起' : '展开',
              icon: Icon(row.expanded ? Icons.expand_more : Icons.chevron_right),
              onPressed: () => app.toggleCollapsed(project.id, row.expanded),
            ),
      title: Text(
        project.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: project.status == NodeStatus.done
            ? theme.textTheme.bodyLarge?.copyWith(
                decoration: TextDecoration.lineThrough,
                color: theme.colorScheme.outline,
              )
            : null,
      ),
      subtitle: _Subtitle(row: row, due: due, overdue: overdue),
      trailing: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (value) async {
          await _handleMenu(context, value);
        },
        itemBuilder: (_) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'child', child: Text('新建子项目')),
          PopupMenuItem<String>(value: 'open', child: Text('打开详情')),
          PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
          PopupMenuItem<String>(value: 'move', child: Text('移动到…')),
          PopupMenuItem<String>(value: 'archive', child: Text('归档')),
          PopupMenuItem<String>(value: 'delete', child: Text('删除')),
        ],
      ),
      onTap: () => _open(context),
    );
  }

  Future<void> _handleMenu(BuildContext context, String value) async {
    final project = row.project;
    switch (value) {
      case 'child':
        onStartAddChild();
        break;
      case 'open':
        await _open(context);
        break;
      case 'rename':
        onStartRename();
        break;
      case 'move':
        await moveProjectAction(context, app, project.id);
        break;
      case 'archive':
        await archiveProjectAction(context, app, project.id, archived: true);
        break;
      case 'delete':
        await deleteProjectAction(context, app, project.id);
        break;
    }
  }

  Future<void> _open(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProjectDetailPage(app: app, projectId: row.project.id),
      ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.row, required this.due, required this.overdue});

  final _ProjectRow row;
  final String due;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = row.project;
    final style = theme.textTheme.labelSmall;
    return Row(
      children: <Widget>[
        if (due.isNotEmpty) ...<Widget>[
          Icon(
            Icons.event,
            size: 13,
            color: overdue ? theme.colorScheme.error : theme.colorScheme.outline,
          ),
          const SizedBox(width: 3),
          Text(due, style: style?.copyWith(color: overdue ? theme.colorScheme.error : null)),
          const SizedBox(width: 10),
        ],
        if (row.childCount > 0) ...<Widget>[
          const Icon(Icons.account_tree_outlined, size: 13),
          const SizedBox(width: 3),
          Text('${row.childCount} 个子项目', style: style),
          const SizedBox(width: 10),
        ],
        if (project.purpose.isNotEmpty)
          Expanded(
            child: Text(
              project.purpose,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
      ],
    );
  }
}
