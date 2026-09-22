import 'package:flutter/material.dart';

/// 电脑端外壳（设计文档 3.1.1 / 6.2 / ADR-023）：**侧栏 + 多栏，编辑优先**。
///
/// 当前是 M2 的**结构占位**：导航骨架已按信息架构摆好，
/// 数据绑定与真实视图在 M4（业务层）/ M6（UI）接入。
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

/// 导航项 —— 两个板块 + 聚合视图 + 归档区（设计文档 4.10）。
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
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            extended: true,
            minExtendedWidth: 220,
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
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                  child: Row(
                    children: <Widget>[
                      Text(_selected.label, style: theme.textTheme.headlineSmall),
                      const Spacer(),
                      // 设计文档 §2「状态可见」：同步状态必须常驻可见（M5 接入真实状态）
                      const _SyncStatusChip(),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          _selected.icon,
                          size: 56,
                          color: theme.colorScheme.outlineVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${_selected.label} —— 视图待接入',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '数据层与业务规则已就绪（core / store / sync 三块已测试通过）',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 同步状态指示（先把位置占住，M5 接入真实状态机）。
class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      avatar: Icon(Icons.cloud_off_outlined, size: 18, color: theme.colorScheme.outline),
      label: const Text('未配对 · 本地可用'),
      visualDensity: VisualDensity.compact,
    );
  }
}
