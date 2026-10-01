import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/task.dart';
import '../../features/workspace.dart';
import '../common/dialogs.dart';
import '../common/empty_state.dart';
import '../common/keyboard_dismiss_guard.dart';
import '../common/labels.dart';
import '../events/event_detail_page.dart';
import '../events/task_actions.dart';
import '../projects/project_detail_page.dart';
import '../theme/shape_tokens.dart';

/// 全局搜索：**只搜未归档、未删除；灵感只搜待处理的**。
///
/// 多选（Q26）：任务条目上多了"长按进多选、批量改期 / 归档"这条捷径 ——
/// 原来搜到一条任务想改到期日，只能点进去、在任务线上再找一遍。习惯与
/// 「全部任务」页、灵感页**完全一致**。
///
/// 多选**只收任务命中**：批量动作（设到期日 / 归档）本来就只对任务有意义，
/// 让项目 / 事件 / 灵感也能被选中，只会造出一个按下去没有动作的选中集。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.app, this.embedded = false});

  final AppController app;

  /// 是否被**桌面外壳**嵌进内容区。
  ///
  /// 嵌进去时：①不画自己的 `AppBar`（外壳顶上已经有一条标题栏，否则两条标题
  /// 上下叠着）；②**不 `autofocus`** —— 桌面外壳用 `IndexedStack` 让八页一直活着，
  /// 一开机就让这一页抢走键盘焦点，灵感页的速记输入框就永远拿不到光标。
  final bool embedded;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _query = '';

  /// 多选模式（只作用于任务命中）。
  bool _selecting = false;
  final Set<String> _selectedIds = <String>{};

  /// 当前列表里**可见的任务命中** id（「全选」按它算）。
  final Set<String> _visibleIds = <String>{};

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
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
    // 批量动作里有 `await`（确认框 / 日期选择器），期间本页可能已经被 pop 掉（Q-2）。
    // 内层函数里的 `context.mounted` 守的是弹窗那条路由，查不出本 State 已 dispose。
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

  /// 全选 / 取消全选（只作用于当前可见的那些任务命中）。
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
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        // 多要一条：只按 `hits.length` 判断截断会永远看到"正好 100 条"，
        // 分不出"刚好 100 条"与"还有更多"（Q20）。
        final hits = widget.app.ws.search(_query, limit: searchHitLimit + 1);
        final truncated = hits.length > searchHitLimit;
        final shown = truncated ? hits.sublist(0, searchHitLimit) : hits;
        final hasQuery = _query.trim().isNotEmpty;

        // 只有**任务**命中能进多选：批量动作都是任务动作
        final visibleTaskIds = <String>{
          for (final hit in shown)
            if (hit.doc == DocName.tasks) hit.entity.id,
        };
        _selectedIds.removeWhere((id) => !visibleTaskIds.contains(id));
        _visibleIds
          ..clear()
          ..addAll(visibleTaskIds);
        if (_selecting && _visibleIds.isEmpty) {
          // **不在 build 里改状态**（Q-6）：这里原来直接 `_selecting = false`，
          // 靠"反正马上要重建"侥幸成立；一旦上层加了 `const` 优化或提前 return，
          // 界面就会停在"动作条还画着、_selecting 已经是 false"的不一致态。
          // 挪到帧后统一应用，行为一样但不再依赖 build 的副作用。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _exitSelection();
          });
        }

        return Scaffold(
          appBar: widget.embedded ? null : AppBar(title: const Text('搜索')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 搜索框做成**页面上一个明显的框**（实机反馈）：
              // 原来是标题栏里一个没有边框的输入框，看着像一行说明文字，
              // 第一眼根本认不出"这里能打字"。
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                // 键盘收起 = **只放掉焦点**（ADR-087）：搜索框是这一页的主入口，
                // 收掉它等于把主功能藏了；查询与结果一个字都不动，再点一下接着搜。
                // 放焦点不是为了好看 —— 不放的话，之后碰任何一处都会让框架回头补一次
                // 输入连接，键盘自己就回来了（2026-09-29 修复的同一类缺陷）。
                child: KeyboardDismissGuard(
                  isFocused: () => _focus.hasFocus,
                  onKeyboardDismissed: _focus.unfocus,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    // 嵌在桌面外壳里时**不抢焦点**：八页一直活着（`IndexedStack`），
                    // 一开机就 autofocus 会把光标从灵感页的速记框上夺走。
                    autofocus: !widget.embedded,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '搜项目 / 事件 / 任务 / 灵感',
                      // 能点的用胶囊（《界面规范》§4）
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(AppShapes.pillRadius),
                        ),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: hasQuery
                          ? IconButton(
                              tooltip: '清空',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _controller.clear();
                                setState(() => _query = '');
                              },
                            )
                          : null,
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
              ),
              if (_selecting)
                TaskSelectionBar(
                  selectedCount: _selectedIds.length,
                  allSelected:
                      _visibleIds.isNotEmpty && _selectedIds.length == _visibleIds.length,
                  canSelectAll: _visibleIds.isNotEmpty,
                  onToggleAll: _toggleSelectAll,
                  onExit: _exitSelection,
                  onSetDue: () => _batchSetDue(context),
                  onArchive: () => _batchArchive(context),
                ),
              if (hasQuery)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Row(
                    children: <Widget>[
                      Text(
                        // 触到上限时必须如实说（Q20 / 《界面规范》§7）：只写「命中 100 条」，
                        // 用户会以为一共就这么多 —— 而"前 100 条"只是截断之后剩下的那一段。
                        // 多选状态统一写「已选 N 条」。
                        _selecting
                            ? '已选 ${_selectedIds.length} 条'
                            : shown.isEmpty
                                ? '没有匹配的结果'
                                : truncated
                                    ? '命中 $searchHitLimit 条 · 只显示前 $searchHitLimit 条，还有更多'
                                    : '命中 ${shown.length} 条',
                        style: theme.textTheme.labelSmall,
                      ),
                      const Spacer(),
                      if (!_selecting && visibleTaskIds.isNotEmpty)
                        TextButton(
                          // 长按也能进多选；这一枚是**看得见**的那条路
                          onPressed: () => _enterSelection(visibleTaskIds.first),
                          child: const Text('多选'),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: !hasQuery
                    ? const EmptyState(
                        icon: Icons.search,
                        title: '输入关键词开始搜索',
                        hint: '范围：未归档的项目 / 事件 / 任务与待处理灵感',
                      )
                    : shown.isEmpty
                        ? const EmptyState(
                            icon: Icons.search_off,
                            title: '没有匹配的结果',
                            hint: '请输入其他关键词；已归档与已丢弃的内容在归档区',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: shown.length,
                            separatorBuilder: (_, _) => const Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                            ),
                            itemBuilder: (context, index) {
                              final hit = shown[index];
                              final isTask = hit.doc == DocName.tasks;
                              return _HitTile(
                                app: widget.app,
                                hit: hit,
                                selecting: _selecting && isTask,
                                selected: _selectedIds.contains(hit.entity.id),
                                onToggleSelect: () => _toggleSelection(hit.entity.id),
                                onLongPress: isTask
                                    ? () => _longPress(hit.entity.id)
                                    // 多选只收任务：别的类型按下去没有批量动作可做，
                                    // 与其让用户选上一个"选不了"的东西，不如明说
                                    : () => showToast(
                                        context,
                                        '多选只支持任务；项目 / 事件 / 灵感请打开详情页修改',
                                      ),
                              );
                            },
                          ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _longPress(String taskId) {
    if (_selecting) {
      _toggleSelection(taskId);
    } else {
      _enterSelection(taskId);
    }
  }

  Future<void> _batchSetDue(BuildContext context) async {
    final ids = _selectedIds.toList(growable: false);
    if (await batchSetTasksDueAction(context, widget.app, ids)) {
      _exitSelection();
    }
  }

  Future<void> _batchArchive(BuildContext context) async {
    final ids = _selectedIds.toList(growable: false);
    if (await batchArchiveTasksAction(context, widget.app, ids)) {
      _exitSelection();
    }
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({
    required this.app,
    required this.hit,
    this.selecting = false,
    this.selected = false,
    this.onToggleSelect,
    this.onLongPress,
  });

  final AppController app;
  final SearchHit hit;

  /// 多选态（只有任务命中会进这个状态）：整行变成"勾选行"
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entity = hit.entity;
    Widget tile = ListTile(
      leading: Icon(entityTypeIcon(entity)),
      title: Text(hit.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${entityTypeLabel(entity)} · 命中「${_fieldLabel(hit.matchedField)}」',
        style: theme.textTheme.labelSmall,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(context),
    );

    if (selecting) {
      // 多选态：点这一行只切换选中（用 `AbsorbPointer` 把原来"点开"的那条路
      // 关掉），底色垫在 `Material` 上而不是包 `DecoratedBox`（《界面规范》§6 第 2 条）。
      tile = Material(
        type: selected ? MaterialType.canvas : MaterialType.transparency,
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
            : null,
        child: AbsorbPointer(child: tile),
      );
    }

    return GestureDetector(
      onTap: selecting ? onToggleSelect : null,
      onLongPress: onLongPress,
      child: tile,
    );
  }

  Future<void> _open(BuildContext context) async {
    final entity = hit.entity;
    switch (hit.doc) {
      case DocName.projects:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ProjectDetailPage(app: app, projectId: entity.id),
          ),
        );
        break;
      case DocName.events:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => EventDetailPage(app: app, eventId: entity.id),
          ),
        );
        break;
      case DocName.tasks:
        final task = entity as Task;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => EventDetailPage(app: app, eventId: task.eventId),
          ),
        );
        break;
      case DocName.inspirations:
        final inspiration = entity as Inspiration;
        if (!context.mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('灵感原文', style: Theme.of(sheetContext).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Text(inspiration.text),
                ],
              ),
            ),
          ),
        );
        break;
    }
  }

  static String _fieldLabel(String field) {
    // 字段名与界面同步（Q4）：「目的」→「有什么问题 / 思路」，
    // 与项目详情页那个字段卡、AI 提示词里用的词一模一样。
    const labels = <String, String>{
      'title': '标题',
      'purpose': '有什么问题 / 思路',
      'implementation': '实现',
      'name': '名称',
      'text': '内容',
    };
    return labels[field] ?? field;
  }
}
