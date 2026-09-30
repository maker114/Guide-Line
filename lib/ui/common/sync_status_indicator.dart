import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../app/auto_sync_state.dart';
import '../../core/store/github_sync.dart';
import 'diff_colors.dart';

/// 标题栏右侧那枚**自动同步指示器**（handoff #87c57e；2026-09-30 改成一条连续动画）。
///
/// 形状自己会说话，不用配文字说明（右上角状态表，ADR-093）：
///   · 在传 → 一个转动的**缺口圆环**；
///   · 传完了 → 同一支描边**横向拉长、合口**，成了绿色胶囊，摆出这次上传的
///     **提交码**（7 位短码），停 2 秒再按原路收回圆环并淡出（计时在控制器里）；
///   · 没传成（黄）→ 一样的胶囊形状，写一句短话（「云端有更新」/「GitHub 未连接」），
///     点一下看原因原话；
///   · 真的失败（红）→ 写「未同步」，同样点得动；
///   · 没事 → 整块**不出现**（关着同步、或者比对下来两边一样）。
///
/// 「拉长成一个胶囊」不是"圆消失、胶囊出现"两个动画：**描边只有一条**，
/// [morph] 从 0 到 1 的同时，圆环的缺口慢慢合上、宽度从 [_height] 长到文字宽，
/// 底色也从透明淡入 —— 看见的是同一支笔把圆拉成胶囊。
///
/// 「向左拉伸」是右侧对齐的自然结果：这一格在 `AppBar.actions` 里靠右，
/// 宽度变大只会往左边长，不会把标题推走。
class SyncStatusIndicator extends StatefulWidget {
  const SyncStatusIndicator({super.key, required this.state, this.onShowReason});

  final AutoSyncState state;

  /// 黄/红态点一下：把原因原话摆出来。
  ///
  /// 为什么不直接写在胶囊里：标题栏这一格放不下"云端和这台手机都改过……"这种整句话，
  /// 而截断成"同步失败"又恰好丢掉了用户唯一需要知道的东西。
  final VoidCallback? onShowReason;

  /// 指示器高度（也是圆环那一格的外框边长）：26 是"能塞进标题栏又不撑高标题栏"的一档。
  static const double _height = 26;

  /// 描边粗细 —— 圆环是它，胶囊的边也是它。
  static const double _strokeWidth = 2.4;

  /// 胶囊里文字两侧的留白。
  static const double _sidePadding = 10;

  /// 胶囊最宽到哪：标题栏那一格是借来的，长句必须在这里截断（量宽度与画文字共用）。
  static const double _maxLabelWidth = 108;

  static const Duration _enterDuration = Duration(milliseconds: 180);
  static const Duration _morphDuration = Duration(milliseconds: 280);
  static const Duration _exitDuration = Duration(milliseconds: 200);

  /// 胶囊上写什么（右上角状态表的"显示"那一列）。
  ///
  /// 与颜色一起公开，是为了让界面测试能盯住这张表：形状与文字画在控件里、
  /// 底色画在私有画笔里，测试从外面看不见画笔。
  static String textOf(AutoSyncState state) {
    switch (state.phase) {
      case AutoSyncPhase.done:
        return state.commitSha.isEmpty ? '已同步' : shortSha(state.commitSha);
      case AutoSyncPhase.blocked:
      case AutoSyncPhase.offline:
      case AutoSyncPhase.failed:
        return state.label;
      case AutoSyncPhase.running:
      case AutoSyncPhase.idle:
        return '';
    }
  }

  /// 胶囊底色（ADR-093）：绿 = 传上去了，黄 = 这次没传，红 = 这次真的失败。
  ///
  /// 黄跟差异面板里的"修改"是同一对色（需求③），不新增颜色；红用主题的
  /// `errorContainer`，不自己调一个红。
  static Color backgroundOf(BuildContext context, AutoSyncState state) {
    final scheme = Theme.of(context).colorScheme;
    final diff = DiffColors.ofContext(context);
    switch (state.phase) {
      case AutoSyncPhase.done:
        return diff.addedBackground;
      case AutoSyncPhase.blocked:
      case AutoSyncPhase.offline:
        return diff.modifiedBackground;
      case AutoSyncPhase.failed:
        return scheme.errorContainer;
      case AutoSyncPhase.running:
      case AutoSyncPhase.idle:
        return scheme.surfaceContainerHighest;
    }
  }

  /// 描边色：圆环就是靠它转的，胶囊成形后会留一点透明（不是消失）。
  static Color foregroundOf(BuildContext context, AutoSyncState state) {
    final scheme = Theme.of(context).colorScheme;
    final diff = DiffColors.ofContext(context);
    switch (state.phase) {
      case AutoSyncPhase.done:
        return diff.addedForeground;
      case AutoSyncPhase.blocked:
      case AutoSyncPhase.offline:
        return diff.modifiedForeground;
      case AutoSyncPhase.failed:
        return scheme.onErrorContainer;
      case AutoSyncPhase.running:
      case AutoSyncPhase.idle:
        return scheme.primary;
    }
  }

  @override
  State<SyncStatusIndicator> createState() => _SyncStatusIndicatorState();
}

class _SyncStatusIndicatorState extends State<SyncStatusIndicator>
    with TickerProviderStateMixin {
  /// 出现：0.62 → 1 的缩放 + 淡入（需求②要的"进入动画"）。
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: SyncStatusIndicator._enterDuration,
  );

  /// 成形：0 = 缺口圆环，1 = 合口胶囊。
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: SyncStatusIndicator._morphDuration,
  );

  /// 缺口绕圈（只在"在传"时转）。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// 退场：1 = 还在，0 = 该消失了。
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: SyncStatusIndicator._exitDuration,
    value: 1,
  );

  /// 真正摆出来的那一份状态。
  ///
  /// 与 [SyncStatusIndicator.state] 分开是因为**退场要时间**：控制器两秒后把状态
  /// 打回 `idle`，而这一格还得把"收成圆环 → 淡出"放完，那期间画的是上一份状态。
  late AutoSyncState _shown;

  /// 正在退场（放完才真的换成 [_idle]）。
  bool _leaving = false;

  static const AutoSyncState _idle = AutoSyncState.idle();

  @override
  void initState() {
    super.initState();
    _shown = widget.state;
    _morph.value = _shown.isRunning ? 0 : 1;
    if (_shown.isVisible) {
      _enter.forward(from: 0);
      if (_shown.isRunning) _spin.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant SyncStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state != oldWidget.state) _apply(widget.state);
  }

  @override
  void dispose() {
    _enter.dispose();
    _morph.dispose();
    _spin.dispose();
    _exit.dispose();
    super.dispose();
  }

  /// 状态变了：决定这一格该播哪一段动画。
  void _apply(AutoSyncState next) {
    if (next.phase == AutoSyncPhase.idle) {
      _startLeaving();
      return;
    }
    if (_leaving) {
      // 退场放到一半又有了新状态（比如又点了一次同步）：收回来接着显示。
      _leaving = false;
      _exit.value = 1;
    } else if (next == _shown) {
      return;
    }

    final wasRunning = _shown.isRunning;
    setState(() => _shown = next);
    if (!_enter.isCompleted) _enter.forward(from: 0);
    if (next.isRunning) {
      // 从胶囊回到圆环（重试同步）：原路收回去，缺口再转起来。
      _morph.reverse();
      if (!_spin.isAnimating) _spin.repeat();
      return;
    }
    _spin.stop();
    if (wasRunning) {
      _morph.forward();
    } else if (_morph.value < 1) {
      // 一露面就是胶囊（启动静默比对、或开局就有黄胶囊）：没有圆环那一段。
      _morph.value = 1;
    }
  }

  /// 该消失了：先按原路收回圆环，再淡出 —— 不是"啪"地不见（需求②）。
  void _startLeaving() {
    if (_leaving || !_shown.isVisible) return;
    _leaving = true;
    _spin.stop();
    _morph.reverse().whenComplete(() {
      if (!mounted || !_leaving) return;
      _exit.reverse().whenComplete(() {
        if (!mounted || !_leaving) return;
        setState(() {
          _leaving = false;
          _shown = _idle;
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown.isVisible) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final text = SyncStatusIndicator.textOf(_shown);
    final background = SyncStatusIndicator.backgroundOf(context, _shown);
    final foreground = SyncStatusIndicator.foregroundOf(context, _shown);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: foreground,
      fontWeight: FontWeight.w600,
    );
    final pillWidth =
        _measureLabel(text, labelStyle) + SyncStatusIndicator._sidePadding * 2;
    final tappable = _shown.hasReason && widget.onShowReason != null;

    final pill = TweenAnimationBuilder<double>(
      // 换一句话（黄→绿、两次提交码不同）时宽度自己续着走，不跳。
      // 圆环态那一段不参与：宽度由 morph 从 _height 长上来。
      tween: Tween<double>(
        begin: _shown.isRunning
            ? SyncStatusIndicator._height
            : pillWidth,
        end: pillWidth,
      ),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      builder: (context, targetWidth, _) => AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_enter, _morph, _spin, _exit]),
        builder: (context, _) {
          final morph = _morph.value;
          final width = lerpDouble(SyncStatusIndicator._height, targetWidth, morph)!;
          // 文字在圆环还没拉长之前不出现；拉长到一半开始淡入。
          final textOpacity = morph <= 0.5 ? 0.0 : (morph - 0.5) / 0.5;
          return ClipRect(
            child: SizedBox(
              width: width,
              height: SyncStatusIndicator._height,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RingPillPainter(
                        morph: morph,
                        spin: _spin.value,
                        // 底色随成形淡入：圆环那一段是"没有底色"的。
                        fill: Color.lerp(
                          background.withValues(alpha: 0),
                          background,
                          morph,
                        )!,
                        // 描边同一支笔：圆环画满，胶囊的边留一点透明，不喧宾夺主。
                        stroke: foreground.withValues(alpha: 1 - 0.72 * morph),
                      ),
                    ),
                  ),
                  if (textOpacity > 0.01)
                    Opacity(
                      opacity: textOpacity,
                      child: SizedBox(
                        width: SyncStatusIndicator._maxLabelWidth,
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: labelStyle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    final body = tappable
        ? InkWell(
            onTap: widget.onShowReason,
            borderRadius: BorderRadius.circular(SyncStatusIndicator._height / 2),
            child: pill,
          )
        : pill;

    return Semantics(
      button: tappable,
      label: _semanticsLabel(_shown, text),
      child: Padding(
        // 贴着标题栏右边缘不好看，也不好在窄屏上点到（用户口径：圆环原来偏右）。
        padding: const EdgeInsets.only(right: 10),
        child: Opacity(
          opacity: (_enter.value * _exit.value).clamp(0.0, 1.0),
          child: Transform.scale(
            // 出现时从 0.62 弹到 1，消失时缩到 0.86 —— 两头都不"啪"。
            scale: lerpDouble(0.62, 1, _enter.value)! *
                lerpDouble(0.86, 1, _exit.value)!,
            child: body,
          ),
        ),
      ),
    );
  }

  /// 量一下这句话要占多宽 —— 宽度动画的终点靠它，所以必须与真正画出来的
  /// 那个 [Text] 用同一份样式、同一个宽度上限（否则收尾时会看到胶囊"抽"一下）。
  double _measureLabel(String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return math.min(painter.width, SyncStatusIndicator._maxLabelWidth);
  }

  static String _semanticsLabel(AutoSyncState state, String text) {
    switch (state.phase) {
      case AutoSyncPhase.running:
        return '正在同步到 GitHub';
      case AutoSyncPhase.done:
        return '已同步，提交号 $text';
      case AutoSyncPhase.blocked:
      case AutoSyncPhase.offline:
      case AutoSyncPhase.failed:
        return state.hasReason ? '${state.label}：${state.reason}' : state.label;
      case AutoSyncPhase.idle:
        return '';
    }
  }
}

/// 一条描边画两个形状（需求②）。
///
/// 画的是同一个圆角矩形的轮廓，只差两件事：
///   · 取多长 —— 缺口从 0.72 圈合到整整一圈（[morph] 1 的时候就是胶囊的边）；
///   · 多大的矩形 —— 外框宽度由 [SyncStatusIndicator] 交给它，圆环态是正方形。
/// 所以"圆环拉长成胶囊"是同一支笔的连续动作，不是两个控件交接。
class _RingPillPainter extends CustomPainter {
  const _RingPillPainter({
    required this.morph,
    required this.spin,
    required this.fill,
    required this.stroke,
  });

  final double morph;

  /// 缺口当前转到哪（0..1 圈）。
  final double spin;

  final Color fill;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    // 往里收半个描边宽：描边是骑在路径上的，不收就会被外框裁掉半条。
    const inset = SyncStatusIndicator._strokeWidth / 2;
    final width = math.max(0.0, size.width - inset * 2);
    final height = math.max(0.0, size.height - inset * 2);
    final rect = Rect.fromLTWH(inset, inset, width, height);
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(height / 2),
    );

    if (fill.a > 0) {
      canvas.drawRRect(rrect, Paint()..color = fill);
    }

    final metric = (Path()..addRRect(rrect)).computeMetrics().first;
    final total = metric.length;
    if (total <= 0) return;
    final sweep = total * lerpDouble(0.72, 1, morph)!;
    final begin = total * spin;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = SyncStatusIndicator._strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = stroke;

    final head = metric.extractPath(begin, math.min(begin + sweep, total));
    canvas.drawPath(head, paint);
    // 绕过头了就把剩下的那截补上（合口成胶囊时必然走到这里）。
    final overflow = begin + sweep - total;
    if (overflow > 0) canvas.drawPath(metric.extractPath(0, overflow), paint);
  }

  @override
  bool shouldRepaint(covariant _RingPillPainter old) =>
      old.morph != morph ||
      old.spin != spin ||
      old.fill != fill ||
      old.stroke != stroke;
}
