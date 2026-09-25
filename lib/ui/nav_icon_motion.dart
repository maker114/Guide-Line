import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 底部导航图标的"点一下"手势。
///
/// 实机反馈：不要统一的缩放弹跳，而是**每个图标有自己的一下** ——
///   · 灯泡亮一下（**只在上半圈**发散几条直线）；
///   · 节点树摇一下（像被碰了一下的树枝，摆两下就停）；
///   · 折线走一遍（从一个点开始连线，一路走完三个点）；
///   · 三个点转一圈。
///
/// 每种手势都声明自己"静止时是什么样"（[restProgress]）：前三种是"归于无"，
/// 折线是"画满" —— 这样动画播完不需要任何收尾逻辑，
/// 图标也不会在选中与未选中之间留下差异。
enum NavIconMotion {
  /// 灯泡：进度 0 = 不画光线。
  bulbGlow(restProgress: 0),

  /// 节点树：进度 0 = 不偏不斜。
  treeSway(restProgress: 0),

  /// 折线：进度 **1** = 完整图形（静止的样子），0 = 只剩起点的那个点。
  lineTrace(restProgress: 1),

  /// 三个点：进度 0 = 没转过。
  dotsSpin(restProgress: 0);

  const NavIconMotion({required this.restProgress});

  /// 一次动作**播完后停在哪** —— 也就是"静止时是什么样子"。
  final double restProgress;
}

/// 一次动作的时长。四种手势共用，节奏才统一。
const Duration navIconMotionDuration = Duration(milliseconds: 300);

/// 实心 / 空心图标交叉淡入的时长（比一次动作短，看着像同一件事）。
const Duration navIconSwapDuration = Duration(milliseconds: 160);

/// 灯泡光线的几何（相对图标框短边的比例，便于随字号缩放）。
///
///   · 起点留在灯泡轮廓**外面**一点：贴着描边画会糊成一团；
///   · 长度取得短 —— 这是"亮一下"，不是"放光芒"；
///   · **只有上半圈**（角度在 `-180° ~ 0°` 之间，屏幕坐标 y 向下），
///     灯泡的灯座在下半圈，那里也发光就不像灯泡了。
const double _rayStart = 0.44;
const double _rayFull = 0.57;
const double _rayStroke = 0.07;

/// 上半圈光线的角度（弧度，`-π/2` 是正上方）。
final List<double> _rayAngles = <double>[
  for (final degrees in <double>[-160, -125, -90, -55, -20]) degrees * math.pi / 180,
];

/// 按 [motion] 把图标画成"正在动"的样子。
///
/// [animation] 是 `restProgress → 1` 的一次进度；这个 widget 自己不持控制器 ——
/// 什么时候播由调用方（选中某一项时）决定。
class NavIconMotionView extends StatelessWidget {
  const NavIconMotionView({
    super.key,
    required this.motion,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.color,
    required this.flashColor,
    required this.animation,
    this.size = 22,
  });

  final NavIconMotion motion;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final Color color;

  /// "亮一下"用的高亮色（主题色）。
  final Color flashColor;

  final Animation<double> animation;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final progress = animation.value.clamp(0.0, 1.0);
        return switch (motion) {
          // 一次来回：0 → 1 → 0，所以"最亮"出现在动作正中间
          NavIconMotion.bulbGlow => _bulb(math.sin(math.pi * progress)),
          NavIconMotion.treeSway => _sway(progress),
          NavIconMotion.lineTrace => _trace(progress),
          NavIconMotion.dotsSpin => _spin(progress),
        };
      },
    );
  }

  /// 灯泡：图标朝主题色亮一下，**上半圈**发散几条短线再淡掉。
  Widget _bulb(double bump) {
    return Stack(
      alignment: Alignment.center,
      // 光线要画到图标框外面一点，所以不能裁；`Positioned.fill` 让它不占额外布局
      clipBehavior: Clip.none,
      children: <Widget>[
        _glyph(color: Color.lerp(color, flashColor, 0.9 * bump)!),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: NavBulbRays(progress: bump, color: flashColor),
            ),
          ),
        ),
      ],
    );
  }

  /// 节点树：像被碰了一下的树枝 —— **摆两下就停**（振幅随时间衰减）。
  ///
  /// 用衰减的正弦而不是单次缩放：单次缩放就是"弹一下"，四个图标全一个动作；
  /// 摆动的方向、频率与另外三个都不一样，一眼能认出是哪个图标在动。
  Widget _sway(double progress) {
    final swing = math.sin(2 * math.pi * progress) * (1 - progress);
    return Transform.translate(
      offset: Offset(2.2 * swing, 0),
      child: Transform.rotate(
        angle: 0.12 * swing,
        child: _glyph(color: color),
      ),
    );
  }

  /// 折线：**从一个点开始连线，一路走完三个点**。
  ///
  /// 用的是"沿水平方向逐步揭开真图标"，而不是自己画一条折线：
  /// 图标里那三个点在横向上本来就是依次排开的，揭开的过程自然读成"连线走过去"，
  /// 而且静止时显示的就是那个真正的 Material 图标 —— 自绘迟早会和旁边的图标
  /// 不是一套（粗细、端点、比例都得对一遍）。
  Widget _trace(double progress) {
    return ClipRect(
      clipper: NavIconRevealClipper(
        // 留一线起点：进度 0 时先露出最左边那个"点"，再开始连线
        reveal: 0.16 + 0.84 * progress.clamp(0.0, 1.0),
      ),
      child: _glyph(color: color),
    );
  }

  /// 三个点：绕中心转一整圈（转 180° 是看不出来的 —— 一排点转过去还是那一排）。
  Widget _spin(double progress) {
    return Transform.rotate(
      angle: 2 * math.pi * Curves.easeInOut.transform(progress),
      child: _glyph(color: color),
    );
  }

  /// 实心 / 空心两版图标交叉淡入（切换选中态时不要"啪"地换掉）。
  Widget _glyph({required Color color}) {
    return AnimatedSwitcher(
      duration: navIconSwapDuration,
      child: Icon(
        selected ? selectedIcon : icon,
        // key 让 `AnimatedSwitcher` 知道"换图标了"
        key: ValueKey<bool>(selected),
        size: size,
        color: color,
      ),
    );
  }
}

/// 「折线走一遍」用的揭开裁剪：只露左边 [reveal] 比例的部分。
///
/// [reveal] 为 1 就是完整图形（静止状态），所以它既是动画也是静态形态。
class NavIconRevealClipper extends CustomClipper<Rect> {
  const NavIconRevealClipper({required this.reveal});

  final double reveal;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * reveal.clamp(0.0, 1.0), size.height);

  @override
  bool shouldReclip(NavIconRevealClipper oldClipper) =>
      oldClipper.reveal != reveal;
}

/// 灯泡上半圈那几条发散的光线（`NavIconMotion.bulbGlow` 专用）。
///
/// [progress] 是 `sin(πt)`：`0` 表示不画（静止），峰值时最长最亮 ——
/// 所以"亮一下"结束之后画布上什么都不剩。
class NavBulbRays extends CustomPainter {
  const NavBulbRays({required this.progress, required this.color});

  final double progress;
  final Color color;

  /// 相对图标框短边的起点半径 / 长度 / 线宽。
  static const double startRatio = _rayStart;
  static const double fullRatio = _rayFull;
  static const double strokeRatio = _rayStroke;

  /// 光线的角度（弧度）：**只有上半圈**（负角度 = 屏幕坐标里往上）。
  static List<double> get rayAngles => List<double>.unmodifiable(_rayAngles);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final center = size.center(Offset.zero);
    final side = size.shortestSide;
    final paint = Paint()
      ..color = color.withValues(alpha: progress.clamp(0.0, 1.0))
      ..strokeWidth = side * strokeRatio
      ..strokeCap = StrokeCap.round;

    final from = side * startRatio;
    final to = side * (startRatio + (fullRatio - startRatio) * progress);
    for (final angle in _rayAngles) {
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(center + direction * from, center + direction * to, paint);
    }
  }

  @override
  bool shouldRepaint(NavBulbRays oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
