import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../shared/widgets.dart';

/// 板块一右栏：灵感箱（速记 → 分配 → 合并 / 丢弃）。
class InspirationPanel extends StatefulWidget {
  const InspirationPanel({super.key, required this.app, this.selectedProjectId});

  final AppController app;
  final String? selectedProjectId;

  @override
  State<InspirationPanel> createState() => _InspirationPanelState();
}

class _InspirationPanelState extends State<InspirationPanel> {
  final TextEditingController _capture = TextEditingController();
  bool _onlySelectedProject = false;

  @override
  void dispose() {
    _capture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.app.ws;
    final all = ws.inspirationInbox;
    final selectedId = widget.selectedProjectId;
    final list = (_onlySelectedProject && selectedId != null)
        ? all.where((i) => i.projectId == selectedId).toList(growable: false)
        : all;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionLabel(
          '灵感箱（${all.length}）',
          trailing: selectedId == null
              ? null
              : FilterChip(
                  label: const Text('仅当前项目'),
                  selected: _onlySelectedProject,
                  onSelected: (value) => setState(() => _onlySelectedProject = value),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            controller: _capture,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: '随手记一条灵感…（Ctrl+Enter 保存）',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: '保存',
                icon: const Icon(Icons.add),
                onPressed: _save,
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(
                  icon: Icons.lightbulb_outline,
                  title: '灵感箱是空的',
                  hint: '想到什么就先扔进来，之后再决定归到哪个项目',
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _InspirationTile(
                    app: widget.app,
                    inspiration: list[index],
                    onError: (message) => showNotice(context, message, error: true),
                  ),
                ),
        ),
      ],
    );
  }

  void _save() {
    final text = _capture.text;
    if (text.trim().isEmpty) return;
    final projectId = _onlySelectedProject ? widget.selectedProjectId : null;
    final error = widget.app.run(() => widget.app.ws.captureInspiration(text, projectId: projectId));
    if (error != null) {
      if (mounted) showNotice(context, error, error: true);
      return;
    }
    _capture.clear();
  }
}

class _InspirationTile extends StatelessWidget {
  const _InspirationTile({
    required this.app,
    required this.inspiration,
    required this.onError,
  });

  final AppController app;
  final Inspiration inspiration;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final theme = Theme.of(context);
    final project = inspiration.projectId == null ? null : ws.findProject(inspiration.projectId!);

    return ListTile(
      dense: true,
      title: Text(inspiration.text),
      subtitle: Row(
        children: <Widget>[
          Icon(
            project == null ? Icons.inbox_outlined : Icons.folder_outlined,
            size: 13,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              project?.title ?? '未分配',
              style: theme.textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(formatTimestamp(inspiration.createdAt), style: theme.textTheme.labelSmall),
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '更多操作',
        onSelected: (value) async {
          switch (value) {
            case 'assign':
              await _assign(context);
              break;
            case 'merge':
              await _merge(context);
              break;
            case 'discard':
              app.run(() => ws.discardInspiration(inspiration.id));
              break;
            case 'delete':
              final ok = await confirmAction(
                context,
                title: '删除灵感',
                message: '删除后可在「归档区 → 回收站」恢复。',
                confirmLabel: '删除',
                danger: true,
              );
              if (ok) app.run(() => ws.deleteInspiration(inspiration.id));
              break;
          }
        },
        itemBuilder: (context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'assign', child: Text('分配到项目…')),
          PopupMenuItem<String>(value: 'merge', child: Text('合并进项目…')),
          PopupMenuItem<String>(value: 'discard', child: Text('丢弃')),
          PopupMenuItem<String>(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }

  Future<void> _assign(BuildContext context) async {
    final projectId = await showProjectPicker(context, app);
    if (projectId == null) return;
    final error = app.run(
      () => app.ws.assignInspiration(inspiration.id, projectId.isEmpty ? null : projectId),
    );
    if (error != null && context.mounted) onError(error);
  }

  Future<void> _merge(BuildContext context) async {
    final projectId = inspiration.projectId ??
        await showProjectPicker(context, app);
    if (projectId == null || projectId.isEmpty) return;
    final project = app.ws.findProject(projectId);
    if (project == null) {
      onError('目标项目不存在');
      return;
    }
    if (!context.mounted) return;

    final merged = await showDialog<String>(
      context: context,
      builder: (context) => MergeEditorDialog(project: project, inspiration: inspiration),
    );
    if (merged == null) return;

    final error = app.run(() => app.ws.mergeInspiration(
          inspirationId: inspiration.id,
          projectId: projectId,
          newImplementation: merged,
        ));
    if (error != null) {
      onError(error);
      return;
    }
    if (context.mounted) {
      showNotice(context, '已合并进「${project.title}」，原文可在归档区「已合并」找回');
    }
  }
}

/// 项目选择器（下拉，含缩进层级）。
Future<String?> showProjectPicker(BuildContext context, AppController app) {
  final flat = <MapEntry<String, int>>[];
  void walk(String? parentId, int depth) {
    for (final project in app.ws.projectTree.childrenOf(parentId).whereType<Project>()) {
      if (project.archived) continue;
      flat.add(MapEntry(project.id, depth));
      walk(project.id, depth + 1);
    }
  }

  walk(null, 0);

  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('选择项目'),
      children: <Widget>[
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('（解除分配）'),
        ),
        for (final entry in flat)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(entry.key),
            child: Padding(
              padding: EdgeInsets.only(left: entry.value * 16.0),
              child: Text(app.ws.findProject(entry.key)?.title ?? entry.key),
            ),
          ),
      ],
    ),
  );
}

/// 合并编辑器（设计文档 4.8）：**上下分区**，上区可编辑、下区只读对照。
class MergeEditorDialog extends StatefulWidget {
  const MergeEditorDialog({super.key, required this.project, required this.inspiration});

  final Project project;
  final Inspiration inspiration;

  @override
  State<MergeEditorDialog> createState() => _MergeEditorDialogState();
}

class _MergeEditorDialogState extends State<MergeEditorDialog> {
  late final TextEditingController _implementation =
      TextEditingController(text: widget.project.implementation);

  @override
  void dispose() {
    _implementation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('合并进「${widget.project.title}」'),
      content: SizedBox(
        width: 640,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('上区：项目的「实现」内容（可编辑）', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Expanded(
              child: TextField(
                controller: _implementation,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '把下面这条灵感的内容整合进来（不会自动追加）',
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('下区：灵感原文（供参考，只读）', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Container(
              height: 140,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(6),
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.inspiration.text,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '保存后：项目正文更新，该灵感置为「已合并」并从灵感箱消失（可在归档区撤销）。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_implementation.text),
          child: const Text('保存并合并'),
        ),
      ],
    );
  }
}
