import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../common/animated_collapse.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/empty_state.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/keyboard_dismiss_guard.dart';
import '../common/project_picker.dart';
import '../common/selection.dart';
import '../theme/shape_tokens.dart';
import 'empty_box_lines.dart';
import 'inspiration_selection.dart';
import 'merge_editor_page.dart';

/// 灵感 Tab：**速记优先**（手机端的主要场景）。
///
/// 顶部常驻输入框（**写的时候就选好项目**），下面按创建时间倒序列出未处理的灵感；
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

  /// 正在写的这条灵感要归到哪个项目（`null` = 未分配）。
  ///
  /// 这是"写下来的时候就分好类"的落点：不再需要事后一条条去分配。
  /// 记完**不重置** —— 连着记几条同一个项目的想法是常见动作。
  String? _captureProjectId;

  /// 多选模式：长按任一条进入，之后点条目标即选中。
  ///
  /// **入口只有长按这一个**（2026-09-27 实机反馈：把"多选"这个入口拿掉）：
  /// 页头那枚「多选」按钮与 ⋮ 里的「多选…」都删了 —— 批量动作一件没少
  /// （分配 / 合并 / 丢弃 / 删除都在选中后的动作条上），只是不再有两个显眼的
  /// 入口把每一屏的注意力分走。
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
    // 批量动作里有 `await`（确认框 / 合并编辑器），期间本页可能已经被 pop 掉（Q-2）。
    // 内层函数里的 `context.mounted` 守的是弹层那条路由，查不出本 State 已 dispose。
    if (!mounted) return;
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
  ///
  /// 判断本身抽在 `selection.dart` 的 `selectionAfterToggleAll` 里 ——
  /// 四个页面各有一份多选，而这一格是唯一容易各写各的（见那个函数的文档）。
  void _toggleSelectAll() {
    final next = selectionAfterToggleAll(
      visibleIds: _visibleIds,
      selectedIds: _selectedIds,
    );
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.app.ws;
    // 已归档项目（含子项目）下的待处理灵感**不在这一页**（Q10）——数由
    // `Workspace` 给同一个，归档区「被隐藏」分区用的是同一个口径。
    final all = ws.inspirationInbox;
    final hiddenCount = ws.inspirationsHiddenByArchivedProjects;
    final byProject = (_onlySelectedProject && _selectedProjectId != null)
        ? all.where((i) => i.projectId == _selectedProjectId)
        : all;
    final list = byProject.toList(growable: false);
    /// 有没有在筛：筛着的时候标题行的数字必须说清"筛出几条 / 一共几条"，
    /// 否则会出现"标题写 12 条、列表只有 3 条"这种对不上号的情况（实机反馈）。
    final filtering = _onlySelectedProject && _selectedProjectId != null;

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
        // 书写区**一直在**（2026-09-28 实机反馈："多选时不必收起灵感输入框，
        // 保持原来的坐标就好"）—— 原来多选是整块把它换成动作条，一进多选
        // 输入框就跳走了；现在动作条**接在它下面**，书写区一个像素都不动。
        _buildCaptureArea(),
        // 动作条**滑出来**（多选时切换要流畅）
        AnimatedCollapse(
          expanded: _selecting,
          child: _buildSelectionBar(context),
        ),
        if (!_selecting && filtering)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                if (_selectedProjectId != null)
                  Flexible(
                    child: FilterChip(
                      label: Text('只看「${ws.findProject(_selectedProjectId!)?.title ?? ''}」'),
                      selected: _onlySelectedProject,
                      onSelected: (value) => setState(() {
                        _onlySelectedProject = value;
                        // 正在按某个项目筛，多半就是在给它记东西 —— 顺手把书写区的
                        // 归属也切过去（**看得见**的一步，不是暗中的规则）
                        if (value) _captureProjectId = _selectedProjectId;
                      }),
                    ),
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
                _selecting
                    ? '已选 ${_selectedIds.length} 条'
                    : (filtering ? '筛出 ${list.length} 条 / 未处理共 ${all.length} 条' : '未处理 ${all.length} 条'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              // 这里**不再有**那枚「多选」按钮（2026-09-27 实机反馈）：
              // 长按任一条就能进多选，页头不需要再占一个常驻入口。
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 被归档项目遮住的那些灵感**必须有个交代**（Q10）：它们从列表里消失，
        // 不吭声就等于"灵感被静默吞了"；而归档区那个数字由同一个函数给。
        if (hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              shape: AppShapes.card,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '另有 $hiddenCount 条在已归档项目下，去归档区看',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: list.isEmpty
              ? (all.isEmpty
                  ? EmptyState(
                      icon: Icons.lightbulb_outline,
                      // 空箱文案**每次启动抽一句、本次会话固定**（ADR-084）。
                      // 种子存在偏好里，所以切页签 / 返回都不会变。
                      title: emptyBoxLineFor(widget.app.prefs.emptyBoxSeed),
                      // 全被归档项目遮住时，"空"是**算出来的空**：不说清楚，
                      // 用户会以为灵感没了（Q10）—— 这一句是**必须留**的，
                      // 与上面那句趣味文案不是一回事
                      hint: hiddenCount > 0
                          ? '另有 $hiddenCount 条在已归档项目下，去归档区看'
                          : null,
                    )
                  // 箱子不空、只是被筛掉了：必须说清"一共还有多少条"，
                  // 否则用户会以为灵感丢了
                  : EmptyState(
                      icon: Icons.filter_alt_off_outlined,
                      title: '没有符合筛选的灵感',
                      hint: '未处理共 ${all.length} 条，清除筛选就能看到',
                      action: TextButton(
                        onPressed: () => setState(() {
                          _selectedProjectId = null;
                          _onlySelectedProject = false;
                        }),
                        child: const Text('清除筛选'),
                      ),
                    ))
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
  /// 按实机反馈：**与「目的」那种字段一样的样式，但不要内框** ——
  /// 所以外面是一张带轻阴影的卡片（`Card(elevation: 1)`，没有标题行），
  /// 里面直接放一个**无边框**的输入区。之前那版是"外框 + 内框"两层，
  /// 看着像个表单；再往前那版连外框都没有，又看不出这是输入区。
  ///
  /// 底部一行是**书写时就选项目**（实机反馈的原意：归类应该在写下来的那一刻做，
  /// 而不是事后一条条补）+ 「记下」。
  Widget _buildCaptureArea() {
    // 速记框是**常驻**的（这一页整个就是速记），所以"键盘收起"在这里的含义
    // 与页内编辑器不同：**不收起输入框**（收掉它等于把主功能藏了），
    // 只让它不再占着键盘 —— 再点一下就能接着打，内容一个字都不动。
    //
    // 关键是**放掉焦点**：不放的话，用户之后碰任何一下都会让框架回头补一次
    // 输入连接，键盘就自己回来了（2026-09-28 实机反馈）。
    return KeyboardDismissGuard(
      isFocused: () => _focus.hasFocus,
      onKeyboardDismissed: _focus.unfocus,
      child: _captureCard(),
    );
  }

  Widget _captureCard() {
    final theme = Theme.of(context);
    final project = _captureProjectId == null
        ? null
        : widget.app.ws.findProject(_captureProjectId!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _capture,
                focusNode: _focus,
                // 三行起步（实机反馈"稍微拉长一点"）：速记常常一次写两三句，
                // 两行的高度写着写着就要滚，三行才够一口气写完
                minLines: 3,
                maxLines: 8,
                textInputAction: TextInputAction.newline,
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: '「灵感」在此钉下一个锚点……',
                  hintStyle: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                  // 无内框：外框由卡片给
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              Row(
                children: <Widget>[
                  // 归属选择：一个胶囊小按钮，一眼看出这条灵感将归到哪儿。
                  // 它占**左侧剩余空间**（项目名长了就地省略），「记下」由
                  // `Expanded` 之后的固定位置兜住 —— 按钮的位置不跟着项目名长短跑
                  // （实机反馈：改个项目名，记下按钮就挪了）。
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Flexible(
                          child: InkWell(
                            onTap: _pickCaptureProject,
                            borderRadius: BorderRadius.circular(AppShapes.chipRadius),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  ProjectMarker(color: project?.color, size: 12),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      project?.title ?? '未分配',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelMedium,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Icon(
                                    Icons.expand_more,
                                    size: 16,
                                    color: theme.colorScheme.outline,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _save,
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('记下'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      shape: const StadiumBorder(),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选这条灵感归哪个项目（可"不分配"）。
  Future<void> _pickCaptureProject() async {
    final picked = await pickProject(
      context,
      widget.app,
      title: '这条灵感归到哪个项目',
      allowNone: true,
      noneLabel: '不分配项目',
    );
    if (picked == null || !mounted) return;
    setState(() => _captureProjectId = picked == pickNone ? null : picked);
  }

  /// 多选动作条（共用控件，项目详情页的待处理灵感用的是同一个）。
  Widget _buildSelectionBar(BuildContext context) {
    final count = _selectedIds.length;
    final allSelected = _visibleIds.isNotEmpty && count == _visibleIds.length;
    final actions = InspirationBatchActions(
      app: widget.app,
      selectedIds: _selectedIds.toList(growable: false),
      onDone: _exitSelection,
    );
    return InspirationSelectionBar(
      selectedCount: count,
      allSelected: allSelected,
      canSelectAll: _visibleIds.isNotEmpty,
      onToggleAll: _toggleSelectAll,
      onExit: _exitSelection,
      onAssign: () => actions.assign(context),
      // 顺序取列表顺序：`inspirationInbox` 与页面上那份列表是同一个排序，
      // 用选中的 id 过滤出来即可（Set 本身没有顺序）
      onMerge: () => actions.merge(context, widget.app.ws.inspirationInbox),
      onDiscard: () => actions.discard(context),
      onDelete: () => actions.delete(context),
    );
  }

  void _save() {
    final text = _capture.text;
    if (text.trim().isEmpty) return;
    // 归属在书写时就定好了（`_captureProjectId`），这里不再"顺手"从筛选里猜
    final error = widget.app.run(
      () => widget.app.ws.captureInspiration(text, projectId: _captureProjectId),
    );
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    _capture.clear();
    _focus.requestFocus();
    // 记下了却看不见，必须当场说明 —— 否则用户以为没记上（实机反馈）
    final hidden = _onlySelectedProject &&
        _selectedProjectId != null &&
        _captureProjectId != _selectedProjectId;
    if (hidden && mounted) {
      showToast(context, '已记下，但被当前筛选挡住了，清除筛选就能看到');
    }
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
      // 多选时行首换个**圆形**勾选记号（与动作条、分类页展开区同一个形状，
      // 不再是方形 Checkbox）
      leading: selecting
          ? Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
            )
          : null,
      title: Text(
        inspiration.text,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      // 归属 + 时间一行说完（标签系统已于 2026-09-27 移除，
      // 所以这里不再有第二行标签胶囊）。
      subtitle: Row(
        children: <Widget>[
          // 项目标识色也体现在这里：灵感列表里就能按颜色认项目。
          // 未分配 / 未设色时是灰色空心圆（`ProjectMarker` 自己处理）
          ProjectMarker(color: project?.color, size: 14),
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
                  noneLabel: '解除分配',
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
                  // 灵感是扁平实体，**不进回收站**；备份里可能仍有它的原文，
                  // 但那是整库退回，不能说成"这一条可以找回"
                  message: '灵感不进回收站，删除后无法在应用里找回。\n'
                      '备份与历次导出里可能仍有，但只能整库退回。',
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

    final result = await Navigator.of(context).push<MergeResult>(
      MaterialPageRoute<MergeResult>(
        builder: (_) => MergeEditorPage(project: project, inspiration: inspiration),
      ),
    );
    if (result == null || !context.mounted) return;
    await applyMergeResult(context, app, project, inspiration, result);
  }

  void _run(BuildContext context, void Function() action) {
    final error = app.run(action);
    if (error != null) showToast(context, error, error: true);
  }
}
