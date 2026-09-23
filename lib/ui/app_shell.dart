import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'events/event_tab.dart';
import 'inspiration/inspiration_tab.dart';
import 'more/more_tab.dart';
import 'projects/project_tab.dart';

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
                    ProjectTab(app: app),
                    EventTab(app: app),
                    MoreTab(app: app),
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
