import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/labels.dart';
import 'project_actions.dart';

/// 项目详情：**目的 / 实现 / 日期 / 三态**，加子项目与已分配灵感。
///
/// 「实现」是灵感合并的落点（ADR-033），所以正文用大段可点区域展示，
/// 一眼能看出内容有没有被写进去。
class ProjectDetailPage extends StatelessWidget {
  const ProjectDetailPage({super.key, required this.app, required this.projectId});

  final AppController app;
  final String projectId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final ws = app.ws;
        final project = ws.findProject(projectId);
        if (project == null || project.deleted) {
          return Scaffold(
            appBar: AppBar(title: const Text('项目')),
            body: const Center(child: Text('这个项目已被删除')),
          );
        }

        final parent = project.parentId == null ? null : ws.findProject(project.parentId!);
        final children = ws.projectTree
            .childrenOf(projectId)
            .whereType<Project>()
            .where((p) => !p.archived)
            .toList(growable: false);
        final inspirations = ws.liveInspirations
            .where((i) => i.isPending && i.projectId == projectId)
            .toList(growable: false)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

        return Scaffold(
          appBar: AppBar(
            title: Text(project.title, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) async {
                  switch (value) {
                    case 'child':
                      await createProjectAction(context, app, parentId: project.id);
                      break;
                    case 'rename':
                      await renameProjectAction(context, app, project.id, project.title);
                      break;
                    case 'move':
                      await moveProjectAction(context, app, project.id);
                      break;
                    case 'archive':
                      await archiveProjectAction(context, app, project.id, archived: true);
                      break;
                    case 'delete':
                      if (!context.mounted) return;
                      await deleteProjectAction(context, app, project.id);
                      if (context.mounted) Navigator.of(context).maybePop();
                      break;
                  }
                },
                itemBuilder: (_) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'child', child: Text('新建子项目')),
                  PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
                  PopupMenuItem<String>(value: 'move', child: Text('移动到…')),
                  PopupMenuItem<String>(value: 'archive', child: Text('归档')),
                  PopupMenuItem<String>(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              if (parent != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.subdirectory_arrow_right, size: 18),
                  title: Text('属于「${parent.title}」', style: Theme.of(context).textTheme.labelMedium),
                ),
              _StatusField(app: app, project: project),
              _DateField(app: app, project: project),
              _TextField(
                title: '目的',
                hint: '为什么做这个项目',
                value: project.purpose,
                onEdit: () => editProjectFieldAction(
                  context,
                  app,
                  project.id,
                  field: 'purpose',
                  currentValue: project.purpose,
                ),
              ),
              _TextField(
                title: '实现',
                hint: '怎么做 —— 灵感合并进来会写到这里',
                value: project.implementation,
                onEdit: () => editProjectFieldAction(
                  context,
                  app,
                  project.id,
                  field: 'implementation',
                  currentValue: project.implementation,
                ),
              ),
              _ChildrenField(app: app, project: project, children: children),
              _InspirationsField(inspirations: inspirations),
            ],
          ),
        );
      },
    );
  }
}

class _StatusField extends StatelessWidget {
  const _StatusField({required this.app, required this.project});

  final AppController app;
  final Project project;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('状态', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<NodeStatus>(
            segments: <ButtonSegment<NodeStatus>>[
              for (final status in NodeStatus.values)
                ButtonSegment<NodeStatus>(value: status, label: Text(nodeStatusLabel(status))),
            ],
            selected: <NodeStatus>{project.status},
            onSelectionChanged: (selection) {
              final status = selection.first;
              final error = app.run(() => app.ws.setProjectStatus(project.id, status));
              if (error != null) showToast(context, error, error: true);
            },
          ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.app, required this.project});

  final AppController app;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final date = project.date;
    return ListTile(
      leading: const Icon(Icons.event_outlined),
      title: const Text('日期'),
      subtitle: Text(
        date == null ? '未设置' : '$date（${describeDate(date)}）',
        style: date != null && isOverdue(date) && project.status != NodeStatus.done
            ? TextStyle(color: Theme.of(context).colorScheme.error)
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (date != null)
            IconButton(
              tooltip: '清除日期',
              icon: const Icon(Icons.close),
              onPressed: () => _set(context, null),
            ),
          IconButton(
            tooltip: '选择日期',
            icon: const Icon(Icons.edit_calendar_outlined),
            onPressed: () => _pick(context),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final initial = project.date == null ? now : (DateTime.tryParse(project.date!) ?? now);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
    );
    if (picked == null || !context.mounted) return;
    final month = picked.month.toString().padLeft(2, '0');
    final day = picked.day.toString().padLeft(2, '0');
    _set(context, '${picked.year}-$month-$day');
  }

  void _set(BuildContext context, String? value) {
    final error = app.run(() => app.ws.updateProject(project.id, date: value));
    if (error != null) showToast(context, error, error: true);
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.title,
    required this.hint,
    required this.value,
    required this.onEdit,
  });

  final String title;
  final String hint;
  final String value;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(title, style: theme.textTheme.labelLarge),
                    const Spacer(),
                    Icon(Icons.edit_outlined, size: 18, color: theme.colorScheme.outline),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  value.isEmpty ? hint : value,
                  style: value.isEmpty
                      ? theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                          fontStyle: FontStyle.italic,
                        )
                      : theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChildrenField extends StatelessWidget {
  const _ChildrenField({required this.app, required this.project, required this.children});

  final AppController app;
  final Project project;
  final List<Project> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 8, 0),
          child: Row(
            children: <Widget>[
              Text('子项目 ${children.length}', style: theme.textTheme.labelLarge),
              const Spacer(),
              TextButton.icon(
                onPressed: () => createProjectAction(context, app, parentId: project.id),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('还没有子项目', style: theme.textTheme.bodySmall),
          )
        else
          for (final child in children)
            ListTile(
              leading: Icon(
                nodeStatusIcon(child.status),
                size: 20,
                color: nodeStatusColor(child.status, theme.colorScheme),
              ),
              title: Text(child.title),
              subtitle: Text(
                describeDate(child.date).isEmpty ? '未设置日期' : describeDate(child.date),
                style: theme.textTheme.labelSmall,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ProjectDetailPage(app: app, projectId: child.id),
                ),
              ),
            ),
      ],
    );
  }
}

class _InspirationsField extends StatelessWidget {
  const _InspirationsField({required this.inspirations});

  final List<Inspiration> inspirations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Text('待处理灵感 ${inspirations.length}', style: theme.textTheme.labelLarge),
        ),
        if (inspirations.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('这个项目下没有待处理灵感', style: theme.textTheme.bodySmall),
          )
        else ...<Widget>[
          for (final inspiration in inspirations)
            ListTile(
              dense: true,
              leading: const Icon(Icons.lightbulb_outline, size: 18),
              title: Text(inspiration.text, maxLines: 3, overflow: TextOverflow.ellipsis),
              subtitle: Text(relativeTime(inspiration.createdAt), style: theme.textTheme.labelSmall),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '去「灵感」页可以把它合并进上面的「实现」',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}
