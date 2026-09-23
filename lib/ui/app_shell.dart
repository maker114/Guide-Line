import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'inspiration/inspiration_tab.dart';

/// 手机端外壳：**底部四 Tab + 速记优先**（对应归档设计 §3.1.1 的手机端定位）。
///
/// ```
/// 灵感   速记输入框置顶 + 未处理列表
/// 项目   项目树 → 详情
/// 事件   事件 → 任务线
/// 更多   到期 / 全部任务 / 搜索 / 归档区 / 备份与导出 / 设置
/// ```
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.app});

  final AppController app;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<InspirationTabState> _inspirationKey = GlobalKey<InspirationTabState>();
  late int _index = widget.app.prefs.lastTabIndex.clamp(0, 3);

  static const List<String> _titles = <String>['灵感', '项目', '事件', '更多'];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final app = widget.app;
        return Scaffold(
          appBar: AppBar(
            title: Text(_titles[_index]),
            actions: <Widget>[
              if (_index == 3)
                TextButton(
                  onPressed: () => _showAbout(context),
                  child: const Text('关于'),
                ),
            ],
          ),
          body: Column(
            children: <Widget>[
              if (app.startupWarnings.isNotEmpty) _WarningBanner(messages: app.startupWarnings),
              Expanded(
                child: IndexedStack(
                  index: _index,
                  children: <Widget>[
                    InspirationTab(key: _inspirationKey, app: app),
                    _Placeholder(
                      icon: Icons.account_tree_outlined,
                      title: '项目与灵感',
                      hint: '项目树（≤3 层）、目的 / 实现 / 日期、三态完成、归档与删除\n—— 下一轮实现（M4）',
                      stats: '当前：项目 ${app.projectCount} 个 · 灵感 ${app.inspirationCount} 条',
                    ),
                    _Placeholder(
                      icon: Icons.timeline_outlined,
                      title: '事件与任务线',
                      hint: '事件 → 主线标准任务 → 子任务 / 并列任务，含到期日与勾选完成\n—— 下一轮实现（M4）',
                      stats: '当前：事件 ${app.eventCount} 个 · 任务 ${app.taskCount} 条',
                    ),
                    _MoreTab(app: app),
                  ],
                ),
              ),
            ],
          ),
          floatingActionButton: _index == 0
              ? null
              : FloatingActionButton.extended(
                  onPressed: () {
                    setState(() => _index = 0);
                    app.setLastTab(0);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _inspirationKey.currentState?.focusCapture();
                    });
                  },
                  icon: const Icon(Icons.bolt),
                  label: const Text('速记'),
                ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (index) {
              setState(() => _index = index);
              app.setLastTab(index);
            },
            destinations: const <NavigationDestination>[
              NavigationDestination(
                icon: Icon(Icons.lightbulb_outline),
                selectedIcon: Icon(Icons.lightbulb),
                label: '灵感',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_tree_outlined),
                selectedIcon: Icon(Icons.account_tree),
                label: '项目',
              ),
              NavigationDestination(
                icon: Icon(Icons.timeline_outlined),
                selectedIcon: Icon(Icons.timeline),
                label: '事件',
              ),
              NavigationDestination(
                icon: Icon(Icons.more_horiz),
                selectedIcon: Icon(Icons.more_horiz),
                label: '更多',
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Guide Line',
      applicationVersion: '1.0.0+1',
      children: <Widget>[
        const Text('本地优先的个人生活管理工具（单机版）。'),
        const SizedBox(height: 8),
        Text('数据目录：${widget.app.dataDirectory.path}'),
      ],
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          const Icon(Icons.warning_amber_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(messages.join('；'), style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _MoreTab extends StatelessWidget {
  const _MoreTab({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        const _SectionHeader('浏览'),
        ListTile(
          leading: const Icon(Icons.event_available_outlined),
          title: const Text('今天 / 本周到期'),
          subtitle: Text('当前 ${app.ws.tasksDueOnOrBefore(_today()).length} 条待处理'),
          enabled: false,
          trailing: const Text('下一轮'),
        ),
        ListTile(
          leading: const Icon(Icons.checklist_outlined),
          title: const Text('全部任务'),
          subtitle: Text('当前 ${app.taskCount} 条'),
          enabled: false,
          trailing: const Text('下一轮'),
        ),
        ListTile(
          leading: const Icon(Icons.search),
          title: const Text('搜索'),
          subtitle: Text('项目 / 事件 / 任务 / 灵感（${app.projectCount + app.eventCount + app.taskCount + app.inspirationCount} 条可搜）'),
          enabled: false,
          trailing: const Text('下一轮'),
        ),
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: const Text('归档区'),
          subtitle: Text('已归档 / 已丢弃 / 已合并 / 回收站（当前 ${app.archiveCount} 条）'),
          enabled: false,
          trailing: const Text('下一轮'),
        ),
        const _SectionHeader('数据安全'),
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('数据文件'),
          subtitle: Text('${app.storeFileSize} · ${app.dataDirectory.path}'),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('备份与恢复'),
          subtitle: Text('已有 ${app.backups.length} 份备份（自动轮转 + 日快照）'),
          enabled: false,
          trailing: const Text('下一轮'),
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('导出 / 分享'),
          subtitle: const Text('导出为 .json.gz 后可通过系统分享发出'),
          enabled: false,
          trailing: const Text('下一轮'),
        ),
        const _SectionHeader('关于'),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('版本'),
          subtitle: Text('1.0.0+1（Android 单机版）'),
        ),
      ],
    );
  }

  static String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.hint,
    required this.stats,
  });

  final IconData icon;
  final String title;
  final String hint;
  final String stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 56, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(hint, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(stats, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
