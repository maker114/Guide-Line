import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/rules/archive_zone.dart';
import '../platform/data_directory.dart';
import '../platform/shortcut_channel.dart';
import 'common/dialogs.dart';
import 'events/event_tab.dart';
import 'inspiration/inspiration_tab.dart';
import 'more/more_tab.dart';
import 'more/upcoming_page.dart';
import 'nav_icon_motion.dart';
import 'projects/project_tab.dart';
import 'shell_title.dart';
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

/// 底部导航条的**横向内边距**（左右各 20dp）。
///
/// 右下角那个速记胶囊必须与底栏的一格**等宽**，所以它也得按同一个内边距算 ——
/// 这条数只在这里写一次，两边都用它（见 [navCellWidth]）。
const double navHorizontalPadding = 20;

/// 底栏**一格**的宽度 = 选中滑块的宽度 = 速记胶囊的宽度。
///
/// 输入是"扣掉横向内边距之后底栏能用的宽度"：一格 = 可用宽度 / 格数。
/// 速记胶囊与底栏用**同一个函数**算，谁也不许写死像素
/// （2026-09-26 批 B 第 ③ 项）。
double navCellWidth(double availableWidth) =>
    availableWidth / AppBottomNav.itemCount;

/// 滑动时长：切换页签时胶囊从旧位置滑到新位置。
///
/// 收得比上一版（300ms）短：实机反馈"太粘滞、像质量很大"，
/// 主要是尾随边要花小半程去追平 —— 缩短总时长 + 让拉伸提前收回（见
/// [_navStretchAt]）合起来才是"质量小一点"。
const Duration _navSlideDuration = Duration(milliseconds: 220);

/// 拖拽时惯性拉伸的上限（dp）：跳三格也不会拉成一条香肠。
///
/// **原值 12 → 新值 18（×1.5，2026-09-26 批 C 第 ② 项）**。
/// 为什么调大：12 那一版是被"太粘滞、像质量很大"压下来的，但压过头了 ——
/// 拖动时几乎看不出被拖长，用户反馈"感觉不到惯性"。这次只把**幅度**放回一档，
/// 包络形状（峰值靠前半程、后半程提前收）不动，所以不会退回"拖到最后才追平"。
const double navStretchMax = 18;

/// 关闭动画（`MediaQuery.disableAnimations`）时的拉伸上限：**回到原值 12**。
///
/// 无障碍开关打开时，一切"惯性"都该退化成直接到达 —— 拉伸本身就是运动感的一部分。
const double navStretchMaxReduced = 12;

/// 点按切换时指示器那一下的曲线：**过冲更明显，再吸回目标格**。
///
/// `Cubic(0.34, 1.5, 0.64, 1)` 是 `easeOutBack` 的收小版：峰值 ≈ 1.08，
/// 也就是最多多走**行程的 8%**（批 D 第 ② 项：原值 y1 = 1.35 → 峰值 4.1%，
/// 在 360dp 屏上一格 80dp 只多走约 3.3dp，实机"点按感觉不到惯性"）。
///
/// 这里的"行程"是**相邻两格之间**那一段 —— 指示器每次只喂一个区间
/// （`fromIndex` 到 `fromIndex + 1`），跨两格的点按由两段接起来，
/// 所以过冲的**绝对**幅度 ≈ 一格行程的 8%：360dp 屏上一格 80dp → 约 6.4dp，
/// 800dp 测试面上一格 200dp → 约 16dp。**不会**因为跳三格就涨成一大截。
///
/// 为什么不再往上抬：`easeOutBack` 的峰值 ≈ 1.10（y1 = 1.7），落位前多走 10%
/// 行程，一格就多走 8dp，看着像没对准。1.5 这一档是"看得出来"与"像没对准"
/// 之间的位置；若实机上手觉得弹，**只降 y1**（1.45 → 峰值 6.6%）即可，
/// 曲线的 x1 / x2 与收尾形状都不用动。
///
/// 它只作用在**前导边**上，且 `t = 1` 时与 `easeOutCubic` 一样落在目标格 ——
/// 页面翻页（`animateToPage`）与指示器读的是同一个连续页位置，
/// **结束值一致**，所以过冲不会留下错位。
const Curve navTapSettleCurve = Cubic(0.34, 1.5, 0.64, 1);

/// 惯性拉伸量（dp）：随进度**鼓起再收回**。
///
/// `sin(πt)` 负责"两头 0、中间最大"，再乘 `(1 - 0.4t)` 让它在后半程**提前**收 ——
/// 只靠 `sin(πt)` 的话，尾随边会一路拖到最后一两帧才追平，那正是"粘滞"的来源。
///
/// [max] 由调用方给：正常是 [navStretchMax]，关闭动画时是 [navStretchMaxReduced]。
double _navStretchAt(double progress, double max) =>
    max * math.sin(math.pi * progress) * (1 - 0.4 * progress);

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
/// 两个可选开关（2026-09-26 批 C 第 ② 项）：
///   · [tapSettle]：这次位移是**点按**引起的（`animateToPage`），前导边改走
///     [navTapSettleCurve]（明显一点的过冲 + 吸回）。**拖动时不要开** ——
///     手指还在屏幕上，过冲会变成"不跟手"。开了它前导边会短暂越过目标格，
///     所以要用 [barWidth] 夹住，别让它顶到导航条外面。
///   · [stretchMax]：拉伸上限。正常 [navStretchMax]，
///     关闭动画时 [navStretchMaxReduced]。
({double left, double width}) navIndicatorGeometry({
  required double t,
  required double fromLeft,
  required double toLeft,
  required double nominalWidth,
  double stretchMax = navStretchMax,
  bool tapSettle = false,
  double? barWidth,
}) {
  final progress = t.clamp(0.0, 1.0);
  final eased = (tapSettle ? navTapSettleCurve : Curves.easeOutCubic)
      .transform(progress);
  final width = nominalWidth + _navStretchAt(progress, stretchMax);

  // 导航条的右边界：一格宽 × 格数就是栏宽（指示器一直是一格宽）
  final limit = barWidth ?? nominalWidth * AppBottomNav.itemCount;

  if (toLeft >= fromLeft) {
    // 向右：前导边是右边，先到位；宽度长在左边（尾随边落后再追平）
    final right = fromLeft + nominalWidth + (toLeft - fromLeft) * eased;
    // 过冲时右边界会短暂越过目标格；越过**导航条**就不行了（会从外胶囊头顶出来），
    // 所以在这里夹住。跳最后一格时正好顶住端部：过冲退化成"顶到位"。
    final bounded = right > limit ? limit : right;
    return (left: bounded - width, width: width);
  }
  // 向左：前导边是左边，先到位；宽度长在右边
  final left = fromLeft + (toLeft - fromLeft) * eased;
  return (left: left < 0 ? 0 : left, width: width);
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
///
/// [tapSettle]：这次位移是不是**点按**引起的。点按是"隔空"的，
/// 所以让指示器多走一点再过冲吸回（[_navStretchAt] 那套跟手逻辑之外的第二条动效）；
/// 拖动时手指就在屏幕上，任何过冲都会读成"不跟手"，这时必须关掉它。
class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.page,
    required this.onSelect,
    this.overdueCount = 0,
    this.tapSettle = false,
  });

  final ValueListenable<double> page;
  final ValueChanged<int> onSelect;
  final int overdueCount;
  final bool tapSettle;

  /// 底栏有几格。**速记胶囊的宽度也按它算**（见 [navCellWidth]），所以是公开的。
  static const int itemCount = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 无障碍：系统要求关掉动画时，拉伸回到原值、点按不再过冲（见 [navStretchMaxReduced]）
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 指示器与**一格同宽**：最左那格 left = 0、最右那格 right = 栏宽，
        // 两端圆弧于是与外部胶囊完全重合（圆角半径同为 `_navRadius`）。
        // 宽度与速记胶囊共用 [navCellWidth]，两处不会算出不同的数。
        final nominalWidth = navCellWidth(constraints.maxWidth);

        // 指示器跟着 **PageView 的连续页位置**走，而不是自己跑一条动画。
        // 这样"手指拖到一半"与"松手后滑过去"用的是同一个数：
        // 拖拽时它线性跟手，动画时它自带缓动（`animateToPage` 的曲线），
        // 指示器永远不会和页面内容错位。
        return ValueListenableBuilder<double>(
          valueListenable: page,
          builder: (context, value, _) {
            final current = value.clamp(0.0, (itemCount - 1).toDouble());
            final fromIndex = current.floor();
            final toIndex = current.ceil();
            final geometry = navIndicatorGeometry(
              t: current - fromIndex,
              fromLeft: nominalWidth * fromIndex,
              toLeft: nominalWidth * toIndex,
              nominalWidth: nominalWidth,
              stretchMax:
                  reduceMotion ? navStretchMaxReduced : navStretchMax,
              tapSettle: tapSettle && !reduceMotion,
              barWidth: constraints.maxWidth,
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

/// 右下角的**速记胶囊**（自绘，2026-09-26 批 B 第 ③ 项）。
///
/// 形状尺寸与底栏那个"滑块"（`AppBottomNav` 的选中指示器）**一致**：
///    · 高 [_navHeight]（48）；
///    · 圆角 `_navRadius`（= 高度一半，同一个常量，所以两端圆弧同径）；
///    · 宽 = 底栏**一格** —— 底栏在左右各 [navHorizontalPadding] 的内边距里排
///      [AppBottomNav.itemCount] 格，所以一格 = (屏宽 − 40) / 4，
///      用与底栏同一个 [navCellWidth] 算，**不写死像素**。
///
/// 颜色：**实心强调色**（`primary` / `onPrimary`），阴影沿用底栏那层轻阴影。
///
/// 以前这里跟底栏滑块一样取 `secondaryContainer`（= 强调色 22% 透明度），
/// 实机反馈"速记按钮看着是透明的"：那层淡色压在**卡片、列表**上面时几乎看不出来
/// （实测它与页面底的对比度只有 1.9~4.7，深色 + 墨黑主题下只有 1.94），
/// 只有压在底栏那条不透明的白条上才像样。滑块留在底栏内部、周围永远是那条实心底，
/// 所以它保持原样；右下角这颗是浮在内容上的动作入口，必须自己站得住。
/// 前景取 `onPrimary`（按强调色明暗算出的黑或白），对比度由主题保证。
///
/// **放不下就只留图标**：窄屏 + 1.6 倍字体时"图标 + 「速记」"会超过一格宽 ——
/// 这时只画 `Icons.bolt`，但 `tooltip` 与语义标签**始终**是「速记」：
/// 按钮叫什么、点下去干什么，与它此刻多宽无关。
class CapturePillButton extends StatelessWidget {
  const CapturePillButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  /// 与底栏滑块同高（用例按它量"高度 48"）。
  static const double height = _navHeight;

  /// 按钮文字的**唯一出处**：`tooltip`、语义标签、显示出来的字都用它，
  /// 免得三处各写一遍、改一处漏两处。
  static const String label = '速记';

  static const double _iconSize = 22;
  static const double _gap = 6;
  static const double _horizontalPadding = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = navCellWidth(
      MediaQuery.sizeOf(context).width - navHorizontalPadding * 2,
    );
    final showLabel = _labelFits(context, theme, width);
    final foreground = scheme.onPrimary;

    final content = showLabel
        ? Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.bolt, size: _iconSize, color: foreground),
              const SizedBox(width: _gap),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: theme.textTheme.labelLarge?.copyWith(color: foreground),
                ),
              ),
            ],
          )
        : Icon(Icons.bolt, size: _iconSize, color: foreground);

    final pill = SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // 实心强调色：这颗按钮浮在列表 / 卡片上，必须有自己能站得住的底
          color: scheme.primary,
          // 与底栏滑块**同一个** `_navRadius`：48 高时两端就是两个半径 24 的半圆
          borderRadius: BorderRadius.circular(_navRadius),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.10),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        // 水波纹要画在这层 `Material` 上，才会落在底色之上；
        // 用 `MaterialType.transparency` 而不是给一个颜色 —— 颜色只从 `colorScheme` 取。
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            // 胶囊形状的水波纹：圆形的会溢出到按钮外面（`AppShapes.pill` 就是胶囊）
            customBorder: AppShapes.pill,
            child: Center(child: content),
          ),
        ),
      ),
    );

    return showLabel
        ? Tooltip(message: label, child: pill)
        : Semantics(
            label: label,
            button: true,
            child: Tooltip(
              message: label,
              // 只画图标时语义标签由外层 `Semantics` 给，别让工具提示再念一遍
              excludeFromSemantics: true,
              child: pill,
            ),
          );
  }

  /// 一格宽度是否放得下「图标 + 速记」。
  ///
  /// 用 `TextPainter` 按**当前字号缩放**实测，而不是写一个像素阈值：
  /// 要防的正是"窄屏 + 1.6 倍字体"那种情况，写死的数一定会算错。
  bool _labelFits(BuildContext context, ThemeData theme, double width) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: theme.textTheme.labelLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final needed = _horizontalPadding * 2 + _iconSize + _gap + painter.width;
    painter.dispose();
    return needed <= width;
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
  ///
  /// 标题栏（[ShellTitle]）也读它：标题与底栏同一个数、同一条曲线，
  /// 拖动切页时两者节奏才一致。
  final ValueNotifier<double> _pageProgress = ValueNotifier<double>(0);

  /// 这次位移是不是**点按**引起的（`animateToPage` 正在跑）。
  ///
  /// 底栏靠它区分两条路径：点按给一点过冲（"吸住"的收尾感），
  /// 拖动不给（手指就在屏幕上，过冲会显得不跟手）。
  bool _tapAnimating = false;

  /// 点按动画的序号：只有**最后发起的那一次**跑完才许把 [_tapAnimating] 收掉。
  int _tapAnimationId = 0;

  static const List<String> _titles = <String>['灵感', '项目', '事件', '更多'];

  /// 回收站到期清理的提示是否被关掉了。
  ///
  /// 关掉就是关掉（本次运行不再出现）：那是启动时的**维护动作**，
  /// 用户看过一次、表示知道了，就没有理由每次重建界面再念一遍。
  bool _trashNoticeClosed = false;

  /// 第 [index] 页的标题栏文案。
  ///
  /// 项目页与事件页都要**带上数量**（实机反馈「项目   4」）：数量原来在正文第一行
  /// （「共 4 个项目 / 共 2 个事件」），与标题分居两行、白占一行高度。
  ///
  /// 口径（2026-09-26 用户确认）：**只数最外层、已归档的不计、与收起 / 展开无关**。
  /// 项目页数的是"根层有几条"（分类或目标都算一条，分类里面的一律不数）；
  /// 事件页数的是未归档事件数。以前这里取的是"列表里画出来的行数"，
  /// 一收起分类数字就变小 —— 正文那两行计数因此一并去掉了。
  ///
  /// 翻页过渡中会**同时**问两页要标题，所以这点必须按**传进来的页号**算、
  /// 不能读 `_index`：否则过渡中两层写的都是同一页的数。
  String _titleAt(AppController app, int index) {
    switch (index) {
      case 1:
        return '${_titles[1]}   ${rootProjectCount(app)}';
      case 2:
        return '${_titles[2]}   ${visibleEventCount(app)}';
      default:
        return _titles[index.clamp(0, _titles.length - 1)];
    }
  }

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
    // 本次点按的编号：连点两次时，**前一次** `animateToPage` 的 future 会因为被接管
    // 而立刻完成，没有这个号就会把后一次还没跑完的过冲标记提前收掉
    final id = ++_tapAnimationId;
    setState(() {
      _index = index;
      // 点按是"隔空"的：这一程让指示器带一点过冲再吸回目标格（见 [navTapSettleCurve]）
      _tapAnimating = true;
    });
    widget.app.setLastTab(index);
    // 与指示器同一个时长与曲线：页面滑过去的同时胶囊也滑过去
    _pages
        .animateToPage(
          index,
          duration: _navSlideDuration,
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
      // 落位后收掉"点按"标记。这一步重建**不会让胶囊跳一下**：
      // 过冲曲线的终点与常规曲线一致（都正好落在整数格上）。
      if (mounted && _tapAnimationId == id) {
        setState(() => _tapAnimating = false);
      }
    });
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
    setState(() {
      _index = 0;
      // `jumpToPage` 没有位移过程，别把上一次点按的过冲标记留在身上
      //（序号也往后走一格，正在飞的那次点按动画跑完时就不再收标记了）
      _tapAnimationId += 1;
      _tapAnimating = false;
    });
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
            // 标题跟着**连续页位置**走（交叉淡入淡出 + 轻微横移），
            // 与底栏滑块、页面翻页共用同一个数 —— 拖动切页时不再"啪"地换掉。
            // 标题栏其余元素（下面那个只在「更多」页出现的入口）**不跟着动**：
            // 它们仍按整数页号 `_index` 出现 / 消失。
            title: ShellTitle(
              page: _pageProgress,
              pageCount: _titles.length,
              titleAt: (index) => _titleAt(app, index),
            ),
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
                _WarningBanner(
                  messages: app.startupWarnings,
                  onTap: () => _showDataIncident(context, app),
                ),
              // 回收站到期清理（Q12）：清了多少条必须让人看得见 ——
              // 数据被自动删掉却一声不吭，是"损坏永不静默"那条规矩的漏网之鱼。
              if (app.lastTrashPurgedCount > 0 && !_trashNoticeClosed)
                _WarningBanner(
                  messages: <String>[
                    '回收站有 ${app.lastTrashPurgedCount} 条已超过 $trashRetentionDays 天，已自动清除',
                  ],
                  onDismiss: () => setState(() => _trashNoticeClosed = true),
                ),
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
          // 速记按钮（2026-09-26 批 B 第 ③ 项）：**自绘的胶囊**，
          // 形状尺寸与底栏的滑块一致（高 48、圆角 `_navRadius`、宽 = 一格）。
          // 灵感页不显示（那一页整个就是速记）；位置与间距仍交给 `Scaffold`
          // 的 `floatingActionButton` 槽位 —— 它本来就会把按钮抬到底栏**上方**，
          // 不会压住底栏。点击行为不变：切到灵感页并聚焦速记框。
          floatingActionButton: _index == 0
              ? null
              : CapturePillButton(onPressed: _goCapture),
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
            padding: const EdgeInsets.fromLTRB(
              navHorizontalPadding,
              0,
              navHorizontalPadding,
              18,
            ),
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
                  tapSettle: _tapAnimating,
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

  /// 数据事故的详情（Q16）：从哪一份备份恢复的、隔离文件叫什么，以及"先导出一份"。
  ///
  /// 告警条原来只有一行不可点的小字，用户看完最多"哦"一声；而事故之后**最该做的一件事
  /// 恰恰是导出**（那是数据离开这台手机的唯一通道）。所以这里把话说全，
  /// 并且把导出动作直接放在手边。
  Future<void> _showDataIncident(BuildContext context, AppController app) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('数据恢复记录'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final line in app.dataIncidentLines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('· $line'),
                ),
              const SizedBox(height: 6),
              Text(
                '这些文件都在应用私有目录：${app.dataDirectory.path}\n'
                '隔离的原文件不会被覆盖，也不会自动删除；备份仍可在「备份与恢复」里查看。',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              if (app.exportOverdue) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '导出提醒已重新开始计时 —— 出过事故之后，先导出一份最要紧。',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
          // 能点的用胶囊（《界面规范》§2）：`FilledButton` 的默认形状就是胶囊
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final result = await app.exportAndShare();
              if (context.mounted) {
                showToast(context, result.message, error: !result.ok);
              }
            },
            child: const Text('一键导出'),
          ),
        ],
      ),
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

/// 启动告警条（数据文件损坏、从备份恢复、回收站到期清理之类）。
///
/// 做成**带外边距的卡片**而不是通栏色带（实机反馈："顶部标题栏偶尔背景颜色
/// 不一样"）：通栏色带紧贴在标题栏下面，看着像是标题栏自己变了色；
/// 而且满色的 `errorContainer` 违反"底色一律中性灰"这条主题约定。
///
/// 两种交互，按告警的性质给：
///   · 数据事故（损坏 / 恢复）——**整条可点**，点开是"出了什么事、怎么办"，
///     末尾还带一个「一键导出」。只有一行小字时用户能做的顶多是"哦"一声；
///   · 维护提示（回收站清理）——**可关掉**。它没有"下一步动作"，
///     但要让人确认自己看见了。
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.messages, this.onTap, this.onDismiss});

  final List<String> messages;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
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
          if (onDismiss != null)
            IconButton(
              tooltip: '知道了',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: onDismiss,
            )
          else if (onTap != null)
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.outline,
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHigh,
        child: onTap == null
            ? row
            : InkWell(
                borderRadius: BorderRadius.circular(AppShapes.cardRadius),
                onTap: onTap,
                child: row,
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
            MaterialPageRoute<void>(builder: (_) => UpcomingTasksPage(app: app)),
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
