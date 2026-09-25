import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../platform/data_directory.dart';
import '../platform/shortcut_channel.dart';
import 'events/event_tab.dart';
import 'inspiration/inspiration_tab.dart';
import 'more/due_page.dart';
import 'more/more_tab.dart';
import 'nav_icon_motion.dart';
import 'projects/project_tab.dart';
import 'theme/shape_tokens.dart';

/// 底部导航的形状参数（自绘，改动时这几个要一起看）。
///
/// 目标（实机反馈的第三版）：选中框是**胶囊**（高度不变、两端各是一个半圆），
/// 选中最左 / 最右那一格时，它的两端圆弧与**外部胶囊的圆弧完全重合**；
/// 切换时左右滑动，途中被**短暂拉长**（惯性）。
///
/// **为什么自绘而不用 `NavigationBar`**：试过三版都不对。它的选中指示器
/// 框尺寸**写死的**（`_kIndicatorWidth = 64`、`_kIndicatorHeight = 32`，
/// 见 Flutter 源码 `navigation_bar.dart`），`indicatorShape` 只能决定
/// "在这个框里画什么形状"、改不了框。实机量到的两版：
///   · 自绘半径 34 的圆 → 被框裁成 **64×28** 的压扁胶囊；
///   · 半径改成 32（框宽的一半）→ 又被高度裁成 **64×56** 的椭圆。
/// 想要"任意宽度 + 两端与外部胶囊同弧 + 能滑动"只能自己画。
const double _navHeight = 48;

/// 选中胶囊与外部胶囊**共用的圆角半径**。
///
/// 两者同值 + 指示器与格子同宽（横向内边距取 0），选中最左那格时左端
/// left = 0、圆心距胶囊左内缘正好等于半径 —— 两段弧**同心同径、完全重合**；
/// 最右那格同理（right = 栏宽）。这是"圆弧重叠"的唯一条件。
const double _navRadius = _navHeight / 2;

/// 外层内边距：横纵都取 0 —— 横向让指示器能顶到胶囊两端的弧上，
/// 纵向让指示器与胶囊等高。
const double _navOuterPadding = 0;

/// 滑动时长：切换页签时胶囊从旧位置滑到新位置。
///
/// 收得比上一版（300ms）短：实机反馈"太粘滞、像质量很大"，
/// 主要是尾随边要花小半程去追平 —— 缩短总时长 + 让拉伸提前收回（见
/// [_navStretchAt]）合起来才是"质量小一点"。
const Duration _navSlideDuration = Duration(milliseconds: 220);

/// 惯性拉伸的上限（dp）：跳三格也不会拉成一条香肠。
///
/// 从 20 收到 12：拉伸越小，"被拖着走"的黏滞感越弱。
const double _navStretchMax = 12;

/// 惯性拉伸量（dp）：随进度**鼓起再收回**。
///
/// `sin(πt)` 负责"两头 0、中间最大"，再乘 `(1 - 0.4t)` 让它在后半程**提前**收 ——
/// 只靠 `sin(πt)` 的话，尾随边会一路拖到最后一两帧才追平，那正是"粘滞"的来源。
double _navStretchAt(double progress) =>
    _navStretchMax * math.sin(math.pi * progress) * (1 - 0.4 * progress);

/// 选中指示器的 Key：用例靠它量"滑到哪儿了、此刻多宽"。
@visibleForTesting
const Key navIndicatorKey = Key('AppBottomNav.indicator');

/// 某一项**图标动画层**的 Key：用例靠它判断"这一项动起来了没有"。
@visibleForTesting
Key navIconKey(String label) => Key('AppBottomNav.icon.$label');

/// 选中指示器的几何：进度 [t]（0 → 1）时，宽 [nominalWidth] 的胶囊从 [fromLeft]
/// 滑到 [toLeft]，返回它此刻的 `left` 与 `width`。
///
/// 惯性 = **前导边先走、尾随边落后**，两条边都只朝目标方向走：
///   · **前导边**（运动方向那一侧）走 `easeOutCubic` —— 起步快、后段慢慢靠上去，
///     而且**正好停在目标格边界上，不越过去**；
///   · **宽度**加一个鼓起包络（[_navStretchAt]）—— 起步 0、中途最宽、
///     后半程提前收回；拉出来的这部分全部长在**尾随边**那一侧。
///
/// 为什么不是"把中心放到缓动位置上、宽度对称地鼓"：那样前导边会先冲过目标格
/// 再退回来 —— 实机上看着就是"右边界到位之后又往左挪了一下"（用户反馈的原话），
/// 不像惯性，像没对准。让尾随边单独落后，前导边就是单调到位，
/// 拉伸感一点没少，却不会有回弹。
///
/// 因为前导边始终落在起点与终点之间、尾随边落在它后面，胶囊**不会越出导航条**
/// （最左 / 最右那格起步时正好贴边，之后只会更靠里），所以这里不需要夹取。
({double left, double width}) navIndicatorGeometry({
  required double t,
  required double fromLeft,
  required double toLeft,
  required double nominalWidth,
}) {
  final progress = t.clamp(0.0, 1.0);
  final eased = Curves.easeOutCubic.transform(progress);
  final width = nominalWidth + _navStretchAt(progress);

  if (toLeft >= fromLeft) {
    // 向右：前导边是右边，先到位；宽度长在左边（尾随边落后再追平）
    final right = fromLeft + nominalWidth + (toLeft - fromLeft) * eased;
    return (left: right - width, width: width);
  }
  // 向左：前导边是左边，先到位；宽度长在右边
  return (left: fromLeft + (toLeft - fromLeft) * eased, width: width);
}

/// 底部导航的一项：可点的方块（图标在上、文字在下）。
///
/// **不含选中背景**：选中胶囊是整条导航共用的一个，在 `AppBottomNav` 里
/// 靠 `Stack` 定位并做滑动动画 —— 每项各画一个就只能"淡入淡出"，
/// 做不到"滑过去 + 途中拉长"。
///
/// 它自己负责**图标那一下**（实机反馈：每个图标该有自己的一下，见 [NavIconMotion]）：
/// 点一下、以及选中状态变化时播一次；四种手势都是瞬态的，播完与静止时一模一样。
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.motion,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final NavIconMotion motion;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> with SingleTickerProviderStateMixin {
  /// 从"静止进度"走到 1 就是"动一下"。
  ///
  /// 起始值与结束值都取 `motion.restProgress`：前三种手势是"归于无"（0），
  /// 折线是"画满"（1）—— 播完落回静止样子，不需要额外的收尾逻辑。
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: navIconMotionDuration,
    value: widget.motion.restProgress,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        _motion.value = widget.motion.restProgress;
      }
    });

  @override
  void didUpdateWidget(_NavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // **只在"变成选中"时动一下**（实机反馈）：从选中退出去时不用再播一次 ——
    // 切页时旧的那一项安静退场就好，两个图标一起动反而乱。
    if (widget.selected && !oldWidget.selected) _motion.forward(from: 0);
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 选中那一项的图标与文字跟胶囊上的前景色走（胶囊是 `secondaryContainer`）
    final foreground =
        widget.selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return Expanded(
      child: InkWell(
        // 点击本身不再触发动画：触发点只有一个 —— **变成选中**。
        // （点已经选中的那一项只是回到这一页，没什么可庆祝的。）
        onTap: widget.onTap,
        // 指示器是胶囊，水波纹也跟着走胶囊 —— 圆形的波纹会溢出到相邻格子
        customBorder: const StadiumBorder(),
        child: SizedBox(
          height: _navHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Badge.count(
                count: widget.badgeCount,
                isLabelVisible: widget.badgeCount > 0,
                child: NavIconMotionView(
                  key: navIconKey(widget.label),
                  motion: widget.motion,
                  icon: widget.icon,
                  selectedIcon: widget.selectedIcon,
                  selected: widget.selected,
                  color: foreground,
                  flashColor: scheme.primary,
                  animation: _motion,
                ),
              ),
              Text(
                widget.label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: foreground),
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
///
/// [page] 是**连续**的页位置（`0.0` = 灵感、`1.5` = 项目与事件之间），
/// 由外层的 `PageController` 驱动 —— 左右滑动切页时指示器就跟着手指走。
class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.page,
    required this.onSelect,
    this.overdueCount = 0,
  });

  final ValueListenable<double> page;
  final ValueChanged<int> onSelect;
  final int overdueCount;

  static const int _itemCount = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 指示器与**一格同宽**：最左那格 left = 0、最右那格 right = 栏宽，
        // 两端圆弧于是与外部胶囊完全重合（圆角半径同为 `_navRadius`）。
        final nominalWidth = constraints.maxWidth / _itemCount;

        // 指示器跟着 **PageView 的连续页位置**走，而不是自己跑一条动画。
        // 这样"手指拖到一半"与"松手后滑过去"用的是同一个数：
        // 拖拽时它线性跟手，动画时它自带缓动（`animateToPage` 的曲线），
        // 指示器永远不会和页面内容错位。
        return ValueListenableBuilder<double>(
          valueListenable: page,
          builder: (context, value, _) {
            final current = value.clamp(0.0, (_itemCount - 1).toDouble());
            final fromIndex = current.floor();
            final toIndex = current.ceil();
            final geometry = navIndicatorGeometry(
              t: current - fromIndex,
              fromLeft: nominalWidth * fromIndex,
              toLeft: nominalWidth * toIndex,
              nominalWidth: nominalWidth,
            );
            // 图标在过半格时切到"选中"那一版（与页面翻过去同步）
            final index = current.round();

            return Stack(
              children: <Widget>[
                Positioned(
                  // 纵向顶到 0：配合外层零内边距，胶囊与外部胶囊**等高**
                  left: geometry.left,
                  top: 0,
                  child: Container(
                    key: navIndicatorKey,
                    width: geometry.width,
                    height: _navHeight,
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(_navRadius),
                    ),
                  ),
                ),
                Row(
                  children: <Widget>[
                    _NavItem(
                      icon: Icons.lightbulb_outline,
                      selectedIcon: Icons.lightbulb,
                      label: '灵感',
                      motion: NavIconMotion.bulbGlow,
                      selected: index == 0,
                      onTap: () => onSelect(0),
                    ),
                    _NavItem(
                      icon: Icons.account_tree_outlined,
                      selectedIcon: Icons.account_tree,
                      label: '项目',
                      motion: NavIconMotion.treeSway,
                      selected: index == 1,
                      onTap: () => onSelect(1),
                    ),
                    _NavItem(
                      icon: Icons.timeline_outlined,
                      selectedIcon: Icons.timeline,
                      label: '事件',
                      motion: NavIconMotion.lineTrace,
                      selected: index == 2,
                      onTap: () => onSelect(2),
                    ),
                    // 逾期数量挂在「更多」上：到期视图在那一页下面，
                    // 不做推送唤醒（ADR-062），所以至少让用户一进 App 就看得见
                    _NavItem(
                      icon: Icons.more_horiz,
                      selectedIcon: Icons.more_horiz,
                      label: '更多',
                      motion: NavIconMotion.dotsSpin,
                      selected: index == 3,
                      badgeCount: overdueCount,
                      onTap: () => onSelect(3),
                    ),
                  ],
                ),
              ],
            );
          },
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

  /// 四个页签的**横向翻页**容器：左右滑动 = 切页（实机反馈）。
  late final PageController _pages = PageController(initialPage: _index);

  /// **连续**的页位置（`1.5` = 项目与事件之间），给底部导航画指示器用。
  ///
  /// 单独用一个 `ValueNotifier` 而不是每次 `setState`：滑动过程中这玩意儿
  /// 每帧都在变，让整个外壳跟着重建太浪费 —— 只有底栏需要它。
  final ValueNotifier<double> _pageProgress = ValueNotifier<double>(0);

  static const List<String> _titles = <String>['灵感', '项目', '事件', '更多'];

  @override
  void initState() {
    super.initState();
    _pageProgress.value = _index.toDouble();
    _pages.addListener(_syncPageProgress);
    _bindCaptureShortcut();
  }

  @override
  void dispose() {
    _pages
      ..removeListener(_syncPageProgress)
      ..dispose();
    _pageProgress.dispose();
    super.dispose();
  }

  /// 把 `PageController` 的像素偏移换算成"第几页 + 小数"，喂给底栏。
  void _syncPageProgress() {
    if (!_pages.hasClients) return;
    final position = _pages.position;
    if (!position.hasContentDimensions || position.viewportDimension == 0) return;
    _pageProgress.value =
        (position.pixels / position.viewportDimension).clamp(0.0, 3.0);
  }

  /// 长按桌面图标 → 速记：热启动靠推送，冷启动靠启动时问一次。
  void _bindCaptureShortcut() {
    ShortcutChannel.onCapture(_goCapture);
    ShortcutChannel.consumePendingCapture().then((pending) {
      if (pending) _goCapture();
    });
  }

  /// 切换底部页签（底部导航每一项都用它，所以"点着切页"只有一个入口）。
  ///
  /// 滑动切页走的是另一条路（`onPageChanged`），两条最终都落到 `_index` 与偏好上。
  void _selectTab(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    widget.app.setLastTab(index);
    // 与指示器同一个时长与曲线：页面滑过去的同时胶囊也滑过去
    _pages.animateToPage(
      index,
      duration: _navSlideDuration,
      curve: Curves.easeOutCubic,
    );
  }

  /// 滑动结束时（或滑过一半时）由 `PageView` 通知：标题、FAB、偏好都跟着走。
  void _onPageChanged(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    widget.app.setLastTab(index);
  }

  /// 切到灵感页并把光标放进输入框 —— 「记一笔」的代价必须足够小。
  void _goCapture() {
    if (!mounted) return;
    setState(() => _index = 0);
    widget.app.setLastTab(0);
    // 用 `jumpToPage` 而不是动画：冷启动时输入框还没建出来，动画会让"聚焦"
    // 晚一帧，抢不到键盘（HyperOS 上实测会被系统丢掉）
    if (_pages.hasClients) _pages.jumpToPage(0);
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
                // 左右滑动切页：四个页签排成一排，滑动时底栏的胶囊跟着走。
                // 每页包一层 `_KeepAlivePage`，切过去再切回来不丢状态
                // （滚动位置、输入到一半的灵感、展开的项目/任务线）。
                child: PageView(
                  controller: _pages,
                  onPageChanged: _onPageChanged,
                  children: <Widget>[
                    _KeepAlivePage(
                      child: InspirationTab(key: _inspirationKey, app: app),
                    ),
                    _KeepAlivePage(child: ProjectTab(app: app)),
                    _KeepAlivePage(child: EventTab(app: app)),
                    _KeepAlivePage(child: MoreTab(app: app)),
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
          // 要"任意宽度 + 两端与外部胶囊同弧 + 能滑动"就只能自己画。
          //
          // 自绘之后全是可控的：选中指示器与一格同宽、圆角 `_navRadius`，
          // 而外部胶囊用的是**同一个** `_navRadius` —— 选中最左 / 最右那格时
          // 两段圆弧完全重合（等宽等径又对齐），中间几格则是一个纯胶囊。
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
                  page: _pageProgress,
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

/// 让 `PageView` 里的一页**活着**。
///
/// 换掉 `IndexedStack` 之后，滑走的页面会被销毁 —— 滚动位置、输入到一半的灵感、
/// 展开的项目树全都丢。`PageView` 支持自动保活，前提是子树里有人要保活，
/// 所以这里包一层最小的 `AutomaticKeepAliveClientMixin`。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 启动告警条（数据文件损坏、从备份恢复之类）。
///
/// 做成**带外边距的卡片**而不是通栏色带（实机反馈："顶部标题栏偶尔背景颜色
/// 不一样"）：通栏色带紧贴在标题栏下面，看着像是标题栏自己变了色；
/// 而且满色的 `errorContainer` 违反"底色一律中性灰"这条主题约定。
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.warning_amber_outlined,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  messages.join('；'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 逾期提醒条。
///
/// 设计文档明确不做推送唤醒（ADR-062），所以"提醒"只能在用户打开 App 时发生：
/// 这条横幅 + 「更多」上的角标，就是这个 App 全部的到期提醒手段。
///
/// 与告警条一样做成卡片：**底部色带贴在标题栏下面会被当成标题栏变色**
/// （实机反馈），而且它的底色也不该跟着主题色跑。
class _DueBanner extends StatelessWidget {
  const _DueBanner({required this.count, required this.app});

  final int count;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHigh,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppShapes.cardRadius),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => DuePage(app: app)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '有 $count 条任务已逾期',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
