import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import 'merge_editor_page.dart';

/// 灵感 Tab：**速记优先**（手机端的主要场景）。
///
/// 顶部常驻输入框，下面按创建时间倒序列出未处理的灵感；
/// 每条可以「分配 / 合并 / 丢弃 / 删除」。
class InspirationTab extends StatefulWidget {
  const InspirationTab({super.key, required this.app});

  final AppController app;

  @override
  State<InspirationTab> createState() => InspirationTabState();
}

class InspirationTabState extends State<InspirationTab> {
  final TextEditingController _capture = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _onlySelectedProject = false;
  String? _selectedProjectId;

  @override
  void dispose() {
    _capture.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 供外壳的「速记」入口调用：聚焦输入框。
  void focusCapture() {
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.app.ws;
    final all = ws.inspirationInbox;
    final list = (_onlySelectedProject && _selectedProjectId != null)
        ? all.where((i) => i.projectId == _selectedProjectId).toList(growable: false)
        : all;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: _capture,
            focusNode: _focus,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: '想到什么就先扔进来…',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: '保存',
                icon: const Icon(Icons.send),
                onPressed: _save,
              ),
            ),
          ),
        ),
        if (_selectedProjectId != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                FilterChip(
                  label: Text('只看「${ws.findProject(_selectedProjectId!)?.title ?? ''}」'),
                  selected: _onlySelectedProject,
                  onSelected: (value) => setState(() => _onlySelectedProject = value),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _selectedProjectId = null;
                    _onlySelectedProject = false;
                  }),
                  child: const Text('清除筛选'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Row(
            children: <Widget>[
              Text('未处理 ${all.length} 条', style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: list.isEmpty
              ? const _EmptyInspiration()
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _InspirationTile(
                    app: widget.app,
                    inspiration: list[index],
                    onFilterProject: (projectId) => setState(() {
                      _selectedProjectId = projectId;
                      _onlySelectedProject = true;
                    }),
                  ),
                ),
        ),
      ],
    );
  }

  void _save() {
    final text = _capture.text;
    if (text.trim().isEmpty) return;
    final projectId = _onlySelectedProject ? _selectedProjectId : null;
    final error =
        widget.app.run(() => widget.app.ws.captureInspiration(text, projectId: projectId));
    if (error != null) {
      _notify(error, error: true);
      return;
    }
    _capture.clear();
    _focus.requestFocus();
  }

  void _notify(String message, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.errorContainer : null,
      ),
    );
  }
}

class _EmptyInspiration extends StatelessWidget {
  const _EmptyInspiration();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.lightbulb_outline, size: 56, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text('灵感箱是空的', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '在上面输入框里随手记一条，之后再决定归到哪个项目',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _InspirationTile extends StatelessWidget {
  const _InspirationTile({
    required this.app,
    required this.inspiration,
    required this.onFilterProject,
  });

  final AppController app;
  final Inspiration inspiration;
  final ValueChanged<String> onFilterProject;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final theme = Theme.of(context);
    final project = inspiration.projectId == null ? null : ws.findProject(inspiration.projectId!);

    return ListTile(
      title: Text(inspiration.text),
      subtitle: Row(
        children: <Widget>[
          Icon(
            project == null ? Icons.inbox_outlined : Icons.folder_outlined,
            size: 14,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: GestureDetector(
              onTap: project == null ? null : () => onFilterProject(project.id),
              child: Text(
                project?.title ?? '未分配',
                style: theme.textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Text(_relativeTime(inspiration.createdAt), style: theme.textTheme.labelSmall),
        ],
      ),
      trailing: IconButton(
        tooltip: '更多',
        icon: const Icon(Icons.more_vert),
        onPressed: () => _showActions(context),
      ),
      onTap: () => _showActions(context),
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final ws = app.ws;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('分配到项目…'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final projectId = await pickProject(context, app, title: '分配到项目');
                if (projectId == null || !context.mounted) return;
                _run(context, () => ws.assignInspiration(inspiration.id, projectId));
              },
            ),
            ListTile(
              leading: const Icon(Icons.merge_type),
              title: const Text('合并进项目…'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _merge(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('丢弃'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _run(context, () => ws.discardInspiration(inspiration.id));
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final ok = await _confirm(
                  context,
                  title: '删除灵感',
                  message: '删除后可在「更多 → 归档区 → 回收站」恢复。',
                );
                if (!ok || !context.mounted) return;
                _run(context, () => ws.deleteInspiration(inspiration.id));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _merge(BuildContext context) async {
    final ws = app.ws;
    var projectId = inspiration.projectId;
    if (projectId == null) {
      projectId = await pickProject(context, app, title: '合并到哪个项目');
      if (projectId == null) return;
    }
    final project = ws.findProject(projectId);
    if (project == null) return;
    if (!context.mounted) return;

    final merged = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => MergeEditorPage(project: project, inspiration: inspiration),
      ),
    );
    if (merged == null) return;

    final error = app.run(() => ws.mergeInspiration(
          inspirationId: inspiration.id,
          projectId: project.id,
          newImplementation: merged,
        ));
    if (error != null) {
      if (context.mounted) _notify(context, error, error: true);
      return;
    }
    if (context.mounted) {
      _notify(context, '已合并进「${project.title}」，原文可在归档区「已合并」找回');
    }
  }

  void _run(BuildContext context, void Function() action) {
    final error = app.run(action);
    if (error != null) _notify(context, error, error: true);
  }

  void _notify(BuildContext context, String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.errorContainer : null,
      ),
    );
  }

  static String _relativeTime(int millis) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - millis;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${d.month}-${d.day}';
  }
}

/// 项目选择器（底部弹出的树形列表，带缩进）。
Future<String?> pickProject(
  BuildContext context,
  AppController app, {
  required String title,
  bool allowClear = false,
}) {
  final flat = <MapEntry<Project, int>>[];
  void walk(String? parentId, int depth) {
    for (final project in app.ws.projectTree.childrenOf(parentId).whereType<Project>()) {
      if (project.archived) continue;
      flat.add(MapEntry(project, depth));
      walk(project.id, depth + 1);
    }
  }

  walk(null, 0);

  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
          ),
          if (flat.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('还没有项目，先去「项目」页建一个'),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  if (allowClear)
                    ListTile(
                      leading: const Icon(Icons.clear),
                      title: const Text('（解除分配）'),
                      onTap: () => Navigator.of(sheetContext).pop(''),
                    ),
                  for (final entry in flat)
                    ListTile(
                      contentPadding: EdgeInsets.only(left: 16.0 + entry.value * 20, right: 16),
                      leading: const Icon(Icons.folder_outlined, size: 18),
                      title: Text(entry.key.title),
                      onTap: () => Navigator.of(sheetContext).pop(entry.key.id),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error)
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
