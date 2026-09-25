import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../platform/data_directory.dart';
import '../platform/shortcut_channel.dart';
import 'events/event_tab.dart';
import 'inspiration/inspiration_tab.dart';
import 'more/due_page.dart';
import 'more/more_tab.dart';
import 'projects/project_tab.dart';

/// 底部导航的形状参数（自绘，改动时这几个要一起看）。
///
/// 目标（实机反馈）：选中框是**正圆**、把图标与文字都罩住，
/// **上下与外部胶囊相切**，切换时**左右滑动**。
///
/// **为什么自绘而不用 `NavigationBar`**：试过三版都不对。它的选中指示器
/// 框尺寸**写死的**（`_kIndicatorWidth = 64`、`_kIndicatorHeight = 32`，
/// 见 Flutter 源码 `navigation_bar.dart`），`indicatorShape` 只能决定
/// "在这个框里画什么形状"、改不了框。实机量到的两版：
///   · 自绘半径 34 的圆 → 被框裁成 **64×28** 的压扁胶囊；
///   · 半径改成 32（框宽的一半）→ 又被高度裁成 **64×56** 的椭圆。
/// 想要"正圆 + 上下相切 + 能滑动"只能自己画。
const double _navIndicatorRadius = 24;

/// 导航内容高度 = 选中圆直径。
const double _navHeight = _navIndicatorRadius * 2;

/// 外层纵向内边距：**取 0**，好让圆上下与胶囊内缘相切
/// （实机反馈"圆直径大一点、上下和外部胶囊相切"）。
/// 再大一点圆就会被胶囊裁掉上下两端，不再是个完整的圆。
const double _navOuterPadding = 0;

/// 外部胶囊的圆角半径 = 选中圆半径 + 外层内边距。
///
/// 于是圆心距胶囊左内缘正好等于圆半径，圆在这点与胶囊左端的弧**相切** ——
/// 两者同心同径，视觉上完全贴合。
const double _navRadius = _navIndicatorRadius + _navOuterPadding;

/// 滑动时长：切换页签时圆从旧位置滑到新位置。
const Duration _navSlideDuration = Duration(milliseconds: 260);

/// 底部导航的一项：可点的方块（图标在上、文字在下）。
///
/// **不含选中背景**：选中圆是整条导航共用的一个，在 `AppBottomNav` 里
/// 靠 `Stack` 定位并做滑动动画 —— 每项各画一个圆就只能"淡入淡出"，
/// 做不到"滑过去"。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          height: _navHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Badge.count(
                count: badgeCount,
                isLabelVisible: badgeCount > 0,
                child: Icon(
                  selected ? selectedIcon : icon,
                  size: 22,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自绘的底部导航条。
///
/// 单独抽成一个组件不只是为了整洁：`NavigationBar` 被换掉之后，
/// 界面上就没有那个类型可找了，而用例要靠"找到底栏 → 点里面的页签"来切页。
/// 给它一个**自己的公开类型**，测试用 `find.byType(AppBottomNav)` 定位，
/// 比按文案或图标去猜稳得多。
class AppBottomNav extends StatefulWidget {
  const AppBottomNav({
    super.key,
    required this.index,
    required this.onSelect,
    this.overdueCount = 0,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final int overdueCount;

  @override
  State<AppBottomNav> createState() => _AppBottomNavState();
}

class _AppBottomNavState extends State<AppBottomNav> {
  static const int _itemCount = 4;

  /// 上一次显示的页签。
  ///
  /// 用它判断"要不要播滑动动画"：与传进来的 index 比，变了才滑。
  /// 之所以自己存一份而不是看 `didUpdateWidget` 的 `oldWidget.index`，
  /// 是为了不依赖"父级一定会传新值"—— 父级因别的原因重建时不会误播动画。
  /// 对齐发生在 build 里（而不是动画结束后），因为动画起点由
  /// `AnimatedPositioned` 自己按旧位置接管，这里只负责"这次要不要动"。
  int _shownIndex = 0;

  @override
  void initState() {
    super.initState();
    _shownIndex = widget.index;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / _itemCount;
        // 圆在"选中那一格"里居中
        final target = itemWidth * widget.index + (itemWidth - _navIndicatorRadius * 2) / 2;
        final animate = _shownIndex != widget.index;
        _shownIndex = widget.index;

        return Stack(
          children: <Widget>[
            AnimatedPositioned(
              // 首次出现不播动画；之后 index 一变就从旧位置滑到新位置
              duration: animate ? _navSlideDuration : Duration.zero,
              curve: Curves.easeOutCubic,
              left: target,
              // 纵向顶到 0：配合外层零纵向内边距，圆上下与胶囊内缘**相切**
              top: 0,
              child: Container(
                width: _navIndicatorRadius * 2,
                height: _navIndicatorRadius * 2,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Row(
              children: <Widget>[
                _NavItem(
                  icon: Icons.lightbulb_outline,
                  selectedIcon: Icons.lightbulb,
                  label: '灵感',
                  selected: widget.index == 0,
                  onTap: () => widget.onSelect(0),
                ),
                _NavItem(
                  icon: Icons.account_tree_outlined,
                  selectedIcon: Icons.account_tree,
                  label: '项目',
                  selected: widget.index == 1,
                  onTap: () => widget.onSelect(1),
                ),
                _NavItem(
                  icon: Icons.timeline_outlined,
                  selectedIcon: Icons.timeline,
                  label: '事件',
                  selected: widget.index == 2,
                  onTap: () => widget.onSelect(2),
                ),
                // 逾期数量挂在「更多」上：到期视图在那一页下面，
                // 不做推送唤醒（ADR-062），所以至少让用户一进 App 就看得见
                _NavItem(
                  icon: Icons.more_horiz,
                  selectedIcon: Icons.more_horiz,
                  label: '更多',
                  selected: widget.index == 3,
                  badgeCount: widget.overdueCount,
                  onTap: () => widget.onSelect(3),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
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

  /// 切换底部页签（底部导航每一项都用它，所以"切页"这件事只有一个入口）。
  void _selectTab(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    widget.app.setLastTab(index);
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
          // 底部导航：**自绘的长条胶囊**。
          //
          // 为什么不用 `NavigationBar`（试过三版都不对）：
          //   · 它的选中指示器框尺寸是**写死的**（`_kIndicatorWidth = 64`、
          //     `_kIndicatorHeight = 32`，见 Flutter 源码），`indicatorShape`
          //     只能决定"在这个框里画什么形状"，改不了框；
          //   · 给 `StadiumBorder` 得到 64×32 的胶囊；自绘半径 34 的圆会被
          //     这个框**裁成椭圆**（实机量出来是 64×28 与 64×56 两次都不是圆）。
          // 要"正圆 + 半径与外部胶囊一致"就只能自己画。
          //
          // 自绘之后全是可控的：圆半径 `_navIndicatorRadius`，
          // 外部圆角 `_navRadius = 圆半径 + 内边距`，选中最左/最右时两者同弧相切。
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
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
              child: Padding(
                padding: const EdgeInsets.all(_navOuterPadding),
                child: AppBottomNav(
                  index: _index,
                  overdueCount: app.overdueCount,
                  onSelect: _selectTab,
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
