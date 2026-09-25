import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/empty_state.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/project_picker.dart';
import '../common/tag_editor.dart';
import '../theme/shape_tokens.dart';
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

  /// 多选模式（灵感整理第 6 条）：长按任一条进入，之后点条目标即选中。
  bool _selecting = false;
  final Set<String> _selectedIds = <String>{};

  /// 当前列表里**可见**的那些 id（「全选」按它算，不含被筛选掉的）。
  final Set<String> _visibleIds = <String>{};

  /// 正在就地改正文的那一条
  String? _editingId;

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

  void _enterSelection(String id) {
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(id);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  /// 全选 / 取消全选（只作用于当前可见的那些）。
  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _visibleIds.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(_visibleIds);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.app.ws;
    final all = ws.inspirationInbox;
    final list = (_onlySelectedProject && _selectedProjectId != null)
        ? all.where((i) => i.projectId == _selectedProjectId).toList(growable: false)
        : all;

    // 选中项可能已被别人改动（例如在别处合并掉了），每次构建都清一遍幽灵选中
    final visibleIds = list.map((i) => i.id).toSet();
    _selectedIds.removeWhere((id) => !visibleIds.contains(id));
    // 「全选」按当前可见项算，所以存下来给动作条用
    _visibleIds
      ..clear()
      ..addAll(visibleIds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_selecting) _buildSelectionBar(context) else _buildCaptureArea(),
        if (!_selecting && _selectedProjectId != null)
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
              Text(
                _selecting ? '已选 ${_selectedIds.length} 条' : '未处理 ${all.length} 条',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const Spacer(),
              if (!_selecting && list.isNotEmpty)
                TextButton(
                  onPressed: () => _enterSelection(list.first.id),
                  child: const Text('多选'),
                ),
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
                    selecting: _selecting,
                    selected: _selectedIds.contains(list[index].id),
                    editing: _editingId == list[index].id,
                    onEditClosed: () => setState(() => _editingId = null),
                    onStartEdit: () => setState(() => _editingId = list[index].id),
                    onLongPress: () => _enterSelection(list[index].id),
                    onToggleSelect: () => _toggleSelection(list[index].id),
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

  /// 速记书写区。
  ///
  /// 按实机反馈：**要外框**（一眼能看出"这里是个输入区"，深色主题下同样成立），
  /// 但**不要卡片标题**，也不要阅读型输入框那种重边框 ——
  /// 所以用一个 1px 描边 + 大圆角的容器（`shapeCard` 那一档），无阴影。
  Widget _buildCaptureArea() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppShapes.cardRadius),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _capture,
              focusNode: _focus,
              minLines: 2,
              maxLines: 8,
              textInputAction: TextInputAction.newline,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: '「灵感」在此钉下一个锚点……',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.outline,
                ),
                // 外框由外层容器给，输入框自己不再画一遍
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _save,
                icon: const Icon(Icons.send, size: 18),
                label: const Text('记下'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  shape: const StadiumBorder(),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 多选时的批量动作条：胶囊形按钮，动作少而明确。
  Widget _buildSelectionBar(BuildContext context) {
    final theme = Theme.of(context);
    final count = _selectedIds.length;
    final allSelected = _visibleIds.isNotEmpty && count == _visibleIds.length;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: '退出多选',
              icon: const Icon(Icons.close),
              onPressed: _exitSelection,
            ),
            // 全选只作用于**当前可见**的那些：有筛选时就是筛出来的那些。
            // "全选"若连看不见的也选上，用户不知道自己提交了什么。
            // 勾选框放在前面（"已选 n 条"已经由标题行显示，这里不重复）。
            Checkbox(
              value: allSelected,
              tristate: false,
              onChanged: _visibleIds.isEmpty ? null : (_) => _toggleSelectAll(),
            ),
            Tooltip(
              message: allSelected ? '取消全选' : '全选',
              child: const Icon(Icons.done_all, size: 18),
            ),
            const Spacer(),
            _BarAction(
              tooltip: '分配到项目…',
              icon: Icons.drive_file_move_outline,
              onPressed: count == 0 ? null : () => _batchAssign(context),
            ),
            _BarAction(
              tooltip: '丢弃',
              icon: Icons.visibility_off_outlined,
              onPressed: count == 0 ? null : () => _batchDiscard(context),
            ),
            _BarAction(
              tooltip: '删除',
              icon: Icons.delete_outline,
              onPressed: count == 0 ? null : () => _batchDelete(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _batchAssign(BuildContext context) async {
    final picked = await pickProject(
      context,
      widget.app,
      title: '分配到项目',
      allowNone: true,
      noneLabel: '（解除分配）',
    );
    if (picked == null || !context.mounted) return;
    final projectId = picked == pickNone ? null : picked;
    final ids = _selectedIds.toList(growable: false);
    final error = widget.app.run(() => widget.app.ws.assignInspirations(ids, projectId));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) showToast(context, '已分配 ${ids.length} 条');
    _exitSelection();
  }

  Future<void> _batchDiscard(BuildContext context) async {
    final ids = _selectedIds.toList(growable: false);
    final error = widget.app.run(() => widget.app.ws.discardInspirations(ids));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) {
      showToast(context, '已丢弃 ${ids.length} 条，可在归档区「已丢弃」找回');
    }
    _exitSelection();
  }

  Future<void> _batchDelete(BuildContext context) async {
    final ids = _selectedIds.toList(growable: false);
    final ok = await confirmAction(
      context,
      title: '删除 ${ids.length} 条灵感',
      // 灵感是扁平实体，**不进回收站**（回收站只装项目 / 事件 / 任务），
      // 所以这里不能写"可恢复" —— 删除就是删除。
      message: '删除后无法在应用内找回，请确认。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    final error = widget.app.run(() => widget.app.ws.deleteInspirations(ids));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) showToast(context, '已删除 ${ids.length} 条');
    _exitSelection();
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
    this.selecting = false,
    this.selected = false,
    this.editing = false,
    this.onStartEdit,
    this.onEditClosed,
    this.onLongPress,
    this.onToggleSelect,
  });

  final AppController app;
  final Inspiration inspiration;
  final ValueChanged<String> onFilterProject;

  /// 多选模式：整条变成"勾选行"，点它只切换选中
  final bool selecting;
  final bool selected;

  /// 正在就地改正文
  final bool editing;
  final VoidCallback? onStartEdit;
  final VoidCallback? onEditClosed;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final theme = Theme.of(context);
    final project = inspiration.projectId == null ? null : ws.findProject(inspiration.projectId!);

    if (editing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: InlineTextField(
          value: inspiration.text,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          hint: '灵感内容',
          textStyle: theme.textTheme.bodyMedium,
          onSubmitted: (text) =>
              app.run(() => app.ws.updateInspirationText(inspiration.id, text)),
          onEditClosed: onEditClosed,
        ),
      );
    }

    return ListTile(
      // 多选时用勾选框替掉原来的项目图标，位置不变、不跳
      leading: selecting
          ? Checkbox(
              value: selected,
              onChanged: (_) => onToggleSelect?.call(),
            )
          : null,
      title: Text(
        inspiration.text,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // 项目标识色也体现在这里：灵感列表里就能按颜色认项目
              ProjectMarker(
                color: project?.color,
                fallbackIcon: project == null ? Icons.inbox_outlined : Icons.folder_outlined,
                size: 14,
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
          // 标签（灵感整理第 5 条）：只在有标签时占位，免得每条都多一行空白
          if (inspiration.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: <Widget>[
                  for (final tag in inspiration.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(tag, style: theme.textTheme.labelSmall),
                    ),
                ],
              ),
            ),
        ],
      ),
      selected: selecting && selected,
      trailing: selecting
          ? null
          : IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showActions(context),
            ),
      onTap: selecting ? () => onToggleSelect?.call() : () => _showActions(context),
      // 长按进入多选；已经在多选里就直接切换（与系统相册的习惯一致）
      onLongPress: selecting ? () => onToggleSelect?.call() : onLongPress,
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
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑内容'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onStartEdit?.call();
              },
            ),
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
              leading: const Icon(Icons.label_outline),
              title: Text(inspiration.tags.isEmpty ? '加标签…' : '标签（${inspiration.tags.length}）…'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final tags = await editTags(
                  context,
                  initial: inspiration.tags,
                  title: '编辑标签',
                );
                if (tags == null || !context.mounted) return;
                _run(context, () => ws.updateInspirationTags(inspiration.id, tags));
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
              leading: const Icon(Icons.checklist),
              title: const Text('多选…'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onLongPress?.call();
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
                  message: '删除后无法在应用内找回，请确认。',
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

/// 批量动作条上的一个**胶囊图标按钮**（三处共用，外观一致）。
///
/// 按实机反馈把批量动作条从"裸图标排一排"改成胶囊按钮：
/// 每个按钮有自己的底色与圆角，边界清楚，也更符合全应用的形状规范。
class _BarAction extends StatelessWidget {
  const _BarAction({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.surface,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: const Size(44, 36),
          ),
        ),
      ),
    );
  }
}
