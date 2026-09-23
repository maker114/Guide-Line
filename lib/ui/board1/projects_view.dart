import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/project.dart';
import '../../core/rules/cascade.dart';
import '../../core/rules/completion.dart';
import '../shared/widgets.dart';

/// 板块一左栏：项目树（≤3 层、可折叠、归档项目不在主视图出现）。
class ProjectTreePane extends StatelessWidget {
  const ProjectTreePane({
    super.key,
    required this.app,
    required this.selectedId,
    required this.onSelect,
  });

  final AppController app;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final roots = ws.projectTree
        .childrenOf(null)
        .whereType<Project>()
        .where((p) => !p.archived)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionLabel(
          '项目与灵感',
          trailing: IconButton(
            tooltip: '新建项目',
            icon: const Icon(Icons.add),
            onPressed: () => _createProject(context, null),
          ),
        ),
        Expanded(
          child: roots.isEmpty
              ? EmptyState(
                  icon: Icons.account_tree_outlined,
                  title: '还没有项目',
                  hint: '先建一个项目，把灵感收拢进去',
                  action: FilledButton.icon(
                    onPressed: () => _createProject(context, null),
                    icon: const Icon(Icons.add),
                    label: const Text('新建项目'),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: _rows(context, roots, 0),
                ),
        ),
      ],
    );
  }

  List<Widget> _rows(BuildContext context, List<Project> projects, int depth) {
    final ws = app.ws;
    final rows = <Widget>[];
    for (final project in projects) {
      final children = ws.projectTree
          .childrenOf(project.id)
          .whereType<Project>()
          .where((p) => !p.archived)
          .toList(growable: false);
      final collapsed = app.isCollapsed(project.id);
      final check = checkCompletion(ws.projectTree, project.id);

      rows.add(
        _ProjectTile(
          project: project,
          depth: depth,
          hasChildren: children.isNotEmpty,
          collapsed: collapsed,
          selected: project.id == selectedId,
          completeBlockedReason: check.canComplete ? null : check.reason,
          onTap: () => onSelect(project.id),
          onToggleCollapse: () => app.toggleCollapsed(project.id, !collapsed),
          onStatus: (status) {
            final error = app.run(() => ws.setProjectStatus(project.id, status));
            if (error != null) showNotice(context, error, error: true);
          },
          onAddChild: depth + 1 < maxProjectDepth ? () => _createProject(context, project.id) : null,
        ),
      );

      if (children.isNotEmpty && !collapsed) {
        rows.addAll(_rows(context, children, depth + 1));
      }
    }
    return rows;
  }

  Future<void> _createProject(BuildContext context, String? parentId) async {
    final title = await promptText(context, title: parentId == null ? '新建项目' : '新建子项目');
    if (title == null) return;
    final created = app.ws.createProject(title: title, parentId: parentId);
    onSelect(created.id);
    if (context.mounted) showNotice(context, '已创建「${created.title}」');
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.project,
    required this.depth,
    required this.hasChildren,
    required this.collapsed,
    required this.selected,
    required this.completeBlockedReason,
    required this.onTap,
    required this.onToggleCollapse,
    required this.onStatus,
    this.onAddChild,
  });

  final Project project;
  final int depth;
  final bool hasChildren;
  final bool collapsed;
  final bool selected;
  final String? completeBlockedReason;
  final VoidCallback onTap;
  final VoidCallback onToggleCollapse;
  final ValueChanged<NodeStatus> onStatus;
  final VoidCallback? onAddChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? theme.colorScheme.secondaryContainer : null,
        padding: EdgeInsets.only(left: 8.0 + depth * 16, right: 4, top: 2, bottom: 2),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 24,
              child: hasChildren
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      tooltip: collapsed ? '展开' : '折叠',
                      icon: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
                      onPressed: onToggleCollapse,
                    )
                  : null,
            ),
            NodeStatusChip(
              status: project.status,
              completeBlockedReason: completeBlockedReason,
              onChanged: onStatus,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                project.title,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  decoration: project.status == NodeStatus.done ? TextDecoration.lineThrough : null,
                  color: project.status == NodeStatus.ignored ? theme.colorScheme.outline : null,
                ),
              ),
            ),
            if (project.date != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(project.date!, style: theme.textTheme.labelSmall),
              ),
            if (onAddChild != null)
              IconButton(
                tooltip: '新建子项目',
                padding: EdgeInsets.zero,
                iconSize: 16,
                icon: const Icon(Icons.add_box_outlined),
                onPressed: onAddChild,
              ),
          ],
        ),
      ),
    );
  }
}

/// 板块一中栏：选中项目的详情与操作。
class ProjectDetailPane extends StatelessWidget {
  const ProjectDetailPane({super.key, required this.app, required this.projectId});

  final AppController app;
  final String? projectId;

  @override
  Widget build(BuildContext context) {
    final project = projectId == null ? null : app.ws.findProject(projectId!);
    if (project == null || project.deleted) {
      return const EmptyState(
        icon: Icons.touch_app_outlined,
        title: '选一个项目',
        hint: '左栏点选项目后，这里可以编辑目的 / 实现 / 日期',
      );
    }

    final ws = app.ws;
    final theme = Theme.of(context);
    final check = checkCompletion(ws.projectTree, project.id);
    final children = ws.projectTree.childrenOf(project.id).whereType<Project>().toList();
    final parent = project.parentId == null ? null : ws.findProject(project.parentId!);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            NodeStatusChip(
              status: project.status,
              dense: false,
              completeBlockedReason: check.canComplete ? null : check.reason,
              onChanged: (status) {
                final error = app.run(() => ws.setProjectStatus(project.id, status));
                if (error != null) showNotice(context, error, error: true);
              },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(project.title, style: theme.textTheme.headlineSmall),
            ),
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(context, project),
            ),
            IconButton(
              tooltip: project.archived ? '取消归档' : '归档（含子项目）',
              icon: Icon(project.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              onPressed: () {
                app.run(() => ws.setProjectArchived(project.id, !project.archived));
                showNotice(
                  context,
                  project.archived ? '已取消归档（含子项目）' : '已归档（含子项目，可在归档区找回）',
                );
              },
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context, project),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: <Widget>[
            _MetaChip(icon: Icons.flag_outlined, text: project.date ?? '无日期'),
            _MetaChip(icon: Icons.account_tree_outlined, text: '${children.length} 个子项目'),
            if (parent != null) _MetaChip(icon: Icons.arrow_upward, text: '父：${parent.title}'),
            _MetaChip(icon: Icons.update, text: formatTimestamp(project.updatedAt)),
          ],
        ),
        const Divider(height: 28),
        _Field(
          label: '目的（为什么做这件事）',
          value: project.purpose,
          hint: '还没有写目的',
          onSave: (value) => app.run(() => ws.updateProject(project.id, purpose: value)),
        ),
        const SizedBox(height: 16),
        _Field(
          label: '实现（怎么做）',
          value: project.implementation,
          hint: '还没有写实现；灵感合并的结果会写到这里',
          maxLines: 12,
          onSave: (value) => app.run(() => ws.updateProject(project.id, implementation: value)),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, Project project) async {
    final title = await promptText(
      context,
      title: '编辑项目',
      label: '项目名',
      initial: project.title,
      confirmLabel: '保存',
    );
    if (title == null) return;
    app.run(() => app.ws.updateProject(project.id, title: title));
  }

  Future<void> _delete(BuildContext context, Project project) async {
    final plan = planProjectDeletion(app.ws.projectTree, app.ws.allInspirations, project.id);
    final confirmed = await confirmAction(
      context,
      title: '删除项目',
      message: '「${project.title}」将同时删除 ${plan.projectIds.length - 1} 个子项目、'
          '${plan.inspirationIdsToDelete.length} 条灵感'
          '${plan.inspirationIdsToUnassign.isEmpty ? '' : '；'
              '${plan.inspirationIdsToUnassign.length} 条已合并灵感会退回灵感列表'}。\n\n'
          '删除后可在「归档区 → 回收站」恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed) return;
    app.run(() => app.ws.deleteProject(project.id));
    if (context.mounted) showNotice(context, '已删除，可在归档区恢复');
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 15, color: theme.colorScheme.outline),
        const SizedBox(width: 4),
        Text(text, style: theme.textTheme.labelMedium),
      ],
    );
  }
}

/// 可编辑长文本字段（失焦/回车保存）。
class _Field extends StatefulWidget {
  const _Field({
    required this.label,
    required this.value,
    required this.hint,
    required this.onSave,
    this.maxLines = 4,
  });

  final String label;
  final String value;
  final String hint;
  final ValueChanged<String> onSave;
  final int maxLines;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  @override
  void didUpdateWidget(covariant _Field oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focus.hasFocus) {
      _controller.text = widget.value;
    }
  }

  void _save() {
    if (_controller.text.trim() == widget.value.trim()) return;
    widget.onSave(_controller.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        TextField(
          controller: _controller,
          focusNode: _focus,
          maxLines: widget.maxLines,
          minLines: 2,
          decoration: InputDecoration(
            hintText: widget.hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }
}
