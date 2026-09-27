import 'package:flutter/material.dart';

import '../theme/shape_tokens.dart';

/// 「已完成的节点被自动收起」那一行的开关。
///
/// 自动收起本身是按实机反馈加的（做完的节点一多，就看不见当前做到哪了），
/// 但**收起来的东西必须能再看回来** —— 实机反馈：想回看前面做完的节点时，
/// 点那一行跳进详情页，详情页又按同一条规则折了一遍，等于没有出路。
/// 所以这里是一个**就地展开**的开关，两边都用它：
///   · 事件列表页：卡里那一行；
///   · 事件详情页：任务线顶部那一行。
///
/// 记号的位置与大小（2026-09-27 实机反馈：调整展开与收起箭头的位置和大小）：
///   · **挪到行尾** —— 行尾是"这里可以展开"的通用位置，而放在文案左边时，
///     图标与文字挤在一起，看着像一句话的开头而不是一个开关；
///   · **15 → 20dp** —— 与任务框那个 `expand_more`（18）以及行尾 ⋮ 的份量对齐，
///     15dp 在 360dp 屏上明显偏小、点不准。
class FoldToggleRow extends StatelessWidget {
  const FoldToggleRow({
    super.key,
    required this.hiddenCount,
    required this.expanded,
    required this.onTap,
    this.compact = false,
  });

  /// 被自动收起的节点数（展开状态下也要显示，用户才知道自己展开了几个）。
  final int hiddenCount;

  /// 当前是不是"已全部展开"。
  final bool expanded;

  final VoidCallback onTap;

  /// 列表页用紧凑版（缩进与任务行对齐）；详情页用常规版。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 40 : 8, 2, 12, compact ? 8 : 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                expanded ? '收起已完成节点' : '另有 $hiddenCount 个已完成节点',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // 与任务框的折叠箭头同一个节奏：转动而不是换图标（`unfold_more`
            // 朝上下，展开时转成收拢那一版）
            Icon(
              expanded ? Icons.unfold_less : Icons.unfold_more,
              size: 20,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}
