import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../common/dialogs.dart';
import '../common/empty_state.dart';
import '../common/format.dart';
import '../common/project_picker.dart';
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

  /// 供外壳的「速记」入口调用：聚焦输入框并把键盘唤起来。
  void focusCapture() {
    _focus.requestFocus();
    unawaited(_ensureKeyboardShown());
  }

  /// 冷启动时窗口往往还没拿到焦点，部分 ROM（实测小米 HyperOS）会把这一轮
  /// 「显示输入法」的请求丢掉 —— 表现是光标在闪但键盘不弹，用户还得再点一下输入框，
  /// 「长按图标就能记一笔」这件事就不成立了。稍后显式再要一次键盘，代价极低。
  Future<void> _ensureKeyboardShown() async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || !_focus.hasFocus) return;
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
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
              ? const EmptyState(
                  icon: Icons.lightbulb_outline,
                  title: '灵感箱是空的',
                  hint: '在上面输入框里随手记一条，之后再决定归到哪个项目',
                )
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
      showToast(context, error, error: true);
      return;
    }
    _capture.clear();
    _focus.requestFocus();
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
          Text(relativeTime(inspiration.createdAt), style: theme.textTheme.labelSmall),
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
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('分配到项目…'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final picked = await pickProject(
                  context,
                  app,
                  title: '分配到项目',
                  allowNone: true,
                  noneLabel: '（解除分配）',
                );
                if (picked == null || !context.mounted) return;
                final projectId = picked == pickNone ? null : picked;
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
                final ok = await confirmAction(
                  context,
                  title: '删除灵感',
                  message: '删除后可在「更多 → 归档区 → 回收站」恢复。',
                  confirmLabel: '删除',
                  danger: true,
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
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) {
      showToast(context, '已合并进「${project.title}」，原文可在归档区「已合并」找回');
    }
  }

  void _run(BuildContext context, void Function() action) {
    final error = app.run(action);
    if (error != null) showToast(context, error, error: true);
  }
}
