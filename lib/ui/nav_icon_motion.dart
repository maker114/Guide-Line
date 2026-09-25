import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 底部导航图标的"点一下"手势。
///
/// 实机反馈：不要统一的缩放弹跳，而是**每个图标有自己的一下** ——
///   · 灯泡亮一下（一圈发散状直线）；
///   · 节点树摇一下（像被碰了一下的树枝，摆两下就停）；
///   · 折线折一下（斜切一下再弹回）；
///   · 三个点转一圈。
///
/// 四种都是**瞬态**的：进度回到 0 时图标与静止时一模一样 ——
/// 所以"动完了"不需要任何收尾状态，也不会在选中与未选中之间留下差异。
enum NavIconMotion { bulbGlow, treeSway, lineFold, dotsSpin }

/// 一次动作的时长。四种手势共用，节奏才统一。
const Duration navIconMotionDuration = Duration(milliseconds: 300);

/// 实心 / 空心图标交叉淡入的时长（比一次动作短，看着像同一件事）。
const Duration navIconSwapDuration = Duration(milliseconds: 160);

/// 灯泡那圈光线的条数与几何（相对图标框的比例，便于随字号缩放）。
///
/// 起点留在灯泡轮廓**外面**一点：贴着描边画会糊成一团，留一线空隙才像"亮起来"。
const int _rayCount = 8;
const double _rayStart = 0.42;
const double _rayFull = 0.60;
const double _rayStroke = 0.075;

/// 按 [motion] 把图标画成"正在动"的样子。
///
/// [animation] 是 `0 → 1` 的一次进度；这个 widget 自己不持控制器 ——
/// 什么时候弹由调用方（点一下、切页时选中）决定。
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
        // 一次来回：0 → 1 → 0，所以峰值出现在动作正中间
        final bump = math.sin(math.pi * progress);
        return switch (motion) {
          NavIconMotion.bulbGlow => _bulb(bump),
          NavIconMotion.treeSway => _sway(progress),
          NavIconMotion.lineFold => _fold(bump),
          NavIconMotion.dotsSpin => _spin(progress),
        };
      },
    );
  }

  /// 灯泡：图标本身朝主题色亮一下，外面一圈直线**发散**出去再淡掉。
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

  /// 折线：斜切加一点压扁 —— 看上去就是那条线被"折"了一下再弹回来。
  Widget _fold(double bump) {
    final matrix = Matrix4.identity()
      ..setEntry(0, 1, 0.34 * bump) // skewX
      ..setEntry(1, 1, 1 - 0.14 * bump); // 轻微压扁
    return Transform(
      transform: matrix,
      alignment: Alignment.center,
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

/// 灯泡外面那圈发散的光线（`NavIconMotion.bulbGlow` 专用）。
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
  static const int rayCount = _rayCount;

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
    for (var i = 0; i < rayCount; i += 1) {
      final angle = -math.pi / 2 + i * 2 * math.pi / rayCount;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(center + direction * from, center + direction * to, paint);
    }
  }

  @override
  bool shouldRepaint(NavBulbRays oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
