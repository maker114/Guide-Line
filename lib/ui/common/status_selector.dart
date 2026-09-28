import 'package:flutter/material.dart';

import '../theme/shape_tokens.dart';

/// 三态选择（未完成 / 已完成 / 已搁置）的统一外观。
///
/// 四条外观约定来自实机反馈：
///   · **整体是胶囊**，不是带分割线的分段控件 —— 中间**不画竖线**；
///   · **选中项套一个小胶囊**（用主题色的低透明底），一眼看出选的是哪个；
///   · 胶囊本身**略带阴影**，与「目的」等输入栏的观感一致；
///   · **三个选项等宽**，整体撑满可用宽度，所以左右两端到边缘的距离始终相等。
///
/// 刻意不用 `SegmentedButton`：它的默认外观带分隔线、选中态是整块填充，
/// 与这里要的"胶囊里套小胶囊"不是一套东西，改它的 theme 反而更绕。
///
/// **它不只服务三态**（2026-09-28）：全应用需要"少数几个互斥选项"的地方
/// 一律用它 —— 「清单 / 文本」的切换与归档区的三档也是同一个控件，
/// 这样切换控件在哪儿都长一样。传 `stretch: false` 可以让它**按内容宽**排
/// （标题行右侧那种位置不能撑满整行）。
class StatusPillSelector<T> extends StatelessWidget {
  const StatusPillSelector({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    this.stretch = true,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;
  final EdgeInsets padding;

  /// 是否把选项**平分整行宽度**（默认）。
  ///
  /// `false` = 整条只占内容那么多（各选项最宽的那个自然把宽度撑出来），
  /// 给"标题行右侧"这类不能撑满整行的位置用。**不靠 `IntrinsicWidth` 去凑等宽**：
  /// 那会在每一帧多做一次固有尺寸测量，而这些选项的字数本来就相近
  /// （「清单 / 文本」「已归档 / 已处理的灵感 / 回收站」），差几个像素不值得。
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final pills = <Widget>[
      for (final value in values)
        _Pill(
          label: labelOf(value),
          active: value == selected,
          stretch: stretch,
          onTap: () => onSelected(value),
        ),
    ];

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        boxShadow: <BoxShadow>[
          // 轻阴影：只给一点层次，不做"浮起来"的效果
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: stretch
          ? Row(
              children: <Widget>[
                // 等宽 + 平分可用宽度：这样"两端到边缘的距离相等"是布局保证的，
                // 不依赖选项文字长短（"未完成"比"已完成"长一个字，靠内容撑会歪）。
                for (final pill in pills) Expanded(child: pill),
              ],
            )
          : Row(mainAxisSize: MainAxisSize.min, children: pills),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.active,
    required this.onTap,
    this.stretch = true,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      selected: active,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        child: AnimatedContainer(
          // 选中态是"小胶囊滑过去"的观感：底色与文字色都走同一个时长，
          // 160ms 够快不至于拖沓，又不至于闪一下就没了
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: stretch ? 8 : 16,
            vertical: stretch ? 9 : 7,
          ),
          decoration: BoxDecoration(
            color: active ? scheme.primary.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            style: (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
              color: active ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
