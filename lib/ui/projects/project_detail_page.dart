import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/rules/handoff_export.dart';
import '../../features/workspace.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import '../common/status_selector.dart';
import '../inspiration/merge_editor_page.dart';
import 'handoff_preview_page.dart';
import 'project_actions.dart';
import 'project_checklist.dart';

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
                    case 'handoff':
                      if (!context.mounted) return;
                      await _exportHandoff(context, project);
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
                  PopupMenuItem<String>(
                    value: 'handoff',
                    child: Text('导出交接说明…'),
                  ),
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
              // 「实现」由两部分组成：上面的**待办清单**（结构化、可勾选），
              // 下面的**正文**（整段说明 / 灵感合并的落点 / AI 整理的输出）。
              // 两者并存：清单是"要做什么"的拆分，正文是"整体怎么做"的说明。
              ProjectChecklist(
                app: app,
                project: project,
                onSplitFromImplementation: () => _splitIntoItems(context, project),
              ),
              _ImplementationField(project: project, onSubmit: (value) {
                // AI 整理后正文会被替换，空内容会被业务层拒绝（不让正文被清没）
                final error = value.trim().isEmpty
                    ? null
                    : app.run(() => ws.replaceImplementation(project.id, value));
                if (error != null) showToast(context, error, error: true);
              }),
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

  /// 生成并把用户送到**交接说明预览页**（真正写文件在那一步）。
  Future<void> _exportHandoff(BuildContext context, Project project) async {
    final markdown = HandoffExport.build(
      project: project,
      // 事件与项目没有关联字段，所以带全部事件与任务（设计文档 §3.2）
      events: app.ws.liveEvents,
      tasks: app.ws.liveTasks,
      inspirations: app.ws.liveInspirations
          .where((i) => i.projectId == project.id)
          .toList(growable: false),
      now: DateTime.now(),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HandoffPreviewPage(
          app: app,
          projectId: project.id,
          projectTitle: project.title,
          markdown: markdown,
        ),
      ),
    );
  }

  /// 把「实现」正文按行拆成清单条目（**显式动作**）。
  ///
  /// 不在读取时自动拆：把一段中文按行拆开是不可逆的猜测，自动拆等于
  /// 第一次打开就悄悄改了数据形态。拆之前说清会发生什么，拆完报告条数。
  Future<void> _splitIntoItems(BuildContext context, Project project) async {
    final lines = Workspace.splitImplementationLines(project.implementation);
    if (lines.isEmpty) {
      showToast(context, '正文里没有可拆成条目的内容', error: true);
      return;
    }

    if (project.items.isNotEmpty) {
      final ok = await confirmAction(
        context,
        title: '从正文重拆',
        message: '会先清空现在这 ${project.items.length} 条，再按正文重新拆成 ${lines.length} 条。\n'
            '正文本身不会动。',
        confirmLabel: '重拆',
        danger: true,
      );
      if (!ok || !context.mounted) return;
      final cleared = app.run(() => app.ws.clearProjectItems(project.id));
      if (cleared != null) {
        if (context.mounted) showToast(context, cleared, error: true);
        return;
      }
    }

    final error = app.run(() => app.ws.splitImplementationIntoItems(project.id));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) showToast(context, '已拆成 ${lines.length} 条');
  }
}

/// 「实现」正文：与清单并存的那一段整体说明。
///
/// 它是三样东西的共同落点 —— 灵感合并写进来、AI 整理写回来、交接导出从这里取。
/// 清单为空时它就是主角；清单不为空时它退成"整理稿"，所以默认收起来。
class _ImplementationField extends StatefulWidget {
  const _ImplementationField({required this.project, required this.onSubmit});

  final Project project;
  final ValueChanged<String> onSubmit;

  @override
  State<_ImplementationField> createState() => _ImplementationFieldState();
}

class _ImplementationFieldState extends State<_ImplementationField> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = widget.project.implementation;
    final hasItems = widget.project.items.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 8, 0),
          child: Row(
            children: <Widget>[
              Text('实现正文', style: theme.textTheme.labelLarge),
              const SizedBox(width: 8),
              Text(
                value.trim().isEmpty ? '还没有内容' : '${value.trim().length} 字',
                style: theme.textTheme.labelSmall,
              ),
              const Spacer(),
              // 清单为空时正文就是主内容，默认展开；有清单时默认收起，免得两屏都是字
              if (value.trim().isNotEmpty)
                IconButton(
                  tooltip: _expanded ? '收起' : '展开',
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
            ],
          ),
        ),
        if (_expanded || value.trim().isEmpty || !hasItems)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: InlineTextField(
              value: value,
              hint: '怎么做 —— 灵感合并、AI 整理都会写到这里',
              minLines: 1,
              maxLines: 12,
              allowEmpty: true,
              textStyle: theme.textTheme.bodyMedium,
              onSubmitted: widget.onSubmit,
            ),
          ),
      ],
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
          StatusPillSelector<NodeStatus>(
            values: NodeStatus.values,
            selected: project.status,
            labelOf: nodeStatusLabel,
            onSelected: (status) {
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
