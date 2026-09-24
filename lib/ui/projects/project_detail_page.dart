import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import '../inspiration/merge_editor_page.dart';
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('名称', style: Theme.of(context).textTheme.labelLarge),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: InlineTextField(
                  value: project.title,
                  hint: '项目名',
                  textStyle: Theme.of(context).textTheme.titleMedium,
                  onSubmitted: (title) =>
                      app.run(() => ws.updateProject(project.id, title: title)),
                ),
              ),
              _StatusField(app: app, project: project),
              _ColorField(app: app, project: project),
              _DateField(app: app, project: project),
              _TextField(
                title: '目的',
                hint: '为什么做这个项目',
                value: project.purpose,
                onSubmitted: (value) =>
                    app.run(() => ws.updateProject(project.id, purpose: value)),
              ),
              _TextField(
                title: '实现',
                hint: '怎么做 —— 灵感合并进来会写到这里',
                value: project.implementation,
                onSubmitted: (value) =>
                    app.run(() => ws.updateProject(project.id, implementation: value)),
              ),
              _ChildrenField(app: app, project: project, children: children),
              _InspirationsField(
                app: app,
                project: project,
                inspirations: inspirations,
              ),
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

/// 标识色（灵感整理第 10 条）：只在项目树与这里显示，不影响任何规则。
class _ColorField extends StatelessWidget {
  const _ColorField({required this.app, required this.project});

  final AppController app;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorOfHex(project.color);
    return ListTile(
      leading: Icon(
        Icons.palette_outlined,
        color: color ?? theme.colorScheme.outline,
      ),
      title: const Text('标识色'),
      subtitle: Text(
        project.color ?? '未设置（在项目树里用主题色）',
        style: theme.textTheme.labelSmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color ?? theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () async {
        final picked = await pickProjectColor(context, current: project.color);
        // null = 取消；'' = 明确选了"不用标识色"
        if (picked == null || !context.mounted) return;
        final error = app.run(
          () => app.ws.setProjectColor(project.id, picked.isEmpty ? null : picked),
        );
        if (error != null && context.mounted) showToast(context, error, error: true);
      },
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
        date == null ? '未设置' : describeDateWithDays(date),
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
      helpText: project.date == null ? '选择日期' : '当前：${describeDateWithDays(project.date)}',
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
    required this.onSubmitted,
  });

  final String title;
  final String hint;
  final String value;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              InlineTextField(
                value: value,
                hint: hint,
                minLines: 1,
                maxLines: 12,
                allowEmpty: true,
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                  fontStyle: FontStyle.italic,
                ),
                onSubmitted: onSubmitted,
              ),
            ],
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
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Text('子项目 ${children.length}', style: theme.textTheme.labelLarge),
        ),
        InlineComposer(
          label: '新建子项目',
          hint: '子项目名',
          leading: Icons.subdirectory_arrow_right,
          onCreate: (title) {
            final error =
                app.run(() => app.ws.createProject(title: title, parentId: project.id));
            if (error != null) showToast(context, error, error: true);
          },
        ),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
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
  const _InspirationsField({
    required this.app,
    required this.project,
    required this.inspirations,
  });

  final AppController app;
  final Project project;
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
          // 点一条**直接进合并编辑器**（灵感整理第 9 条）。
          // 原来这里是只读列表，还让用户"去灵感页合并"——入口绕了一圈。
          for (final inspiration in inspirations)
            ListTile(
              dense: true,
              leading: const Icon(Icons.lightbulb_outline, size: 18),
              title: Text(inspiration.text, maxLines: 3, overflow: TextOverflow.ellipsis),
              subtitle: Text(relativeTime(inspiration.createdAt), style: theme.textTheme.labelSmall),
              trailing: const Icon(Icons.merge_type, size: 18),
              onTap: () => _merge(context, inspiration),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '点一条即可把它合并进上面的「实现」',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }

  /// 与灵感页走的是同一个 `MergeEditorPage`，只是入口在项目侧。
  Future<void> _merge(BuildContext context, Inspiration inspiration) async {
    final merged = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => MergeEditorPage(project: project, inspiration: inspiration),
      ),
    );
    if (merged == null || !context.mounted) return;

    final error = app.run(() => app.ws.mergeInspiration(
          inspirationId: inspiration.id,
          projectId: project.id,
          newImplementation: merged,
        ));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) {
      showToast(context, '已合并进「${project.title}」，原文可在归档区「已合并」找回');
    }
  }
}
