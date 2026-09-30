import 'package:flutter/material.dart';

import '../../app/auto_sync_state.dart';
import '../../core/store/github_sync.dart';
import 'diff_colors.dart';

/// 标题栏右侧那枚**自动同步指示器**（handoff #87c57e）。
///
/// 形状自己会说话，不用配文字说明：
///   · 在传 → 一个转动的**缺口圆环**（圆，不是长条：这一格平时很窄，
///     一旦变成条就会推着标题换行）；
///   · 传完了 → 圆环**向左拉伸成胶囊**，变绿，并摆出这次上传的**提交码**；
///   · 没传成 → 胶囊变红，写「未同步」，点一下看原因原话；
///   · 没事 → 整块**不出现**（关着同步、或者比对下来两边一样）。
///
/// 「向左拉伸」是右侧对齐的自然结果：这一格在 `AppBar.actions` 里靠右，
/// 宽度变大只会往左边长，不会把标题推走。宽度变化交给 [AnimatedSize]，
/// 于是看见的是"圆被拉长"，而不是"圆消失、胶囊出现"。
class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key, required this.state, this.onShowReason});

  final AutoSyncState state;

  /// 失败时点一下：把原因原话摆出来。
  ///
  /// 为什么不直接写在胶囊里：标题栏这一格放不下"云端和这台手机都改过……"这种整句话，
  /// 而截断成"同步失败"又恰好丢掉了用户唯一需要知道的东西。
  final VoidCallback? onShowReason;

  /// 指示器高度：26 是"能塞进标题栏又不撑高标题栏"的一档。
  static const double _height = 26;

  /// 圆环的直径（比高度小一圈，转起来才不贴着边）。
  static const double _ringSize = 20;

  @override
  Widget build(BuildContext context) {
    if (state.phase == AutoSyncPhase.idle) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final diff = DiffColors.ofContext(context);
    final running = state.phase == AutoSyncPhase.running;

    final background = switch (state.phase) {
      AutoSyncPhase.running => scheme.surfaceContainerHighest,
      AutoSyncPhase.done => diff.addedBackground,
      AutoSyncPhase.failed => scheme.errorContainer,
      AutoSyncPhase.idle => scheme.surfaceContainerHighest,
    };
    final foreground = switch (state.phase) {
      AutoSyncPhase.running => scheme.primary,
      AutoSyncPhase.done => diff.addedForeground,
      AutoSyncPhase.failed => scheme.onErrorContainer,
      AutoSyncPhase.idle => scheme.primary,
    };
    // 老记账（1.8.5 及以前）没有提交码：那时写「已同步」而不编一个码出来。
    final label = switch (state.phase) {
      AutoSyncPhase.done =>
        state.commitSha.isEmpty ? '已同步' : shortSha(state.commitSha),
      AutoSyncPhase.failed => '未同步',
      _ => '',
    };

    final pill = AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        height: _height,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
          horizontal: running ? (_height - _ringSize) / 2 : 10,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(_height / 2),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: running
              ? SizedBox(
                  key: const ValueKey<String>('ring'),
                  width: _ringSize,
                  height: _ringSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    valueColor: AlwaysStoppedAnimation<Color>(foreground),
                  ),
                )
              : Text(
                  label,
                  key: ValueKey<String>('label-$label'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );

    return Semantics(
      button: state.phase == AutoSyncPhase.failed && onShowReason != null,
      label: switch (state.phase) {
        AutoSyncPhase.running => '正在同步到 GitHub',
        AutoSyncPhase.done => '已同步，提交号 $label',
        AutoSyncPhase.failed => '同步未完成，$label',
        AutoSyncPhase.idle => '',
      },
      child: Padding(
        // 贴着标题栏右边缘不好看，也不好在窄屏上点到。
        padding: const EdgeInsets.only(right: 4),
        child: state.phase == AutoSyncPhase.failed && onShowReason != null
            ? InkWell(
                onTap: onShowReason,
                borderRadius: BorderRadius.circular(_height / 2),
                child: pill,
              )
            : pill,
      ),
    );
  }
}
