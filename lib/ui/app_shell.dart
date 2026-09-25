import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../platform/data_directory.dart';
import '../platform/shortcut_channel.dart';
import 'events/event_tab.dart';
import 'inspiration/inspiration_tab.dart';
import 'more/due_page.dart';
import 'more/more_tab.dart';
import 'projects/project_tab.dart';

/// 底部导航的形状参数（都是推算出来的，别单独改其中一个）。
///
/// 目标（实机反馈）：选中框尽量接近**正圆**、把图标和文字都罩住，
/// 且它与外部胶囊的圆角同源，选最左 / 最右时能贴合胶囊内侧的弧。
///
/// 有一个绕不开的限制：`NavigationBar` 的选中指示器尺寸是**写死的**
/// （`_kIndicatorWidth = 64`、`_kIndicatorHeight = 32`，见 Flutter 源码），
/// `indicatorShape` 只决定形状、**改不了尺寸**。想要正圆就得让宽 = 高，
/// 而宽固定 64 → 指示器高度得是 64 → 导航高度得 128，那太占地方了。
/// 所以这里取一个折中：把导航高度定成 56，指示器变成 64 × 28 的椭圆。
/// 形状用 `StadiumBorder`，两端是完整半圆，视觉上就是个"横着的胶囊"，
/// 与整个应用的形状规范一致；**要真正的正圆只能自绘导航**，那不值得。
const double _navHeight = 56;

/// 外部胶囊的圆角半径：半个导航高度 + 外层纵向内边距 →
/// 胶囊两端是完整半圆，与里面的选中胶囊同一套弧线。
const double _navOuterPadding = 6;
const double _navRadius = _navHeight / 2 + _navOuterPadding;

/// 选中指示器的**正圆**形状。
///
/// 为什么要自己画：`NavigationBar` 的指示器尺寸是**写死的**
/// （`_kIndicatorWidth = 64`、`_kIndicatorHeight = 32`，见 Flutter 源码），
/// `indicatorShape` 只能决定"在这个 64×32 的框里画什么形状"，
/// 改不了框本身 —— 所以给 `CircleBorder` 或 `StadiumBorder` 得到的都是椭圆
/// （64 宽的胶囊 / 被压扁的圆），不是正圆。
///
/// 这里换成"**无视框的实际尺寸、按给定半径画圆**"：
/// 半径取外部胶囊的圆角半径 [_navRadius]，于是：
///   · 它是个正圆；
///   · 圆的高度 = 2 × _navRadius，把图标与文字整个罩住；
///   · 选中最左 / 最右那一项时，圆与胶囊端部的弧**是同一条弧**，完全贴合。
///
/// 唯一的代价：指示器框宽仍是 64，划水波纹（InkWell）时高亮区域比圆略宽。
/// 视觉上圆本身是准的 —— 这是不自己重写整个导航栏的前提下能做到的最接近。
class _NavIndicatorCircle extends ShapeBorder {
  const _NavIndicatorCircle(this.radius);

  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final center = rect.center;
    return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => _NavIndicatorCircle(radius * t);
}

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
          //   · 外边距 20、底部留 18（避开系统手势条）；
          //   · 图标与文字的间距由 `labelPadding` 压到 0，配合小一号图标，
          //     整条胶囊才紧凑（参数见文件顶部的推导说明）。
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                // 圆角与里面的选中胶囊**同源**（都是 _navRadius），
                // 所以两端的弧与选中块的弧是同一套
                borderRadius: BorderRadius.circular(_navRadius),
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
                borderRadius: BorderRadius.circular(_navRadius),
                child: NavigationBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  height: _navHeight,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  selectedIndex: _index,
                  indicatorShape: const _NavIndicatorCircle(_navRadius),
                  onDestinationSelected: (index) {
                    setState(() => _index = index);
                    app.setLastTab(index);
                  },
                  // 图标小一号、标签与图标之间**不留额外间距**：
                  // 默认的 labelPadding(top: 4) + 24px 图标会让内容撑到贴边。
                  labelPadding: EdgeInsets.zero,
                  destinations: <NavigationDestination>[
                    const NavigationDestination(
                      icon: Icon(Icons.lightbulb_outline, size: 22),
                      selectedIcon: Icon(Icons.lightbulb, size: 22),
                      label: '灵感',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.account_tree_outlined, size: 22),
                      selectedIcon: Icon(Icons.account_tree, size: 22),
                      label: '项目',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.timeline_outlined, size: 22),
                      selectedIcon: Icon(Icons.timeline, size: 22),
                      label: '事件',
                    ),
                    // 逾期任务的数量挂在「更多」上：到期视图在那一页下面，
                    // 不做推送唤醒（ADR-062），所以至少让用户一进 App 就看得见。
                    NavigationDestination(
                      icon: Badge.count(
                        count: app.overdueCount,
                        isLabelVisible: app.overdueCount > 0,
                        child: const Icon(Icons.more_horiz, size: 22),
                      ),
                      selectedIcon: Badge.count(
                        count: app.overdueCount,
                        isLabelVisible: app.overdueCount > 0,
                        child: const Icon(Icons.more_horiz, size: 22),
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
