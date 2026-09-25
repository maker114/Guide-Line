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
            Icon(
              expanded ? Icons.unfold_less : Icons.unfold_more,
              size: 15,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                expanded
                    ? '收起已完成节点'
                    : '另有 $hiddenCount 个已完成节点（点开看全过程）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
