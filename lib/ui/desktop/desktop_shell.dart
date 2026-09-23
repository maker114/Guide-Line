import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import '../../core/rules/completion.dart';
import '../archive/archive_zone_page.dart';
import '../board1/board1_page.dart';
import '../board2/board2_page.dart';
import '../settings/settings_page.dart';
import '../shared/widgets.dart';

/// 电脑端外壳（设计文档 3.1.1 / 6.2 / ADR-023）：**侧栏 + 多栏，编辑优先**。
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.app});

  final AppController app;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

enum _NavItem {
  projects('项目与灵感', Icons.account_tree_outlined),
  events('事件与任务线', Icons.timeline_outlined),
  dueSoon('今天 / 本周到期', Icons.event_available_outlined),
  allTasks('全部任务', Icons.checklist_outlined),
  archive('归档区', Icons.inventory_2_outlined),
  settings('设置', Icons.settings_outlined);

  const _NavItem(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _DesktopShellState extends State<DesktopShell> {
  _NavItem _selected = _NavItem.projects;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Scaffold(
          body: Row(
            children: <Widget>[
              NavigationRail(
                extended: true,
                minExtendedWidth: 210,
                selectedIndex: _NavItem.values.indexOf(_selected),
                onDestinationSelected: (index) {
                  setState(() => _selected = _NavItem.values[index]);
                },
                destinations: <NavigationRailDestination>[
                  for (final item in _NavItem.values)
                    NavigationRailDestination(
                      icon: Icon(item.icon),
                      label: Text(item.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Row(
                        children: <Widget>[
                          Text(_selected.label, style: theme.textTheme.headlineSmall),
                          const Spacer(),
                          if (_selected == _NavItem.archive)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                '这里的东西都还能找回；只有「彻底删除」不可恢复',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          _SyncStatusChip(app: widget.app),
                        ],
                      ),
                    ),
                    if (widget.app.startupWarnings.isNotEmpty)
                      _WarningBanner(messages: widget.app.startupWarnings),
                    const Divider(height: 1),
                    Expanded(child: _content()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _content() {
    switch (_selected) {
      case _NavItem.projects:
        return Board1Page(app: widget.app);
      case _NavItem.events:
        return Board2Page(app: widget.app);
      case _NavItem.dueSoon:
        return _DueSoonView(app: widget.app);
      case _NavItem.allTasks:
        return _AllTasksView(app: widget.app);
      case _NavItem.archive:
        return ArchiveZonePage(app: widget.app);
      case _NavItem.settings:
        return SettingsPage(app: widget.app);
    }
  }
}

/// 同步状态位（设计文档 §2「状态可见」）。
class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCloud = app.hasCloud;
    final label = hasCloud ? app.syncStatus.label : '本地模式 · 未配置云端';
    return Chip(
      avatar: Icon(
        hasCloud ? Icons.cloud_sync_outlined : Icons.cloud_off_outlined,
        size: 18,
        color: theme.colorScheme.outline,
      ),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: <Widget>[
          const Icon(Icons.warning_amber_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(messages.join('；'), style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// 到期聚合视图（Q29 / Q48）。
class _DueSoonView extends StatelessWidget {
  const _DueSoonView({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final weekLater = today.add(const Duration(days: 7));
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    final overdue = app.ws.tasksDueOnOrBefore(fmt(today.subtract(const Duration(days: 1))));
    final dueSoon = app.ws
        .tasksDueOnOrBefore(fmt(weekLater))
        .where((t) => (t.dueAt ?? '').compareTo(fmt(today)) >= 0)
        .toList(growable: false);

    if (overdue.isEmpty && dueSoon.isEmpty) {
      return const EmptyState(
        icon: Icons.event_available_outlined,
        title: '没有到期任务',
        hint: '给任务设置到期日后，会在这里按时间聚合',
      );
    }

    return ListView(
      children: <Widget>[
        if (overdue.isNotEmpty) ...<Widget>[
          SectionLabel('已逾期（${overdue.length}）'),
          for (final task in overdue) _TaskRow(app: app, task: task, overdue: true),
        ],
        if (dueSoon.isNotEmpty) ...<Widget>[
          SectionLabel('本周到期（${dueSoon.length}）'),
          for (final task in dueSoon) _TaskRow(app: app, task: task, overdue: false),
        ],
      ],
    );
  }
}

/// 全部任务（按到期日排序，无日期沉底）。
class _AllTasksView extends StatelessWidget {
  const _AllTasksView({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final tasks = app.ws.liveTasks.where((t) => !t.archived).toList(growable: false);
    if (tasks.isEmpty) {
      return const EmptyState(
        icon: Icons.checklist_outlined,
        title: '还没有任务',
        hint: '在「事件与任务线」里为事件添加任务',
      );
    }
    tasks.sort((a, b) {
      final byDate = (a.dueAt ?? '9999').compareTo(b.dueAt ?? '9999');
      if (byDate != 0) return byDate;
      return a.order.compareTo(b.order);
    });

    return ListView(
      children: <Widget>[
        for (final task in tasks) _TaskRow(app: app, task: task, overdue: false),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.app, required this.task, required this.overdue});

  final AppController app;
  final Task task;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final theme = Theme.of(context);
    final event = ws.findEvent(task.eventId);
    final check = checkCompletion(ws.taskTree, task.id);
    final isOverdue = overdue && task.status == NodeStatus.pending;

    return ListTile(
      dense: true,
      leading: NodeStatusChip(
        status: task.status,
        completeBlockedReason: check.canComplete ? null : check.reason,
        onChanged: (status) {
          final error = app.run(() => ws.setTaskStatus(task.id, status));
          if (error != null) showNotice(context, error, error: true);
        },
      ),
      title: Text(
        task.title,
        style: theme.textTheme.bodyMedium?.copyWith(
          decoration: task.status == NodeStatus.done ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text('${event?.name ?? '（事件已删除）'} · ${task.dueAt ?? '无到期日'}'),
      trailing: isOverdue
          ? Text('逾期', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.error))
          : null,
    );
  }
}
