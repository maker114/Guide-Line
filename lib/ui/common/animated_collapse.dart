import 'package:flutter/material.dart';

/// 全应用统一的**展开 / 收起动画时长**。
///
/// 180ms 与事件详情页折叠箭头那一个的 `_foldDuration` 同一个数 ——
/// 箭头转 180° 与内容长出来同步收尾，看着才是"一件事"。
const Duration expandCollapseDuration = Duration(milliseconds: 180);

/// 展开 / 收起的**共用动画壳**（2026-09-28 实机反馈：给所有展开收起动作加动画）。
///
/// 四处都在用它：多选动作条、分类页展开区的清单、任务框下的子任务、输入框的展开。
/// 抽出来是因为"展开顺不顺"是**一种感觉**：各处各写一个时长与曲线，
/// 用户就会觉得有的地方跟手、有的地方粘。
///
/// 做法是 `AnimatedSize`（高度）+ `AnimatedSwitcher`（交叉淡入）：
///   · **高度**从 0 长到内容高，`alignment: topCenter` 让它从顶上往下长；
///   · **淡入**一起走 —— 只长高度会像"抽屉被拉开一条缝"，配一点透明度才像"出现"；
///   · 外面套 `ClipRect`：动画中途子内容可能比可视区高，不裁会溢出到下面的行上。
class AnimatedCollapse extends StatelessWidget {
  const AnimatedCollapse({
    super.key,
    required this.expanded,
    required this.child,
  });

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: expandCollapseDuration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: expandCollapseDuration,
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          // 默认的切换是"新旧同时缩放"，在高度变化上会打架；这里只要交叉淡入，
          // 高度交给外层 `AnimatedSize`
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[...previousChildren, ?currentChild],
          ),
          child: expanded
              ? KeyedSubtree(key: const ValueKey<String>('shown'), child: child)
              : const SizedBox.shrink(key: ValueKey<String>('hidden')),
        ),
      ),
    );
  }
}
