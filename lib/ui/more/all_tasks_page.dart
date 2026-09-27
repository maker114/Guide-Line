import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/task.dart';
import '../common/empty_state.dart';
import '../common/status_selector.dart';
import '../common/task_tile.dart';
import '../common/urgency.dart';
import '../events/task_actions.dart';
import 'task_grouping.dart';

/// 全部任务：**跨事件的任务总表**。
///
/// 事件层级在手机上层层点进去太慢，这里给一个"平铺"的入口：
/// 可以按完成度 / 事件 / 紧迫度分组（分组与排序在 `task_grouping.dart`）。
///
/// 多选（Q26）：这一页原来只能一条条点进事件去改期。现在与灵感页**同一套习惯** ——
/// 长按任一条进入多选、点条目标切换选中、「全选」只作用于当前可见的那些；
/// 批量动作给「设到期日」与「归档」。
class AllTasksPage extends StatefulWidget {
  const AllTasksPage({super.key, required this.app});

  final AppController app;

  @override
  State<AllTasksPage> createState() => _AllTasksPageState();
}

class _AllTasksPageState extends State<AllTasksPage> {
  TaskGrouping _grouping = TaskGrouping.completion;

  /// 多选模式：长按任一条进入，之后点条目即切换选中。
  bool _selecting = false;
  final Set<String> _selectedIds = <String>{};

  /// 当前列表里**可见**的那些 id（「全选」按它算）。
  final Set<String> _visibleIds = <String>{};

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
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final theme = Theme.of(context);
        final app = widget.app;
        // 顶部那排「全部 / 未完成 / 已完成 / 已搁置」筛选条整行去掉了
        // （实机反馈：分类不要了）—— 想看某种状态，切「按完成度」就行，
        // 它天然把三种状态分成三组、顺序固定。
        final tasks = app.ws.liveTasks.where((t) => !t.archived).toList(growable: false);
        final rows = _buildRows(context, tasks);

        // 选中项可能已经被别人改动（例如在别处归档掉了），每次构建都清一遍幽灵选中
        final visibleIds = <String>{
          for (final row in rows)
            if (row.task != null) row.task!.id,
        };
        _selectedIds.removeWhere((id) => !visibleIds.contains(id));
        _visibleIds
          ..clear()
          ..addAll(visibleIds);
        // 一条都没了（全被归档 / 删掉）时自动退出多选，别留一条空的动作条
        if (_selecting && _visibleIds.isEmpty) {
          // **不在 build 里改状态**（Q-6）：挪到帧后统一应用，别依赖 build 的副作用
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _exitSelection();
          });
        }

        return Scaffold(
          appBar: AppBar(title: const Text('全部任务')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
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
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  // 分组调节栏走全应用统一的胶囊选择器（与项目详情的「状态」
                  // 同一套观感），不再是 Material 的分段控件
                  child: StatusPillSelector<TaskGrouping>(
                    values: TaskGrouping.values,
                    selected: _grouping,
                    labelOf: (value) => value.label,
                    onSelected: (value) => setState(() => _grouping = value),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: <Widget>[
                    Text(
                      // 多选状态**统一写「已选 N 条」**（《界面规范》§7）
                      _selecting ? '已选 ${_selectedIds.length} 条' : '共 ${tasks.length} 条，含子任务',
                      style: theme.textTheme.labelSmall,
                    ),
                    const Spacer(),
                    if (!_selecting && tasks.isNotEmpty)
                      TextButton(
                        onPressed: () => _enterSelection(tasks.first.id),
                        child: const Text('多选'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(
                        icon: Icons.checklist_outlined,
                        title: '没有符合条件的任务',
                        hint: '换个筛选条件试试；要新建任务，得先去「事件」里开一条线 —— 任务总得有归属',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: rows.length,
                        itemBuilder: (context, index) => _buildRow(context, rows[index]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, TaskRow row) {
    final header = row.header;
    if (header != null) {
      return TaskGroupHeader(title: header, count: row.count, color: row.color);
    }

    final task = row.task!;
    Widget tile = TaskTile(app: widget.app, task: task);
    if (_selecting) {
      // 多选态：整行变成"勾选行" —— 点它只切换选中，不再进事件详情。
      // 底色垫在 `Material` 上，而不是包一层 `DecoratedBox`：ListTile 的水波纹画在
      // 最近的 `Material` 上，中间夹一层有底色的 `DecoratedBox` 会让它报错
      // （《界面规范》§6.2，事件页踩过同一个坑）。
      final selected = _selectedIds.contains(task.id);
      tile = Material(
        type: selected ? MaterialType.canvas : MaterialType.transparency,
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.45)
            : null,
        child: AbsorbPointer(child: tile),
      );
    }

    return GestureDetector(
      // 长按进入多选（与灵感页同一套习惯）；已经在多选里就直接切换选中
      onLongPress:
          _selecting ? () => _toggleSelection(task.id) : () => _enterSelection(task.id),
      onTap: _selecting ? () => _toggleSelection(task.id) : null,
      child: Column(
        children: <Widget>[
          tile,
          const Divider(height: 1, indent: 16, endIndent: 16),
        ],
      ),
    );
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

  List<TaskRow> _buildRows(BuildContext context, List<Task> tasks) {
    final app = widget.app;
    final colors = UrgencyColors.ofContext(context);
    final List<TaskGroup> groups;
    switch (_grouping) {
      case TaskGrouping.completion:
        groups = groupByCompletion(tasks);
      case TaskGrouping.event:
        groups = groupByEvent(
          tasks,
          app.ws.liveEvents,
          (eventId) => app.ws.findEvent(eventId)?.name ?? '事件已删除',
        );
      case TaskGrouping.urgency:
        groups = groupByUrgency(tasks);
    }
    return flattenTaskGroups(groups, (tone) => colors.of(tone ?? Urgency.none));
  }
}
