import 'package:flutter/material.dart';

/// 清单条目的勾选记号：**一条直线，勾上时下折成对勾**（2026-10-15 用户要求）。
///
/// 口径（用户原话："将清单的圆圈换个表现，用直线，然后下折转为对勾"）：
///
/// ```
/// 未勾             勾上（动画约 180ms）
/// ────      →      ──╲
///                    ╲╱
/// ```
///
/// 形状是**一条线自己折过去**，不是"直线淡出、对勾淡入"：
/// 它的两个端点一直在，只是中段往下沉、右端抬起来 ——
/// 于是未勾时是一条横线，勾上时是同一个折角形成的对勾。
///
/// 三条边界：
///   · **只换记号，不换命中区**：尺寸与原来那个 18 的圆完全相同，
///     调用方（`IconButton` / 整行 `InkWell`）一个像素都不用动；
///   · **初始态不动画**：进页面时已经勾上的条目直接画成对勾，
///     只有"这一帧从不勾变成勾"才播动画（否则打开一页几十条会一起抖）；
///   · **颜色只有两档**：勾上是 `primary`、未勾是 `outline` —— 与其它记号同一套
///     （见 `lib/ui/common/labels.dart` 的 `nodeStatusColor`）。
///
/// 它**不自己处理点击**：点哪里、点了之后写什么，都由调用方决定
/// （事件详情页是那个 24×24 的按钮，任务列表是整行）。
class LineCheckMark extends StatefulWidget {
  const LineCheckMark({
    super.key,
    required this.checked,
    this.size = lineCheckMarkSize,
  });

  /// 勾上没有。
  final bool checked;

  /// 记号的边长（正方形）。默认 [lineCheckMarkSize]。
  final double size;

  @override
  State<LineCheckMark> createState() => _LineCheckMarkState();
}

/// 记号的默认边长：**与原来说明书里那个 18 的圆同尺寸**。
const double lineCheckMarkSize = 18;

/// 某一条清单的勾选记号的 Key。
///
/// **为什么需要它**：这个记号是自绘的（不是 `Icon`），用例没法再靠
/// `find.byIcon(Icons.radio_button_unchecked)` 找到它 —— 而对"清单"这个功能来说，
/// "这一条勾上了没有"正是最该被守住的那一件事。所以给它一个稳定的 Key，
/// 从外面既能点到、也能断言形状（`LineCheckMark.checked`）。
///
/// 与 `taskChecklistRowKeyPrefix` 同一套做法：id 拼在 Key 里，
/// 一行一条不会互相盖住。**不加 `@visibleForTesting`** —— 它同时被 `lib/`
/// 那几处调用点用着（三处清单都要一人一个 Key），加了会让 analyze 报
/// `invalid_use_of_visible_for_testing_member`。
Key lineCheckMarkKey(String itemId) => Key('LineCheckMark.$itemId');

/// 描线动画的时长。比 `expandCollapseDuration`（200ms）略快一点：
/// 勾一条待办是个轻动作，动画比一次展开 / 收起再快一点才不相称。
const Duration lineCheckMarkDuration = Duration(milliseconds: 180);

class _LineCheckMarkState extends State<LineCheckMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: lineCheckMarkDuration,
    // 初值直接给到位：**进页面时不播动画**
    value: widget.checked ? 1 : 0,
  );

  @override
  void didUpdateWidget(LineCheckMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.checked == oldWidget.checked) return;
    if (widget.checked) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _LineCheckPainter(
            progress: _controller.value,
            color: widget.checked ? scheme.primary : scheme.outline,
          ),
        ),
      ),
    );
  }
}

/// 画那一条会折的线。
///
/// 坐标系按**边长归一化**再乘以实际尺寸 —— 于是同一个画笔在 18 与 20 上都成立。
class _LineCheckPainter extends CustomPainter {
  const _LineCheckPainter({required this.progress, required this.color});

  /// 0 = 一条横线（未勾），1 = 一个对勾（已勾）。
  final double progress;

  final Color color;

  /// 线宽按边长取（18 时约 1.6），四角圆头。
  static const double _strokeRatio = 0.09;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = (s * _strokeRatio).clamp(1.2, 2.0);
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 一条线在归一化坐标里的两个端点：
    //   · 未勾：两点都在同一条水平线上（y 相同）⇒ 画出来是一条横线；
    //   · 勾上：折点往下、右端抬起来 ⇒ 画出来是一个对勾。
    // 两段用**同一个** `progress` 线性插值，所以过渡就是那条线自己折过去。
    //
    // 折点是"最终那个对勾的底点"，同时刻意取在**水平线的中点**上 ——
    // 这样线折下去的时候左端不会跟着跑，只有中段在下沉。
    final leftY = _lerp(0.48, 0.40, progress);
    final turnY = _lerp(0.48, 0.76, progress);
    final tipY = _lerp(0.48, 0.26, progress);

    final left = Offset(s * 0.12, s * leftY);
    final turn = Offset(s * 0.50, s * turnY);
    final tip = Offset(s * 0.88, s * tipY);

    canvas.drawLine(left, turn, paint);
    canvas.drawLine(turn, tip, paint);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(_LineCheckPainter old) =>
      old.progress != progress || old.color != color;
}
