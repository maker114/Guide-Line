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
class StatusPillSelector<T> extends StatelessWidget {
  const StatusPillSelector({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
  });

  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

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
      child: Row(
        children: <Widget>[
          for (final value in values)
            // 等宽 + 平分可用宽度：这样"两端到边缘的距离相等"是布局保证的，
            // 不依赖选项文字长短（"未完成"比"已完成"长一个字，靠内容撑会歪）。
            Expanded(
              child: _Pill(
                label: labelOf(value),
                active: value == selected,
                onTap: () => onSelected(value),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

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
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(
            color: active ? scheme.primary.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: active ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
