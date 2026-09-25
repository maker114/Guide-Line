import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../platform/data_directory.dart';
import '../platform/shortcut_channel.dart';
import 'events/event_tab.dart';
import 'inspiration/inspiration_tab.dart';
import 'more/due_page.dart';
import 'more/more_tab.dart';
import 'projects/project_tab.dart';
import 'theme/shape_tokens.dart';

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
  final GlobalKey<InspirationTabState> _inspirationKey =
      GlobalKey<InspirationTabState>();
  late int _index = widget.app.prefs.lastTabIndex.clamp(0, 3);

  static const List<String> _titles = <String>['灵感', '项目', '事件', '更多'];

  @override
  void initState() {
    super.initState();
    _bindCaptureShortcut();
  }

  /// 长按桌面图标 → 速记：热启动靠推送，冷启动靠启动时问一次。
  void _bindCaptureShortcut() {
    ShortcutChannel.onCapture(_goCapture);
    ShortcutChannel.consumePendingCapture().then((pending) {
      if (pending) _goCapture();
    });
  }

  /// 切到灵感页并把光标放进输入框 —— 「记一笔」的代价必须足够小。
  void _goCapture() {
    if (!mounted) return;
    setState(() => _index = 0);
    widget.app.setLastTab(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inspirationKey.currentState?.focusCapture();
    });
  }

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
              if (app.startupWarnings.isNotEmpty)
                _WarningBanner(messages: app.startupWarnings),
              if (app.overdueCount > 0)
                _DueBanner(count: app.overdueCount, app: app),
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
              // 速记按钮：**胶囊形**（按实机反馈）。
              // `FloatingActionButton.extended` 的默认圆角是 16，看着仍是个圆角方块；
              // 这里显式给 StadiumBorder 才是真正的胶囊。
              : FloatingActionButton.extended(
                  onPressed: _goCapture,
                  shape: const StadiumBorder(),
                  icon: const Icon(Icons.bolt),
                  label: const Text('速记'),
                ),
          // 底部导航做成**悬浮的长条胶囊**（按实机反馈）：
          //   · 原来 `NavigationBar` 铺满底边、底色占满整个区域，看着是一大片灰；
          //   · 现在高度收到 56、左右外边距加到 20，视觉上更"窄"；
          //   · 底部留 18dp 避开系统手势条 —— 原来只留 10dp，胶囊会压在那条系统栏上；
          //   · 图标与文字在胶囊内垂直居中由 `NavigationBar` 保证，高度给够即可。
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(AppShapes.pillRadius + 12),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Theme.of(context).colorScheme.shadow
                        .withValues(alpha: 0.10),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppShapes.pillRadius + 12),
                child: NavigationBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  height: 56,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  selectedIndex: _index,
                  indicatorShape: const StadiumBorder(),
                  onDestinationSelected: (index) {
                    setState(() => _index = index);
                    app.setLastTab(index);
                  },
                  destinations: <NavigationDestination>[
                    const NavigationDestination(
                      icon: Icon(Icons.lightbulb_outline),
                      selectedIcon: Icon(Icons.lightbulb),
                      label: '灵感',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.account_tree_outlined),
                      selectedIcon: Icon(Icons.account_tree),
                      label: '项目',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.timeline_outlined),
                      selectedIcon: Icon(Icons.timeline),
                      label: '事件',
                    ),
                    // 逾期任务的数量挂在「更多」上：到期视图在那一页下面，
                    // 不做推送唤醒（ADR-062），所以至少让用户一进 App 就看得见。
                    NavigationDestination(
                      icon: Badge.count(
                        count: app.overdueCount,
                        isLabelVisible: app.overdueCount > 0,
                        child: const Icon(Icons.more_horiz),
                      ),
                      selectedIcon: Badge.count(
                        count: app.overdueCount,
                        isLabelVisible: app.overdueCount > 0,
                        child: const Icon(Icons.more_horiz),
                      ),
                      label: '更多',
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: AppInfo.displayName,
      applicationVersion: AppInfo.versionLabel,
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
          Expanded(
            child: Text(messages.join('；'), style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// 逾期提醒条。
///
/// 设计文档明确不做推送唤醒（ADR-062），所以"提醒"只能在用户打开 App 时发生：
/// 这条横幅 + 「更多」上的角标，就是这个 App 全部的到期提醒手段。
class _DueBanner extends StatelessWidget {
  const _DueBanner({required this.count, required this.app});

  final int count;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: InkWell(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => DuePage(app: app)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '有 $count 条任务已逾期',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
